#!/usr/bin/env python3
"""Assert engine/backend ordering, rollback inventory and side-effect-free skips."""
import json
from pathlib import Path
import sys

root, scenario, output = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
result = json.loads(output)
prerequisite = result.get('prerequisite')
calls = (root / 'package-calls').read_text().splitlines()
restarts = (root / 'init-calls').read_text().splitlines()
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]
inventory = root / 'package-inventory'
manifest = json.loads((root / 'ch1/manifest.json').read_text())
if scenario == 'T14-bridge':
    assert result['code'] == 'PREREQ_MANUAL_REQUIRED', result
    assert (inventory / 'aether-proxy').read_text().strip() == '0.7.1-r1'
    assert len(calls) == 1 and len(restarts) == 1, (calls, restarts)
    assert not (inventory / 'aether-dns').exists()
    # The first hop must stay below the engine gate; only the fresh CLI's
    # terminal hop discovers the missing prerequisite and fails safely.
    assert not any(e['code'] == 'UPDATE_STARTED' and e['args']['package'] == 'aether-dns' for e in events)
    sys.exit(0)
if scenario.startswith('T14'):
    assert 'aether-dns' not in manifest['packages'], manifest
    assert not (root / 'bin/aether-dns').exists() and not (root / 'bin/chinadns-ng').exists()
    assert not (inventory / 'aether-dns').exists() and not (inventory / 'chinadns-ng').exists()
    assert 'prerequisite' not in result, result
    assert not (root / 'engine-probes').read_text()
    queries = (root / 'package-queries').read_text().splitlines()
    assert 'aether-dns' not in queries and 'chinadns-ng' not in queries, queries
    assert not any(e['args'].get('package') in ('aether-dns', 'chinadns-ng') for e in events), events
else:
    assert manifest['packages']['aether-proxy']['current']['version'] == '1.0.0-r1'
    assert prerequisite['package'] == 'aether-dns', result
    assert prerequisite['action'] in ('installed', 'skipped', 'rolled_back', 'manual_required'), result


def package(call):
    if call.startswith('remove '):
        return 'remove-engine'
    filename = Path(call.split()[-1]).name.removeprefix('new-')
    return filename.split('_')[0]


order = [package(call) for call in calls]
installed_events = [(e['args']['package'], e['args']['version'])
                    for e in events if e['code'] == 'UPDATE_INSTALLED']
if scenario.startswith('T14'):
    assert order == ['aether-proxy'], calls
    assert installed_events == [('aether-proxy', '0.7.1-r1')], installed_events
    assert result['ok'] and result['to'] == '0.7.1-r1', result
    if scenario == 'T14-bridge':
        assert manifest['packages']['aether-proxy']['current']['version'] == '1.1.0-r1'
        assert result['code'] == 'BRIDGE_INSTALLED', result
elif scenario == 'T1':
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

# Never filter DNS calls/events out of the oracle: the exact sequence is the contract.
if not scenario.startswith('T14'):
    expected_events = []
    if scenario in ('T1',):
        expected_events = [('aether-proxy', '1.0.0-r1')]
    elif scenario in ('T2', 'T3', 'T8', 'T10', 'T11', 'T12'):
        expected_events = [('aether-dns', '1.0.0-r1'), ('aether-proxy', '1.0.0-r1')]
    elif scenario in ('T5', 'T6'):
        expected_events = [('aether-dns', '1.0.0-r1')]
    assert installed_events == expected_events, (installed_events, expected_events)
