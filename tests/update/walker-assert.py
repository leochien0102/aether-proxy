#!/usr/bin/env python3
"""Exact ordered calls/events are the oracle; never discard engine side effects."""
import json
from pathlib import Path
import sys

root, scenario, output = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
result = json.loads(output)
state = root / 'package-inventory'
calls = (root / 'package-calls').read_text().splitlines()
restarts = (root / 'init-calls').read_text().splitlines()
handoffs = (root / 'handoffs').read_text().splitlines()
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]


def backend():
    return (state / 'aether-proxy').read_text().strip()


def call_has(call, package, version):
    filename = Path(call.split()[-1]).name.removeprefix('new-')
    return filename.startswith(f'{package}_{version}_') or filename.startswith(f'{package}-{version}_')


if scenario == 'legacy-no-progress':
    assert result['code'] == 'BRIDGE_UNAVAILABLE' and backend() == '0.7.0-r1', result
    assert len(calls) == 1 and len(restarts) == 1 and len(handoffs) == 1
    sys.exit(0)

if scenario == 'legacy':
    # The mock represents a released single-hop CLI; the real successor must be
    # invoked again, within the original cap, and finish the engine transaction.
    assert result['ok'] and result['to'] == '1.0.0-r1' and backend() == '1.0.0-r1', result
    assert len(handoffs) == 2, handoffs
    assert handoffs[0].split()[0] == handoffs[1].split()[0], handoffs
    assert [line.split()[1] for line in handoffs] == ['2', '1'], handoffs
    assert (state / 'aether-dns').read_text().strip() == '1.0.0-r1'
    sys.exit(0)

expected = {
    'W1': [('aether-proxy', '0.7.0-r1'), ('aether-dns', '1.0.0-r1'), ('aether-proxy', '1.0.0-r1')],
    'W2': [('aether-dns', '1.0.0-r1'), ('aether-proxy', '1.0.0-r1')],
    'W3': [], 'W6': [], 'W6-newer': [], 'W5-low': [],
    'W4': [('aether-proxy', '0.7.0-r1'), ('aether-dns', '1.0.0-r1'), ('aether-proxy', '1.0.0-r1')],
    'W5': [('aether-proxy', '0.7.0-r1')],
    'W7-cap': [('aether-proxy', '0.7.0-r1'), ('aether-proxy', '0.8.0-r1')],
    'W7-progress': [('aether-proxy', '0.7.0-r1')],
    'fresh-signature': [('aether-proxy', '0.7.0-r1')],
}[scenario]
extra = 1 if scenario == 'W4' else 0
assert len(calls) == len(expected) + extra, (calls, result)
for call, (package, version) in zip(calls, expected):
    assert call_has(call, package, version), (calls, expected)
started = [(e['args']['package'], e['args']['version']) for e in events if e['code'] == 'UPDATE_STARTED']
assert started == expected, (started, expected)
if scenario in ('W1', 'W2'):
    assert result['ok'] and result['to'] == '1.0.0-r1', result
    assert backend() == '1.0.0-r1'
    assert (state / 'aether-dns').read_text().strip() == '1.0.0-r1'
    # The apk stub records installation metadata only; opkg also materializes the engine.
    if calls[0].startswith('install '):
        assert (root / 'bin/aether-dns').exists()
    assert len(restarts) == (2 if scenario == 'W1' else 1), restarts
    assert len(handoffs) == (1 if scenario == 'W1' else 0), handoffs
elif scenario == 'W3':
    assert result['code'] == 'BRIDGE_UNAVAILABLE' and backend() == '0.6.3-r1', result
    assert not restarts and not handoffs
elif scenario in ('W6', 'W6-newer'):
    version = '1.0.0-r1' if scenario == 'W6' else '1.1.0-r1'
    assert result['code'] == 'UPDATE_UP_TO_DATE' and backend() == version, result
    assert not restarts and not handoffs
elif scenario == 'W7-cap':
    # The newly signed chain is valid and strictly increasing, but cannot enlarge
    # the initial hop budget. This is independent of bridge_plan's order checks.
    assert result['code'] == 'BRIDGE_UNAVAILABLE' and backend() == '0.8.0-r1', result
    assert len(restarts) == 2 and len(handoffs) == 1
elif scenario == 'W7-progress':
    assert result['code'] == 'BRIDGE_UNAVAILABLE' and backend() == '0.6.3-r1', result
    assert len(restarts) == 1 and len(handoffs) == 1
elif scenario == 'fresh-signature':
    assert result['code'] == 'MANIFEST_BAD_SIGNATURE' and backend() == '0.7.0-r1', result
    assert len(restarts) == 1 and len(handoffs) == 1
elif scenario == 'W4':
    assert result['code'] == 'CMD_FAILED' and backend() == '0.7.0-r1', result
    assert calls[-1].startswith(('remove aether-dns', 'del aether-dns')), calls
    assert not (state / 'aether-dns').exists()
    assert len(handoffs) == 1
elif scenario == 'W5-low':
    assert result['code'] == 'BRIDGE_INCOMPLETE' and backend() == '0.6.3-r1', result
    assert not calls and not restarts and not handoffs
    assert not started
    assert not (state / 'aether-dns').exists()
    assert any(e['code'] == 'BRIDGE_INCOMPLETE' for e in events)
elif scenario == 'W5':
    assert result['code'] == 'BRIDGE_INCOMPLETE' and backend() == '0.7.0-r1', result
    assert len(restarts) == 1 and len(handoffs) == 1
    assert any(e['code'] == 'BRIDGE_INCOMPLETE' for e in events)
    original_deadline = float((root / 'start-deadline').read_text())
    assert abs(float(handoffs[0].split()[0]) - original_deadline) < 0.000001, handoffs
# A bridge completion must follow its successful install and must not duplicate starts.
bridges = [e['args']['version'] for e in events if e['code'] == 'BRIDGE_INSTALLED']
if scenario not in ('W3', 'W6', 'W6-newer', 'W5-low'):
    assert bridges[0] == ('1.0.0-r1' if scenario == 'W2' else '0.7.0-r1'), bridges
for name in ('luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'):
    assert (state / name).read_text().strip() == '1.0.0-r1'
