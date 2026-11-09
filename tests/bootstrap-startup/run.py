#!/usr/bin/env python3
"""B3 real engine/socket and actual daemon+proc-fixture experiments, not a model."""
import contextlib
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tests/xray-ready'))
from lifecycle import Fixture, wait_for

passed = 0
ONLY = os.environ.get('B3_CASE')
ENV = dict(os.environ, LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib'))
ENGINES = [HERE / '.build/source/target/release/aether-dns',
           Path('/workspace/openwrt/ci-spike/tools/chinadns-ng-2025.08.09/chinadns-ng')]


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS ', label, flush=True)


class Authority:
    """Controlled A/IN UDP/TCP authority; no resolver or lifecycle substitution."""
    def __init__(self, ip='192.0.2.17', negative=False, silent=False, port=0):
        self.ip, self.negative, self.silent = ip, negative, silent
        self.requests = []
        self.done = threading.Event()
        # T15.9: UDP and TCP have separate port spaces; this is bounded
        # trial allocation, not an atomic reservation across both protocols.
        for attempt in range(16):
            self.udp = self.tcp = None
            binding = False
            try:
                self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                binding = True
                self.udp.bind(('127.0.0.1', port))
                binding = False
                selected = self.udp.getsockname()[1]
                binding = True
                self.tcp.bind(('127.0.0.1', selected))
                self.tcp.listen()
            except BaseException as error:
                for resource in (self.udp, self.tcp):
                    if resource is not None:
                        resource.close()
                # Only bind/listen contention may choose another dynamic port.
                # Fixed endpoints (including the impostor control) never move.
                if (binding and port == 0 and isinstance(error, OSError) and
                        error.errno == errno.EADDRINUSE and attempt < 15):
                    continue
                raise
            break
        self.port = selected
        try:
            self.thread = threading.Thread(target=self.serve)
            self.thread.start()
        except BaseException:
            self.udp.close()
            self.tcp.close()
            raise

    def serve(self):
        while not self.done.is_set():
            for sock in select.select([self.udp, self.tcp], [], [], .03)[0]:
                peer = None
                try:
                    if sock is self.tcp:
                        peer, _ = sock.accept()
                        peer.settimeout(.5)
                        prefix = peer.recv(2)
                        if len(prefix) != 2:
                            continue
                        size = struct.unpack('!H', prefix)[0]
                        packet = b''
                        while len(packet) < size:
                            chunk = peer.recv(size - len(packet))
                            if not chunk:
                                break
                            packet += chunk
                    else:
                        packet, address = sock.recvfrom(65535)
                    end, labels = 12, []
                    while packet[end]:
                        n = packet[end]
                        labels.append(packet[end + 1:end + 1 + n].decode())
                        end += n + 1
                    assert packet[end + 1:end + 5] == b'\x00\x01\x00\x01'
                    self.requests.append((sock is self.tcp, '.'.join(labels), time.monotonic()))
                    if self.silent:
                        continue
                    answer = packet[:2] + struct.pack('!5H', 0x8183 if self.negative else 0x8180,
                                                    1, 0 if self.negative else 1, 0, 0) + packet[12:end + 5]
                    if not self.negative:
                        answer += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + socket.inet_aton(self.ip)
                    if peer is None:
                        sock.sendto(answer, address)
                    else:
                        peer.sendall(struct.pack('!H', len(answer)) + answer)
                except (OSError, IndexError):
                    if not self.done.is_set():
                        raise
                finally:
                    if peer is not None:
                        peer.close()

    def close(self):
        self.done.set()
        self.thread.join(timeout=2)
        self.udp.close()
        self.tcp.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def driver_command(spec, modules=None):
    if modules:
        command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(modules / '*.uc'),
                   '-L', str(ROOT / 'tests/host/prefix/lib/ucode/*.so')]
    else:
        command = [str(ROOT / 'tests/host/ucode')]
    return command + [str(HERE / 'driver.uc'), '--', json.dumps(spec)]


def records(text):
    found = []
    while 'RESULT ' in text:
        text = text.split('RESULT ', 1)[1]
        value, end = json.JSONDecoder().raw_decode(text)
        found.append(value)
        text = text[end:]
    return found


