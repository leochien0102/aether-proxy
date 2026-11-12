#!/usr/bin/env python3
"""M4-09: real CLI boundary, private config/render paths only (docs/05, docs/10)."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ENTRY = [str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--']

with tempfile.TemporaryDirectory(prefix='aether-port-scope-') as temp:
    conf = Path(temp)
    for name in ('gfwlist', 'chnlist', 'apple'):
        (conf / (name + '.txt')).write_text('example.com\n')
    for name in ('chnroute4', 'gfw_static4'):
        (conf / (name + '.txt')).write_text('1.0.0.0/8\n')
    for scope in ('all', 'common', 'common_extra'):
        for ports in ('8080, 5000-5002', '0', '65536', '5000-4999', 'abc',
                      ','.join(str(i) for i in range(1, 66))):
            (conf / 'aetherproxy').write_text(
                f"config global 'main'\n option port_scope '{scope}'\n option extra_ports '{ports}'\n")
            result = subprocess.run(ENTRY + ['render', 'nft', '--json', '--confdir', temp,
                                            '--baseline-dir', temp, '--data-dir', temp,
                                            '--custom-dir', temp, '--no-precheck'], text=True, capture_output=True)
            valid = scope != 'common_extra' or ports == '8080, 5000-5002'
            assert result.returncode == (0 if valid else 2), (scope, ports, result)
            assert not result.stderr, result.stderr
            reply = json.loads(result.stdout)
            assert reply['ok'] == valid, reply
            if not valid:
                assert reply['code'] == 'CONFIG_INVALID', reply
                assert any(e['field'] == 'main.extra_ports' for e in reply['errors']), reply
            print(f'PASS  M4-09 CLI {scope} {ports}: ' + ('rendered' if valid else 'main.extra_ports field error'))
