#!/usr/bin/env python3
"""T15.7 passive and handler-scope controls; run serially, always restore."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'aether-proxy/src/lib/xray_ready.uc'
ORIGINAL = SOURCE.read_text()
DIAG = ROOT / 'aether-proxy/src/lib/socket_diag.uc'
DIAG_ORIGINAL = DIAG.read_text()
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
mutations = [(SOURCE, *mutation) for mutation in mutations]


def diag_replace(old, new):
    assert DIAG_ORIGINAL.count(old) == 1, old
    return DIAG_ORIGINAL.replace(old, new, 1)


handler_guard = "return !state.seen && socket.strerror(errno) == 'No such file or directory';"
echo_bypass = diag_replace('substr(payload, 4, 16) != substr(original, 0, 16)', 'false')
echo_body = '(!(flags & C.SOCKET_DIAG.capped) && substr(payload, 4, 72) != original)'
assert echo_bypass.count(echo_body) == 1
echo_bypass = echo_bypass.replace(echo_body, 'false', 1)
mutations += [
    (DIAG, 'missing-handler-disabled', 'handler', diag_replace(handler_guard, 'return false;'),
     'P4 handler-missing error uses exactly one counted legacy handshake'),
    (DIAG, 'missing-handler-done-disabled', 'handler', diag_replace(
     'if (!dump_handler_missing(negative_errno(code), state))', 'if (true)'),
     'P4 handler-missing done uses exactly one counted legacy handshake'),
    (DIAG, 'global-ENOENT', 'handler', diag_replace(
     'return index(C.SOCKET_DIAG.compatible_errors, socket.strerror(errno)) >= 0;',
     "return socket.strerror(errno) == 'No such file or directory' || "
     'index(C.SOCKET_DIAG.compatible_errors, socket.strerror(errno)) >= 0;'),
     'P4 handler-missing transport create-ENOENT is not unsupported'),
    (DIAG, 'handler-after-evidence', 'handler', diag_replace(handler_guard,
     "return socket.strerror(errno) == 'No such file or directory';"),
     'P3/P4 handler-missing done-after-record-0 fails closed with zero fallback accepts'),
    (DIAG, 'handler-bad-echo', 'handler', echo_bypass,
     'P3/P4 handler-missing echo-seq fails closed with zero fallback accepts'),
]
try:
    for target, name, case, mutated, expected in mutations:
        target.write_text(mutated)
        result = subprocess.run(['python3', 'tests/xray-ready/passive.py'], cwd=ROOT,
            env=dict(os.environ, PASSIVE_CASE=case), text=True, capture_output=True, timeout=90)
        (LOGS / f'passive-mutation-{name}.log').write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and f'AssertionError: {expected}' in result.stderr, (
            name, result.stdout, result.stderr)
        print(f'PASS  mutation {name}: AssertionError: {expected}', flush=True)
        SOURCE.write_text(ORIGINAL)
        DIAG.write_text(DIAG_ORIGINAL)
finally:
    SOURCE.write_text(ORIGINAL)
    DIAG.write_text(DIAG_ORIGINAL)
result = subprocess.run(['bash', 'tests/xray-ready/passive.sh'], cwd=ROOT,
                        text=True, capture_output=True, timeout=90)
(LOGS / 'passive-restored.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0, result.stdout + result.stderr
print('PASS  restored passive entry: ' + result.stdout.splitlines()[-1])
