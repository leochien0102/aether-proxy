#!/usr/bin/env python3
"""M4-05: pin real transaction arguments, not package-manager version semantics.

apk-tools v3.0.5 app_add.c pins a local asset via apk_dep_from_pkg(); package.c
uses APK_DEPMASK_CHECKSUM. No --allow-downgrade option exists or is needed.
The stub verifies our call/inventory only; upstream evidence is in the report.
"""
import json
from pathlib import Path
import sys

root, manager, outcome, output = sys.argv[1:]
root = Path(root)
result = json.loads(output)
calls = (root / 'package-calls').read_text().splitlines()
prefix = ['install', '--force-downgrade'] if manager == 'opkg' else ['add', '--allow-untrusted']
assert calls[0].split()[:-1] == prefix, calls
assert '1.0.0-r1' in calls[0] and 'aether-dns' in calls[0], calls
assert 'aether-proxy' in calls[1], calls
expected = '1.0.0-r1'
if outcome == 'rollback':
    assert len(calls) == 3, calls
    assert calls[-1].split()[:-1] == prefix, calls
    assert 'aether-dns' in calls[-1] and '2026.11.04-r2' in calls[-1], calls
    expected = '2026.11.04-r2'
else:
    assert len(calls) == 2, calls
assert (root / 'package-inventory/aether-dns').read_text().strip() == expected
assert result['prerequisite']['version'] == expected, result
assert result['prerequisite']['action'] == ('installed' if outcome == 'success' else 'rolled_back'), result
for call in calls:
    print(f'EVIDENCE M4-05 {manager} {outcome}: {call}')
