#!/usr/bin/env python3
"""T16.55 exact terminal acceptance oracle and retained per-invocation evidence."""
import json
from pathlib import Path
import re
import sys

root, manager, mode, scenario, requested, rc, output, start1, start2 = sys.argv[1:]
root = Path(root)
backend, app, language = 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'
current = '0.2.0-r1'


def inventory(directory):
    return {p.name: p.read_text().strip() for p in sorted(directory.iterdir())}


def filename(package):
    return (f'{package}_{current}_aarch64_generic.ipk' if manager == 'opkg'
            else f'{package}-{current}_aarch64_generic.apk')


result = json.loads(output)
before = inventory(root / 'terminal-before')
after = inventory(root / 'package-inventory')
calls = (root / 'package-calls').read_text().splitlines()
requests = [[re.search(r'"GET (\S+) HTTP/', line).group(1)
             for line in (root / f'http{n}').read_text().splitlines()[int(start):]
             if '"GET ' in line] for n, start in ((1, start1), (2, start2))]
record = dict(manager=manager, mode=mode, scenario=scenario, requested=requested,
              exit=int(rc), result=result, installs=calls, inventory=after, requests=requests)
with (root / 'terminal-evidence.jsonl').open('a') as stream:
    stream.write(json.dumps(record, ensure_ascii=False) + '\n')

compatibility = mode == 'compatibility'
group = requested != language
# Ordinary single-package requests intentionally reinstall even equal/newer/missing packages.
candidates = ([p for p in (app, language) if p in before and before[p] == '0.1.0-r1']
              if group else [language])
if compatibility:
    if scenario == 'backend-newer':
        candidates = []
    elif not group:
        candidates = [language] if before.get(language) == '0.1.0-r1' else []
noop = compatibility and not candidates
failed = next((p for p in candidates if scenario.endswith('-fails') and
               p == (language if scenario.startswith('language-') else app)), None)
code = ('UPDATE_VERIFY_FAILED' if 'download-fails' in scenario else 'CMD_FAILED') if failed else None
expected_inventory = dict(before)
expected_calls = []
expected_requests = [['/manifest.json', '/manifest.json.sig'], []]
companions = {app: 'skipped', language: 'skipped'}
installed_events = []
for package in candidates:
    path = '/' + filename(package)
    expected_requests[0].append(path)
    if package == failed and 'download-fails' in scenario:
        expected_requests[1].append(path)
    else:
        prefix = 'install ' if manager == 'opkg' else 'add --allow-untrusted '
        expected_calls.append(prefix + str(root / 'root/tmp/aether-proxy-dl' / filename(package)))
    if package == failed:
        companions[package] = 'failed'
    else:
        companions[package] = 'installed'
        expected_inventory[package] = current
        installed_events.append((package, current))

if noop:
    expected_result = dict(ok=True, package=backend, **{'from': before[backend]},
                           to=before[backend], rolled_back=False, code='UPDATE_UP_TO_DATE')
elif group:
    expected_result = dict(ok=not failed, package=backend, **{'from': before[backend]},
                           to=before[backend], rolled_back=False, code=code,
                           companions={p: companions[p] for p in (app, language)})
else:
    expected_result = dict(ok=not failed, package=language,
                           **{'from': None if failed else before.get(language)},
                           to=None if failed else current, rolled_back=False, code=code)
if failed:
    expected_result['detail'] = ('asset size or sha256 mismatch, or download failed'
                                 if 'download-fails' in scenario else
                                 f'{manager} install exited 7: fixture install failure: {failed}')

if scenario == 'query-fails':
    failed = app
    expected_result = dict(ok=False, package=backend,
                           **{'from': None if compatibility else before[backend]},
                           to=None if compatibility else before[backend], rolled_back=False,
                           code='CMD_FAILED',
                           detail=f'{manager} exited 7: fixture query failure: {app}',
                           companions={app: 'skipped' if compatibility else 'failed', language: 'skipped'})

errors = []


def check(label, actual, expected):
    if actual != expected:
        errors.append(f'{label}: expected {expected!r}, got {actual!r}')


check('exit', int(rc), 1 if failed else 0)
check('return shape', result, expected_result)
check('actual GET paths by channel', requests, expected_requests)
check('package-manager calls', calls, expected_calls)
check('complete inventory', after, expected_inventory)
check('service activation', (root / 'init-calls').read_text().splitlines(), [])
check('service signals', (root / 'signals').read_text().splitlines(), [])
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]
check('installed events', [(e['args']['package'], e['args']['version'])
                           for e in events if e['code'] == 'UPDATE_INSTALLED'], installed_events)
check('rollback events', [e for e in events if e['code'] == 'UPDATE_ROLLED_BACK'], [])
if failed and group and not (compatibility and scenario == 'query-fails'):
    check('visible companion failure event', any(
        e['code'] == 'CMD_FAILED' and e['args'].get('cmd') == f'update package {failed}'
        and e['args'].get('rc') == 1 and e['args'].get('stderr') == expected_result['detail']
        for e in events), True)
check('download residue', sorted(p.name for p in (root / 'root/tmp/aether-proxy-dl').glob('*')
                                if p.suffix in ('.ipk', '.apk', '.part')), [])
if errors:
    print('\n'.join(f'T16.55 {manager} {mode} {scenario}: {error}' for error in errors), file=sys.stderr)
    sys.exit(1)
