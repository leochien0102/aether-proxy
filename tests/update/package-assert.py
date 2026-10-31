#!/usr/bin/env python3
"""T9.29 transaction evidence for signed channels (docs/08 manual rollback policy)."""
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
grouped = mode == 'automatic' or mode in ('forward:' + backend, 'forward:' + app)
if not grouped:
    assert 'companions' not in result, result


def asset_call(package, version, previous):
    """Exact arguments: opkg downgrades only, apk always allow-untrusted."""
    if manager == 'opkg':
        prefix = 'install --force-downgrade ' if previous else 'install '
        filename = f'{package}_{version}_aarch64_generic.ipk'
    else:
        prefix = 'add --allow-untrusted '
        filename = f'{package}-{version}_aarch64_generic.apk'
    return prefix + str(root / 'root/tmp/aether-proxy-dl' / filename)


if mode.startswith('reject:'):
    assert result['ok'] is False and result['code'] == 'USAGE', result
    assert not calls and not queries and not restarts and not signals
    # No manifest, signature or asset requests; valid channels were checked just before the call.
    for number in (1, 2):
        assert (root / f'http{number}').read_bytes() == (root / f'policy-http{number}').read_bytes()
    assert (root / 'run/updates.json').read_bytes() == (root / 'policy-cache').read_bytes()
    for package in (backend, app, i18n, 'aether-xray'):
        expected = '26.10.10-r1' if package == 'aether-xray' else current
        assert (inventory / package).read_text().strip() == expected
elif mode == 'automatic':
    assert result == {'ok': False, 'package': backend, 'from': old, 'to': current,
                      'rolled_back': True, 'code': 'UPDATE_VERIFY_FAILED',
                      'companions': {app: 'skipped', i18n: 'skipped'}}, result
    assert calls == [asset_call(backend, current, False), asset_call(backend, old, True)], calls
    assert restarts == ['restart', 'restart'] and not signals, (restarts, signals)
    assert (inventory / backend).read_text().strip() == old
    for package in (app, i18n):
        assert (inventory / package).read_text().strip() == current
    update_events = [event for event in events
                     if event['code'] in ('UPDATE_VERIFY_FAILED', 'UPDATE_ROLLED_BACK', 'UPDATE_INSTALLED')]
    assert [(event['code'], event['args']['package'], event['args']['version'])
            for event in update_events] == [
                ('UPDATE_VERIFY_FAILED', backend, current), ('UPDATE_ROLLED_BACK', backend, old)]
elif grouped:
    # T9.38: an already-current group is a no-op, even from the page entry point.
    assert result == {'ok': True, 'package': backend, 'from': current, 'to': current,
                      'rolled_back': False, 'code': None,
                      'companions': {app: 'skipped', i18n: 'skipped'}}, result
    assert not calls and not restarts and not signals
    assert not any(event['code'] == 'UPDATE_INSTALLED' for event in events)
    for package in (backend, app, i18n, 'aether-xray'):
        assert queries.count(package) == (1 if package == 'aether-xray' else 2), queries
else:
    direction, package = mode.split(':')
    previous = direction == 'previous'
    version = ('26.7.28-r1' if previous else '26.10.10-r1') if package == 'aether-xray' else current
    before = '26.10.10-r1' if package == 'aether-xray' else current
    assert result == {'ok': True, 'package': package, 'from': before, 'to': version,
                      'rolled_back': False, 'code': None}, result
    assert calls == [asset_call(package, version, previous)], calls
    assert restarts == (['restart'] if package == backend else []), restarts
    assert len(signals) == (1 if package == 'aether-xray' else 0), signals
    for signal in signals:
        prefix = 'call service signal '
        assert signal.startswith(prefix), signal
        assert json.loads(signal[len(prefix):]) == {'name': 'aether-proxy', 'signal': 12}, signal
    assert (inventory / package).read_text().strip() == version
    installed = [event['args'] for event in events if event['code'] == 'UPDATE_INSTALLED']
    assert installed == [{'package': package, 'version': version}], installed
    # Exactly one final refresh: each other manifest package is queried once.
    for name in (backend, app, i18n, 'aether-xray'):
        assert queries.count(name) == (3 if name == package else 1), queries

# Cached versions must describe the actual inventory, including after automatic recovery.
# The previous metadata remains available even for packages that cannot be manually rolled back.
for package, entry in cache['packages'].items():
    assert entry['installed'] == (inventory / package).read_text().strip(), (package, entry)
    assert entry['previous'] == ('26.7.28-r1' if package == 'aether-xray' else old), (package, entry)
assert cache['pm'] == manager
assert not list((root / 'root/tmp/aether-proxy-dl').glob('*.ipk'))
assert not list((root / 'root/tmp/aether-proxy-dl').glob('*.apk'))
