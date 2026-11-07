#!/usr/bin/env python3
"""T15.5: real /proc/socket/Signal contracts plus explicitly labelled proc fixtures."""
import contextlib
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import time
from proc_fixture import seed_elf

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
UCODE = ROOT / 'tests/host/ucode'
passed = 0


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS ', label, flush=True)


def port(protocol='tcp', address='127.0.0.1'):
    with socket.socket(socket.AF_INET6 if ':' in address else socket.AF_INET,
                       socket.SOCK_STREAM if protocol == 'tcp' else socket.SOCK_DGRAM) as s:
        s.bind((address, 0))
        return s.getsockname()[1]


def endpoint(protocol='tcp', role='dns', address='127.0.0.1'):
    return dict(address=address, port=port(protocol, address), protocol=protocol, role=role)


@contextlib.contextmanager
def listener(tmp, entries):
    path = tmp / f'listen-{time.monotonic_ns()}.json'
    path.write_text(json.dumps(entries))
    proc = subprocess.Popen(['python3', str(HERE / 'listener.py'), str(path)])
    try:
        time.sleep(0.06)
        if proc.poll() is not None:
            raise RuntimeError('listener failed')
        yield proc
    finally:
        if proc.poll() is None:
            proc.terminate()
        proc.wait(timeout=2)


