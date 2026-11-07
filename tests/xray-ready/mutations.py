#!/usr/bin/env python3
"""Temporary production mutations, exact assertion failures, unconditional restore."""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'aether-proxy/src/lib/xray_ready.uc'
ORIGINAL = SOURCE.read_text()
NET = ROOT / 'aether-proxy/src/lib/net.uc'
NET_ORIGINAL = NET.read_text()
LOGS = pathlib.Path(__file__).resolve().parent / '.logs'
LOGS.mkdir(exist_ok=True)


def replace_once(old, new):
    assert ORIGINAL.count(old) == 1, old
    return ORIGINAL.replace(old, new, 1)


cancellation = ("\t\tif (cancelled(ctx, on_signal))\n"
                "\t\t\treturn { ok: false, cancelled: true, detail: 'Xray readiness cancelled' };\n")
assert ORIGINAL.count(cancellation) == 2
at = ORIGINAL.rindex(cancellation)
mutations = [
    ('tproxy-only', replace_once('for (let requirement in required)',
        "for (let requirement in filter(required, r => r.role == 'tproxy'))"),
        'W3 real tcp DNS delay cannot pass at TPROXY ready'),
    ('ignore-protocol', replace_once(' || row.protocol != requirement.protocol', ''),
        'W4 real same port wrong protocol cannot pass'),
    ('ignore-ownership', replace_once('!owned[row.inode] || ', ''),
        'W5 real v6-only child plus other IPv4 listener cannot fake dual-stack ownership'),
    ('skip-tail-cancel', ORIGINAL[:at] + ORIGINAL[at:].replace(cancellation, '', 1),
        'W6 last socket ready cancellation wins before success return'),
]
endian_guard = ("\tif (type(little_endian) != 'bool')\n"
                "\t\treturn { ok: false, detail: 'socket table byte order must be an explicit boolean' };")
assert NET_ORIGINAL.count(endian_guard) == 1
minimal = ['python3', 'tests/xray-ready/minimal.py']
endian_unit = [str(ROOT / 'tests/host/ucode'), '-e',
    "import * as t from './tests/unit/xray_ready.uc'; "
    "let c = filter(t.cases, c => c.kind == 'endian')[0]; let r = t.run(c); "
    "if (r != 'PASS') die('A3 explicit parser byte order: ' + r);"]
extra_mutations = [
    ('restore-struct', NET, NET_ORIGINAL.replace("'use strict';", "'use strict';\nimport * as s from 'struct';", 1),
     minimal, 'AssertionError: A2 isolated existing-module imports and readiness succeed without struct'),
    ('default-parser-endian', NET, NET_ORIGINAL.replace(endian_guard,
     "\tif (type(little_endian) != 'bool') little_endian = true;", 1), endian_unit,
     'A3 explicit parser byte order: invalid byte order accepted'),
    ('force-little', SOURCE, replace_once('little_endian: data == 1', 'little_endian: true'), minimal,
     'AssertionError: A3 ELF class 1 BE selects explicit proc byte order with stable FD'),
    ('ignore-elf-magic', SOURCE, replace_once(
     "\tif (substr(header, 0, 4) != chr(127) + 'ELF')\n\t\treturn failure('invalid ELF magic');\n", ''),
     minimal, 'AssertionError: A4 invalid ELF magic fails closed and closes every FD'),
    ('ignore-elf-close', SOURCE, replace_once(
     "\tif (!file.close())\n"
     "\t\treturn failure(`cannot close ELF identity ${path}: ${fs.error() ?? 'unknown error'}`);",
     '\tfile.close();'), minimal,
     'AssertionError: A4 injected ELF close failure is checked and owned FD count stays stable'),
]
try:
    for name, mutated, expected in mutations:
        SOURCE.write_text(mutated)
        result = subprocess.run(['python3', 'tests/xray-ready/run.py'], cwd=ROOT,
                                text=True, capture_output=True, timeout=70)
        (LOGS / f'mutation-{name}.log').write_text(result.stdout + result.stderr)
        assert result.returncode != 0, f'{name}: survived'
        assert f'AssertionError: {expected}' in result.stderr, f'{name}: unexpected failure {result.stderr}'
        print(f'PASS  mutation {name}: AssertionError: {expected}', flush=True)
        SOURCE.write_text(ORIGINAL)
    for name, target, mutated, command, expected in extra_mutations:
        target.write_text(mutated)
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=70)
        (LOGS / f'mutation-{name}.log').write_text(result.stdout + result.stderr)
        assert result.returncode != 0, f'{name}: survived'
        assert expected in result.stderr, f'{name}: unexpected failure {result.stderr}'
        print(f'PASS  mutation {name}: {expected}', flush=True)
        SOURCE.write_text(ORIGINAL)
        NET.write_text(NET_ORIGINAL)
finally:
    SOURCE.write_text(ORIGINAL)
    NET.write_text(NET_ORIGINAL)

result = subprocess.run(['bash', 'tests/xray-ready/run.sh'], cwd=ROOT, text=True, capture_output=True, timeout=120)
(LOGS / 'restored.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0, result.stdout + result.stderr
print('PASS  restored full xray-ready entry: ' + result.stdout.splitlines()[-1])
