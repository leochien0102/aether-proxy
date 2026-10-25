#!/usr/bin/env python3
"""T9.38 exact package-manager order/count, result, inventory and event evidence."""
import json
from pathlib import Path
import sys

root, manager, scenario, requested, output = sys.argv[1:]
root = Path(root)
result = json.loads(output)
backend = 'aether-proxy'
app = 'luci-app-aether-proxy'
i18n = 'luci-i18n-aether-proxy-zh-cn'
xray = 'xray-core'
old, current = '0.1.0-r1', '0.2.0-r1'
calls = (root / 'package-calls').read_text().splitlines()
restarts = (root / 'init-calls').read_text().splitlines()
signals = (root / 'signals').read_text().splitlines()
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]


def asset_call(package, version=current, previous=False, arch='aarch64_generic'):
    if manager == 'opkg':
        prefix = 'install --force-downgrade ' if previous else 'install '
        filename = f'{package}_{version}_{arch}.ipk'
    else:
        prefix = 'add --allow-untrusted '
        filename = f'{package}-{version}_{arch}.apk'
    return prefix + str(root / 'root/tmp/aether-proxy-dl' / filename)


inventory = {backend: old, app: old, i18n: old, xray: '26.7.28-r1'}
expected_calls = []
installed_events = []
if scenario == 'backend-no-asset':
    assert result == {'ok': False, 'package': backend, 'from': None, 'to': None,
                      'rolled_back': False, 'code': 'ARCH_UNSUPPORTED',
                      'detail': f'no {manager} asset for {backend} on aarch64_generic',
                      'companions': {app: 'skipped', i18n: 'skipped'}}, result
    assert not calls and not restarts and not signals
    assert (root / 'run/updates.json').read_bytes() == (root / 'group-cache-before').read_bytes()
    for package, version in inventory.items():
        assert (root / 'package-inventory' / package).read_text().strip() == version
    sys.exit(0)
elif scenario.startswith('single-'):
    version = '26.10.10-r1' if requested == xray else current
    expected_calls = [asset_call(requested, version)]
    assert result == {'ok': True, 'package': requested, 'from': inventory[requested],
                      'to': version, 'rolled_back': False, 'code': None}, result
    inventory[requested] = version
    installed_events = [(requested, version)]
    assert not restarts
    assert len(signals) == (1 if requested == xray else 0), signals
else:
    skipped_backend = scenario in ('pages-only', 'backend-newer', 'app-current',
                                   'i18n-current', 'all-current')
    before = '0.3.0-r1' if scenario == 'backend-newer' else current if skipped_backend else old
    inventory[backend] = before
    companions = {app: 'installed', i18n: 'installed'}
    for package, skip_scenarios in (
            (app, ('missing-app', 'app-no-current', 'app-current', 'all-current')),
            (i18n, ('missing-i18n', 'i18n-no-asset', 'i18n-current', 'all-current'))):
        if scenario in skip_scenarios:
            companions[package] = 'skipped'
    if scenario == 'missing-app':
        inventory[app] = None
    if scenario == 'missing-i18n':
        inventory[i18n] = None
    if scenario in ('app-current', 'all-current'):
        inventory[app] = current
    if scenario in ('i18n-current', 'all-current'):
        inventory[i18n] = '0.3.0-r1'
    recovered = scenario in ('backend-recovers', 'app-entry-recovers')
    backend_failed = recovered or scenario in ('backend-install-fails', 'backend-hash-fails')
    if backend_failed:
        companions = {app: 'skipped', i18n: 'skipped'}
    failures = {
        'app-install-fails': (app, 'CMD_FAILED'),
        'app-download-fails': (app, 'UPDATE_VERIFY_FAILED'),
        'i18n-hash-fails': (i18n, 'UPDATE_VERIFY_FAILED'),
        'first-failure': (app, 'CMD_FAILED'),
    }
    if scenario in failures:
        companions[failures[scenario][0]] = 'failed'
    if scenario == 'first-failure':
        companions[i18n] = 'failed'
    code = None
    if backend_failed:
        code = 'CMD_FAILED' if scenario == 'backend-install-fails' else 'UPDATE_VERIFY_FAILED'
    elif scenario in failures:
        code = failures[scenario][1]
    expected_result = {'ok': code is None, 'package': backend, 'from': before,
                       'to': before if skipped_backend else current, 'rolled_back': recovered,
                       'code': code, 'companions': companions}
    # The main transaction's existing recovery shape has no detail; early or UI failures do.
    if code and not recovered:
        detail = result.get('detail', '')
        assert detail, result
        if code == 'CMD_FAILED':
            failed_package = backend if backend_failed else app
            assert detail == f'{manager} install exited 7: fixture install failure: {failed_package}', result
        else:
            assert detail == 'asset size or sha256 mismatch, or download failed', result
        expected_result['detail'] = detail
    assert result == expected_result, result
    if not skipped_backend and scenario != 'backend-hash-fails':
        expected_calls.append(asset_call(backend))
    if recovered:
        expected_calls.append(asset_call(backend, old, True))
    elif not skipped_backend and not backend_failed:
        inventory[backend] = current
        installed_events.append((backend, current))
    assert restarts == (['restart', 'restart'] if recovered else
                        [] if skipped_backend or backend_failed else ['restart']), restarts
    assert not signals, signals
    for package in (app, i18n):
        status = companions[package]
        attempted_install = status == 'installed' or (package == app and scenario in
                                                     ('app-install-fails', 'first-failure'))
        if attempted_install:
            arch = 'all' if package == app and scenario == 'app-all-asset' else 'aarch64_generic'
            expected_calls.append(asset_call(package, arch=arch))
        if status == 'installed':
            inventory[package] = current
            installed_events.append((package, current))
        if status == 'failed':
            assert any(event['code'] == 'CMD_FAILED' and
                       event['args'].get('cmd') == f'update package {package}' and
                       event['args'].get('rc') == 1 and event['args'].get('stderr')
                       for event in events), (package, events)
    rollback_events = [event['args']['package'] for event in events if event['code'] == 'UPDATE_ROLLED_BACK']
    assert rollback_events == ([backend] if recovered else []), rollback_events

# Exact equality forbids extra transactions, accidental companion rollback and reordering.
assert calls == expected_calls, (calls, expected_calls)
actual_installed = [(event['args']['package'], event['args']['version'])
                    for event in events if event['code'] == 'UPDATE_INSTALLED']
assert actual_installed == installed_events, (actual_installed, installed_events)
cache = json.loads((root / 'run/updates.json').read_text())
for package, version in inventory.items():
    path = root / 'package-inventory' / package
    assert (path.read_text().strip() if path.exists() else None) == version, (package, version)
    if package in cache['packages']:
        assert cache['packages'][package]['installed'] == version, (package, cache)
assert cache['pm'] == manager
assert not list((root / 'root/tmp/aether-proxy-dl').glob('*.ipk'))
assert not list((root / 'root/tmp/aether-proxy-dl').glob('*.apk'))
