#!/usr/bin/env python3
"""T9.28 real CLI + local IPv4 TCP/UDP DNS, without touching global UCI state."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
NODE = 'n_' + '1' * 32
FALLBACK = 'www.microsoft.com'
BLOCKED = 'www.google.com'


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T9.28 ' + name, flush=True)


def global_savedir():
    """Observe pre-existing state without creating/removing any host path."""
    path = Path('/tmp/.uci')
    if not path.exists():
        return None
    return {str(item.relative_to(path)): (item.stat().st_mtime_ns,
            item.read_bytes() if item.is_file() else None)
            for item in [path, *path.rglob('*')]}


def wire_name(name):
    return b''.join(bytes([len(part)]) + part.encode() for part in name.split('.')) + b'\0'


def read_exact(peer, size):
    data = b''
    while len(data) < size:
        chunk = peer.recv(size - len(data))
        if not chunk:
            return None
        data += chunk
    return data


class DNS:
    """Record real DNS requests; per-domain plans control the three independent samples."""
    def __init__(self, tcp, mode='answer', delays=(0.7, 0.02, 0.08)):
        self.tcp, self.mode, self.delays = tcp, mode, delays
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)
        self.sock.bind(('127.0.0.1', 0))
        self.port = self.sock.getsockname()[1]
        self.sock.settimeout(0.1)
        if tcp:
            self.sock.listen(16)
        self.stop = threading.Event()
        self.requests, self.errors, self.workers = [], [], []
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()

    @property
    def upstream(self):
        # The bare spelling is deliberately tested: it means UDP, not TCP.
        return ('tcp://' if self.tcp else '') + f'127.0.0.1#{self.port}'

    def serve(self):
        while not self.stop.is_set():
            try:
                if self.tcp:
                    peer, _ = self.sock.accept()
                    worker = threading.Thread(target=self.tcp_reply, args=(peer,))
                    self.workers.append(worker)
                    worker.start()
                else:
                    data, address = self.sock.recvfrom(65535)
                    self.reply(data, lambda value: self.sock.sendto(value, address))
            except socket.timeout:
                continue
            except OSError as error:
                if not self.stop.is_set():
                    self.errors.append(repr(error))

    def tcp_reply(self, peer):
        with peer:
            peer.settimeout(4)
            try:
                prefix = read_exact(peer, 2)
                if prefix is None:
                    return
                size = struct.unpack('!H', prefix)[0]
                data = read_exact(peer, size)
                if data is None:
                    return

                def send(value):
                    frame = struct.pack('!H', len(value)) + value
                    if self.mode == 'slow':
                        # Neither split length-prefix nor split body gets a fresh 2s budget.
                        for delay, fragment in ((0.7, frame[:1]), (0.7, frame[1:3]), (0.7, frame[3:])):
                            if self.stop.wait(delay):
                                return
                            peer.sendall(fragment)
                    else:
                        for fragment in (frame[:1], frame[1:2], frame[2:7], frame[7:]):
                            peer.sendall(fragment)
                            time.sleep(0.002)

                self.reply(data, send)
            except (BrokenPipeError, ConnectionResetError):
                # Expected: the diagnostic has already enforced its deadline.
                return
            except Exception as error:
                self.errors.append(repr(error))

    def reply(self, data, send):
        try:
            ident, flags, qd, an, ns, ar = struct.unpack('!6H', data[:12])
            offset, labels = 12, []
            while data[offset]:
                size = data[offset]
                labels.append(data[offset + 1:offset + size + 1].decode())
                offset += size + 1
            offset += 1
            qtype, qclass = struct.unpack('!HH', data[offset:offset + 4])
            assert (flags, qd, an, ns, ar, qtype, qclass) == (0x100, 1, 0, 0, 0, 1, 1)
            assert offset + 4 == len(data), 'query must contain exactly one A/IN question'
            domain = '.'.join(labels)
            ordinal = sum(row['domain'] == domain for row in self.requests)
            self.requests.append({'domain': domain, 'at': time.monotonic(), 'ordinal': ordinal})
            question = data[12:]
            answer = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 10, 4) + bytes([192, 0, 2, 10])
            response_flags, count = 0x8180, 1
            if self.mode == 'timeout':
                if self.tcp:
                    self.stop.wait(2.3)
                return
            if self.mode == 'refused' or (self.mode == 'partial' and ordinal % 3 == 2):
                response_flags, count, answer = 0x8185, 0, b''
            elif self.mode == 'invalid':
                variant = len(self.requests) - 1
                if variant == 0:
                    ident ^= 1
                elif variant == 1:
                    question = wire_name('wrong.example') + struct.pack('!HH', 1, 1)
                elif variant == 2:
                    response_flags |= 0x200  # TC is not a successful answer.
                elif variant == 3:
                    count, answer = 0, b''
                elif variant == 4:
                    answer = answer[:-1]  # RDLENGTH exceeds the frame.
                else:
                    answer = wire_name('unrelated.example') + answer[2:]
            elif self.mode == 'pointer-budget':
                # ~39KB: a matching A must not hide 3000 additional TXT records.
                # Each owner points backwards to the preceding owner until the
                # 14-bit pointer space fills, then repeats that deep chain.
                records = bytearray(answer)
                previous = 12
                for _ in range(3000):
                    owner_offset = 12 + len(question) + len(records)
                    records += struct.pack('!HHHIH', 0xc000 | previous, 16, 1, 10, 1) + b'\0'
                    if owner_offset < 0x4000:
                        previous = owner_offset
                response = (struct.pack('!6H', ident, response_flags, 1, 1, 0, 3000) +
                            question + records)
                assert 39000 < len(response) < 40000
                send(response)
                return
            elif self.mode == 'parse-deadline':
                # No compressed-name hop violation: stress the CNAME lookup
                # itself, after most of the *original* socket budget is spent.
                records = bytearray()
                owner = b'\xc0\x0c'
                for index in range(2600):
                    alias = wire_name(f'c{index:04d}')
                    records += owner + struct.pack('!HHIH', 5, 1, 10, len(alias)) + alias
                    owner = alias
                records += owner + answer[2:]
                response = (struct.pack('!6H', ident, response_flags, 1, 2601, 0, 0) +
                            question + records)
                assert len(response) < 65507
                self.stop.wait(1.8)
                send(response)
                return
            elif self.mode == 'cname':
                alias = wire_name('alias.example')
                cname = b'\xc0\x0c' + struct.pack('!HHIH', 5, 1, 10, len(alias)) + alias
                answer = cname + alias + answer[2:]
                count = 2
            if self.mode in ('answer', 'partial'):
                self.stop.wait(self.delays[ordinal % 3])
            response = struct.pack('!6H', ident, response_flags, 1, count, 0, 0) + question + answer
            send(response)
        except Exception as error:
            self.errors.append(repr(error))

    def close(self):
        self.stop.set()
        self.thread.join(timeout=5)
        for worker in self.workers:
            worker.join(timeout=5)
        self.sock.close()
        assert not self.thread.is_alive() and all(not worker.is_alive() for worker in self.workers)
        assert not self.errors, self.errors


def run_suite(t):
    conf, run, root, savedir = (t / name for name in ('conf', 'run', 'root', 'savedir'))
    for path in (conf, run, root, savedir):
        path.mkdir()
    state = run / 'state.json'
    events = run / 'events.jsonl'
    state.write_text('{intentionally corrupt state: diagnostics must not read this}')
    events.write_text('sentinel events\n')
    servers = []
    global_uci_initial = global_savedir()

    def server(*args, **kwargs):
        result = DNS(*args, **kwargs)
        servers.append(result)
        return result

    def config(upstreams, address='node.example.test', enabled=False, direct=False):
        text = (f"config global 'main'\n\toption enabled '{int(enabled)}'\n"
                f"\toption node '{NODE}'\nconfig dns 'dns'\n"
                f"\toption direct_dns_enabled '{int(direct)}'\n"
                f"\toption dns_probe_domain '{BLOCKED}'\n")
        text += ''.join(f"\tlist direct_dns '{upstream}'\n" for upstream in upstreams)
        if address is not None:
            text += (f"config node '{NODE}'\n\toption protocol 'trojan'\n"
                     f"\toption address '{address}'\n\toption port '443'\n"
                     "\toption password 'test'\n\toption security 'tls'\n")
        else:
            text = text.replace(f"\toption node '{NODE}'\n", '')
        (conf / 'aetherproxy').write_text(text)

    def ap(*args, expected=0, human=False, timeout=50):
        before = {path: path.read_bytes() for path in (conf / 'aetherproxy', state, events) if path.exists()}
        global_uci_before = global_savedir()
        started = time.monotonic()
        command = [str(UCODE), '-S', str(ENTRY), '--', 'dns', *args,
                   '--confdir', str(conf), '--run-dir', str(run), '--sys-root', str(root)]
        if not human:
            command.append('--json')
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        elapsed = time.monotonic() - started
        assert result.returncode == expected, (command, result.returncode, result.stdout, result.stderr)
        assert not result.stderr, result.stderr
        for path, value in before.items():
            assert path.read_bytes() == value, ('modified', path)
        assert global_savedir() == global_uci_before, 'created or modified global UCI savedir'
        assert sorted(path.name for path in run.iterdir()) == ['events.jsonl', 'state.json']
        return (result.stdout if human else json.loads(result.stdout)), elapsed

    try:
        # Exercise the real fs calls against missing and short entropy sources;
        # only an in-memory source copy is changed, never the production module.
        diagnostic = (ROOT / 'aether-proxy/src/lib/dns_test.uc').read_text()
        empty = t / 'empty-random'
        empty.write_bytes(b'')
        for path, operation in ((t / 'missing-random', 'open'), (empty, 'read')):
            source = diagnostic.replace('C.RANDOM_DEVICE', json.dumps(str(path)))
            source = source.replace('export function run(', 'function run(')
            source += '\nrun({nodes: {}, main: {}, dns: {direct_dns: ["127.0.0.1#9"]}});\n'
            failed = subprocess.run([str(UCODE), '-S', '-e', source], cwd=ROOT,
                                    text=True, capture_output=True, timeout=5)
            check(f'random ID {operation} failure is explicitly propagated',
                  failed.returncode != 0 and f'{operation} {path}:' in failed.stderr)

        # The command boundary converts a propagated diagnostic I/O error back
        # into the same JSON/exit contract as other CLI failures, without stderr.
        config(['127.0.0.1#9'])
        command_source = (ROOT / 'aether-proxy/src/lib/cmd/dns.uc').read_text()
        command_source = command_source.replace('export function run(', 'function run(')
        command_source = command_source.replace(
            'let diagnostic = loadstring("import * as m from \'aetherproxy.dns_test\'; return m;")();',
            'let diagnostic = { run: function(snapshot) { die("entropy unavailable"); } };')
        command_args = ['test-direct', '--json', '--confdir', str(conf), '--run-dir', str(run),
                        '--sys-root', str(root)]
        command_source += '\nexit(run(' + json.dumps(command_args) + '));\n'
        failed = subprocess.run([str(UCODE), '-S', '-e', command_source], cwd=ROOT,
                                text=True, capture_output=True, timeout=5)
        failure = json.loads(failed.stdout)
        check('entropy failure preserves CLI FS_FAILED JSON exit 1 and empty stderr',
              failed.returncode == 1 and not failed.stderr and failure['ok'] is False
              and failure['code'] == 'FS_FAILED' and 'entropy unavailable' in failure['detail'])
        check('entropy failure emits an FS_FAILED event',
              '"code": "FS_FAILED"' in events.read_text())

        tcp, udp = server(True), server(False)
        tcp_refused, udp_refused = server(True, 'refused'), server(False, 'refused')
        tcp_timeout, udp_timeout = server(True, 'timeout'), server(False, 'timeout')
        tls = f'tls://127.0.0.1#{tcp.port}'
        config([item.upstream for item in servers] + [tls])
        value, elapsed = ap('test-direct')
        check('JSON contains one ordered result per configured upstream', value['ok'] and
              [row['upstream'] for row in value['results']] == [item.upstream for item in servers] + [tls])
        for item, row in zip(servers, value['results']):
            label = 'TCP' if item.tcp else 'UDP'
            check(f'{label} {item.mode}: supported IPv4 socket query', row['unsupported'] is False)
            for group, domain in (('unblocked', 'node.example.test'), ('blocked', BLOCKED)):
                result = row[group]
                check(f'{label} {item.mode} {group}: exactly three A/IN queries in order',
                      [request['domain'] for request in item.requests] == [domain for domain in
                       ('node.example.test', BLOCKED) for _ in range(3)] and
                      result['domain'] == domain and result['total'] == 3)
                if item.mode == 'answer':
                    check(f'{label} answer {group}: three successes and successful-sample median',
                          result['ok'] == 3 and 65 <= result['latency_ms'] <= 150)
                else:
                    check(f'{label} {item.mode} {group}: zero successes and null latency',
                          result['ok'] == 0 and result['latency_ms'] is None)
        unsupported = value['results'][-1]
        check('tls is unsupported without sending any query', unsupported['unsupported'] is True and
              all(unsupported[key]['ok'] == 0 and unsupported[key]['total'] == 3 and
                  unsupported[key]['latency_ms'] is None for key in ('unblocked', 'blocked')) and
              len(tcp.requests) == 6)
        check('TCP and UDP timeout attempts each consume a single two-second deadline', 24 <= elapsed < 30)
        check('disabled switches and corrupt service state do not prevent standalone detection', value['ok'])
        check('configuration state events global savedir and run artifacts remain unchanged',
              global_savedir() == global_uci_initial)
        print(f'INFO  T9.28 answer/refused/timeout matrix elapsed={elapsed:.3f}s', flush=True)

        for tcp_mode in (True, False):
            partial = server(tcp_mode, 'partial', (0.16, 0.02, 0))
            config([partial.upstream], address='192.0.2.1', enabled=True, direct=True)
            value, _ = ap('test-direct')
            row = value['results'][0]
            check(('TCP' if tcp_mode else 'UDP') + ' partial: two successes use their even median only',
                  all(row[key]['ok'] == 2 and 75 <= row[key]['latency_ms'] <= 140
                      for key in ('unblocked', 'blocked')))
            check(('TCP' if tcp_mode else 'UDP') + ' IP node uses www.microsoft.com with both switches enabled',
                  row['unblocked']['domain'] == FALLBACK and
                  [request['domain'] for request in partial.requests] == [FALLBACK] * 3 + [BLOCKED] * 3)

        # Private uci.cursor setup creates a real delta, never /tmp/.uci.
        setup = """import * as uci from 'uci';
