#!/usr/bin/env python3
"""Assert engine/backend ordering, rollback inventory and side-effect-free skips."""
import json
from pathlib import Path
import sys

root, scenario, output = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
result = json.loads(output)
prerequisite = result['prerequisite']
calls = (root / 'package-calls').read_text().splitlines()
restarts = (root / 'init-calls').read_text().splitlines()
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]
inventory = root / 'package-inventory'
assert prerequisite['package'] == 'aether-dns', result
assert prerequisite['action'] in ('installed', 'skipped', 'rolled_back', 'manual_required'), result


def package(call):
    if call.startswith('remove '):
        return 'remove-engine'
    filename = Path(call.split()[-1]).name.removeprefix('new-')
    return filename.split('_')[0]


order = [package(call) for call in calls]
if scenario == 'T1':
    assert prerequisite['action'] == 'skipped', result
    assert order == ['aether-proxy'], calls
elif scenario in ('T2', 'T3', 'T8', 'T10', 'T11', 'T12'):
    assert prerequisite['action'] == 'installed', result
    assert order == ['aether-dns', 'aether-proxy'], calls
    assert json.loads((root / 'run/state.json').read_text())['state'] == 'running'
    if scenario == 'T3':
        assert (root / 'bin/chinadns-ng').exists()
    if scenario == 'T8':
        assert (root / 'bin/custom-engine').exists()
        assert 'custom-engine' in (root / 'conf/aetherproxy').read_text()
    if scenario == 'T10':
        assert result['code'] == 'BRIDGE_INSTALLED', result
        installed = [e['args']['package'] for e in events if e['code'] == 'UPDATE_INSTALLED']
        assert installed == ['aether-dns', 'aether-proxy'], installed
    if scenario == 'T12':
        cache = json.loads((root / 'run/updates.json').read_text())
        assert 'future-unknown-package' not in cache['packages']
elif scenario.startswith('T4'):
    assert result['code'] == 'UPDATE_VERIFY_FAILED', result
    assert not calls and not restarts, (calls, restarts)
elif scenario == 'T5':
    assert order == ['aether-dns', 'aether-proxy', 'remove-engine'], calls
    assert prerequisite['action'] == 'rolled_back', result
    assert not (inventory / 'aether-dns').exists()
    assert (inventory / 'aether-proxy').read_text().strip() == '0.1.0-r1'
    assert json.loads((root / 'run/state.json').read_text())['state'] == 'running'
elif scenario == 'T6':
    assert order == ['aether-dns', 'aether-proxy', 'aether-dns'], calls
    assert '--force-downgrade' in calls[0] and '--force-downgrade' in calls[-1], calls
    assert prerequisite['action'] == 'rolled_back', result
    assert (inventory / 'aether-dns').read_text().strip() == '2026.11.04-r2'
    assert not (inventory / 'aether-dns.provides').exists()
elif scenario == 'T7':
    assert result['code'] == 'PREREQ_MANUAL_REQUIRED', result
    assert prerequisite['action'] == 'manual_required'
    assert 'back up' in result['detail']
    assert not calls and not restarts, (calls, restarts)
elif scenario in ('T9', 'T11-idempotent'):
    assert result['code'] == 'UPDATE_UP_TO_DATE', result
    assert prerequisite['action'] == 'skipped', result
    assert not calls and not restarts, (calls, restarts)
    if scenario == 'T9':
        assert not any(e['code'] == 'UPDATE_INSTALLED' for e in events)
else:
    raise AssertionError(scenario)
