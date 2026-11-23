#!/usr/bin/env python3
"""Installed capability, runtime floor, and recovery are independent gates."""
import json
from pathlib import Path
import sys

root, scenario, output = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
result = json.loads(output)
calls = (root / 'package-calls').read_text().splitlines()
queries = (root / 'package-queries').read_text().splitlines()
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]
if scenario in ('aether-dns', 'chinadns-ng'):
    assert result['ok'] and result['prerequisite']['action'] == 'skipped', result
    assert len(calls) == 1 and 'aether-proxy-' in calls[0], calls
elif scenario in ('no-provides', 'repository-only', 'old'):
    assert result['ok'] and result['prerequisite']['action'] == 'installed', result
    assert len(calls) == 2 and 'aether-dns-' in calls[0] and 'aether-proxy-' in calls[1], calls
else:
    assert not result['ok'], result
    assert result['code'] == ('PREREQ_MANUAL_REQUIRED' if scenario == 'missing-recovery' else 'CMD_FAILED'), result
    assert not calls, calls
    if scenario == 'missing-recovery':
        assert 'exact engine recovery' in result['detail'], result
    elif scenario != 'malformed':
        assert 'exited 99' in result['detail'], result
# Event-level download evidence is synchronous (unlike the HTTP access log).
if scenario not in ('no-provides', 'repository-only', 'old'):
    assert not any(e['code'] == 'UPDATE_STARTED' and e['args'].get('package') == 'aether-dns'
                   for e in events), events
    assert not any('aether-dns' in str(e['args']) and 'DOWNLOAD' in e['code'] for e in events), events
    # Actual HTTP logs also forbid new and recovery engine assets for this transaction.
    # policy_reset preserves logs, so the caller records offsets before invoking us.
    for log in ('http1', 'http2'):
        offset = int((root / (log + '-apk-offset')).read_text())
        assert not any('aether-dns' in line and '.apk' in line
                       for line in (root / log).read_text()[offset:].splitlines())

assert queries.count('query aether-dns') == 1, queries
assert queries.count('query chinadns-ng') == 1, queries
assert all(line in ('query aether-dns', 'query chinadns-ng')
           for line in queries if line.startswith('query ')), queries
