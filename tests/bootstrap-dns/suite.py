#!/usr/bin/env python3
"""T15.4 controlled authority + real ucode driver, not a replacement resolver."""
import contextlib
import json
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
DRIVER = ROOT / 'tests/bootstrap-dns/driver.uc'
IP = '192.0.2.17'
OLD = '192.0.2.99'
ONLY = sys.argv[1] if len(sys.argv) > 1 else None
LKG_FILE = subprocess.check_output([str(UCODE), '-e',
           "import * as c from 'aetherproxy.const'; print(c.NODE_IP_FILE);"], text=True, cwd=ROOT)


def check(label, condition):
    if not condition:
        raise AssertionError(label)
    print('PASS  ' + label, flush=True)


def name(value):
    return b''.join(bytes([len(x)]) + x.encode() for x in value.split('.')) + b'\0'


def rr(owner, kind=1, data=None, klass=1):
    if data is None:
        data = socket.inet_aton(IP)
    owner = name(owner) if isinstance(owner, str) else owner
    return owner + struct.pack('!HHIH', kind, klass, 30, len(data)) + data


def exact(peer, size):
    data = b''
    while len(data) < size:
        part = peer.recv(size - len(data))
        if not part:
            return None
        data += part
    return data


class Authority:
    def __init__(self, mode='answer'):
        self.mode = mode
        self.stop = threading.Event()
        self.requests, self.errors, self.workers = [], [], []
        # UDP and TCP have separate port namespaces; retry boundedly if a UDP
        # candidate collides with a live/TIME_WAIT TCP socket. Never use reuse-port.
        for _ in range(10):
            self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.udp.bind(('127.0.0.1', 0))
            self.port = self.udp.getsockname()[1]
            try:
                self.tcp.bind(('127.0.0.1', self.port))
                break
            except OSError as error:
                self.udp.close()
                self.tcp.close()
                if error.errno != 98:
                    raise
        else:
            raise RuntimeError('no shared UDP/TCP candidate after ten attempts')
        self.tcp.listen(32)
        for sock in (self.udp, self.tcp):
            sock.settimeout(.05)
        self.threads = [threading.Thread(target=self.serve, args=(tcp,)) for tcp in (False, True)]
        for thread in self.threads:
            thread.start()

    @property
    def endpoint(self):
        return {'address': '127.0.0.1', 'port': self.port}

    def serve(self, tcp):
        sock = self.tcp if tcp else self.udp
        while not self.stop.is_set():
            try:
                if tcp:
                    peer, _ = sock.accept()
                    worker = threading.Thread(target=self.stream, args=(peer,))
                else:
                    data, address = sock.recvfrom(65535)
                    worker = threading.Thread(target=self.respond,
                                              args=(data, False, lambda b, a=address: sock.sendto(b, a), address))
                self.workers.append(worker)
                worker.start()
            except socket.timeout:
                pass
            except OSError as error:
                if not self.stop.is_set():
                    self.errors.append(str(error))

    def stream(self, peer):
        with peer:
            peer.settimeout(4)
            try:
                prefix = exact(peer, 2)
                if prefix is None:
                    return
                data = exact(peer, struct.unpack('!H', prefix)[0])
                if data is None:
                    return

                def send(body):
                    frame = struct.pack('!H', len(body)) + body
                    if self.mode == 'tcp-short-length':
                        peer.sendall(b'\0\x05hello')
                    elif self.mode == 'tcp-surplus':
                        peer.sendall(frame + b'garbage')
                    elif self.mode == 'tcp-eof':
                        peer.sendall(frame[:-1])
                    elif self.mode == 'tcp-long-length':
                        peer.sendall(struct.pack('!H', len(body) + 1) + body)
                    elif self.mode in ('shared-deadline', 'tcp-timeout', 'cancel-tcp'):
                        peer.sendall(frame[:1])
                        if self.mode == 'shared-deadline':
                            self.stop.wait(.18)
                            peer.sendall(frame[1:])
                        else:
                            self.stop.wait(3.5)
                    else:
                        for chunk in (frame[:1], frame[1:2], frame[2:7], frame[7:]):
                            peer.sendall(chunk)
                            self.stop.wait(.003)
                self.respond(data, True, send, None)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Client deadline/cancel owns the socket, not the authority.
            except Exception as error:
                self.errors.append(repr(error))

    def respond(self, data, tcp, send, address):
        try:
            ident, flags, qd, an, ns, ar = struct.unpack('!6H', data[:12])
            at, labels = 12, []
            while data[at]:
                size = data[at]
                labels.append(data[at + 1:at + 1 + size].decode())
                at += size + 1
            at += 1
            qtype, qclass = struct.unpack('!HH', data[at:at + 4])
            assert (flags, qd, an, ns, ar, qtype, qclass) == (256, 1, 0, 0, 0, 1, 1)
            assert at + 4 == len(data)
            domain = '.'.join(labels)
            self.requests.append((tcp, domain, time.monotonic(), ident))
            q = data[12:]
            answer, count, flags, extra, additional = rr(b'\xc0\x0c'), 1, 0x8180, b'', 0
            mode = self.mode
            if mode in ('silent', 'cancel-udp') or (mode == 'cancel-cname' and domain == 'alias.test'):
                return
            if mode in ('tc', 'shared-deadline', 'tcp-timeout', 'cancel-tcp', 'tcp-eof',
                        'tcp-short-length', 'tcp-long-length', 'tcp-tc', 'tcp-wrong-id', 'tcp-max',
                        'tcp-surplus') and not tcp:
                if mode == 'shared-deadline':
                    self.stop.wait(.17)
                flags, answer, count = 0x8380, b'', 0
            elif mode in ('nx', 'servfail', 'nodata'):
                flags = {'nx': 0x8183, 'servfail': 0x8182, 'nodata': 0x8180}[mode]
                answer, count = b'', 0
            elif mode == 'multi':
                q = name(domain.upper()) + struct.pack('!HH', 1, 1)
                answer += rr(domain, data=socket.inet_aton('192.0.2.18'))
                count = 2
            elif mode == 'wrong-source':
                packet = struct.pack('!6H', ident, flags, 1, count, 0, 0) + q + answer
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rogue:
                    rogue.sendto(packet, address)
                return
            elif mode in ('wrong-id', 'flood'):
                packet = struct.pack('!6H', ident ^ 1, flags, 1, count, 0, 0) + q + answer
                until = time.monotonic() + .6
                while not self.stop.is_set():
                    send(packet)
                    if mode == 'wrong-id' or time.monotonic() >= until:
                        break
                    self.stop.wait(.003)
                return
            elif mode == 'qr':
                flags &= ~0x8000
            elif mode == 'opcode':
                flags |= 0x800
            elif mode in ('question', 'tc-question'):
                q = name('wrong.test') + struct.pack('!HH', 1, 1)
                if mode == 'tc-question':
                    flags |= 0x200
            elif mode == 'question-label-dot':
                q = bytes([len(domain)]) + domain.encode() + b'\0' + struct.pack('!HH', 1, 1)
            elif mode == 'qtype':
                q = q[:-4] + struct.pack('!HH', 28, 1)
            elif mode == 'qclass':
                q = q[:-2] + struct.pack('!H', 3)
            elif mode == 'qd':
                qd = 2
            elif mode in ('cname', 'cname-only', 'cancel-cname', 'cycle', 'hops', 'hops-16',
                          'cumulative-hops', 'questions'):
                if mode == 'cname':
                    # A before its CNAME, and an unrelated A before both.
                    answer = rr('other.test', data=socket.inet_aton(OLD)) + rr('alias.test')
                    answer += rr(domain, 5, name('alias.test'))
                    count = 3
                elif mode in ('cname-only', 'cancel-cname'):
                    if domain == 'node.test':
                        answer = rr(domain, 5, name('alias.test'))
                elif mode == 'cycle':
                    answer = rr(domain, 5, name('alias.test')) + rr('alias.test', 5, name(domain))
                    count = 2
                elif mode in ('hops', 'hops-16'):
                    hops = 16 if mode == 'hops-16' else 17
                    names = [domain] + [f'c{i}.test' for i in range(hops)]
                    answer = b''.join(rr(a, 5, name(b)) for a, b in zip(names, names[1:]))
                    answer += rr(names[-1])
                    count = hops + 1
                elif mode == 'cumulative-hops':
                    n = len(self.requests)
                    middle, target = f'm{n}.test', f'q{n}.test'
                    answer = rr(domain, 5, name(middle)) + rr(middle, 5, name(target))
                    count = 2
                else:
                    ordinal = len(self.requests)
                    answer = rr(domain, 5, name(f'q{ordinal}.test'))
            elif mode == 'unrelated':
                answer = rr('unrelated.test')
                extra, additional = rr(domain), 1
            elif mode == 'additional':
                answer, count = b'', 0
                extra, additional = rr(domain), 1
            elif mode == 'short':
                send(struct.pack('!H', ident) + b'\0' * 7)
                return
            elif mode == 'pointer-cycle':
                offset = 12 + len(q)
                answer = rr(struct.pack('!H', 0xc000 | offset))
            elif mode == 'pointer-out':
                answer = rr(b'\xff\xff')
            elif mode == 'bad-a':
                answer = rr(domain, data=b'\x01\x02\x03')
            elif mode == 'rr-boundary':
                answer = answer[:-1]
            elif mode == 'name-long':
                answer = rr((b'\x3f' + b'a' * 63) * 4 + b'\0')
            elif mode == 'cname-boundary':
                answer = rr(domain, 5, name('alias.test') + b'\0')
            elif mode == 'pointer-budget':
                # 129 valid backward pointers in opaque TXT RDATA, then an owner
                # referring to that chain. No cycles, only the hop budget rejects it.
                offset = 12 + len(q) + 12
                chain, previous = bytearray(), 12
                for i in range(129):
                    chain += struct.pack('!H', 0xc000 | previous)
                    previous = offset + i * 2
                answer = rr(b'\xc0\x0c', 16, bytes(chain)) + rr(struct.pack('!H', 0xc000 | previous))
                count = 2
            if tcp and mode == 'tcp-tc':
                flags |= 0x200
            if tcp and mode == 'tcp-wrong-id':
                ident ^= 1
            if tcp and mode == 'tcp-max':
                # Exactly 65535 bytes, including a complete opaque additional RR.
                base = 12 + len(q) + len(answer)
                extra = rr(b'\xc0\x0c', 16, b'x' * (65535 - base - 12))
                additional = 1
            packet = struct.pack('!6H', ident, flags, qd, count, 0, additional) + q + answer + extra
            if mode == 'trailing':
                packet += b'\0'
            if mode == 'section-count':
                packet = packet[:10] + struct.pack('!H', 1) + packet[12:]
            send(packet)
        except Exception as error:
            self.errors.append(repr(error))

    def close(self):
        self.stop.set()
        for thread in self.threads:
            thread.join(5)
        for worker in self.workers:
            worker.join(5)
        self.udp.close()
        self.tcp.close()
        assert not any(t.is_alive() for t in self.threads + self.workers)
        assert not self.errors, self.errors


