#!/usr/bin/env python3
"""Temporary production mutations, exact assertion failures, unconditional restore."""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'aether-proxy/src/lib/xray_ready.uc'
ORIGINAL = SOURCE.read_text()
LOGS = pathlib.Path(__file__).resolve().parent / '.logs'
LOGS.mkdir(exist_ok=True)


def replace_once(old, new):
    assert ORIGINAL.count(old) == 1, old
    return ORIGINAL.replace(old, new, 1)


cancellation = "\t\tif (cancelled(ctx, on_signal))\n\t\t\treturn { ok: false, cancelled: true, detail: 'Xray readiness cancelled' };\n"
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
finally:
    SOURCE.write_text(ORIGINAL)

result = subprocess.run(['bash', 'tests/xray-ready/run.sh'], cwd=ROOT, text=True, capture_output=True, timeout=120)
(LOGS / 'restored.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0, result.stdout + result.stderr
print('PASS  restored full xray-ready entry: ' + result.stdout.splitlines()[-1])