def begin(tmp, pid, required, **options):
    path = tmp / f'wait-{time.monotonic_ns()}.json'
    path.write_text(json.dumps(dict(pid=pid, required=required, **options)))
    return subprocess.Popen([str(UCODE), str(HERE / 'driver.uc'), str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def finish(proc):
    out, err = proc.communicate(timeout=7)
    if proc.returncode:
        raise RuntimeError(f'driver rc={proc.returncode}: {err} {out}')
    return json.loads(out)


def run(tmp, pid, required, **options):
    return finish(begin(tmp, pid, required, **options))


def proc_hex(address, byteorder):
    packed = socket.inet_pton(socket.AF_INET6 if ':' in address else socket.AF_INET, address)
    return ''.join(f'{int.from_bytes(packed[i:i+4], byteorder):08X}' for i in range(0, len(packed), 4))


def owned_udp_tuple(pid, ep, peer=None):
    # Prove the real negative's preconditions independently of the gate decision:
    # this child owns the inode, and both local and remote tuples are the requested ones.
    path = pathlib.Path(f'/proc/{pid}')
    suffix = '6' if ':' in ep['address'] else ''
    local = f'{proc_hex(ep["address"], sys.byteorder)}:{ep["port"]:04X}'
    zero = '::' if suffix else '0.0.0.0'
    remote = f'{proc_hex(peer["address"] if peer else zero, sys.byteorder)}:{peer["port"] if peer else 0:04X}'
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        owned = {os.readlink(fd) for fd in (path / 'fd').iterdir()}
        for line in (path / f'net/udp{suffix}').read_text().splitlines()[1:]:
            fields = line.split()
            if fields[1] == local and fields[2] == remote and fields[3] == ('01' if peer else '07'):
                if f'socket:[{fields[9]}]' in owned:
                    return True
        time.sleep(0.01)
    return False


def row(ep, inode, state=None, address=None, remote=None, remote_port=0):
    address = address or ep['address']
    remote = remote or ('::' if ':' in address else '0.0.0.0')
    # These rooted fixtures explicitly use little-endian ELF metadata.
    return (f' 0: {proc_hex(address, "little")}:{ep["port"]:04X} '
            f'{proc_hex(remote, "little")}:{remote_port:04X} '
            f'{state or ("0A" if ep["protocol"] == "tcp" else "07")} '
            f'00000000:00000000 00:00000000 00000000 0 0 {inode}\n')


def fixture(tmp, entries):
    root = tmp / f'proc-{time.monotonic_ns()}'
    seed_elf(root)
    proc = root / 'proc/123'
    (proc / 'fd').mkdir(parents=True)
    (proc / 'net').mkdir()
    # stat fields 4..22: final field is starttime, matching the production parser.
    (proc / 'stat').write_text('123 (test child) S ' + ' '.join(['0'] * 18 + ['987']) + '\n')
    for name in ('tcp', 'tcp6', 'udp', 'udp6'):
        (proc / 'net' / name).write_text('')
    for index, (ep, text) in enumerate(entries):
        inode = str(700 + index)
        (proc / 'fd' / str(index)).symlink_to(f'socket:[{inode}]')
        name = ep['protocol'] + ('6' if ':' in ep['address'] else '')
        with (proc / 'net' / name).open('a') as f:
            f.write(text or row(ep, inode))
    return root, proc


def main(tmp):
    # W1/W2 pure cases use actual published renderer formats; failures are fatal.
    pure = subprocess.run([str(UCODE), '-e',
        "import * as t from './tests/unit/xray_ready.uc'; "
        "for (let c in t.cases) { let r = t.run(c); print(c.name, ': ', r, '\\n'); if (r != 'PASS') exit(1); }"],
        cwd=ROOT, text=True, capture_output=True)
    check(pure.returncode == 0, 'W1/W2/W4 actual renderer reference and pure socket parser contracts')
    print(pure.stdout, end='')

    for protocol in ('tcp', 'udp'):
        tproxy, dns = endpoint(role='tproxy'), endpoint(protocol)
        with listener(tmp, [tproxy, dict(dns, delay=0.4)]) as child:
            result = run(tmp, child.pid, [tproxy, dns])
            check(result['ok'] and result['elapsed_ms'] >= 280,
                  f'W3 real {protocol} DNS delay cannot pass at TPROXY ready')
            check(result['elapsed_ms'] < 1500, f'W1 real single {protocol} ignores unused port/protocol')

    for address, family, label in [('127.0.0.1', socket.AF_INET, 'IPv4'), ('::1', socket.AF_INET6, 'IPv6')]:
        with socket.socket(family, socket.SOCK_DGRAM) as target:
            target.bind((address, 0))
            dns = endpoint('udp', address=address)
            peer = dict(address=address, port=target.getsockname()[1])
            with listener(tmp, [dict(dns, peer=peer)]) as child:
                check(owned_udp_tuple(child.pid, dns, peer),
                      f'W4 real connected UDP {label} child owns matching local tuple and specified peer')
                result = run(tmp, child.pid, [dns])
                check(not result['ok'] and not result.get('cancelled') and
                      4900 <= result['elapsed_ms'] < 5700,
                      f'W4 real owned connected UDP {label} cannot satisfy DNS inbound')
                check(result['fd_delta'] == 0 and owned_udp_tuple(child.pid, dns, peer),
                      f'W10 real connected UDP {label} rejection preserves child socket and FD count')
            with listener(tmp, [dns]) as child:
                check(owned_udp_tuple(child.pid, dns),
                      f'W4 real unconnected UDP {label} child owns matching local tuple with zero peer')
                check(run(tmp, child.pid, [dns])['ok'],
                      f'W4 real unconnected UDP {label} binding satisfies DNS inbound')

    tproxy, tcp, udp = endpoint(role='tproxy'), endpoint(), endpoint('udp')
    with listener(tmp, [tproxy, tcp, udp]) as child:
        check(run(tmp, child.pid, [tproxy, tcp, udp])['ok'], 'W1 real mixed TCP/UDP requires both')
    with listener(tmp, [tproxy]) as child:
        result = run(tmp, child.pid, [tproxy, tcp, udp])
        check(not result['ok'] and 4900 <= result['elapsed_ms'] < 5700,
              'W3 real missing DNS fails at shared five second deadline')
        check(result['fd_delta'] == 0, 'W10 real missing-DNS timeout closes every FD')
        result = run(tmp, child.pid, [tproxy])
        check(result['ok'], 'W2 real T2/T3 unreferenced DNS does not block')
        check(result['fd_delta'] == 0, 'W10 independent succeeding wait leaves no FD')

    # The first DNS comes late; the second would arrive beyond the original budget.
    with listener(tmp, [tproxy, dict(tcp, delay=2.8), dict(udp, delay=6)]) as child:
        result = run(tmp, child.pid, [tproxy, tcp, udp])
        check(not result['ok'] and 4900 <= result['elapsed_ms'] < 5700,
              'W6 real multiple sockets share one deadline not per-port deadlines')

    for wrong, label in [(dict(tcp, protocol='udp'), 'wrong protocol'),
                         (dict(tcp, address='127.0.0.2'), 'wrong address')]:
        with listener(tmp, [wrong]) as child:
            result = run(tmp, child.pid, [tcp], cancel_ms=250)
            check(not result['ok'], f'W4 real same port {label} cannot pass')
    v6 = endpoint(address='::1')
    with listener(tmp, [v6]) as child:
        check(run(tmp, child.pid, [v6])['ok'], 'W4 real IPv6 loopback matches IPv6 requirement')
        check(not run(tmp, child.pid, [dict(v6, address='127.0.0.1')], cancel_ms=250)['ok'],
              'W4 real IPv6-only loopback is not IPv4 loopback')
    for protocol in ('tcp', 'udp'):
        ep = endpoint(protocol)
        with listener(tmp, [dict(ep, address='::', v6only=1)]) as child:
            check(not run(tmp, child.pid, [ep], cancel_ms=250)['ok'],
                  f'W4 real IPv6-only wildcard {protocol} is not IPv4')
    ep = endpoint()
    with listener(tmp, [dict(ep, address='::', v6only=1)]) as child, listener(tmp, [ep]) as occupier:
        check(not run(tmp, child.pid, [ep], cancel_ms=250)['ok'],
              'W5 real v6-only child plus other IPv4 listener cannot fake dual-stack ownership')
        check(run(tmp, occupier.pid, [ep])['ok'], 'W10 competing IPv4 owner remains unaffected')
    ep = endpoint(role='tproxy', address='0.0.0.0')
    with listener(tmp, [dict(ep, address='::', v6only=0)]) as child:
        result = run(tmp, child.pid, [ep], repeat=50)
        check(result['ok'], 'W4 real dual-stack TPROXY serves IPv4 with owned tcp6 inode')
        check(result['fd_delta'] == 0, 'W10 repeated dual-stack probes close every FD')

    with listener(tmp, [tproxy, tcp, udp]) as occupier, listener(tmp, []) as child:
        check(not run(tmp, child.pid, [tproxy, tcp, udp], cancel_ms=250)['ok'],
              'W5 real other process owns all ports and cannot satisfy child')
        check(run(tmp, occupier.pid, [tproxy, tcp, udp])['ok'],
              'W10 rejecting child leaves other process sockets untouched')
        result = run(tmp, child.pid, [tcp], change_ms=80, other_pid=occupier.pid)
        check(not result['ok'] and 'generation' in result['detail'], 'W5 child handle PID change fails closed')

    with listener(tmp, []) as child:
        proc = begin(tmp, child.pid, [tcp])
        time.sleep(0.15)
        child.terminate()
        child.wait(timeout=2)
        result = finish(proc)
        check(not result['ok'] and result['elapsed_ms'] < 800, 'W5 real child exit aborts wait')
    with listener(tmp, [tproxy]) as child:
        for _ in range(3):
            proc = begin(tmp, child.pid, [tproxy, tcp])
            time.sleep(0.15)
            proc.send_signal(signal.SIGTERM)
            result = finish(proc)
            check(result.get('cancelled') and result['elapsed_ms'] < 800 and result['fd_delta'] == 0,
                  'W6/W10 real SIGTERM cancels promptly with no probe FD leak')
        result = run(tmp, child.pid, [tproxy], cancel_at_check=4)
        check(result.get('cancelled') and not result['ok'],
              'W6 last socket ready cancellation wins before success return')

    # Explicit proc fixtures cover states/errors that cannot be made stable with real
    # host scheduling. Neither tables nor ownership fall back to host /proc.
    for state in ('01', '02', '03'):
        root, _ = fixture(tmp, [(tcp, row(tcp, '700', state=state))])
        check(not run(tmp, 123, [tcp], root=str(root), cancel_ms=50)['ok'],
              f'W4 proc fixture TCP state {state} is not LISTEN')
    for address, label in [('127.0.0.1', 'IPv4'), ('::1', 'IPv6')]:
        dns = endpoint('udp', address=address)
        cases = [('connected state', dict(state='01')),
                 ('nonzero remote address', dict(remote=address)),
                 ('nonzero remote port', dict(remote_port=40001))]
        for reason, fields in cases:
            root, _ = fixture(tmp, [(dns, row(dns, '700', **fields))])
            result = run(tmp, 123, [dns], root=str(root), cancel_ms=50)
            check(not result['ok'] and result['fd_delta'] == 0,
                  f'W4 proc fixture UDP {label} {reason} is not unconnected inbound')
    root, p = fixture(tmp, [(udp, None)])
    check(run(tmp, 123, [udp], root=str(root))['ok'], 'W4 proc fixture UDP bound inode accepted')
    (p / 'fd/0').unlink()
    check(not run(tmp, 123, [udp], root=str(root), cancel_ms=50)['ok'],
          'W5 proc fixture missing owned inode fails closed')
    (p / 'fd').rmdir()
    check(not run(tmp, 123, [udp], root=str(root), cancel_ms=50)['ok'],
          'W5 proc fixture unreadable FD directory fails closed')
    root, p = fixture(tmp, [(tcp, None)])
    (p / 'net/tcp').write_text('malformed row\n')
    check(not run(tmp, 123, [tcp], root=str(root), cancel_ms=50)['ok'],
          'W5 proc fixture malformed socket table fails closed')
    root, p = fixture(tmp, [(tcp, None)])
    proc = begin(tmp, 123, [udp], root=str(root))
    time.sleep(0.08)
    (p / 'stat').write_text((p / 'stat').read_text().replace('987', '988'))
    result = finish(proc)
    check(not result['ok'] and 'generation' in result['detail'], 'W5 proc fixture PID reuse starttime rejected')
    check(result['fd_delta'] == 0, 'W10 proc fixture failure closes file descriptors')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.run-', dir=HERE) as directory:
        main(pathlib.Path(directory))
    print(f'xray-ready: {passed} passed, 0 failed')
