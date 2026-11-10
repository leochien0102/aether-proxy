#!/usr/bin/env python3
"""M4-04 V1–V5: exact event order plus observations before package writes."""
import json
from pathlib import Path
import sys

root, scenario, output = Path(sys.argv[1]), sys.argv[2], json.loads(sys.argv[3])
events = [json.loads(line) for line in (root / 'run/events.jsonl').read_text().splitlines()]
p = 'aether-proxy'
app = 'luci-app-aether-proxy'
i18n = 'luci-i18n-aether-proxy-zh-cn'
xray = 'aether-xray'
dns = 'aether-dns'
sequence = [(e['code'], e['args'].get('package')) for e in events
            if e['code'] in ('UPDATE_STARTED', 'UPDATE_INSTALLED', 'SERVICE_STOPPED',
                             'SERVICE_STARTED', 'UPDATE_VERIFY_FAILED', 'UPDATE_ROLLED_BACK', 'TEST_INSTALL')]

def pair(package):
    return [('UPDATE_STARTED', package), ('TEST_INSTALL', package), ('UPDATE_INSTALLED', package)]

if scenario == 'V1':
    expected = [('UPDATE_STARTED', p), ('TEST_INSTALL', p), ('SERVICE_STOPPED', None),
                ('SERVICE_STARTED', None), ('UPDATE_INSTALLED', p)] + pair(app) + pair(i18n)
    assert output['ok'], output
elif scenario == 'V2':
    expected = pair(xray)
    assert output['ok'], output
elif scenario.startswith('V3'):
    assert output['code'] == 'UPDATE_VERIFY_FAILED', output
    assert not any(e['code'] == 'UPDATE_STARTED' for e in events), events
    assert not (root / 'package-calls').read_text(), 'download failure invoked installer'
    # Also freeze the boundary itself: moving the event after install must fail V3.
    source = (Path(__file__).resolve().parents[2] / 'aether-proxy/src/lib/update.uc').read_text()
    boundary = ("log.event('notice', 'UPDATE_STARTED', { package: name, version: asset.version });\n"
                "\tlet installed = install_package")
    assert boundary in source, 'V3 UPDATE_STARTED must immediately precede install_package'
    expected = []
elif scenario == 'V4':
    expected = [('UPDATE_STARTED', p), ('TEST_INSTALL', p), ('SERVICE_STOPPED', None),
                ('SERVICE_STARTED', None), ('UPDATE_VERIFY_FAILED', p), ('TEST_INSTALL', p),
                ('UPDATE_ROLLED_BACK', p), ('SERVICE_STOPPED', None), ('SERVICE_STARTED', None)]
    assert output['rolled_back'] and output['code'] == 'UPDATE_VERIFY_FAILED', output
elif scenario == 'V5':
    expected = pair(dns) + [('UPDATE_STARTED', p), ('TEST_INSTALL', p),
                            ('SERVICE_STOPPED', None), ('SERVICE_STARTED', None), ('UPDATE_INSTALLED', p)]
    assert output['prerequisite']['action'] == 'installed', output
else:
    raise AssertionError(scenario)
assert sequence == expected, (scenario, sequence, expected)
for event in events:
    if event['code'] in ('UPDATE_STARTED', 'UPDATE_INSTALLED'):
        assert event['level'] == 'notice', event
        assert set(event['args']) == {'package', 'version'}, event
        version = '26.10.10-r1' if scenario == 'V2' else '1.0.0-r1' if scenario == 'V5' else '0.2.0-r1'
        assert event['args']['version'] == version, event
print(scenario + ': ' + ' → '.join(f'{code}({package})' if package else code
                                  for code, package in sequence if code != 'TEST_INSTALL'))
