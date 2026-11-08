#!/usr/bin/env python3
"""T15.7 four targeted controls; never run concurrently with other suites."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'aether-proxy/src/lib/xray_ready.uc'
ORIGINAL = SOURCE.read_text()
LOGS = Path(__file__).resolve().parent / '.logs'
LOGS.mkdir(exist_ok=True)


def replace(old, new):
    assert ORIGINAL.count(old) == 1, old
    return ORIGINAL.replace(old, new, 1)


mutations = [
    ('old-active', 'kernel', replace('diag.query(ctx, row, little_endian, deadline, stopped)',
        '{ ok: true, fallback: true }'),
        'P1 kernel supported path accepts exactly zero probe connections'),
    ('ignore-v6only', 'kernel', replace('return evidence.dual_stack;', 'return true;'),
        'P2 kernel v6only plus competing IPv4 owner cannot satisfy IPv4'),
    ('bad-message-fallback', 'faults', replace('return evidence;', 'evidence = { ok: true, fallback: true };'),
        'P3/P4 wire family fails closed with zero fallback accepts'),
    ('probe-after-budget', 'faults', replace('if (stopped() || now_ms() >= deadline)', 'if (stopped())'),
        'P5 exhausted diag budget cannot start compatibility handshake'),
]
try:
    for name, case, mutated, expected in mutations:
        SOURCE.write_text(mutated)
        result = subprocess.run(['python3', 'tests/xray-ready/passive.py'], cwd=ROOT,
            env=dict(os.environ, PASSIVE_CASE=case), text=True, capture_output=True, timeout=90)
        (LOGS / f'passive-mutation-{name}.log').write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and f'AssertionError: {expected}' in result.stderr, (
            name, result.stdout, result.stderr)
        print(f'PASS  mutation {name}: AssertionError: {expected}', flush=True)
        SOURCE.write_text(ORIGINAL)
finally:
    SOURCE.write_text(ORIGINAL)
result = subprocess.run(['bash', 'tests/xray-ready/passive.sh'], cwd=ROOT,
                        text=True, capture_output=True, timeout=90)
(LOGS / 'passive-restored.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0, result.stdout + result.stderr
print('PASS  restored passive entry: ' + result.stdout.splitlines()[-1])
