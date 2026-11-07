#!/usr/bin/env python3
"""Approved T15.5 A1-A6: isolated real implementation, ELF failures and FD bounds."""
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile

from proc_fixture import elf_ident
from run import endpoint, fixture, listener

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
passed = 0


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS ', label, flush=True)


class Minimal:
    def __init__(self, base):
        self.base = base
        self.modules = base / 'modules'
        self.native = base / 'native'
        self.native.mkdir()
        shutil.copytree(ROOT / 'aether-proxy/src/lib', self.modules / 'aetherproxy')
        for name in ('fs', 'log', 'socket', 'uci', 'uloop'):
            shutil.copyfile(ROOT / f'tests/host/prefix/lib/ucode/{name}.so', self.native / f'{name}.so')
        self.paths = [str(self.modules / '*.uc'), str(self.native / '*.so')]
        self.env = dict(os.environ, LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib'))

    def fault_boundary(self):
        # Only the fs boundary in a source copy is substituted, never readiness,
        # validation, deadline, cancellation, socket ownership or a package module.
        shutil.copyfile(HERE / 'fault_fs.uc', self.modules / 'testfs.uc')
        path = self.modules / 'aetherproxy/xray_ready.uc'
        source = path.read_text()
        assert source.count("import * as fs from 'fs';") == 1
        path.write_text(source.replace("import * as fs from 'fs';", "import * as fs from 'testfs';"))

    def begin(self, pid, required, fault=None, **options):
        path = self.base / 'spec.json'
        path.write_text(json.dumps(dict(pid=pid, required=required, **options)))
        env = dict(self.env)
        if fault is not None:
            env['XRAY_READY_FS_FAULT'] = fault
        return subprocess.Popen([str(ROOT / 'tests/host/prefix/bin/ucode'), str(HERE / 'minimal.uc'),
            str(path), json.dumps(self.paths), str(HERE / 'driver.uc')], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def finish(self, proc):
        out, err = proc.communicate(timeout=8)
        if proc.returncode != 0:
            print(out + err, flush=True)
        check(proc.returncode == 0 and not err,
              'A2 isolated existing-module imports and readiness succeed without struct')
        records, remaining = [], out.strip()
        decoder = json.JSONDecoder()
        while remaining:
            value, end = decoder.raw_decode(remaining)
            records.append(value)
            remaining = remaining[end:].strip()
        assert records[0]['runtime_missing'] and records[0]['compiler_missing']
        return records[1], records[2] if len(records) > 2 else None

    def run(self, pid, required, fault=None, **options):
        return self.finish(self.begin(pid, required, fault, **options))


def main(base):
    isolated = Minimal(base)
    ep, udp = endpoint(role='tproxy'), endpoint('udp')
    with listener(base, [ep, udp]) as child:
        result, _ = isolated.run(child.pid, [ep, udp], repeat=50)
        check(result['ok'] and result['successes'] == 50 and result['fd_delta'] == 0,
              'A2 real readiness TCP UDP and repeated ELF reads work without struct')
    check(sorted(p.name for p in isolated.native.iterdir()) ==
          ['fs.so', 'log.so', 'socket.so', 'uci.so', 'uloop.so'],
          'A1 only five declared native modules; compiler and runtime struct negative controls pass')

    isolated.fault_boundary()
    root, procdir = fixture(base, [(ep, None)])
    elf = root / 'proc/self/exe'
    for little in (True, False):
        for elf_class in (1, 2):
            elf.write_bytes(elf_ident(little, elf_class))
            address = '0100007F' if little else '7F000001'
            (procdir / 'net/tcp').write_text(
                f'0: {address}:{ep["port"]:04X} 00000000:0000 0A '
                '00000000:00000000 00:00000000 00000000 0 0 700\n')
            result, stats = isolated.run(123, [ep], root=str(root), fault='none', repeat=40)
            check(result['ok'] and result['successes'] == 40 and result['fd_delta'] == 0 and
                  stats['opened'] == stats['closed'] == 40,
                  f'A3 ELF class {elf_class} {"LE" if little else "BE"} '
                  'selects explicit proc byte order with stable FD')

    # Identical data with opposite encoding must not match loopback. This kills a
    # parser that silently defaults to little-endian instead of using EI_DATA.
    elf.write_bytes(elf_ident(False))
    (procdir / 'net/tcp').write_text(
        f'0: 0100007F:{ep["port"]:04X} 00000000:0000 0A '
        '00000000:00000000 00:00000000 00000000 0 0 700\n')
    result, _ = isolated.run(123, [ep], root=str(root), fault='none', cancel_ms=60)
    check(not result['ok'], 'A3 BE ELF cannot accept LE-encoded wrong-address fixture')
    elf.write_bytes(elf_ident())
    valid = elf_ident()
    bad_headers = [('short', valid[:15], 'short ELF'), ('empty', b'', 'short ELF'),
        ('magic', b'BAD!' + valid[4:], 'invalid ELF magic')]
    for offset, name in ((4, 'class'), (5, 'data encoding'), (6, 'version')):
        for value in (0, 3):
            bad_headers.append((f'{name}-{value}', valid[:offset] + bytes([value]) + valid[offset+1:],
                                f'invalid ELF {name}'))
    for name, header, detail in bad_headers:
        elf.write_bytes(header)
        result, stats = isolated.run(123, [ep], root=str(root), fault='none', repeat=40, continue_on_failure=True)
        check(not result['ok'] and detail in result['detail'] and result['failures'] == 40 and
              result['successes'] == 0 and result['fd_delta'] == 0 and stats['opened'] == stats['closed'] == 40,
              f'A4 invalid ELF {name} fails closed and closes every FD')
    elf.unlink()
    result, _ = isolated.run(123, [ep], root=str(root), fault='none', repeat=40, continue_on_failure=True)
    check(not result['ok'] and 'cannot open ELF' in result['detail'] and result['fd_delta'] == 0 and
          result['successes'] == 0 and result['failures'] == 40,
          'A4 missing rooted ELF never borrows valid host ELF or defaults endian')
    elf.mkdir()
    result, stats = isolated.run(123, [ep], root=str(root), fault='none')
    check(not result['ok'] and 'cannot read ELF' in result['detail'] and result['fd_delta'] == 0 and
          stats['opened'] == stats['closed'] == 1,
          'A4 real unreadable ELF directory closes FD and fails closed')
    elf.rmdir()
    elf.write_bytes(valid)
    for fault, detail in [('open', 'cannot open ELF'), ('read', 'cannot read ELF'),
                          ('close', 'cannot close ELF'), ('read-close', 'cannot close ELF')]:
        result, stats = isolated.run(123, [ep], root=str(root), fault=fault,
                                    repeat=40, continue_on_failure=True)
        count = 0 if fault == 'open' else 40
        check(not result['ok'] and detail in result['detail'] and result['failures'] == 40 and
              result['successes'] == 0 and result['fd_delta'] == 0 and stats['opened'] == stats['closed'] == count,
              f'A4 injected ELF {fault} failure is checked and owned FD count stays stable')

    # These callbacks bracket the actual ELF open/read/close, independently of
    # socket readiness. Cancel before open and after close must both win.
    for at in (1, 2):
        result, stats = isolated.run(123, [ep], root=str(root), fault='none', cancel_at_check=at,
                                    repeat=40, continue_on_failure=True)
        count = 0 if at == 1 else 40
        check(result.get('cancelled') and result['cancellations'] == 40 and result['fd_delta'] == 0 and
              stats['opened'] == stats['closed'] == count,
              f'A4 cancellation at ELF check {at} wins and closes every FD')
    child = isolated.begin(123, [ep], root=str(root), fault='signal')
    try:
        readable, _, _ = select.select([child.stderr], [], [], 3)
        check(bool(readable) and child.stderr.readline() == 'ELF_OPEN\n', 'A4 real TERM waits at opened ELF boundary')
        child.send_signal(signal.SIGTERM)
        result, stats = isolated.finish(child)
        check(result.get('cancelled') and result['fd_delta'] == 0 and result['elapsed_ms'] < 800 and
              stats['opened'] == stats['closed'] == 1,
              'A4 real SIGTERM during ELF read cancels with FD closed')
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()
    result, stats = isolated.run(123, [ep], root=str(root), fault='budget')
    check(not result['ok'] and 'within 5 seconds' in result['detail'] and
          5000 <= result['elapsed_ms'] < 5800 and result['fd_delta'] == 0 and stats['opened'] == stats['closed'] == 1,
          'A4 ELF read consumes original five second budget instead of resetting it')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.minimal-', dir=HERE) as directory:
        main(Path(directory))
    print(f'xray-ready minimal modules and ELF: {passed} passed, 0 failed')