def run_driver(spec, modules=None, timeout=20):
    result = subprocess.run(driver_command(spec, modules), env=ENV, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise AssertionError(f'driver exited {result.returncode}: {result.stdout}\n{result.stderr}')
    result.records = records(result.stdout)
    assert result.records, (result.stdout, result.stderr)
    return result.records


def module_copy(base, filename, old, new):
    modules = base / 'modules'
    shutil.copytree(ROOT / 'aether-proxy/src/lib', modules / 'aetherproxy')
    path = modules / 'aetherproxy' / filename
    text = path.read_text()
    assert text.count(old) == 1, old
    path.write_text(text.replace(old, new))
    return modules


def lifecycle_alive(pid, starttime):
    path = Path(f'/proc/{pid}/stat')
    if not path.exists():
        return False
    fields = path.read_text().rsplit(')', 1)[1].split()
    return fields[0] not in ('Z', 'X') and fields[19] == str(starttime)


def empty_generations(directory):
    parent = directory / 'bootstrap'
    return not parent.exists() or not list(parent.iterdir())


def real_engines(base):
    for ordinal, engine in enumerate(ENGINES):
        info = subprocess.check_output([str(engine), '-V'], text=True, stderr=subprocess.STDOUT)
        print('ENGINE', engine.name, hashlib.sha256(engine.read_bytes()).hexdigest(), info.splitlines()[0], flush=True)
        for tcp in (False, True):
            run = base / f'engine-{ordinal}-{tcp}'
            run.mkdir()
            sentinel = run / 'external'
            sentinel.write_bytes(b'not-owned\0')
            with Authority() as authority:
                spec = dict(dir=str(run), engine=str(engine), repeat=3,
                            upstream=f'{"tcp://" if tcp else "udp://"}127.0.0.1#{authority.port}')
                values = run_driver(spec)
                final = values[-1]
                check(all(r['value']['ip'] == authority.ip and r['value']['source'] == 'dns' and
                          r['end']['ok'] and r['again']['ok'] and r['gone'] for r in final['results']),
                      f'C12 real {engine.name} {tcp=} production bootstrap+B1 stop and idempotence')
                check(final['before'] == final['after'] and empty_generations(run),
                      f'C6 real {engine.name} repeated callback-confirmed cleanup stable FD no files')
                selected = all(r[0] == tcp and r[1] == 'node.startup.test' for r in authority.requests)
                check(authority.requests and selected,
                      f'C2 real {engine.name} selected upstream protocol and only node queries')
                check(sentinel.read_bytes() == b'not-owned\0', f'C6 real {engine.name} external file unchanged')
        with Authority() as china, Authority('192.0.2.22') as direct:
            for enabled in (False, True):
                run = base / f'select-{ordinal}-{enabled}'
                run.mkdir()
                old = (len(china.requests), len(direct.requests))
                value = run_driver(dict(action='resolve', dir=str(run), engine=str(engine), direct=enabled,
                    china=[f'udp://127.0.0.1#{china.port}'], direct_dns=[f'tcp://127.0.0.1#{direct.port}']))[-1]
                check(value.get('ip') == (direct.ip if enabled else china.ip) and
                      (len(china.requests) == old[0] if enabled else len(direct.requests) == old[1]),
                      f'C2 real {engine.name} frozen china/direct selection {enabled=}')
        run = base / f'literal-{ordinal}'
        run.mkdir()
        result = run_driver(dict(action='resolve', dir=str(run), engine='/nonexistent-engine', address='192.0.2.8'))[-1]
        check(result.get('source') == 'literal' and empty_generations(run),
              'C1 literal has zero bootstrap even without engine')
        run = base / f'save-failure-{ordinal}'
        (run / 'state/node-ip.json').mkdir(parents=True)
        with Authority() as authority:
            value = run_driver(dict(action='resolve', dir=str(run), engine=str(engine),
                upstream=f'127.0.0.1#{authority.port}'))[-1]
            check(not value['ok'] and len(authority.requests) == 1 and empty_generations(run),
                  f'C3 real {engine.name} LKG save failure not reported as DNS success')
        for negative, cached in ((False, True), (True, True), (True, False)):
            run = base / f'lkg-{ordinal}-{negative}-{cached}'
            state = run / 'state'
            state.mkdir(parents=True)
            if cached:
                (state / 'node-ip.json').write_text(json.dumps({'nodes': {'node.startup.test': '192.0.2.99'}}))
            with Authority(negative=negative) as authority:
                value = run_driver(dict(action='resolve', dir=str(run), engine=str(engine),
                    upstream=f'127.0.0.1#{authority.port}'))[-1]
                check((value.get('source') == ('lkg' if negative else 'dns') if cached else not value['ok']) and
                      (len(authority.requests) == 3 if negative else len(authority.requests) >= 1),
                      f'C3 real {engine.name} DNS-first three failures before LKG {negative=} {cached=}')
        run = base / f'unconfirmed-{ordinal}'
        run.mkdir()
        with Authority() as authority:
            value = run_driver(dict(action='unconfirmed', dir=str(run), engine=str(engine),
                upstream=f'127.0.0.1#{authority.port}'))[-1]
            check(not value['ok'] and value['callback'] and value['record_retained'] and
                  4900 <= value['elapsed_ms'] < 6000,
                  'C6 withheld-exit-callback fixture bounded failure preserves generation')
            check(run_driver(dict(action='recover', dir=str(run)))[-1]['ok'] and empty_generations(run),
                  'C8 confirmed old lifecycle disappearance permits owned cleanup without signals')


def real_cancellation(base):
    for index, engine in enumerate(ENGINES):
        run = base / f'real-cancel-{index}'
        run.mkdir()
        with Authority(silent=True) as upstream:
            p = subprocess.Popen(driver_command(dict(action='resolve', dir=str(run), engine=str(engine),
                upstream=f'127.0.0.1#{upstream.port}')), env=ENV, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                wait_for(lambda: bool(upstream.requests))
                at = time.monotonic()
                p.terminate()
                output, error = p.communicate(timeout=8)
                value = records(output)[-1]
                check(p.returncode == 0 and value.get('cancelled') and value['before'] == value['after'] and
                      time.monotonic() - at < 2 and empty_generations(run) and
                      not (run / 'state/node-ip.json').exists(),
                      f'C7 real {engine.name} SIGTERM cancels B1 and stops child with stable FD no cache')
            finally:
                if p.poll() is None:
                    p.terminate()
                p.communicate(timeout=8)


def loss_during_query(base):
    run = base / 'lost-query'
    run.mkdir()
    with Authority(silent=True) as upstream:
        spec = dict(action='resolve', dir=str(run), engine=str(ENGINES[0]),
                    upstream=f'127.0.0.1#{upstream.port}')
        p = subprocess.Popen(driver_command(spec), env=ENV, text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            wait_for(lambda: len(upstream.requests) > 0)
            owner = next((run / 'bootstrap').glob('*/owner.json'))
            record = json.loads(owner.read_text())
            pid = record['process']['pid']
            assert lifecycle_alive(pid, record['process']['starttime'])
            assert record['argv'][2] in Path(f'/proc/{pid}/cmdline').read_bytes().decode().split('\0')
            port = int(next(line.split()[1] for line in record['config_text'].splitlines()
                            if line.startswith('bind-port ')))
            os.kill(pid, signal.SIGKILL)
            wait_for(lambda: not lifecycle_alive(pid, record['process']['starttime']))
            with Authority(ip='192.0.2.99', port=port) as impostor:
                output, error = p.communicate(timeout=4)
                value = records(output)[-1]
                check(p.returncode == 0 and not value['ok'] and value.get('fatal') and
                      not impostor.requests and not (run / 'state/node-ip.json').exists() and empty_generations(run),
                      'C5 child lost during actual lookup cannot query replacement endpoint or cache impostor')
        finally:
            if p.poll() is None:
                p.terminate()
            p.communicate(timeout=8)


def ignored_term(base):
    work = base / 'ignored-term'
    work.mkdir()
    engine = work / 'engine'
    engine.write_text('''#!/usr/bin/python3
from pathlib import Path
import signal, socket, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
text = Path(sys.argv[sys.argv.index('-C') + 1]).read_text()
port = int(next(line.split()[1] for line in text.splitlines() if line.startswith('bind-port ')))
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
udp.bind(('127.0.0.1', port))
tcp.bind(('127.0.0.1', port))
tcp.listen()
while True:
    time.sleep(.01)
''')
    engine.chmod(0o755)
    run = work / 'run'
    run.mkdir()
    p = subprocess.Popen(driver_command(dict(action='hold', dir=str(run), engine=str(engine),
        upstream='127.0.0.1#40000')), env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        output, deadline, first = '', time.monotonic() + 5, None
        while time.monotonic() < deadline and first is None:
            if select.select([p.stdout], [], [], .1)[0]:
                output += os.read(p.stdout.fileno(), 65536).decode()
                try:
                    first = records(output)[0]
                except (json.JSONDecodeError, IndexError):
                    pass
        assert first is not None and first.get('started'), output
        p.terminate()
        time.sleep(.2)
        check(lifecycle_alive(first['pid'], first['record']['process']['starttime']) and
              (Path(first['path']) / 'owner.json').exists(),
              'C6 actual TERM-ignoring child keeps identity until exit instead of trusting successful kill')
        output, error = p.communicate(timeout=4)
        result = records(output.decode())[-1]
        check(p.returncode == 0 and result['results'][0]['end']['ok'] and empty_generations(run) and
              not Path(f'/proc/{first["pid"]}').exists(),
              'C6 existing supervisor KILL upgrade confirms actual callback before deleting ignored-TERM resources')
    finally:
        if p.poll() is None:
            p.terminate()
        p.communicate(timeout=8)


def parallel_crash(base):
    processes = []
    with Authority() as authority:
        try:
            for i in range(2):
                run = base / f'parallel-{i}'
                run.mkdir()
                p = subprocess.Popen(driver_command(dict(action='hold', dir=str(run), engine=str(ENGINES[0]),
                    upstream=f'127.0.0.1#{authority.port}')), env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                processes.append((p, run))
                output, deadline = '', time.monotonic() + 5
                first = None
                while time.monotonic() < deadline and first is None:
                    if select.select([p.stdout], [], [], .1)[0]:
                        output += os.read(p.stdout.fileno(), 65536).decode()
                        try:
                            first = records(output)[0]
                        except (json.JSONDecodeError, IndexError):
                            pass  # Wait for this real driver's complete JSON publication.
                assert first is not None and first.get('started'), output
                children = Path(f'/proc/{p.pid}/task/{p.pid}/children').read_text().split()
                check(children == [str(first['pid'])] and
                      {v.name for v in Path(first['path']).iterdir()} ==
                      {'owner.json', 'bootstrap.conf', 'aether-bootstrap-dns.pid'},
                      'C6 private generation owns exactly one engine child and no FIFO reader')
                processes[-1] = (p, run, first)
            a, b = processes
            os.kill(a[2]['pid'], signal.SIGKILL)
            wait_for(lambda: not Path(f'/proc/{a[2]["pid"]}').exists())
            time.sleep(5.2)
            check(not (Path(a[2]['path']) / 'aether-bootstrap-dns.pid').exists(),
                  'C6 actual unexpected private SIGKILL has no automatic respawn after formal backoff')
            def query_other():
                endpoint = b[2]['endpoint']
                name = b'\x04node\x07startup\x04test\x00'
                request = b'\x12\x34\x01\x00\x00\x01' + b'\x00' * 6 + name + b'\x00\x01\x00\x01'
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                    client.settimeout(1)
                    client.sendto(request, (endpoint['address'], endpoint['port']))
                    response, _ = client.recvfrom(65535)
                    return response[-4:] == socket.inet_aton(authority.ip)
            check(query_other(), 'C6 another same-engine private instance still resolves after first crashes')
            a[0].terminate()
            a[0].communicate(timeout=8)
            check(a[0].returncode == 0 and empty_generations(a[1]) and query_other(),
                  'C6 first stop deletes only its generation and leaves sibling socket alive')
        finally:
            for entry in processes:
                p = entry[0]
                if p.poll() is None:
                    p.terminate()
                p.communicate(timeout=8)
                check(p.returncode == 0, 'C6 resource driver waits and exits after real child callback')


def unconfirmed(base):
    run = base / 'withheld-callback'
    run.mkdir()
    with Authority() as authority:
        value = run_driver(dict(action='unconfirmed', dir=str(run), engine=str(ENGINES[0]),
            upstream=f'127.0.0.1#{authority.port}'))[-1]
        check(not value['ok'] and value['callback'] and value['record_retained'] and
              4900 <= value['elapsed_ms'] < 6000,
              'C6 withheld-exit-callback fixture bounded failure preserves generation')
        check(run_driver(dict(action='recover', dir=str(run)))[-1]['ok'] and empty_generations(run),
              'C8 confirmed old lifecycle disappearance permits owned cleanup without signals')


def fixture_failures(base):
    engine = ENGINES[0]
    with Authority() as occupied, Authority() as upstream:
        work = base / 'collision'
        work.mkdir()
        needle = '\t\tlet selected = candidate();'
        modules = module_copy(work, 'bootstrap.uc', needle,
            f"\t\tlet selected = attempt == 0 ? {{ ok: true, endpoint: {{ address: '127.0.0.1', "
            f"port: {occupied.port} }} }} : candidate();")
        run = work / 'run'
        run.mkdir()
        value = run_driver(dict(dir=str(run), engine=str(engine), upstream=f'127.0.0.1#{upstream.port}'), modules)[-1]
        if 'results' not in value:
            print('COLLISION DEBUG', value, flush=True)
        resolved = value.get('results', [{}])[0].get('value', {}).get('ip')
        check(resolved == upstream.ip and empty_generations(run) and not occupied.requests,
              'C5 real occupied first candidate not accepted and reaped before second candidate')
    for cached in (False, True):
        run = base / f'partial-ready-{cached}'
        (run / 'state').mkdir(parents=True)
        if cached:
            (run / 'state/node-ip.json').write_text(json.dumps({'nodes': {'node.startup.test': '192.0.2.99'}}))
        at = time.monotonic()
        value = run_driver(dict(action='resolve', dir=str(run), engine=str(HERE / 'tcp-only.py'),
            upstream='127.0.0.1#40000'))[-1]
        check(4.9 <= time.monotonic() - at < 7 and empty_generations(run) and
              (value.get('source') == 'lkg' if cached else not value['ok']),
              f'C3 runtime missing-UDP begin failure safely cleaned before LKG outcome {cached=}')
    with Authority() as occupier:
        work = base / 'candidate-cap'
        work.mkdir()
        modules = module_copy(work, 'bootstrap.uc', '\t\tlet selected = candidate();',
            f"\t\tlet selected = {{ ok: true, endpoint: {{ address: '127.0.0.1', port: {occupier.port} }} }};")
        forks = work / 'forks'
        wrapper = work / 'engine'
        wrapper.write_text(f'''#!/bin/sh
if [ -s '{forks}' ]; then
    while IFS= read -r previous; do
        if [ -d "/proc/$previous" ]; then printf 'UNREAPED\\n' >> '{work / 'violation'}'; fi
    done < '{forks}'
fi
printf '%s\\n' "$$" >> '{forks}'
exec '{engine}' "$@"
''')
        wrapper.chmod(0o755)
        run = work / 'run'
        run.mkdir()
        at = time.monotonic()
        spec = dict(action='resolve', dir=str(run), engine=str(wrapper), upstream='127.0.0.1#40000')
        value = run_driver(spec, modules)[-1]
        count = len(forks.read_text().splitlines())
        check(not value['ok'] and 1 < count <= 10 and time.monotonic() - at < 7 and
              not (work / 'violation').exists() and empty_generations(run),
              'C5 real repeated collision bounded ten candidates each first child reaped before retry')
    for label, target in (('pid', 'aether-bootstrap-dns.pid'), ('config', 'bootstrap.conf')):
        needle = "\tlet pid = fs.readlink('/proc/self');"
        work = base / ('write-fail-' + label)
        work.mkdir()
        modules = module_copy(work, 'sys.uc', needle,
            f"\tif (index(path, '/bootstrap/') >= 0 && index(path, '{target}') >= 0) {{\n"
            f"\t\tlast_error = 'injected {label} failure'; return null;\n\t}}\n" + needle)
        run = work / 'run'
        run.mkdir()
        with Authority() as authority:
            value = run_driver(dict(action='resolve', dir=str(run), engine=str(engine),
                upstream=f'127.0.0.1#{authority.port}'), modules)[-1]
            check(not value['ok'] and value['fatal'] and empty_generations(run) and not authority.requests,
                  f'C5 injected private {label} publication failure stops resources without querying')

    run = base / 'tls-rejected'
    run.mkdir()
    value = run_driver(dict(action='resolve', dir=str(run), engine=str(engine),
        upstream='tls://127.0.0.1#40000'))[-1]
    check(not value['ok'] and value.get('fatal') and empty_generations(run),
          'C5 real aether unsupported TLS rejected without protocol downgrade or respawn')


def calls(f):
    return (f.root / 'calls.log').read_text()


def fragment(f):
    return f.root / 'tmp/dnsmasq.d/aether-proxy.conf'


def context(f, **controls):
    for name, value in controls.items():
        (f.root / name.replace('_', '-')).write_text(str(value))


def interval_stop(base):
    variants = [ ('normal', {}), ('wall-boundary', {'T946_FORCE_WALL_BOUNDARY': '1'}),
                 ('delayed-consumer', {'T946_FORCE_WALL_BOUNDARY': '1', 'T946_DELAY_STOP_SAMPLE': '1'}) ]
    for name, controls in variants:
        env = dict(os.environ, T946_SCENARIO='probe', PYTHONDONTWRITEBYTECODE='1',
                   T946_FORCE_WALL_BOUNDARY='0', T946_DELAY_STOP_SAMPLE='0')
        env.update(controls)
        result = subprocess.run(['python3', str(ROOT / 'tests/daemon/stop-state.py')], cwd=ROOT,
            env=env,
            capture_output=True, text=True, timeout=90)
        (HERE / '.logs' / f'interval-stop-{name}.log').write_text(result.stdout + result.stderr)
        if result.returncode:
            print(result.stdout, result.stderr, flush=True)
        check(result.returncode == 0,
              f'C7 queued interval stop preserves all fields and timestamp under {name}')


def minimal_bootstrap(base):
    from minimal import Minimal
    work = base / 'minimal-bootstrap'
    work.mkdir()
    isolated = Minimal(work)
    run = work / 'run'
    run.mkdir()
    with Authority() as upstream:
        spec = dict(action='resolve', dir=str(run), engine=str(ENGINES[0]), upstream=f'127.0.0.1#{upstream.port}')
        command = [str(ROOT / 'tests/host/prefix/bin/ucode'), str(ROOT / 'tests/xray-ready/minimal.uc'),
                   json.dumps(spec), json.dumps(isolated.paths), str(HERE / 'driver.uc')]
        result = subprocess.run(command, env=isolated.env, capture_output=True, text=True, timeout=12)
        if result.returncode:
            print(result.stdout, result.stderr, flush=True)
        value = records(result.stdout)[-1] if result.returncode == 0 else {}
        check(result.returncode == 0 and value.get('ip') == upstream.ip and empty_generations(run),
              'C13 five-module isolation struct negatives plus real production bootstrap B1 start stop execute')


def frozen(base):
    f = Fixture(base, 'frozen-start')
    context(f, bootstrap_ready_delay='.5')
    with f.daemon():
        wait_for(lambda: 'bootstrap-start ' in calls(f))
        f.conf.write_text(f.conf.read_text().replace('node.example.com', 'changed.invalid')
                          .replace("option mode 'gfw'", "option mode 'invalid-after-freeze'"))
        f.running()
        check('bootstrap-query node.example.com' in calls(f) and 'changed.invalid' not in calls(f) and
              f.state()['mode'] == 'gfw' and f.state()['node_ip'] == '203.0.113.20',
              'C11 startup reuses frozen node and snapshot despite UCI changing during private wait')
    f = Fixture(base, 'preflight-invalid')
    f.conf.write_text(f.conf.read_text().replace("option mode 'gfw'", "option mode 'invalid'"))
    (f.run / 'restart-intent').write_text('restart')
    fragment(f).write_text('unchanged-preflight')
    with f.daemon():
        wait_for(lambda: f.state().get('state') == 'error')
        check(calls(f) == '' and empty_generations(f.run) and fragment(f).read_text() == 'unchanged-preflight' and
              (f.run / 'restart-intent').exists(),
              'C11 invalid preflight has zero command child bootstrap or handoff mutation')


def c4(base):
    f = Fixture(base, 'order')
    context(f, xray_dns_delay='.7', dns_listen_delay='.4')
    intent = f.run / 'restart-intent'
    intent.write_text('restart')
    fragment(f).write_text('old-fragment')
    with f.daemon():
        wait_for(lambda: f.count('xray-dns-pending') == 1)
        check('chinadns-ng -C ' not in calls(f) and 'nft -f ' not in calls(f) and
              not f.events('SERVICE_STARTED') and f.probes() == 0,
              'C4 formal DNS dataplane handoff and probes wait for referenced Xray DNS')
        check(fragment(f).read_text() == 'old-fragment' and intent.exists(),
              'C10 restart intent and exact fragment retained before handoff installation')
        f.running()
        trace = calls(f)
        names = ('bootstrap-query ', 'bootstrap-exit ', 'xray run -c ', 'nft -f ',
                 'ip rule add', 'chinadns-ng -C ', 'dns-owned-ready ', 'dnsmasq restart', 'curl ')
        positions = [trace[:trace.index(name)].count('\n') + 1 for name in names]
        check(positions == sorted(positions) and not intent.exists(),
              'C4 complete private exit Xray gate route formal owned DNS handoff intent probe timeline')
        check('resolveip ' not in trace and empty_generations(f.run),
              'C1 startup never queries system resolver or retained formal handoff')
        steps = f.events('SERVICE_STARTED')[0]['args']['steps']
        check(steps['start_xray_listen'] >= 600 and steps['start_chinadns'] >= 350,
              'C4 delayed Xray and owned formal DNS gates both appear in production timings')
        print('TIMELINE', json.dumps(dict(line_order=dict(zip(names, positions)), steps_ms=steps,
              xray_publication=(f.root / 'xray-dns-published').read_text().strip(),
              dns_publication=[line for line in trace.splitlines() if line.startswith('dns-owned-ready ')],
              intent_after_install=(f.run / 'restart-intent').exists())), flush=True)


def c1(base):
    f = Fixture(base, 'closed-formal')
    context(f, xray_dns_delay='.4')
    (f.run / 'restart-intent').write_text('restart')
    fragment(f).write_text('retained')
    with f.daemon():
        f.running()
        check(f.state()['node_ip'] == '203.0.113.20' and 'resolveip ' not in calls(f) and
              calls(f).index('bootstrap-query ') < calls(f).index('chinadns-ng -C '),
              'C1 domain without LKG resolves through private endpoint before formal DNS exists')


def stop_blocks_daemon(base):
    f = Fixture(base, 'stop-block')
    path = f.modules / 'supervise.uc'
    source = path.read_text()
    needle = '\t\tif (done)\n\t\t\tdone();'
    assert source.count(needle) == 1
    # Fixture withholds private completion delivery, while the actual uloop
    # callback still reaps its real child. Not a simulated D-state claim.
    path.write_text(source.replace(needle, '\t\tif (done && opts.respawn != false)\n\t\t\tdone();'))
    f.env['AETHER_PROXY_TEST_RETRY_DELAY'] = '1'
    (f.run / 'restart-intent').write_text('restart')
    fragment(f).write_text('retain-on-stop-uncertain')
    with f.daemon(expected_exit=1) as child:
        wait_for(lambda: f.state().get('state') == 'error')
        generations = list((f.run / 'bootstrap').iterdir())
        saved = (generations[0] / 'owner.json').read_bytes()
        before = calls(f)
        time.sleep(1.2)  # Retry is now rechecking the retained handle, not forking.
        check(calls(f) == before and 'xray run -c ' not in before and 'chinadns-ng -C ' not in before and
              (generations[0] / 'owner.json').read_bytes() == saved and
              fragment(f).read_text() == 'retain-on-stop-uncertain',
              'C6 actual daemon withheld-exit fixture blocks next stage and retry with retained evidence')
        child.terminate()
        child.wait(timeout=12)
        check(child.returncode == 1 and f.state()['state'] == 'error' and not f.events('SERVICE_STOPPED'),
              'C6 unconfirmed private cleanup never publishes stopped or successful exit')


def c10(base):
    f = Fixture(base, 'restart-failure')
    context(f, xray_dns_missing_port=31082)
    (f.run / 'restart-intent').write_text('restart')
    fragment(f).write_text('retained-failure')
    with f.daemon() as child:
        wait_for(lambda: f.state().get('state') == 'error')
        check((f.run / 'restart-intent').exists() and fragment(f).read_text() == 'retained-failure' and
              'dnsmasq restart' not in calls(f),
              'C10 failed Xray startup keeps intent fragment and zero handoff installs')
        (f.root / 'xray-dns-missing-port').unlink()
        child.send_signal(signal.SIGHUP)
        f.running()
        check(not (f.run / 'restart-intent').exists() and fragment(f).read_text() != 'retained-failure',
              'C10 retry clears intent only after replacement handoff installed')


def cancellation(base):
    for phase, controls, marker in (
            ('private-ready', dict(bootstrap_ready_delay=3), 'bootstrap-start '),
            ('udp-query', dict(resolve_delay=3), 'bootstrap-query '),
            ('tcp-query', dict(bootstrap_query_mode='tcp'), 'bootstrap-tcp-wait'),
            ('cname-query', dict(bootstrap_query_mode='cname'), 'bootstrap-cname-wait'),
            ('xray-gate', dict(xray_dns_delay=3), 'xray run -c '),
            ('formal-gate', dict(dns_listen_delay=3), 'chinadns-ng -C ')):
        f = Fixture(base, 'cancel-' + phase)
        context(f, **controls)
        with f.daemon() as child:
            wait_for(lambda: marker in calls(f))
            before = calls(f)
            child.terminate()
            child.wait(timeout=8)
            after = calls(f)[len(before):]
            forbidden = ('bootstrap-start ', 'xray run -c ', 'chinadns-ng -C ', 'curl ')
            check(not any(name in after for name in forbidden) and
                  not fragment(f).exists() and not f.events('SERVICE_STARTED') and empty_generations(f.run) and
                  (phase not in ('private-ready', 'udp-query', 'tcp-query', 'cname-query') or
                   not (f.root / 'etc/aether-proxy/state/node-ip.json').exists()),
                  f'C7 actual daemon SIGTERM at {phase} no later fork handoff success probe')


def degraded(base):
    for fail_open in (0, 1):
        for direct in (0, 1):
            f = Fixture(base, f'degraded-{fail_open}-{direct}', degraded=True)
            text = f.conf.read_text().replace("option fail_open '1'", f"option fail_open '{fail_open}'")
            # sample omits fail_open: set it explicitly in main, not in dns.
            text = text.replace("option mode 'gfw'", f"option mode 'gfw'\n\toption fail_open '{fail_open}'")
            text += f"\nconfig dns 'dns'\n\toption direct_dns_enabled '{direct}'\n"
            f.conf.write_text(text)
            with f.daemon():
                f.running()
                initial = (f.root / 'dns-start-config.txt').read_text()
                expected = 'trust-dns tcp://9.9.9.9' if direct else 'trust-dns tcp://127.0.0.1#31082'
                check(not (f.run / 'xray.pid').exists() and bool(f.events('SERVICE_STARTED')) and
                      expected in initial and ('nft -f ' in calls(f)) == (not fail_open),
                      f'C9 unresolved no Xray wait initial direct={direct} fail_open={fail_open}')


def orphan(base):
    f = Fixture(base, 'orphan')
    context(f, resolve_delay=3)
    # This fixture's context manager waits only its direct daemon. Our explicit
    # final signal to its isolated test session is harness cleanup, not production.
    with f.daemon(expected_exit=-signal.SIGKILL) as child:
        wait_for(lambda: 'bootstrap-query ' in calls(f))
        dirs = list((f.run / 'bootstrap').iterdir())
        record = json.loads((dirs[0] / 'owner.json').read_text())
        pid = record['process']['pid']
        child.kill()
        child.wait()
        saved = (dirs[0] / 'owner.json').read_bytes()
        collector_record = f.run / 'raw-log.pid'
        if not collector_record.exists():
            collector_record.write_text('historical-fixture\n')
        saved_collector = collector_record.read_bytes()
        command = [str(ROOT / 'tests/host/ucode'), str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'cleanup',
            '--wait', '1', '--sys-root', str(f.root), '--bin-dir', str(f.bin), '--confdir', str(f.conf.parent)]
        result = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=5)
        if result.returncode != 1:
            print('C8 CLEANUP DEBUG', result.returncode, result.stdout, result.stderr, flush=True)
        check(result.returncode == 1 and (dirs[0] / 'owner.json').read_bytes() == saved and
              lifecycle_alive(pid, record['process']['starttime']),
              'C8 actual daemon SIGKILL orphan retained cleanup fails without signals')
        owner = dirs[0] / 'owner.json'
        for label, content in (('missing-pid', json.dumps(dict(record, process=None)).encode()), ('corrupt', b'{')):
            owner.write_bytes(content)
            uncertain = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=5)
            check(uncertain.returncode == 1 and owner.read_bytes() == content and
                  lifecycle_alive(pid, record['process']['starttime']),
                  f'C8 {label} identity retained with zero guessed signals')
            owner.write_bytes(saved)
        (f.run / 'restart-intent').write_text('restart')
        fragment(f).write_text('orphan-retained-handoff')
        protected = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=5)
        check(protected.returncode == 1 and fragment(f).read_text() == 'orphan-retained-handoff',
              'C10 uncertain orphan cleanup still preserves restart-protected handoff')
        (f.run / 'restart-intent').unlink()  # The real init stop/disable does this; procd regression verifies it.
        explicit = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=5)
        check(explicit.returncode == 1 and not fragment(f).exists() and owner.read_bytes() == saved and
              lifecycle_alive(pid, record['process']['starttime']),
              'C10 explicit stop releases handoff despite retained uncertain orphan and failed cleanup')
        before = calls(f)
        # Directly run a second daemon using the same fixture, without altering the
        # original process's context-manager ownership or pretending to reap orphans.
        next_command = [str(ROOT / 'tests/host/ucode'), str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'daemon',
            '--sys-root', str(f.root), '--bin-dir', str(f.bin), '--confdir', str(f.conf.parent)]
        with subprocess.Popen(next_command, env=f.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as retry:
            wait_for(lambda: (f.run / 'daemon.pid').read_text().strip() == str(retry.pid) and
                     f.state().get('failed_step') == 'bootstrap_stop')
            check(calls(f) == before and (dirs[0] / 'owner.json').read_bytes() == saved,
                  'C8 uncertain residue blocks next daemon before any command or child fork')
            retry.terminate()
            retry.wait(timeout=6)
            check(retry.returncode == 1 and f.state().get('state') == 'error',
                  'C8 explicit stop reports unconfirmed orphan as failure not stopped')
            check(collector_record.read_bytes() == saved_collector,
                  'C8 blocked unstarted collector handle never removes historical collector metadata')
        os.killpg(child.pid, signal.SIGKILL)
        time.sleep(.1)
        external = dirs[0] / 'external.keep'
        external.write_bytes(b'not-owned')
        refused = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=8)
        check(refused.returncode == 1 and owner.read_bytes() == saved and external.read_bytes() == b'not-owned',
              'C8 disappeared lifecycle does not authorize deleting external generation entries')
        external.unlink()  # Harness removes only its own external fixture.
        unrelated = subprocess.Popen([str(f.bin / 'chinadns-ng'), '20'], executable='/bin/sleep')
        try:
            replacement = json.loads(saved)
            replacement['process']['pid'] = unrelated.pid
            owner.write_text(json.dumps(replacement))
            (dirs[0] / 'aether-bootstrap-dns.pid').write_text(str(unrelated.pid) + '\n')
            result = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=8)
            check(result.returncode == 0 and empty_generations(f.run) and unrelated.poll() is None,
                  'C8 PID-record reuse fixture clears proven old files without signalling same-name unrelated process')
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=3)
        repeated = subprocess.run(command, env=f.env, text=True, capture_output=True, timeout=8)
        check(repeated.returncode == 0 and empty_generations(f.run),
              'C8 external harness ends orphan then production performs owned idempotent cleanup')


def main(base):
    groups = dict(c1=c1, c4=c4, c10=c10, c6=unconfirmed, c7=cancellation, c9=degraded, c8=orphan,
                  c11=frozen, parallel=parallel_crash, stop_block=stop_blocks_daemon, query_loss=loss_during_query,
                  minimal_bootstrap=minimal_bootstrap, real_cancel=real_cancellation, interval_stop=interval_stop,
                  ignored_term=ignored_term,
                  real=real_engines, failures=fixture_failures)
    if ONLY:
        groups[ONLY](base)
    else:
        for name, run in groups.items():
            print('EVIDENCE', name, 'real engines/sockets' if name in ('real', 'failures') else
                  'actual daemon + synthetic proc fixture; real private query sockets', flush=True)
            run(base)
    print(f'bootstrap-startup: {passed} passed, 0 failed', flush=True)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.runtime-', dir=HERE) as directory:
        main(Path(directory))
