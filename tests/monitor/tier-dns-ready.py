#!/usr/bin/env python3
"""T16.92: monitor DNS tier switches must wait for published_dns readiness before dnsmasq HUP."""
import contextlib
import fcntl
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/xray-ready'))
from proc_fixture import seed_elf  # noqa: E402

passed = 0


def check(condition, label, detail=''):
    global passed
    if not condition:
        raise AssertionError(f'{label}{": " + detail if detail else ""}')
    passed += 1
    print('PASS ', label, flush=True)


def wait_for(predicate, timeout=12, label='timeout'):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(f'wait_for failed: {label}')


def lock_is_free(lock_path):
    if not lock_path.exists():
        return True
    with lock_path.open('a+') as f:
        try:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        return True


FORMAL_DNS_STUB = r'''#!/usr/bin/env python3
import ipaddress
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time

if sys.argv[1:] == ['-V'] or '-C' not in sys.argv:
    os.execv(str(Path(__file__).with_name('chinadns-ng-original')), sys.argv)

config = Path(sys.argv[sys.argv.index('-C') + 1])
if config.name == 'bootstrap.conf':
    os.execv(str(Path(__file__).with_name('chinadns-ng-original')), sys.argv)

root = Path(str(config).split('/var/run/aether-proxy/')[0])
log_path = root / 'calls.log'
pid = os.getpid()


def trace(line):
    with log_path.open('a') as f:
        f.write(line + '\n')
        f.flush()


def addr_hex_le(addr):
    packed = ipaddress.IPv4Address(addr).packed
    return f'{packed[3]:02X}{packed[2]:02X}{packed[1]:02X}{packed[0]:02X}'


def write_atomic(path, content):
    tmp = path.with_name(path.name + f'.tmp.{pid}')
    tmp.write_text(content)
    tmp.replace(path)


def row(addr_hex, port, proto, inode):
    state = '0A' if proto == 'tcp' else '07'
    return (f'  0: {addr_hex}:{port:04X} 00000000:0000 {state} '
            f'00000000:00000000 00:00000000 00000000 0 0 {inode}\n')


bind_addr = '127.0.0.1'
bind_port = 31053
trust_dns = 'none'
for raw in config.read_text().splitlines():
    s = raw.strip()
    if s.startswith('bind-addr '):
        bind_addr = s.split()[1]
    elif s.startswith('bind-port '):
        bind_port = int(s.split()[1])
    elif s.startswith('trust-dns '):
        trust_dns = s.split(None, 1)[1]

behavior = {'mode': 'normal'}
queue_path = root / 'dns-behaviors.json'
if queue_path.exists():
    items = json.loads(queue_path.read_text())
    if items:
        behavior = items.pop(0)
        write_atomic(queue_path, json.dumps(items))

proc = root / 'proc' / str(pid)
(proc / 'fd').mkdir(parents=True, exist_ok=True)
(proc / 'net').mkdir(exist_ok=True)
(proc / 'stat').write_text(Path(f'/proc/{pid}/stat').read_text())
for table in ('tcp', 'udp', 'tcp6', 'udp6'):
    (proc / 'net' / table).write_text('')

(root / 'chinadns.pid').write_text(str(pid))
trace(f'chinadns-ng {" ".join(sys.argv[1:])}')
trace(f'dns-forked {pid} {bind_port} {behavior["mode"]} {trust_dns}')

stop = False


def handle_term(*_):
    global stop
    stop = True


signal.signal(signal.SIGTERM, handle_term)
signal.signal(signal.SIGINT, handle_term)

addr_hex = addr_hex_le(bind_addr)


def publish_owned(port, include_tcp=True, include_udp=True, extra_tcp='', extra_udp='', log_ready=False):
    tcp_inode = 90000 + pid * 10 + 1
    udp_inode = 90000 + pid * 10 + 2
    if include_tcp:
        fd0 = proc / 'fd/0'
        if not fd0.is_symlink():
            fd0.symlink_to(f'socket:[{tcp_inode}]')
        write_atomic(proc / 'net/tcp', extra_tcp + row(addr_hex, port, 'tcp', tcp_inode))
    else:
        write_atomic(proc / 'net/tcp', extra_tcp)
    if include_udp:
        fd1 = proc / 'fd/1'
        if not fd1.is_symlink():
            fd1.symlink_to(f'socket:[{udp_inode}]')
        if log_ready:
            trace(f'dns-ready-publish {pid} {port}')
        write_atomic(proc / 'net/udp', extra_udp + row(addr_hex, port, 'udp', udp_inode))
    else:
        write_atomic(proc / 'net/udp', extra_udp)


try:
    mode = behavior['mode']
    if mode == 'exit_early':
        trace(f'dns-exit-early {pid} {bind_port}')
        sys.exit(1)
    elif mode == 'normal':
        publish_owned(bind_port, True, True, log_ready=True)
    elif mode == 'impostor_only':
        imp_tcp = row(addr_hex, bind_port, 'tcp', 700001)
        imp_udp = row(addr_hex, bind_port, 'udp', 700002)
        write_atomic(proc / 'net/tcp', imp_tcp)
        write_atomic(proc / 'net/udp', imp_udp)
        trace(f'dns-impostor-planted {pid} {bind_port}')
    elif mode == 'barrier':
        gate = root / behavior['gate']
        imp_tcp = row(addr_hex, bind_port, 'tcp', 700001) if behavior.get('impostor') else ''
        imp_udp = row(addr_hex, bind_port, 'udp', 700002) if behavior.get('impostor') else ''
        if behavior.get('impostor'):
            write_atomic(proc / 'net/tcp', imp_tcp)
            write_atomic(proc / 'net/udp', imp_udp)
            trace(f'dns-impostor-planted {pid} {bind_port}')
        tcp_done = False
        while not stop:
            step = gate.read_text().strip() if gate.exists() else 'release'
            if step == 'tcp-only' and not tcp_done:
                publish_owned(bind_port, True, False, extra_tcp=imp_tcp, extra_udp=imp_udp, log_ready=False)
                trace(f'dns-tcp-only {pid} {bind_port}')
                tcp_done = True
            elif step == 'release':
                publish_owned(bind_port, True, True, extra_tcp=imp_tcp, extra_udp=imp_udp, log_ready=True)
                break
            time.sleep(0.01)
    while not stop:
        time.sleep(0.02)
finally:
    shutil.rmtree(proc, ignore_errors=True)
    pidfile = root / 'chinadns.pid'
    if pidfile.exists() and pidfile.read_text().strip() == str(pid):
        pidfile.unlink(missing_ok=True)
    trace(f'dns-exit {pid} {bind_port}')
'''


