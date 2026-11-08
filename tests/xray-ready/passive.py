#!/usr/bin/env python3
"""T15.7: kernel/real listener counts, then labelled transport fault boundaries."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

from run import endpoint, listener, run, fixture, row, finish
from minimal import Minimal

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
passed = 0


def check(value, label):
    global passed
    if not value:
        raise AssertionError(label)
    passed += 1
    print('PASS ', label, flush=True)


def inode(pid, port):
    owned = {os.readlink(p) for p in Path(f'/proc/{pid}/fd').iterdir()}
    for line in Path(f'/proc/{pid}/net/tcp6').read_text().splitlines()[1:]:
        f = line.split()
        if int(f[1].split(':')[1], 16) == port and f'socket:[{f[9]}]' in owned:
            return int(f[9])
    raise AssertionError('real child must own candidate inode')


def message(kind, payload, flags=2, seq=1, endian='<'):
    wire = struct.pack(endian + 'IHHII', 16 + len(payload), kind, flags, seq, 12345) + payload
    return wire + b'\0' * (-len(wire) % 4)


def attr(kind, value=b'\0', endian='<'):
    wire = struct.pack(endian + 'HH', 4 + len(value), kind) + value
    return wire + b'\0' * (-len(wire) % 4)


def record(port, ino, v6only=0, endian='<', extra=b''):
    body = bytearray(72)
    body[0:2] = bytes([socket.AF_INET6, 10])
    body[4:6] = struct.pack('!H', port)
    body[68:72] = struct.pack(endian + 'I', ino)
    return bytes(body) + (attr(11, bytes([v6only]), endian) if v6only is not None else b'') + extra


def done(endian='<', flags=2, status=0):
    return message(3, struct.pack(endian + 'i', status), flags, endian=endian)


def request_wire(port, seq=1, endian='<'):
    body = bytes([socket.AF_INET6, socket.IPPROTO_TCP, 0, 0]) + struct.pack(endian + 'I', 1 << 10)
    body += struct.pack('!HH', port, 0) + bytes(36) + bytes([255]) * 8
    return struct.pack(endian + 'IHHII', 72, 20, 0x301, seq, 0) + body


def handler_error(port, echo=None, **fields):
    echoed = request_wire(port) if echo is None else echo
    return message(2, struct.pack('<i', -2) + echoed, **fields)


def boundary(base):
    base.mkdir()
    iso = Minimal(base)
    shutil.copyfile(HERE / 'diag_socket.uc', iso.modules / 'diag_socket.uc')
    path = iso.modules / 'aetherproxy/socket_diag.uc'
    path.write_text(path.read_text().replace("import * as socket from 'socket';",
                                           "import * as socket from 'diag_socket';"))
    wire = base / 'wire.json'
    iso.env['DIAG_WIRE'] = str(wire)
    return iso, wire


def set_wire(path, messages=(), **fields):
    path.write_text(json.dumps(dict(messages=[list(m) for m in messages], **fields)))


def count(path):
    time.sleep(0.05)  # let the real accept loop observe any completed handshake
    return int(path.read_text())


def kernel(tmp):
    ep = endpoint(role='tproxy', address='0.0.0.0')
    counter = tmp / 'accepts'
    with listener(tmp, [dict(ep, address='::', v6only=0, count_path=str(counter))]) as child:
        result = run(tmp, child.pid, [ep], repeat=50)
        check(result['ok'] and result['successes'] == 50 and result['fd_delta'] == 0,
              'P1 kernel real dual-stack owned listener ready; 50 waits FD stable')
        check(count(counter) == 0, 'P1 kernel supported path accepts exactly zero probe connections')
        # Positive instrumentation control: the listener really counts a handshake.
        with socket.create_connection(('127.0.0.1', ep['port'])):
            pass
        check(count(counter) == 1, 'P1 counter positive control observes one ordinary IPv4 handshake')
        (tmp / 'minimal').mkdir()
        iso = Minimal(tmp / 'minimal')
        result, _ = iso.run(child.pid, [ep], repeat=20)
        check(result['ok'] and result['fd_delta'] == 0 and count(counter) == 1,
              'P6 minimal five modules execute real passive diag; struct double negative; zero new accepts')
        # The fixture has the real port/inode but is not allowed to borrow its kernel.
        root, proc = fixture(tmp, [(dict(ep, address='::'), None)])
        result = run(tmp, 123, [ep], root=str(root), opts={'timeout_ms': 80})
        check(not result['ok'] and count(counter) == 1,
              'P6 rooted tcp6 fixture borrows neither host netlink nor host listener')
    with listener(tmp, [dict(ep, address='::', v6only=1, count_path=str(counter))]) as child:
        with listener(tmp, [dict(ep, address='127.0.0.1')]) as other:
            result = run(tmp, child.pid, [ep], opts={'timeout_ms': 80})
            check(not result['ok'] and result['fd_delta'] == 0 and count(counter) == 0,
                  'P2 kernel v6only plus competing IPv4 owner cannot satisfy IPv4')
    ep = endpoint(address='::1')
    with listener(tmp, [ep]) as child:
        check(not run(tmp, child.pid, [dict(ep, address='127.0.0.1')], opts={'timeout_ms': 80})['ok'],
              'P2 kernel ::1 cannot impersonate IPv4 loopback')
    ep = endpoint()
    with listener(tmp, [ep]) as child:
        check(run(tmp, child.pid, [ep])['ok'], 'P2 kernel explicit IPv4 remains ready')
    with listener(tmp, [dict(ep, address='::ffff:127.0.0.1', v6only=0, count_path=str(counter))]) as child:
        check(run(tmp, child.pid, [ep])['ok'] and count(counter) == 0,
              'P2 kernel mapped IPv4 follows original no-connect tuple rule')

    binary = Path('/workspace/openwrt/ci-spike/tools/xray-26.10.31/xray')
    check(binary.is_file(), 'P7 cached real Xray is available (no download)')
    config = tmp / 'xray.json'
    ep = endpoint(role='tproxy', address='0.0.0.0')
    config.write_text(json.dumps(dict(inbounds=[dict(listen='::', port=ep['port'], protocol='tunnel',
        settings=dict(address='192.0.2.1', port=443, network='tcp'))], outbounds=[dict(protocol='blackhole')])))
    tested = subprocess.run([str(binary), 'run', '-test', '-c', str(config)], capture_output=True)
    check(tested.returncode == 0, 'P7 real Xray accepts unchanged tunnel configuration semantics')
    with (tmp / 'xray.log').open('w') as log:
        child = subprocess.Popen([str(binary), 'run', '-c', str(config)], stdout=log, stderr=log)
        try:
            result = run(tmp, child.pid, [ep], repeat=20)
            check(result['ok'] and result['fd_delta'] == 0,
                  'P7 actual Xray TCPv6 lifecycle uses real passive owned readiness')
        finally:
            child.terminate()
            child.wait(timeout=3)
    check(child.returncode == 0, 'P7 actual Xray lifecycle terminates cleanly')


def faults(tmp):
    ep = endpoint(role='tproxy', address='0.0.0.0')
    counter = tmp / 'fault-accepts'
    iso, wire = boundary(tmp / 'boundary')
    with listener(tmp, [dict(ep, address='::', v6only=0, count_path=str(counter))]) as child:
        ino = inode(child.pid, ep['port'])
        good = record(ep['port'], ino)
        start = count(counter)
        root, _ = fixture(tmp, [(dict(ep, address='::'), None)])
        set_wire(wire, [message(20, good), done()])
        result, stats = iso.run(123, [ep], root=str(root), opts={'timeout_ms': 80})
        check(not result['ok'] and stats['created'] == stats['closed'] == 0 and count(counter) == start,
              'P6 rooted fixture performs zero diag allocations and zero compatibility handshakes')
        for v6only in (0, 1):
            set_wire(wire, [message(20, record(ep['port'], ino, v6only)), done()])
            result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 80})
            check(result['ok'] == (v6only == 0) and result['fd_delta'] == 0 and count(counter) == start,
                  f'P3/P4 wire matched multipart v6only={v6only} never falls back')
        # These are transport boundary faults; readiness still reads the real
        # child/proc and must not connect to its working dual-stack listener.
        bad = {}
        for offset, value, label in [(0, 2, 'family'), (1, 1, 'state'), (4, 0, 'port'),
                                     (8, 1, 'address'), (68, (good[68] + 1) % 256, 'inode')]:
            data = bytearray(good)
            data[offset] = value
            if label == 'port':
                data[4:6] = b'\0\0'
            bad[label] = [message(20, bytes(data)), done()]
        bad.update({
            'sequence': [message(20, good, seq=2), done()],
            'short-header': [b'bad'],
            'short-record': [message(20, good[:71]), done()],
            'bad-length': [struct.pack('<I', 9999) + message(20, good)[4:]],
            'bad-attribute': [message(20, good[:72] + b'\3\0\13\0'), done()],
            'short-attribute': [message(20, good[:72] + b'x'), done()],
            'conflict': [message(20, good + attr(11, b'\1')), done()],
            'bad-protocol': [message(20, good + attr(10, b'\21')), done()],
            'interrupted': [message(20, good, flags=18), done()],
            'done-error': [message(20, good), done(status=-5)],
            'unknown-error': [message(2, struct.pack('<iIHHII', -5, 72, 20, 0x301, 1, 0))],
            'bad-error': [message(2, b'\1')],
            'empty-dump': [done()],
            'duplicate': [message(20, good) + message(20, good), done()],
            'after-done': [message(20, good) + done() + message(20, good)],
        })
        for label, messages in bad.items():
            set_wire(wire, messages)
            result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 100})
            check(not result['ok'] and not result.get('cancelled') and result['fd_delta'] == 0
                  and count(counter) == start, f'P3/P4 wire {label} fails closed with zero fallback accepts')
        set_wire(wire, [message(20, good)], flags=socket.MSG_TRUNC)
        result, _ = iso.run(child.pid, [ep])
        check(not result['ok'] and count(counter) == start and result['fd_delta'] == 0,
              'P3 wire truncated datagram cannot fall back')
        for label, fields in [
                ('unknown-create', dict(create_error=True, errno=5)),
                ('unknown-send', dict(send_error=True, errno=5)),
                ('receive', dict(receive_error=True)),
                ('poll', dict(poll_error=True)),
                ('close', dict(close_error=True)),
                ('missing-DONE', dict(timeout_after=1))]:
            set_wire(wire, [message(20, good), done()], **fields)
            result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 80},
                                repeat=5, continue_on_failure=True)
            check(not result['ok'] and result['fd_delta'] == 0 and count(counter) == start,
                  f'P3/P4 transport {label} never authorizes fallback; repeated FDs stable')
        # Legitimate compatibility cases must really invoke the old bounded probe.
        for label, fields, messages in [
                ('unsupported', dict(create_error=True, errno=97), []),
                ('permission', dict(create_error=True, errno=13), []),
                ('send-permission', dict(send_error=True, errno=1), []),
                ('netlink-unsupported', {}, [message(2, struct.pack('<iIHHII', -95, 72, 20, 0x301, 1, 0), flags=258)]),
                ('missing-attribute', {}, [message(20, record(ep['port'], ino, None)), done()])]:
            set_wire(wire, messages, **fields)
            result, _ = iso.run(child.pid, [ep])
            check(result['ok'] and result['fd_delta'] == 0 and count(counter) == start + 1,
                  f'P4 compatibility {label} uses exactly one counted legacy handshake')
            start += 1
        # No clean DONE means no missing-attribute authorization.
        set_wire(wire, timeout=True)
        result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 120}, repeat=10, continue_on_failure=True)
        check(not result['ok'] and 1150 <= result['elapsed_ms'] < 2100 and result['fd_delta'] == 0
              and count(counter) == start, 'P5 diag short budgets do not renew; repeated timeout FDs stable')
        set_wire(wire, timeout=True)
        for _ in range(3):
            proc = iso.begin(child.pid, [ep])
            time.sleep(0.15)
            proc.send_signal(signal.SIGTERM)
            result, _ = iso.finish(proc)
            check(result.get('cancelled') and result['elapsed_ms'] < 800 and result['fd_delta'] == 0
                  and count(counter) == start, 'P5 real SIGTERM interrupts diag wait without fallback or FD leak')
        result, _ = iso.run(child.pid, [ep])
        check(not result['ok'] and 4900 <= result['elapsed_ms'] < 5700 and result['fd_delta'] == 0
              and count(counter) == start, 'P5 diag consumes default shared five-second budget without fallback')
        set_wire(wire, [message(20, good), done()], delay=70)
        result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 110})
        check(not result['ok'] and result['elapsed_ms'] < 250 and count(counter) == start,
              'P5 multipart diag shares original short deadline')
        set_wire(wire, [message(20, record(ep['port'], ino, None)), done()], delay=70)
        result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 110})
        check(not result['ok'] and count(counter) == start,
              'P5 exhausted diag budget cannot start compatibility handshake')
        set_wire(wire, [message(20, record(ep['port'], ino, None)), done()], delay=20)
        result, _ = iso.run(child.pid, [ep], cancel_ms=30)
        check(result.get('cancelled') and count(counter) == start and result['fd_delta'] == 0,
              'P5 cancellation before fallback beats a working listener')
        set_wire(wire, [message(20, record(ep['port'], ino, None)), done()], delay=20)
        result, _ = iso.run(child.pid, [ep], change_ms=30, other_pid=child.pid + 999999)
        check(not result['ok'] and 'generation' in result['detail'] and count(counter) == start,
              'P4 changed child generation cannot enter compatibility handshake')

    other_counter = tmp / 'other-accepts'
    with listener(tmp, [dict(ep, address='::', v6only=1)]) as child:
        with listener(tmp, [dict(ep, address='127.0.0.1', count_path=str(other_counter))]):
            set_wire(wire, create_error=True, errno=97)
            result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 80})
            check(not result['ok'] and count(other_counter) == 0 and result['fd_delta'] == 0,
                  'P4 unsupported still rejects competing IPv4 ownership without probing impostor')


def handler_faults(tmp):
    """ENOENT is scoped to a clean correlated TCPv6 DUMP, never socket I/O."""
    ep = endpoint(role='tproxy', address='0.0.0.0')
    counter = tmp / 'handler-accepts'
    iso, wire = boundary(tmp / 'handler-boundary')
    with listener(tmp, [dict(ep, address='::', v6only=0, count_path=str(counter))]) as child:
        ino = inode(child.pid, ep['port'])
        error, completion = handler_error(ep['port']), done(status=-2)
        start = count(counter)
        for label, response in [('error', error), ('done', completion)]:
            set_wire(wire, [response])
            result, stats = iso.run(child.pid, [ep])
            check(result['ok'] and result['fd_delta'] == 0 and stats['created'] == stats['closed'] == 1
                  and count(counter) == start + 1,
                  f'P4 handler-missing {label} uses exactly one counted legacy handshake')
            start += 1

        bad = {
            'error-sequence': [handler_error(ep['port'], seq=2)],
            'done-sequence': [message(3, struct.pack('<i', -2), seq=2)],
            'error-short': [message(2, struct.pack('<i', -2) + request_wire(ep['port'])[:15])],
            'done-short': [message(3, b'\xfe\xff\xff')],
            'done-extra': [message(3, struct.pack('<ii', -2, 0))],
            'done-not-multipart': [done(status=-2, flags=0)],
            'error-interrupted': [handler_error(ep['port'], flags=18)],
            'done-interrupted': [done(status=-2, flags=18)],
            'done-positive-status': [done(status=2)],
            'done-unknown-status': [done(status=-5)],
            'done-empty-normal': [done()],
            'error-trailing': [error + b'x'],
            'done-trailing': [completion + b'x'],
            'error-then-record': [error + message(20, record(ep['port'], ino))],
            'done-then-record': [completion + message(20, record(ep['port'], ino))],
        }
        for offset, value, label in [(8, 2, 'echo-seq'), (7, 0, 'echo-not-dump'),
                                     (16, socket.AF_INET, 'echo-family'), (17, 17, 'echo-protocol'),
                                     (24, 0, 'echo-port')]:
            echo = bytearray(request_wire(ep['port']))
            echo[offset] = value
            if label == 'echo-port':
                echo[24:26] = b'\0\0'
            bad[label] = [handler_error(ep['port'], echo=bytes(echo))]
        for v6only in (0, 1, None):
            evidence = message(20, record(ep['port'], ino, v6only))
            bad[f'error-after-record-{v6only}'] = [evidence, error]
            bad[f'done-after-record-{v6only}'] = [evidence, completion]
        contradictory = message(20, record(ep['port'], ino, 1) + attr(11, b'\0'))
        bad['error-after-conflict'] = [contradictory, error]
        bad['done-after-conflict'] = [contradictory, completion]
        for label, responses in bad.items():
            set_wire(wire, responses)
            result, stats = iso.run(child.pid, [ep], opts={'timeout_ms': 100})
            check(not result['ok'] and result['fd_delta'] == 0 and stats['created'] == stats['closed']
                  and count(counter) == start,
                  f'P3/P4 handler-missing {label} fails closed with zero fallback accepts')

        for label, fields in [('create-ENOENT', dict(create_error=True, errno=2)),
                              ('send-ENOENT', dict(send_error=True, errno=2))]:
            set_wire(wire, **fields)
            result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 100})
            check(not result['ok'] and result['fd_delta'] == 0 and count(counter) == start,
                  f'P4 handler-missing transport {label} is not unsupported')
        for label, response in [('error', error), ('done', completion)]:
            for scenario, options in [('budget', dict(opts={'timeout_ms': 40})),
                                      ('cancel', dict(cancel_ms=30)),
                                      ('generation', dict(change_ms=30, other_pid=child.pid + 999999))]:
                set_wire(wire, [response], delay=70)
                result, stats = iso.run(child.pid, [ep], **options)
                expected = (result.get('cancelled') if scenario == 'cancel' else
                            'generation' in result['detail'] if scenario == 'generation' else
                            35 <= result['elapsed_ms'] < 180)
                check(not result['ok'] and expected and result['fd_delta'] == 0 and count(counter) == start
                      and stats['created'] == stats['closed'] == 1,
                      f'P5 handler-missing {label} {scenario} prevents compatibility handshake')
        set_wire(wire, timeout=True)
        result, _ = iso.run(child.pid, [ep], opts={'timeout_ms': 80})
        check(not result['ok'] and result['fd_delta'] == 0 and count(counter) == start,
              'P5 handler-missing no response remains timeout not unsupported')
    other_counter = tmp / 'handler-other-accepts'
    with listener(tmp, [dict(ep, address='::', v6only=1)]) as child:
        with listener(tmp, [dict(ep, address='127.0.0.1', count_path=str(other_counter))]):
            for label, response in [('error', error), ('done', completion)]:
                set_wire(wire, [response])
                result, stats = iso.run(child.pid, [ep], opts={'timeout_ms': 80})
                check(not result['ok'] and result['fd_delta'] == 0 and count(other_counter) == 0
                      and stats['created'] == stats['closed'],
                      f'P4 handler-missing {label} still excludes competing IPv4 ownership')


def main(tmp):
    selection = os.environ.get('PASSIVE_CASE', 'all')
    if selection in ('all', 'kernel'):
        kernel(tmp)
    if selection in ('all', 'faults'):
        faults(tmp)
    if selection in ('all', 'handler'):
        handler_faults(tmp)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.passive-', dir=HERE) as directory:
        main(Path(directory))
    print(f'passive readiness: {passed} passed, 0 failed')
