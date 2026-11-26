#!/usr/bin/env python3
"""T16.114: byte-exact DNS rollback, using TierFixture and real loopback sockets.

The DNS process is a Python STUB, not chinadns-ng: synthetic /proc ownership
exercises the monitor gate; real UDP/TCP DNS replies prove which config it serves.
--monitor-source permits the identical regression against a saved baseline.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import signal
import socket
import struct
import tempfile

spec = importlib.util.spec_from_file_location('tier_ready', pathlib.Path(__file__).with_name('tier-dns-ready.py'))
ready = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ready)
check, wait_for = ready.check, ready.wait_for

# Add wire-level service to the existing ownership/readiness stub, not a second
# independent responder that could survive the managed child being killed.
WIRE = r'''
import socket
import struct
import threading
wire_started = False
answer = socket.inet_aton('192.0.2.11' if '127.0.0.1#' in trust_dns else '192.0.2.22')

def reply(query):
    end = 12
    while query[end]:
        end += query[end] + 1
    end += 5
    return query[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + query[12:end] + b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 0, 4) + answer

def serve_udp(sock):
    while not stop:
        try:
            query, addr = sock.recvfrom(2048)
            sock.sendto(reply(query), addr)
        except socket.timeout:
            pass

def serve_tcp(sock):
    while not stop:
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            continue
        with conn:
            conn.settimeout(1)
            header = conn.recv(2)
            if len(header) != 2:
                continue
            size = struct.unpack('!H', header)[0]
            query = b''
            while len(query) < size:
                part = conn.recv(size - len(query))
                if not part:
                    break
                query += part
            if len(query) == size:
                data = reply(query)
                conn.sendall(struct.pack('!H', len(data)) + data)

def start_wire():
    global wire_started
    if wire_started:
        return
    sockets = []
    for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
        sock = socket.socket(socket.AF_INET, kind)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((bind_addr, bind_port))
        sock.settimeout(.1)
        if kind == socket.SOCK_STREAM:
            sock.listen(8)
        sockets.append(sock)
    for sock, target in zip(sockets, (serve_udp, serve_tcp)):
        threading.Thread(target=target, args=(sock,), daemon=True).start()
    wire_started = True
    trace(f'wire-stub-ready {pid} {socket.inet_ntoa(answer)}')
'''


class Fixture(ready.TierFixture):
    def __init__(self, base, name, monitor_source=None):
        super().__init__(base, name)
        if monitor_source:
            (self.modules / 'monitor.uc').write_bytes(monitor_source.read_bytes())
        stub = ready.FORMAL_DNS_STUB.replace(
            'def publish_owned(port,', WIRE + '\n\ndef publish_owned(port,')
        stub = stub.replace('    tcp_inode = 90000',
                            '    if include_tcp and include_udp:\n        start_wire()\n    tcp_inode = 90000')
        (self.bin / 'chinadns-ng').write_text(stub)
        killall = self.bin / 'killall'
        # Only the first requested HUP fails; restoration must attempt a second.
        killall.write_text('''#!/bin/sh
printf 'killall %s\\n' "$*" >> "$STUB_LOG"
case "$1" in
 -0) exit 1 ;;
 -HUP)
  if [ -f "$SYSROOT/fail-next-hup" ] || [ -f "$SYSROOT/fail-all-hups" ]; then
   rm "$SYSROOT/fail-next-hup"
   printf 'hup-result failed\\n' >> "$STUB_LOG"
   exit 1
  fi
  printf 'hup-result ok\\n' >> "$STUB_LOG" ;;
esac
exit 0
''')

    def wait_running_t1(self):
        super().wait_running_t1()
        self.tier_before = len(self.events('DNS_TIER_CHANGED'))

    @property
    def config(self):
        return self.run / 'current/chinadns.conf'

    def fail_tick(self, proc, behaviors):
        self.queue_behaviors(behaviors)
        (self.root / 'curl-fail').touch()
        self.trigger_tick(proc)

    def failure_done(self, before=0):
        wait_for(lambda: len(self.events('START_FAILED')) > before and self.lock_free(),
                 timeout=15, label=self.base.name + ' failed action settled')


def query(tcp, serial):
    name = f'fresh-{serial}.rollback.test'
    ident = serial % 65536
    q = struct.pack('!HHHHHH', ident, 0x100, 1, 0, 0, 0)
    q += b''.join(bytes([len(x)]) + x.encode() for x in name.split('.')) + b'\0\0\1\0\1'
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as s:
        s.settimeout(1)
        s.connect(('127.0.0.1', 31053))
        if tcp:
            s.sendall(struct.pack('!H', len(q)) + q)
            def receive(n):
                data = b''
                while len(data) < n:
                    part = s.recv(n - len(data))
                    if not part:
                        raise AssertionError('short TCP DNS response')
                    data += part
                return data
            data = receive(struct.unpack('!H', receive(2))[0])
        else:
            s.send(q)
            data = s.recv(2048)
    assert data[:2] == q[:2] and data[12:12 + len(q) - 12] == q[12:], 'fresh query mismatch'
    assert struct.unpack('!H', data[6:8])[0] == 1, 'expected one answer'
    return socket.inet_ntoa(data[-4:])


def answers(serial):
    return (query(False, serial), query(True, serial + 1))


def verify_restored(f, old, offset, initial_answers):
    calls = f.calls()[offset:]
    forks = [l for l in calls if l.startswith('dns-forked ')]
    try:
        fresh = answers(301)
    except OSError as error:
        fresh = str(error)
    print('EVIDENCE', json.dumps({'case': f.base.name, 'tier': f.state().get('dns_tier'),
          'byte_identical': f.config.read_bytes() == old, 'stub_forks': forks,
          'real_loopback_fresh_answers': fresh, 'engine': 'Python stub, NOT chinadns-ng'}), flush=True)
    check(f.state().get('dns_tier') == 'T1', f'{f.base.name}: old tier label')
    check(f.config.read_bytes() == old, f'{f.base.name}: old config byte-identical',
          f'old={hashlib.sha256(old).hexdigest()} current={hashlib.sha256(f.config.read_bytes()).hexdigest()}')
    check(len(forks) == 2, f'{f.base.name}: candidate plus exactly one restoration generation', str(forks))
    candidate = forks[0].split()[1]
    restored = forks[1].split()[1]
    check(any(l.startswith(f'dns-exit {candidate} ') for l in calls)
          and not (f.root / 'proc' / candidate).exists(), f'{f.base.name}: candidate gone')
    check(fresh == initial_answers == ('192.0.2.11', '192.0.2.11'),
          f'{f.base.name}: real loopback UDP/TCP fresh answers from old-config STUB generation {restored}')
    check(len(f.events('DNS_TIER_CHANGED')) == f.tier_before, f'{f.base.name}: no false successful tier event')
    return calls


def failure(base, mode, monitor_source=None, retry=False):
    f = Fixture(base, mode, monitor_source)
    with f.daemon() as proc:
        f.wait_running_t1()
        old = f.config.read_bytes()
        # Deliberately non-renderable formatting ensures rollback restores bytes,
        # rather than regenerating the previous tier from mutable config inputs.
        old += b'\n# byte-exact rollback sentinel\n'
        f.config.write_bytes(old)
        initial = answers(101)
        offset = len(f.calls())
        behavior = 'exit_early' if mode == 'exit' else 'impostor_only' if mode == 'timeout' else 'normal'
        if mode in ('hup', 'hup-both'):
            (f.root / ('fail-all-hups' if mode == 'hup-both' else 'fail-next-hup')).touch()
        f.fail_tick(proc, [{'mode': behavior}, {'mode': 'normal'}])
        f.failure_done()
        calls = verify_restored(f, old, offset, initial)
        detail = f.events('START_FAILED')[-1]['args']['detail']
        expected = {'exit': 'child exited or changed generation', 'timeout': 'required sockets not ready',
                    'hup': 'dnsmasq', 'hup-both': 'dnsmasq'}[mode]
        check(expected in detail and 'set_tier:T2:' in detail,
              mode + ': original failure retained', detail)
        hups = [i for i, l in enumerate(calls) if l == 'killall -HUP dnsmasq']
        wire = [i for i, l in enumerate(calls) if l.startswith('wire-stub-ready ')]
        if mode in ('hup', 'hup-both'):
            results = ['hup-result failed', 'hup-result failed' if mode == 'hup-both' else 'hup-result ok']
            check(len(hups) == 2 and wire[0] < hups[0] < wire[1] < hups[1]
                  and [l for l in calls if l.startswith('hup-result ')] == results,
                  mode + ': ready/notification causal order and results', str(calls))
            if mode == 'hup-both':
                parts = detail.split('rollback_dns:')
                check(len(parts) == 2 and all('dnsmasq' in part for part in parts),
                      'hup-both: forward and rollback notification errors retained', detail)
        else:
            check(not hups, mode + ': no HUP when forward notification not attempted')
        if retry:
            f.trigger_tick(proc)
            wait_for(lambda: f.state().get('dns_tier') == 'T2' and f.lock_free(), label='retry T2')
            check(answers(401) == ('192.0.2.22', '192.0.2.22'), 'retry: fresh candidate answers over real UDP/TCP')
            check(len(f.events('DNS_TIER_CHANGED')) == f.tier_before + 1, 'retry: one successful event and released busy/lock')
        print('TRACE', mode, json.dumps([l for l in calls if l.startswith(('dns-', 'wire-', 'killall -HUP', 'hup-result'))]), flush=True)


def restoration_failure(base, monitor_source=None):
    f = Fixture(base, 'restoration-failure', monitor_source)
    with f.daemon() as proc:
        f.wait_running_t1()
        old = f.config.read_bytes()
        f.fail_tick(proc, [{'mode': 'exit_early'}, {'mode': 'impostor_only'}])
        f.failure_done()
        detail = f.events('START_FAILED')[-1]['args']['detail']
        check('child exited or changed generation' in detail and 'rollback_dns:' in detail
              and 'required sockets not ready' in detail, 'restoration failure: both independent errors retained', detail)
        check(f.config.read_bytes() == old and f.state().get('dns_tier') == 'T1',
              'restoration failure: original bytes and label retained without success claim')
        check(len(f.events('DNS_TIER_CHANGED')) == f.tier_before, 'restoration failure: no successful tier event')


def missing_old_config(base, monitor_source=None):
    f = Fixture(base, 'missing-old-config', monitor_source)
    with f.daemon() as proc:
        f.wait_running_t1()
        old = f.config.read_bytes()
        initial = answers(501)
        offset = len(f.calls())
        f.config.unlink()
        f.fail_tick(proc, [])
        f.failure_done()
        calls = f.calls()[offset:]
        check(not any(l.startswith(('dns-forked ', 'dns-exit ', 'killall -HUP')) for l in calls),
              'missing old config: no process/notification side effects')
        check(not f.config.exists() and answers(601) == initial,
              'missing old config: no publication; previous STUB still answers fresh UDP/TCP')
        check(len(f.events('DNS_TIER_CHANGED')) == f.tier_before,
              'missing old config: no success event')
        f.config.write_bytes(old)


def term(base, rollback, monitor_source=None):
    f = Fixture(base, 'term-rollback' if rollback else 'term-forward', monitor_source)
    with f.daemon() as proc:
        f.wait_running_t1()
        offset = len(f.calls())
        (f.root / 'term-gate').write_text('hold')
        behaviors = ([{'mode': 'exit_early'}] if rollback else []) + [{'mode': 'barrier', 'gate': 'term-gate'}]
        f.fail_tick(proc, behaviors)
        count = 2 if rollback else 1
        wait_for(lambda: len([l for l in f.calls()[offset:] if l.startswith('dns-forked ')]) == count,
                 label='TERM held at ' + ('rollback' if rollback else 'forward') + ' readiness barrier')
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=4)
        calls = f.calls()[offset:]
        check(len([l for l in calls if l.startswith('dns-forked ')]) == count,
              f'{f.base.name}: no respawn after TERM at deterministic readiness barrier')
        check('killall -HUP dnsmasq' not in calls and len(f.events('DNS_TIER_CHANGED')) == f.tier_before,
              f'{f.base.name}: no notification/success after TERM')
        check(f.state().get('state') == 'stopped' and f.lock_free(), f'{f.base.name}: stopped and lock released')
        check(not f.events('START_FAILED'), f'{f.base.name}: cancellation completes without action error')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--monitor-source', type=pathlib.Path)
    parser.add_argument('cases', nargs='*', choices=['exit', 'timeout', 'hup', 'hup-both', 'missing-config', 'restore-fail', 'term-forward', 'term-rollback', 'normal', 't3-retry'])
    args = parser.parse_args()
    cases = args.cases or ['exit', 'timeout', 'hup', 'hup-both', 'missing-config', 'restore-fail', 'term-forward', 'term-rollback', 'normal', 't3-retry']
    with tempfile.TemporaryDirectory(prefix='t16114-tier-rollback-') as tmp:
        base = pathlib.Path(tmp)
        for case in cases:
            if case in ('exit', 'timeout', 'hup', 'hup-both'):
                failure(base, case, args.monitor_source, retry=case == 'exit')
            elif case == 'missing-config':
                missing_old_config(base, args.monitor_source)
            elif case == 'restore-fail':
                restoration_failure(base, args.monitor_source)
            elif case.startswith('term-'):
                term(base, case == 'term-rollback', args.monitor_source)
            else:
                if args.monitor_source:
                    parser.error('normal/t3-retry reuse existing production fixture; no monitor override')
                (ready.scenario_barrier_impostor_and_tcp_only if case == 'normal' else ready.scenario_t3_retry_t2_policy)(base)
    print(f'T16.114 tier-dns-rollback: {ready.passed} passed; wire evidence is Python STUB, not real DNS engine', flush=True)


if __name__ == '__main__':
    main()
