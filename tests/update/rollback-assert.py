#!/usr/bin/env python3
"""T9.16 transaction evidence for run.sh's signed-channel fixtures (docs/08 rollback together)."""
import json
from pathlib import Path
import sys

root, manager, mode, output = sys.argv[1:]
root = Path(root)
result = json.loads(output)
backend = 'aether-proxy'
app = 'luci-app-aether-proxy'
i18n = 'luci-i18n-aether-proxy-zh-cn'
old, current = '0.1.0-r1', '0.2.0-r1'
inventory = root / 'package-inventory'
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]
calls = (root / 'package-calls').read_text().splitlines()
restarts = (root / 'init-calls').read_text().splitlines()
signals = (root / 'signals').read_text().splitlines()
queries = (root / 'package-queries').read_text().splitlines()
cache = json.loads((root / 'run/updates.json').read_text())


def asset_call(package, version, previous, arch='aarch64_generic'):
    """Exact arguments: opkg downgrades only, apk always allow-untrusted."""
    if manager == 'opkg':
        prefix = 'install --force-downgrade ' if previous else 'install '
        filename = f'{package}_{version}_{arch}.ipk'
    else:
        prefix = 'add --allow-untrusted '
        filename = f'{package}-{version}_{arch}.apk'
    return prefix + str(root / 'root/tmp/aether-proxy-dl' / filename)


if ':' in mode:
    direction, package = mode.split(':')
    previous = direction == 'previous'
    version = ('26.7.28-r1' if previous else '26.10.10-r1') if package == 'xray-core' else (
        old if previous else current)
    before = '26.10.10-r1' if package == 'xray-core' else current
    assert result == {'ok': True, 'package': package, 'from': before, 'to': version,
                      'rolled_back': False, 'code': None}, result
    assert calls == [asset_call(package, version, previous)], calls
    assert restarts == (['restart'] if package == backend else []), restarts
    assert len(signals) == (1 if package == 'xray-core' else 0), signals
    assert (inventory / package).read_text().strip() == version
    # Exactly one final refresh: each other manifest package is queried once.
    for name in (backend, app, i18n, 'xray-core'):
        assert queries.count(name) == (3 if name == package else 1), queries
else:
    statuses = {app: 'rolled_back', i18n: 'rolled_back'}
    expected_calls = [asset_call(backend, old, True)]
    expected_versions = {backend: old, app: old, i18n: old}
    error = None
    if mode == 'backend-install':
        expected_calls = [asset_call(backend, old, True)]
        statuses = {app: 'skipped', i18n: 'skipped'}
        expected_versions = {backend: current, app: current, i18n: current}
        error = 'CMD_FAILED'
    elif mode == 'backend':
        statuses = {app: 'skipped', i18n: 'skipped'}
        expected_calls.append(asset_call(backend, current, True))
        expected_versions = {backend: current, app: current, i18n: current}
        error = 'UPDATE_VERIFY_FAILED'
    elif mode == 'skipped':
        statuses = {app: 'skipped', i18n: 'skipped'}
        expected_versions.update({app: current, i18n: None})
    else:
        for package in (app, i18n):
            if mode == 'hash' and package == app:
                statuses[package] = 'failed'
                expected_versions[package] = current
                error = 'UPDATE_VERIFY_FAILED'
                continue
            arch = 'all' if mode == 'all' and package == app else 'aarch64_generic'
            expected_calls.append(asset_call(package, old, True, arch))
            if mode == package:
                statuses[package] = 'failed'
                expected_versions[package] = current
                error = 'CMD_FAILED'
    assert calls == expected_calls, calls
    assert result['companions'] == statuses, result
    assert result['package'] == backend, result
    assert result['from'] == (None if mode == 'backend-install' else current), result
    assert result['to'] == (None if mode == 'backend-install' else old), result
    assert result['ok'] == (error is None) and result['code'] == error, result
    assert result['rolled_back'] == (mode == 'backend'), result
    expected_restarts = [] if mode == 'backend-install' else (
        ['restart', 'restart'] if mode == 'backend' else ['restart'])
    assert restarts == expected_restarts, restarts
    assert not signals, signals
    for package, version in expected_versions.items():
        path = inventory / package
        assert (path.read_text().strip() if path.exists() else None) == version, (package, version)
    if mode in (app, i18n):
        failures = [event for event in events if event['code'] == 'CMD_FAILED']
        assert len(failures) == 1, failures
        assert failures[0]['args']['rc'] == 7 and mode in failures[0]['args']['cmd'], failures
    installed = [event['args']['package'] for event in events if event['code'] == 'UPDATE_INSTALLED']
    expected_installed = [] if mode in ('backend', 'backend-install') else [backend] + [
        package for package in (app, i18n) if statuses[package] == 'rolled_back']
    assert installed == expected_installed, installed
    # Queries prove refresh happens once after both installs, not once per package.
    if mode not in ('backend', 'backend-install'):
        assert queries.count(backend) == 3 and queries.count('xray-core') == 1, queries
        assert queries.count(app) == 2 and queries.count(i18n) == 2, queries
        assert queries[-4:] == ['xray-core', backend, app, i18n], queries

# Every cached installed value must describe the final actual inventory, including
# skipped and failed packages. Refreshing before companions would fail this assertion.
for package, entry in cache['packages'].items():
    path = inventory / package
    version = path.read_text().strip() if path.exists() else None
    assert entry['installed'] == version, (package, entry, version)
assert cache['pm'] == manager
assert not list((root / 'root/tmp/aether-proxy-dl').glob('*.ipk'))
assert not list((root / 'root/tmp/aether-proxy-dl').glob('*.apk'))
