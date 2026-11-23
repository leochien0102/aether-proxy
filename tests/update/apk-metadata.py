#!/usr/bin/env python3
"""Replay captured apk-tools metadata; delegate unrelated package operations."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
base = Path(__file__).resolve().parent
# Baseline replay uses the captured legacy output, not a synthesized list line.
scenario = os.environ.get('APK_METADATA_CASE', '')
if args[:2] == ['list', '-I'] and scenario in ('aether-dns', 'chinadns-ng') and args[-1] == scenario:
    with open(os.environ['UPDATE_PACKAGE_QUERY_CALLS'], 'a') as f:
        f.write(args[-1] + '\n')
    path = base / 'fixtures/apk-provides' / (scenario + '-list')
    sys.stdout.write(path.with_suffix('.stdout').read_text())
    sys.stderr.write(path.with_suffix('.stderr').read_text())
    sys.exit(int(path.with_suffix('.rc').read_text()))
if args and args[0] == 'query':
    assert args[:-1] == ['query', '--from', 'installed', '--format', 'json',
                         '--fields', 'name,version,provides'], args
    name = args[-1]
    with open(os.environ['UPDATE_PACKAGE_QUERY_CALLS'], 'a') as f:
        f.write('query ' + name + '\n')
    scenario = os.environ.get('APK_METADATA_CASE', '')
    fixture = None
    if scenario in ('aether-dns', 'chinadns-ng', 'no-provides', 'old', 'failure', 'malformed', 'legacy-failure', 'repository-only'):
        selected = 'chinadns-ng' if scenario in ('chinadns-ng', 'legacy-failure') else 'aether-dns'
        if name == selected:
            fixture = {'old': 'aether-dns', 'malformed': 'aether-dns', 'legacy-failure': 'failure'}.get(scenario, scenario)
    if fixture:
        if scenario == 'malformed':
            print('{')
            sys.exit(0)
        path = base / 'fixtures/apk-provides' / fixture
        sys.stdout.write(path.with_suffix('.stdout').read_text())
        sys.stderr.write(path.with_suffix('.stderr').read_text())
        sys.exit(int(path.with_suffix('.rc').read_text()))
    # Existing migration tests use mutable inventory, with no declared capability.
    inventory = Path(os.environ['UPDATE_PACKAGE_STATE_DIR']) / name
    print(json.dumps([{'name': name, 'version': inventory.read_text().strip()}]
                     if inventory.exists() else []))
    sys.exit(0)
os.execv(str(base.parent / 'stubs/update-bin/apk'), ['apk', *args])
