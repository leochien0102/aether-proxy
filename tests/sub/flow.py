#!/usr/bin/env python3
"""T9.18: flow validation at the CLI boundary (docs/05 config node, rule 7)."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(sys.argv[1])
T = Path(sys.argv[2])
CONF = T / 'etc/config'
RUN = T / 'var/run/aether-proxy'
CONF.mkdir(parents=True)
RUN.mkdir(parents=True)
CONFIG = CONF / 'aetherproxy'
BASE = "config global 'main'\n\toption enabled '0'\n"
ID = 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
NODE = f"""
config node '{ID}'
	option protocol 'vless'
	option address 'edge.example'
	option port '443'
	option uuid '11111111-2222-4333-8444-555555555555'
	option security 'tls'
"""


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T9.18 ' + name)


def ap(args):
    result = subprocess.run([
        str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
        '--', *args, '--json', '--confdir', str(CONF), '--run-dir', str(RUN), '--sys-root', str(T)
    ], text=True, capture_output=True)
    assert not result.stderr, result.stderr
    return result.returncode, json.loads(result.stdout)


for flow in ('xtls-rprx-vision', 'xtls-rprx-vision-udp443'):
    CONFIG.write_text(BASE + NODE + f"\toption flow '{flow}'\n\toption mux '1'\n")
    rc, value = ap(['check', '--no-precheck'])
    check(flow + ' with Mux returns CONFIG_INVALID and exact mux conflict',
          rc == 2 and value['code'] == 'CONFIG_INVALID'
          and [(e['field'], e['code']) for e in value['errors']] == [(f'node.{ID}.mux', 'conflict')])

CONFIG.write_text(BASE + NODE + "\toption flow 'xtls-rprx-direct'\n")
rc, value = ap(['check', '--no-precheck'])
check('legacy flow returns CONFIG_INVALID and exact flow invalid_enum',
      rc == 2 and value['code'] == 'CONFIG_INVALID'
      and [(e['field'], e['code']) for e in value['errors']] == [(f'node.{ID}.flow', 'invalid_enum')])

# Rejected links must fail before locking or staging and must not touch configuration.
CONFIG.write_text(BASE)
uri = 'vless://11111111-2222-4333-8444-555555555555@edge.example:443?security=tls&flow='
for flow in ('xtls-rprx-direct', 'unknown'):
    for action in ('parse', 'import'):
        before = {p.relative_to(T): p.read_bytes() for p in T.rglob('*') if p.is_file()}
        rc, value = ap(['node', action, uri + flow])
        check(action + ' rejects ' + flow + ' as CONFIG_INVALID invalid_value',
              rc == 2 and value == dict(ok=False, code='CONFIG_INVALID', detail='invalid_value'))
        after = {p.relative_to(T): p.read_bytes() for p in T.rglob('*') if p.is_file()}
        check(action + ' rejecting ' + flow + ' leaves files unchanged', before == after)

for flow in ('xtls-rprx-vision', 'xtls-rprx-vision-udp443', ''):
    rc, value = ap(['node', 'parse', uri + flow])
    check('parse accepts flow ' + (flow or 'empty') + ' unchanged',
          rc == 0 and value['ok'] and value['node']['flow'] == flow)
