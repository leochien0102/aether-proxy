#!/usr/bin/env python3
"""Assert real CLI transactions never cross a pending backend bridge."""
import json
from pathlib import Path
import sys

root, manager, mode, installed, target, output = sys.argv[1:]
root = Path(root)
result = json.loads(output)
calls = (root / 'package-calls').read_text().splitlines()
inventory = root / 'package-inventory'
expected = [] if mode in ('blocked', 'guard', 'check') else [target]
if mode == 'installed':
    versions = ['0.6.3-r1', '0.6.4-r1', '0.6.6-r1', '0.6.8-r1']
    expected = versions[versions.index(installed) + 1:] + [target, target]
if mode == 'mismatch-rollback':
    expected = ['0.6.5-r1', installed]
elif mode == 'rollback':
    expected.append(installed)
assert len(calls) == len(expected), (calls, expected, result)
if mode in ('blocked', 'guard'):
    assert not (root / 'init-calls').read_text(), result
    assert not (root / 'signals').read_text(), result
names = ['aether-proxy'] * len(expected)
if mode == 'installed':
    names[-2:] = ['luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn']
for call, version, name in zip(calls, expected, names):
    filename = (f'{name}_{version}_aarch64_generic.ipk' if manager == 'opkg'
                else f'{name}-{version}_aarch64_generic.apk')
    assert Path(call.split()[-1]).name == filename, calls
    assert ('install ' if manager == 'opkg' else 'add --allow-untrusted ') in call, call
if mode in ('rollback', 'mismatch-rollback') and manager == 'opkg':
    assert '--force-downgrade' in calls[-1], calls
assert (inventory / 'aether-proxy').read_text().strip() == (
    target if mode in ('installed', 'no-rollback') else installed), (calls, result)
for name in ('luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'):
    assert (inventory / name).read_text().strip() == (target if mode == 'installed' else '0.6.3-r1'), name
if mode == 'check':
    filename = (f'aether-proxy_{target}_aarch64_generic.ipk' if manager == 'opkg'
                else f'aether-proxy-{target}_aarch64_generic.apk')
    for name in ('aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'):
        row = result['packages'][name]
        assert row['asset'] == filename, row
        assert row['available'] == target and row['newer'] is True, row
        assert row['bridge_required'] is True, row
        assert row['next_step']['version'] == target, row
        assert row['next_step']['reason'].strip(), row
        assert row['steps_remaining'] == {'0.6.4-r1': 3, '0.6.6-r1': 2, '0.6.8-r1': 1}[target], row
elif mode == 'installed':
    assert result['code'] == 'BRIDGE_INSTALLED', result
    assert result['to'] == target, result
    assert result['steps_remaining'] == 0, result
    assert len((root / 'init-calls').read_text().splitlines()) == len(expected) - 2
    cache = json.loads((root / 'run/updates.json').read_text())['packages']
    assert cache['aether-proxy']['installed'] == target, cache
elif mode in ('rollback', 'mismatch-rollback', 'no-rollback'):
    assert result['code'] == 'UPDATE_VERIFY_FAILED', result
    if mode == 'mismatch-rollback':
        assert result['to'] == target, result
    assert result['rolled_back'] == (mode != 'no-rollback'), result
    events = [json.loads(line)['code'] for line in (root / 'run/events.jsonl').read_text().splitlines()]
    assert ('UPDATE_ROLLED_BACK' in events) == (mode != 'no-rollback'), events
elif mode == 'guard':
    assert result['code'] == 'USAGE', result
else:
    assert result['code'] == 'BRIDGE_UNAVAILABLE', result