@contextlib.contextmanager
def authority(mode='answer'):
    server = Authority(mode)
    try:
        yield server
    finally:
        server.close()


def invoke(directory, server=None, cancel=None, **kwargs):
    opts = {'dir': str(directory), 'endpoint': server.endpoint if server else None, **kwargs}
    started = time.monotonic()
    proc = subprocess.Popen([str(UCODE), str(DRIVER), '--', json.dumps(opts)], cwd=ROOT,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stderr.readline() == 'READY\n'
    if cancel:
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if cancel(server):
                break
            time.sleep(.005)
        else:
            proc.kill()
            raise AssertionError('cancel prerequisite request not observed')
        time.sleep(.03)
        proc.send_signal(signal.SIGTERM)
    out, err = proc.communicate(timeout=12)
    assert proc.returncode == 0 and not err, (proc.returncode, out, err)
    value = json.loads(out)
    assert value['before'] == value['after'], ('FD leak', value)
    return value, time.monotonic() - started


def run(directory):
    (directory / 'run').mkdir()

    def selected(group):
        return ONLY is None or ONLY == group

    if selected('Q1'):
        pure = subprocess.run([str(UCODE), '-e', "import * as t from '" +
                              str(ROOT / 'tests/unit/bootstrap-dns.uc') + "'; "
                              "for (let c in t.cases) { let r = t.run(c); "
                              "if (r != 'PASS') die(c.name + ': ' + r); print('PASS  ', c.name, '\\n'); }"],
                              cwd=ROOT, capture_output=True, text=True)
        assert pure.returncode == 0, pure.stderr
        print(pure.stdout, end='', flush=True)
    if selected('Q2'):
        with authority() as server:
            value, _ = invoke(directory, server, apply=True, domain='192.0.2.1', endpoint=None)
            check('Q2 literal zero DNS without endpoint', value['results'][0]['source'] == 'literal' and
                  not server.requests)
            (directory / 'state').mkdir(exist_ok=True)
            cache = directory / 'state' / LKG_FILE
            cache.write_text(json.dumps({'nodes': {'node.test': OLD, 'bad..test': OLD}}))
            initial = cache.read_bytes()
            for endpoint in (None, {'address': 'localhost', 'port': server.port},
                             {'address': '127.0.0.1', 'port': 53}):
                value, _ = invoke(directory, server, apply=True, endpoint=endpoint)
                check('Q2 invalid endpoint fails without DNS LKG retry', not value['results'][0]['ok'] and
                      not server.requests and cache.read_bytes() == initial and
                      not (directory / 'run/events.jsonl').exists())
            value, _ = invoke(directory, server, apply=True, domain='bad..test')
            check('Q2 invalid domain bypasses warm LKG and network', not value['results'][0]['ok'] and
                  not server.requests and cache.read_bytes() == initial)
            cache.unlink()
        # Both modules must not invoke system resolution; path allowlisting is tested above.
        source = (ROOT / 'aether-proxy/src/lib/bootstrap_dns.uc').read_text()
        check('Q2 no system resolver or command API', all(token not in source for token in
              ('getaddrinfo', 'resolveip', 'sys.run', 'fs.popen', 'system(')))
    if selected('Q3'):
        with authority('multi') as server:
            value, _ = invoke(directory, server)
            check('Q3 A IN case insensitive first wire IPv4', value['results'][0] == {'ok': True, 'ip': IP} and
                  len(server.requests) == 1 and not server.requests[0][0])
    if selected('Q4'):
        for mode in ('wrong-source', 'wrong-id', 'qr', 'opcode', 'question', 'question-label-dot',
                     'qtype', 'qclass', 'qd', 'tc-question'):
            with authority(mode) as server:
                value, _ = invoke(directory, server, timeout=100)
                check('Q4 reject ' + mode, not value['results'][0]['ok'] and len(server.requests) == 1)
    if selected('Q5'):
        for mode in ('shared-deadline', 'tc', 'tcp-max', 'tcp-eof', 'tcp-short-length', 'tcp-long-length',
                     'tcp-tc', 'tcp-wrong-id', 'tcp-timeout', 'tcp-surplus'):
            with authority(mode) as server:
                value, elapsed = invoke(directory, server, timeout=300)
                if mode in ('tc', 'tcp-max'):
                    check('Q5 same endpoint fragmented ' + mode, value['results'][0].get('ip') == IP and
                          [r[0] for r in server.requests] == [False, True] and
                          server.requests[0][3] == server.requests[1][3])
                elif mode == 'shared-deadline':
                    check('Q5 UDP TCP share original deadline', not value['results'][0]['ok'] and
                          .27 < elapsed < .46 and [r[0] for r in server.requests] == [False, True])
                else:
                    check('Q5 reject ' + mode, not value['results'][0]['ok'] and elapsed < .6)
    if selected('Q6'):
        for mode in ('cname', 'cname-only', 'hops-16', 'cycle', 'hops', 'cumulative-hops',
                     'questions', 'unrelated', 'additional'):
            with authority(mode) as server:
                value, _ = invoke(directory, server, timeout=800)
                r = value['results'][0]
                if mode in ('cname', 'cname-only', 'hops-16'):
                    check('Q6 associated ' + mode, r.get('ip') == IP and
                          len(server.requests) == (2 if mode == 'cname-only' else 1))
                else:
                    check('Q6 reject ' + mode, not r['ok'] and len(server.requests) <= 16)
    if selected('Q7'):
        for mode in ('short', 'pointer-cycle', 'pointer-out', 'pointer-budget', 'rr-boundary',
                     'bad-a', 'trailing', 'section-count', 'name-long', 'cname-boundary'):
            with authority(mode) as server:
                value, elapsed = invoke(directory, server, timeout=300)
                check('Q7 reject malformed ' + mode, not value['results'][0]['ok'] and elapsed < .6)
    if selected('Q8'):
        state = directory / 'state'
        state.mkdir(exist_ok=True)
        # Use the actual constant, not a test-owned alternative LKG format/path.
        cache = state / LKG_FILE
        for mode in ('answer', 'nx', 'servfail', 'nodata', 'silent'):
            cache.write_text(json.dumps({'nodes': {'node.test': OLD}}))
            before = cache.read_bytes()
            with authority(mode) as server:
                value, elapsed = invoke(directory, server, apply=True)
                r = value['results'][0]
                if mode == 'answer':
                    check('Q8 DNS precedes warm LKG', r.get('source') == 'dns' and r.get('ip') == IP and
                          len(server.requests) == 1 and json.loads(cache.read_text())['nodes']['node.test'] == IP)
                else:
                    check('Q8 three DNS attempts before ' + mode + ' LKG', r.get('source') == 'lkg' and
                          r.get('ip') == OLD and len(server.requests) == 3 and cache.read_bytes() == before)
                    if mode == 'silent':
                        check('Q10 three default rounds bounded nine seconds', 8.9 < elapsed < 10.2)
        cache.unlink()
        with authority('nx') as server:
            value, _ = invoke(directory, server, apply=True)
            events = (directory / 'run/events.jsonl').read_text()
            check('Q8 no LKG explicit failure and final events', not value['results'][0]['ok'] and
                  len(server.requests) == 3 and 'NODE_RESOLVE_FAILED' in events and
                  'NODE_RESOLVE_FALLBACK' in events)
        # A regular file cannot be the parent of an atomic LKG write (also fails as root).
        cache.parent.rmdir()
        state.write_text('blocked')
        try:
            with authority() as server:
                value, _ = invoke(directory, server, apply=True)
                check('Q8 LKG write failure is not success or fallback', not value['results'][0]['ok'] and
                      len(server.requests) == 1)
        finally:
            state.unlink()
    if selected('Q9'):
        for mode in ('cancel-udp', 'cancel-tcp', 'cancel-cname'):
            with authority(mode) as server:
                directory.joinpath('state').mkdir(exist_ok=True)
                cache = directory / 'state' / LKG_FILE
                cache.write_text(json.dumps({'nodes': {'node.test': OLD}}))
                before = cache.read_bytes()
                event_file = directory / 'run/events.jsonl'
                old_events = event_file.read_bytes() if event_file.exists() else b''
                ready = lambda s: len(s.requests) >= (1 if mode == 'cancel-udp' else 2)
                value, elapsed = invoke(directory, server, apply=True, cancel=ready)
                r = value['results'][0]
                check('Q9 real SIGTERM ' + mode + ' no retry write fallback', r.get('cancelled') is True and
                      not r['ok'] and len(server.requests) == (1 if mode == 'cancel-udp' else 2) and
                      cache.read_bytes() == before and elapsed < .8 and value['stopped'] and
                      (event_file.read_bytes() if event_file.exists() else b'') == old_events)
    if selected('Q10'):
        for mode in ('answer', 'nx', 'flood'):
            with authority(mode) as server, authority() as other:
                value, elapsed = invoke(directory, server, timeout=60, repeat=15)
                check('Q10 repeated ' + mode + ' stable FD and bounded activity', value['before'] == value['after'] and
                      all(r['ok'] == (mode == 'answer') for r in value['results']) and elapsed < 1.5)
                value, _ = invoke(directory, other)
                check('Q10 other endpoint unaffected by ' + mode, value['results'][0].get('ip') == IP)
        with authority('silent') as server:
            value, elapsed = invoke(directory, server)
            check('Q10 default single round three seconds', not value['results'][0]['ok'] and 2.9 < elapsed < 3.7)
        with authority('cancel-udp') as server:
            # Repeated cancellation in one process with real, independently delivered signals.
            opts = {'dir': str(directory), 'endpoint': server.endpoint, 'repeat': 8}
            proc = subprocess.Popen([str(UCODE), str(DRIVER), '--', json.dumps(opts)], cwd=ROOT,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert proc.stderr.readline() == 'READY\n'
            for ordinal in range(1, 9):
                until = time.monotonic() + 1
                while len(server.requests) < ordinal and time.monotonic() < until:
                    time.sleep(.003)
                assert len(server.requests) == ordinal
                proc.send_signal(signal.SIGTERM)
            out, err = proc.communicate(timeout=2)
            assert not err and proc.returncode == 0, (out, err)
            value = json.loads(out)
            check('Q10 repeated real cancellation stable FD', value['before'] == value['after'] and
                  all(r.get('cancelled') for r in value['results']))
    if selected('Q11'):
        paths = ['daemon.uc', 'reload.uc', 'monitor.uc', 'dns_test.uc']
        for path in paths:
            relative = 'aether-proxy/src/lib/' + path
            original = subprocess.check_output(['git', 'show', 'main:' + relative], cwd=ROOT)
            check('Q11 unchanged ' + path, (ROOT / relative).read_bytes() == original)
        source = (ROOT / 'aether-proxy/src/lib/apply.uc').read_text()
        old = subprocess.check_output(['git', 'show', 'main:aether-proxy/src/lib/apply.uc'], cwd=ROOT, text=True)
        start, end = 'function resolve_node(ctx, address) {', '\n// Deliberately not used'
        check('Q11 original resolve_node unchanged', source.split(start)[1].split(end)[0].strip() ==
              old.split(start)[1].split('\nfunction write_boot_list')[0].strip())


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.runtime-', dir=ROOT / 'tests/bootstrap-dns') as temp:
        run(Path(temp))
    print('PASS  T15.4 selected integration scenarios complete', flush=True)