class TierFixture:
    def __init__(self, base, name, enable_t3_trigger=False):
        self.base = base / name
        self.root = self.base / 'root'
        self.run = self.root / 'var/run/aether-proxy'
        self.bin = self.base / 'bin'
        shutil.copytree(ROOT / 'tests/stubs/daemon-bin', self.bin)
        shutil.move(str(self.bin / 'chinadns-ng'), str(self.bin / 'chinadns-ng-original'))
        stub = self.bin / 'chinadns-ng'
        stub.write_text(FORMAL_DNS_STUB)
        stub.chmod(0o755)

        # Dynamic curl wrapper controlled by $SYSROOT/curl-fail.
        curl = self.bin / 'curl'
        curl.write_text(
            '#!/bin/sh\n'
            'printf "curl %s\\n" "$*" >> "$STUB_LOG"\n'
            'if [ -f "$SYSROOT/curl-fail" ]; then printf "500 0.025\\n"; else printf "204 0.012\\n"; fi\n'
            'exit 0\n'
        )
        curl.chmod(0o755)

        # Dynamic resolveip wrapper: $SYSROOT/dns-probe-fail fails only DNS probes, not node resolution.
        resolveip = self.bin / 'resolveip'
        resolveip.write_text(
            '#!/bin/sh\n'
            'printf "resolveip %s\\n" "$*" >> "$STUB_LOG"\n'
            'case " $* " in\n'
            '  *" node.example.com "*) echo "203.0.113.20"; exit 0 ;;\n'
            'esac\n'
            'if [ -f "$SYSROOT/dns-probe-fail" ]; then exit 1; fi\n'
            'echo "93.184.216.34"\n'
            'exit 0\n'
        )
        resolveip.chmod(0o755)

        for directory in ('etc/config', 'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
                          'sys/class/net/br-lan', 'var/lock', 'var/run/aether-proxy',
                          'etc/aether-proxy/state'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for directory in ('data', 'baseline', 'custom'):
            (self.base / directory).mkdir()
        for item in ('gfwlist', 'chnlist', 'apple'):
            (self.base / 'baseline' / f'{item}.txt').write_text('example.com\n')
        (self.base / 'baseline/chnroute4.txt').write_text('1.0.0.0/8\n')
        (self.base / 'baseline/gfw_static4.txt').write_text('91.108.4.0/22\n')
        (self.root / 'var/etc/dnsmasq.conf.test').write_text(
            'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
        script = self.root / 'etc/init.d/dnsmasq'
        script.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
        script.chmod(0o755)
        seed_elf(self.root)
        (self.root / 'proc/net/tcp').write_text(
            ' 0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00000000 00000000 0 0 0\n')
        for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
            (self.root / file).touch()

        sample = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
        sample += (
            "\nconfig dns 'dns'\n"
            "\toption direct_dns_enabled '1'\n"
            "\toption allow_china_fallback '1'\n"
            "\nconfig probe 'probe'\n"
            "\toption fail_threshold '1'\n"
            "\toption recover_threshold '1'\n"
        )
        # Keep degrade_gfw off so proxy failure exercises pure DNS tier switches without reload.
        sample = sample.replace("option mode 'gfw'", "option mode 'gfw'\n\toption degrade_gfw '0'", 1)
        self.conf = self.root / 'etc/config/aetherproxy'
        self.conf.write_text(sample)

        self.modules = self.base / 'modules/aetherproxy'
        shutil.copytree(ROOT / 'aether-proxy/src/lib', self.modules)
        if enable_t3_trigger:
            mon_path = self.modules / 'monitor.uc'
            mon_src = mon_path.read_text()
            needle = '\tlet obs = observe(daemon);'
            assert mon_src.count(needle) == 1
            mon_path.write_text(mon_src.replace(needle, '''
	if (fs.stat(system_path(daemon.ctx, '/t3-retry-now')) != null) {
		if (!fs.unlink(system_path(daemon.ctx, '/t3-retry-now'))) die('t3-retry marker unlink failed');
		daemon.machine.last_t2_retry = 0;
	}
''' + needle))

        self.env = dict(
            os.environ,
            SYSROOT=str(self.root),
            STUB_LOG=str(self.root / 'calls.log'),
            STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
            PATH=str(self.bin) + ':' + os.environ['PATH'],
            AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
            AETHER_PROXY_TEST_RAW_LOG_COLLECTOR=str(ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'),
            LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
        )

    def queue_behaviors(self, items):
        (self.root / 'dns-behaviors.json').write_text(json.dumps(items))

    def calls(self):
        return (self.root / 'calls.log').read_text().splitlines()

    def state(self):
        try:
            return json.loads((self.run / 'state.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def events(self, code=None):
        path = self.run / 'events.jsonl'
        if not path.exists():
            return []
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        return rows if code is None else [e for e in rows if e.get('code') == code]

    def lock_free(self):
        return lock_is_free(self.root / 'var/lock/aether-proxy.lock')

    def trigger_tick(self, proc):
        proc.send_signal(signal.SIGUSR1)

    @contextlib.contextmanager
    def daemon(self):
        command = [
            str(ROOT / 'tests/host/prefix/bin/ucode'),
            '-L', str(self.base / 'modules/*.uc'),
            '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
            '--', 'daemon',
            '--sys-root', str(self.root),
            '--bin-dir', str(self.bin),
            '--confdir', str(self.conf.parent),
            '--data-dir', str(self.base / 'data'),
            '--baseline-dir', str(self.base / 'baseline'),
            '--custom-dir', str(self.base / 'custom'),
        ]
        with (self.base / 'stdout').open('w') as out, (self.base / 'stderr').open('w') as err:
            child = subprocess.Popen(command, env=self.env, stdout=out, stderr=err, start_new_session=True)
            try:
                yield child
            except Exception:
                print('DEBUG state:', json.dumps(self.state()), flush=True)
                print('DEBUG events:', json.dumps(self.events()), flush=True)
                print('DEBUG calls:\n' + '\n'.join(self.calls()), flush=True)
                print('DEBUG stderr:\n' + (self.base / 'stderr').read_text(), flush=True)
                raise
            finally:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                    raise
                stderr = (self.base / 'stderr').read_text()
                check(child.returncode == 0 and not stderr,
                      f'{self.base.name}: daemon exits cleanly', f'rc={child.returncode} stderr={stderr!r}')

    def wait_running_t1(self):
        wait_for(
            lambda: self.state().get('state') == 'running'
            and self.state().get('dns_tier') == 'T1'
            and self.state().get('monitor') is not None
            and self.lock_free(),
            timeout=12,
            label=f'{self.base.name} running T1',
        )
        time.sleep(0.03)


def scenario_barrier_impostor_and_tcp_only(base):
    f = TierFixture(base, 'barrier-impostor-tcp-only')
    with f.daemon() as proc:
        f.wait_running_t1()
        offset = len(f.calls())
        tier_before = len(f.events('DNS_TIER_CHANGED'))
        gate = f.root / 'gate-t2'
        gate.write_text('hold')
        f.queue_behaviors([{'mode': 'barrier', 'gate': 'gate-t2', 'impostor': True}])
        (f.root / 'curl-fail').touch()
        f.trigger_tick(proc)

        wait_for(lambda: any(l.startswith('dns-impostor-planted ') for l in f.calls()[offset:]),
                 label='T2 dns forked with impostor sockets')
        time.sleep(0.35)
        mid_calls = f.calls()[offset:]
        check('killall -HUP dnsmasq' not in mid_calls,
              'T16.92 barrier: no premature HUP after fork with impostor sockets on same port',
              '\n'.join(mid_calls))
        check(len(f.events('DNS_TIER_CHANGED')) == tier_before,
              'T16.92 barrier: no premature DNS_TIER_CHANGED while barrier held')
        check(f.state().get('dns_tier') == 'T1',
              'T16.92 barrier: state.json dns_tier stays T1 while barrier held',
              json.dumps(f.state()))

        gate.write_text('tcp-only')
        wait_for(lambda: any(l.startswith('dns-tcp-only ') for l in f.calls()[offset:]),
                 label='T2 dns tcp-only published')
        time.sleep(0.25)
        tcp_calls = f.calls()[offset:]
        check('killall -HUP dnsmasq' not in tcp_calls,
              'T16.92 barrier: TCP-only without owned UDP does not allow HUP',
              '\n'.join(tcp_calls))
        check(len(f.events('DNS_TIER_CHANGED')) == tier_before,
              'T16.92 barrier: TCP-only does not emit DNS_TIER_CHANGED')
        check(f.state().get('dns_tier') == 'T1',
              'T16.92 barrier: TCP-only keeps state.json dns_tier at T1')

        gate.write_text('release')
        wait_for(lambda: f.state().get('dns_tier') == 'T2'
                 and len(f.events('DNS_TIER_CHANGED')) == tier_before + 1
                 and f.lock_free(),
                 label='T1->T2 committed after barrier release')
        after_calls = f.calls()[offset:]
        fork_idx = next(i for i, l in enumerate(after_calls) if l.startswith('dns-forked '))
        ready_idx = next(i for i, l in enumerate(after_calls) if l.startswith('dns-ready-publish '))
        hup_idxs = [i for i, l in enumerate(after_calls) if l == 'killall -HUP dnsmasq']
        check(len(hup_idxs) == 1 and fork_idx < ready_idx < hup_idxs[0],
              'T16.92 barrier: strict causal order dns-forked < dns-ready-publish < single HUP',
              f'fork={fork_idx} ready={ready_idx} hups={hup_idxs}\n' + '\n'.join(after_calls))
        print('TRACE T16.92 barrier calls:', [l for l in after_calls if l.startswith(('chinadns-ng ', 'dns-', 'killall -HUP'))], flush=True)

        # Ordinary recovery switch T2 -> T1 also waits for owned UDP/TCP and sends exactly one HUP.
        time.sleep(0.05)
        offset2 = len(f.calls())
        tier_before2 = len(f.events('DNS_TIER_CHANGED'))
        gate2 = f.root / 'gate-t1'
        gate2.write_text('hold')
        f.queue_behaviors([{'mode': 'barrier', 'gate': 'gate-t1', 'impostor': False}])
        (f.root / 'curl-fail').unlink()
        f.trigger_tick(proc)
        wait_for(lambda: any(l.startswith('dns-forked ') for l in f.calls()[offset2:]),
                 label='T1 recovery dns forked')
        time.sleep(0.25)
        check('killall -HUP dnsmasq' not in f.calls()[offset2:],
              'T16.92 T2->T1: no HUP while recovery barrier held')
        gate2.write_text('release')
        wait_for(lambda: f.state().get('dns_tier') == 'T1'
                 and len(f.events('DNS_TIER_CHANGED')) == tier_before2 + 1
                 and f.lock_free(),
                 label='T2->T1 committed after barrier release')
        rec_calls = f.calls()[offset2:]
        r_fork = next(i for i, l in enumerate(rec_calls) if l.startswith('dns-forked '))
        r_ready = next(i for i, l in enumerate(rec_calls) if l.startswith('dns-ready-publish '))
        r_hups = [i for i, l in enumerate(rec_calls) if l == 'killall -HUP dnsmasq']
        check(len(r_hups) == 1 and r_fork < r_ready < r_hups[0],
              'T16.92 T2->T1: single HUP strictly after ready publish',
              f'fork={r_fork} ready={r_ready} hups={r_hups}')


def scenario_start_failure(base):
    f = TierFixture(base, 'start-failure')
    with f.daemon() as proc:
        f.wait_running_t1()
        offset = len(f.calls())
        tier_before = len(f.events('DNS_TIER_CHANGED'))
        fail_before = len(f.events('START_FAILED'))
        f.queue_behaviors([{'mode': 'exit_early'}, {'mode': 'normal'}])
        (f.root / 'curl-fail').touch()
        f.trigger_tick(proc)

        wait_for(lambda: len(f.events('START_FAILED')) > fail_before and f.lock_free(),
                 timeout=10, label='start-failure START_FAILED recorded')
        after_calls = f.calls()[offset:]
        err = f.events('START_FAILED')[-1]
        check('killall -HUP dnsmasq' not in after_calls,
              'T16.92 start-failure: zero dnsmasq HUP on early DNS exit', '\n'.join(after_calls))
        check(len(f.events('DNS_TIER_CHANGED')) == tier_before and f.state().get('dns_tier') == 'T1',
              'T16.92 start-failure: does not misreport tier switch success', json.dumps(f.state()))
        check(err.get('args', {}).get('step') == 'monitor:actions'
              and 'set_tier:T2:' in (err.get('args', {}).get('detail') or '')
              and 'formal DNS child exited or changed generation' in (err.get('args', {}).get('detail') or ''),
              'T16.92 start-failure: START_FAILED preserves set_tier:T2 and readiness exit reason',
              json.dumps(err))

        # Next tick succeeds with normal DNS child (no stuck lock/busy state).
        time.sleep(0.05)
        offset2 = len(f.calls())
        f.trigger_tick(proc)
        wait_for(lambda: f.state().get('dns_tier') == 'T2'
                 and len(f.events('DNS_TIER_CHANGED')) == tier_before + 1
                 and f.lock_free(),
                 timeout=10, label='start-failure retry succeeds')
        retry_hups = [l for l in f.calls()[offset2:] if l == 'killall -HUP dnsmasq']
        check(len(retry_hups) == 1, 'T16.92 start-failure: clean retry emits exactly one HUP')


def scenario_readiness_timeout(base):
    f = TierFixture(base, 'readiness-timeout')
    with f.daemon() as proc:
        f.wait_running_t1()
        offset = len(f.calls())
        tier_before = len(f.events('DNS_TIER_CHANGED'))
        fail_before = len(f.events('START_FAILED'))
        f.queue_behaviors([{'mode': 'impostor_only'}])
        (f.root / 'curl-fail').touch()
        f.trigger_tick(proc)

        wait_for(lambda: len(f.events('START_FAILED')) > fail_before and f.lock_free(),
                 timeout=12, label='readiness-timeout START_FAILED recorded')
        after_calls = f.calls()[offset:]
        err = f.events('START_FAILED')[-1]
        check('killall -HUP dnsmasq' not in after_calls,
              'T16.92 timeout: zero dnsmasq HUP on readiness timeout', '\n'.join(after_calls))
        check(len(f.events('DNS_TIER_CHANGED')) == tier_before and f.state().get('dns_tier') == 'T1',
              'T16.92 timeout: does not misreport tier switch success', json.dumps(f.state()))
        check(err.get('args', {}).get('step') == 'monitor:actions'
              and 'set_tier:T2:' in (err.get('args', {}).get('detail') or '')
              and 'formal DNS required sockets not ready within 5 seconds' in (err.get('args', {}).get('detail') or ''),
              'T16.92 timeout: START_FAILED preserves set_tier:T2 and 5s timeout reason',
              json.dumps(err))


def scenario_sigterm_cancels_wait(base):
    f = TierFixture(base, 'sigterm-cancels-wait')
    with f.daemon() as proc:
        f.wait_running_t1()
        offset = len(f.calls())
        tier_before = len(f.events('DNS_TIER_CHANGED'))
        cmd_fail_before = len(f.events('CMD_FAILED'))
        start_fail_before = len(f.events('START_FAILED'))
        gate = f.root / 'term-gate'
        gate.write_text('hold')
        f.queue_behaviors([{'mode': 'barrier', 'gate': 'term-gate', 'impostor': False}])
        (f.root / 'curl-fail').touch()
        f.trigger_tick(proc)

        wait_for(lambda: any(l.startswith('dns-forked ') for l in f.calls()[offset:]),
                 label='dns forked before SIGTERM')
        started = time.monotonic()
        proc.terminate()
        proc.wait(timeout=4)
        elapsed = time.monotonic() - started
        after_calls = f.calls()[offset:]
        dns_starts = [l for l in after_calls if l.startswith('chinadns-ng -C ')]
        dns_forks = [l for l in after_calls if l.startswith('dns-forked ')]
        check(elapsed < 3.5,
              f'T16.92 sigterm: cancels readiness wait promptly ({elapsed:.2f}s)')
        check(len(dns_starts) == 1 and len(dns_forks) == 1,
              'T16.92 sigterm: does not spawn a second DNS child during stop', '\n'.join(after_calls))
        check('killall -HUP dnsmasq' not in after_calls,
              'T16.92 sigterm: zero dnsmasq HUP when cancelled by SIGTERM', '\n'.join(after_calls))
        check(len(f.events('DNS_TIER_CHANGED')) == tier_before,
              'T16.92 sigterm: does not emit DNS_TIER_CHANGED on cancellation')
        check(f.state().get('state') == 'stopped' and len(f.events('PROXY_UNHEALTHY')) == 0,
              'T16.92 sigterm: state is stopped and cancelled transition is not committed as ready',
              json.dumps({'state': f.state(), 'events': f.events()}))
        check(len(f.events('CMD_FAILED')) == cmd_fail_before
              and len(f.events('START_FAILED')) == start_fail_before,
              'T16.92 sigterm: clean stop cancellation does not log spurious action errors',
              json.dumps(f.events('CMD_FAILED') + f.events('START_FAILED')))
        check(f.lock_free(), 'T16.92 sigterm: monitor lock released on stop')
        print('TRACE T16.92 sigterm calls:', [l for l in after_calls if l.startswith(('chinadns-ng ', 'dns-', 'killall -HUP', 'dnsmasq '))], flush=True)


def scenario_t3_retry_t2_policy(base):
    f = TierFixture(base, 't3-retry-t2-policy', enable_t3_trigger=True)
    with f.daemon() as proc:
        f.wait_running_t1()
        # Drive T1 -> T2 -> T3 with failing proxy and failing direct DNS probe.
        (f.root / 'curl-fail').touch()
        (f.root / 'dns-probe-fail').touch()
        f.trigger_tick(proc)
        wait_for(lambda: f.state().get('dns_tier') == 'T2' and f.lock_free(),
                 timeout=10, label='entered T2')
        # Three consecutive failed DNS probes in T2 transition to T3 (immediate tick already did 1).
        for _ in range(3):
            if f.state().get('dns_tier') == 'T3' and f.lock_free():
                break
            time.sleep(0.05)
            f.trigger_tick(proc)
            wait_for(lambda: f.lock_free(), timeout=10, label='tick settled')
            time.sleep(0.05)
        wait_for(lambda: f.state().get('dns_tier') == 'T3' and f.lock_free(),
                 timeout=10, label='entered T3')

        # 5a: T3 -> T2 periodic retry when direct DNS probe succeeds -> stays in T2 (no fallback!).
        (f.root / 'dns-probe-fail').unlink()
        offset_ok = len(f.calls())
        tier_before_ok = len(f.events('DNS_TIER_CHANGED'))
        gate_ok = f.root / 'gate-t3-ok'
        gate_ok.write_text('hold')
        f.queue_behaviors([{'mode': 'barrier', 'gate': 'gate-t3-ok', 'impostor': False}])
        (f.root / 't3-retry-now').touch()
        f.trigger_tick(proc)
        wait_for(lambda: any(l.startswith('dns-forked ') for l in f.calls()[offset_ok:]),
                 label='T3->T2 retry dns forked (probe ok)')
        time.sleep(0.25)
        mid_ok = f.calls()[offset_ok:]
        check('killall -HUP dnsmasq' not in mid_ok,
              'T16.92 T3->T2 (probe ok): no HUP while barrier held')
        check(len(f.events('DNS_TIER_CHANGED')) == tier_before_ok,
              'T16.92 T3->T2 (probe ok): no premature DNS_TIER_CHANGED while barrier held')
        gate_ok.write_text('release')
        wait_for(lambda: f.state().get('dns_tier') == 'T2'
                 and f.state().get('monitor', {}).get('t2_retry_pending') is False
                 and f.lock_free(),
                 timeout=10, label='T3->T2 retry succeeded and settled in T2')
        time.sleep(0.15)
        ok_events = f.events('DNS_TIER_CHANGED')[tier_before_ok:]
        ok_calls = f.calls()[offset_ok:]
        ok_hups = [i for i, l in enumerate(ok_calls) if l == 'killall -HUP dnsmasq']
        ok_ready = next(i for i, l in enumerate(ok_calls) if l.startswith('dns-ready-publish '))
        check(len(ok_events) == 1 and ok_events[0]['args'].get('from') == 'T3'
              and ok_events[0]['args'].get('to') == 'T2'
              and ok_events[0]['args'].get('reason') == 'periodic_retry',
              'T16.92 T3->T2 (probe ok): stays in T2 without falling back to T3',
              json.dumps(ok_events))
        check(len(ok_hups) == 1 and ok_ready < ok_hups[0],
              'T16.92 T3->T2 (probe ok): exactly one HUP strictly after ready publish')

        # Return to T3 for 5b: T3 -> T2 periodic retry when direct DNS probe fails -> falls back to T3.
        (f.root / 'dns-probe-fail').touch()
        for _ in range(4):
            if f.state().get('dns_tier') == 'T3' and f.lock_free():
                break
            time.sleep(0.05)
            f.trigger_tick(proc)
            wait_for(lambda: f.lock_free(), timeout=10, label='tick settled toward T3')
            time.sleep(0.05)
        wait_for(lambda: f.state().get('dns_tier') == 'T3' and f.lock_free(),
                 timeout=10, label='re-entered T3 for fallback subcase')

        offset_fb = len(f.calls())
        tier_before_fb = len(f.events('DNS_TIER_CHANGED'))
        gate_fb = f.root / 'gate-t3-fb'
        gate_fb.write_text('hold')
        f.queue_behaviors([
            {'mode': 'barrier', 'gate': 'gate-t3-fb', 'impostor': False},
            {'mode': 'normal'},
        ])
        (f.root / 't3-retry-now').touch()
        f.trigger_tick(proc)
        wait_for(lambda: any(l.startswith('dns-forked ') for l in f.calls()[offset_fb:]),
                 label='T3->T2 retry dns forked (probe fail)')
        time.sleep(0.25)
        check('killall -HUP dnsmasq' not in f.calls()[offset_fb:],
              'T16.92 T3->T2 (probe fail): no HUP while barrier held')
        gate_fb.write_text('release')
        wait_for(lambda: len(f.events('DNS_TIER_CHANGED')) == tier_before_fb + 2
                 and f.state().get('dns_tier') == 'T3'
                 and f.lock_free(),
                 timeout=10, label='T3->T2->T3 fallback completed')
        fb_events = f.events('DNS_TIER_CHANGED')[tier_before_fb:]
        fb_calls = f.calls()[offset_fb:]
        fb_ready = [i for i, l in enumerate(fb_calls) if l.startswith('dns-ready-publish ')]
        fb_hups = [i for i, l in enumerate(fb_calls) if l == 'killall -HUP dnsmasq']
        check(fb_events[0]['args'].get('to') == 'T2' and fb_events[0]['args'].get('reason') == 'periodic_retry'
              and fb_events[1]['args'].get('to') == 'T3' and fb_events[1]['args'].get('reason') == 't2_retry_failed',
              'T16.92 T3->T2 (probe fail): immediate probe failure falls back to T3 with t2_retry_failed',
              json.dumps(fb_events))
        check(len(fb_ready) == 2 and len(fb_hups) == 2
              and fb_ready[0] < fb_hups[0] < fb_ready[1] < fb_hups[1],
              'T16.92 T3->T2 (probe fail): each switch HUPs once strictly after its own ready publish',
              f'ready={fb_ready} hups={fb_hups}')


def main():
    only = set(sys.argv[1:])
    scenarios = [
        ('barrier', scenario_barrier_impostor_and_tcp_only),
        ('start-failure', scenario_start_failure),
        ('timeout', scenario_readiness_timeout),
        ('sigterm', scenario_sigterm_cancels_wait),
        ('t3-retry', scenario_t3_retry_t2_policy),
    ]
    with tempfile.TemporaryDirectory(prefix='t1692-tier-dns-ready-') as tmp:
        base = pathlib.Path(tmp)
        for name, fn in scenarios:
            if only and name not in only:
                continue
            fn(base)
    print(f't16.92 tier-dns-ready: {passed} passed, 0 failed', flush=True)


if __name__ == '__main__':
    main()