let cursor = uci.cursor(ARGV[0], ARGV[1]);
if (!cursor.load('aetherproxy') || !cursor.set('aetherproxy', 'dns', 'dns_probe_domain', 'staged.example')
    || !cursor.save('aetherproxy')) exit(1);
"""
        staged = subprocess.run([str(UCODE), '-e', setup, '--', str(conf), str(savedir)],
                                cwd=ROOT, text=True, capture_output=True, timeout=5)
        assert staged.returncode == 0 and not staged.stderr, staged.stderr
        delta = (savedir / 'aetherproxy').read_bytes()
        value, _ = ap('test-direct')
        check('independent savedir ignores staged deltas and leaves them untouched',
              value['results'][0]['blocked']['domain'] == BLOCKED and
              (savedir / 'aetherproxy').read_bytes() == delta and global_savedir() == global_uci_initial)

        invalid = server(True, 'invalid')
        config([invalid.upstream], address='192.0.2.1')
        value, _ = ap('test-direct')
        check('wrong ID question TC NODATA malformed and unrelated A replies are not successes',
              all(value['results'][0][key]['ok'] == 0 for key in ('unblocked', 'blocked')) and
              len(invalid.requests) == 6)

        cname = server(True, 'cname')
        config([cname.upstream], address='192.0.2.1')
        value, _ = ap('test-direct')
        check('fragmented TCP prefix and body with compressed CNAME-to-A answers succeed',
              all(value['results'][0][key]['ok'] == 3 for key in ('unblocked', 'blocked')))

        slow = server(True, 'slow')
        config([slow.upstream], address='192.0.2.1')
        value, elapsed = ap('test-direct')
        check('slow split TCP framing cannot reset the overall two-second attempt deadline',
              12 <= elapsed < 14 and all(value['results'][0][key]['ok'] == 0
                                       for key in ('unblocked', 'blocked')))
        print(f'INFO  T9.28 split-prefix/body deadline elapsed={elapsed:.3f}s', flush=True)

        for mode in ('pointer-budget', 'parse-deadline'):
            for tcp_mode in (True, False):
                malicious = server(tcp_mode, mode)
                config([malicious.upstream], address='192.0.2.1')
                # A regression is killed near the six-attempt budget, rather
                # than letting an unbounded parser stall the test suite.
                value, elapsed = ap('test-direct', timeout=14)
                label = 'TCP' if tcp_mode else 'UDP'
                row = value['results'][0]
                check(f'{label} {mode}: six malicious replies exhaust parsing budget without success',
                      elapsed < 14 and [request['domain'] for request in malicious.requests] ==
                      [FALLBACK] * 3 + [BLOCKED] * 3 and
                      all(row[key]['ok'] == 0 and row[key]['total'] == 3 and
                          row[key]['latency_ms'] is None for key in ('unblocked', 'blocked')))
                print(f'INFO  T9.28 {label} {mode} six attempts elapsed={elapsed:.3f}s', flush=True)

        # Bound-but-not-listening TCP and bound-then-closed UDP are deterministic
        # loopback connection refusals; no TEST-NET or external DNS traffic is used.
        closed = []
        for kind, prefix in ((socket.SOCK_STREAM, 'tcp://'), (socket.SOCK_DGRAM, 'udp://')):
            sock = socket.socket(socket.AF_INET, kind)
            sock.bind(('127.0.0.1', 0))
            closed.append(prefix + '127.0.0.1#' + str(sock.getsockname()[1]))
            sock.close()
        config(closed, address=None)
        value, elapsed = ap('test-direct')
        check('closed loopback TCP and UDP ports fail promptly with null medians', elapsed < 2 and
              all(row[key]['ok'] == 0 and row[key]['latency_ms'] is None
                  for row in value['results'] for key in ('unblocked', 'blocked')))
        check('no current node also falls back to www.microsoft.com',
              all(row['unblocked']['domain'] == FALLBACK for row in value['results']))

        config([tls, f'tcp://dns.example@127.0.0.1#{tcp.port}'])
        value, _ = ap('test-direct')
        check('unspecified host-at-IP syntax is conservatively unsupported',
              all(row['unsupported'] for row in value['results']))
        text, _ = ap('test-direct', human=True)
        check('non-JSON output is readable and identifies unsupported upstreams',
              'unsupported' in text and tls in text and not text.lstrip().startswith('{'))
        for args in ((), ('unknown',), ('test-direct', 'extra'), ('test-direct', '--bogus')):
            value, _ = ap(*args, expected=2)
            check('usage ' + repr(args) + ': exit 2 and USAGE JSON',
                  value['ok'] is False and value['code'] == 'USAGE')
        config(['not-an-ip'])
        value, _ = ap('test-direct', expected=2)
        check('invalid DNS configuration reports CONFIG_INVALID without querying',
              value['code'] == 'CONFIG_INVALID' and value['ok'] is False)
    finally:
        for item in servers:
            item.close()


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.dns-test-', dir=ROOT / 'tests/cli') as temporary:
        run_suite(Path(temporary))
    print('PASS  T9.28 DNS socket and CLI integration scenarios complete', flush=True)
