#!/usr/bin/env python3
"""T9.41: committed selection is transactional with an actual target-config Xray test."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT, T = map(Path, sys.argv[1:3])
CONF, RUN = T / 'etc/config', T / 'var/run/aether-proxy'
CONF.mkdir(parents=True, exist_ok=True)
RUN.mkdir(parents=True, exist_ok=True)
INIT = T / 'etc/init.d/aether-proxy'
INIT.parent.mkdir(parents=True, exist_ok=True)
CALLS, XRLOG = T / 'reload.log', T / 'xray.jsonl'
INIT.write_text(f'#!/bin/sh\necho reload >> "{CALLS}"\n')
INIT.chmod(0o755)
XR = T / 'xray'
XR.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1:] == ['version']:
 print(os.environ.get('XR_BANNER', 'Xray 26.9.30 (Xray, Penetrates Everything.)'))
 sys.exit(int(os.environ.get('XR_VERSION_RC', '0')))
assert sys.argv[1:4] == ['run', '-test', '-c'], sys.argv
config = json.loads(Path(sys.argv[4]).read_text())
with open(os.environ['XRLOG'], 'a') as f: f.write(json.dumps(config) + '\\n')
if os.environ.get('XR_RC'):
 print('Failed to start: invalid mldsa65Verify: GARBAGE', file=sys.stderr)
 sys.exit(int(os.environ['XR_RC']))
''')
XR.chmod(0o755)
IDS = ['n_' + str(i) * 32 for i in [1, 2]]
CONFIG = CONF / 'aetherproxy'
BASE = f"config main 'main'\n option node '{IDS[0]}'\n option mode 'gfw'\n option xray_bin '{XR}'\n"
for i, node in enumerate(IDS):
    BASE += f"\nconfig node '{node}'\n option protocol 'vless'\n option address 'edge{i}.example'\n"
    BASE += " option port '443'\n option uuid 'id'\n option security 'reality'\n option sni 'edge.example'\n"
    BASE += " option reality_pbk 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'\n"
    if i:
        BASE += " option reality_pqv 'GARBAGE'\n"


def reset(text=BASE):
    CONFIG.write_text(text)
    CALLS.write_text('')
    XRLOG.write_text('')
    (RUN / 'state.json').write_text('{"state":"running","node_id":"old"}\n')
    (RUN / 'xray.json').write_text('active artifact stays intact\n')
    (RUN / 'staging').mkdir(exist_ok=True)
    (RUN / 'staging/xray.json').write_text('daemon staging stays intact\n')


def call(*args, selected=IDS[1], **env):
    return subprocess.run([str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
                           '--', 'node', 'use', selected, '--json', '--confdir', str(CONF),
                           '--sys-root', str(T), *args], text=True, capture_output=True,
                          env={**os.environ, 'XRLOG': str(XRLOG), **env})


def check(name, condition):
    assert condition, name
    print('PASS  T9.41 ' + name)


reset()
before = CONFIG.read_bytes()
p = call('--mode', 'global', XR_RC='23')
check('preflight failure returns CONFIG_INVALID and Xray summary', p.returncode == 1
      and json.loads(p.stdout).get('code') == 'CONFIG_INVALID'
      and 'invalid mldsa65Verify' in json.loads(p.stdout).get('detail', ''))
check('preflight failure leaves node/mode, state, active and staging artifacts unchanged',
      CONFIG.read_bytes() == before and CALLS.read_text() == ''
      and json.loads((RUN / 'state.json').read_text()) == {'state': 'running', 'node_id': 'old'}
      and (RUN / 'xray.json').read_text() == 'active artifact stays intact\n'
      and (RUN / 'staging/xray.json').read_text() == 'daemon staging stays intact\n')
seen = json.loads(XRLOG.read_text().strip())
check('preflight tests target, not previous node, including opaque PQV',
      seen['outbounds'][0]['settings']['address'] == 'edge1.example'
      and seen['outbounds'][0]['streamSettings']['realitySettings']['mldsa65Verify'] == 'GARBAGE')
check('preflight owns and removes only its scratch directory', not list(RUN.glob('node-use.*')))
# A subsequent cold-start render still sees the old selection after the refused switch.
p = subprocess.run([str(ROOT / 'tests/host/ucode'), '-e',
                    "import * as uci from 'uci'; import * as c from 'aetherproxy.config'; "
                    "import * as x from 'aetherproxy.render.xray'; "
                    "let r=c.load(uci.cursor(ARGV[0])); print(x.render(r.snapshot, {}));", '--', str(CONF)],
                   text=True, capture_output=True)
check('cold render after refused selection still uses old node', p.returncode == 0
      and json.loads(p.stdout)['outbounds'][0]['settings']['address'] == 'edge0.example')

reset()
p = call('--mode', 'global')
check('successful preflight commits both values and reloads once', p.returncode == 0
      and json.loads(p.stdout)['reload'] is True and CALLS.read_text() == 'reload\n'
      and f"option node '{IDS[1]}'" in CONFIG.read_text() and "option mode 'global'" in CONFIG.read_text())
reset()
p = call(selected=IDS[0], XR_RC='23')
check('same node is a no-op without Xray test or reload', p.returncode == 0 and XRLOG.read_text() == ''
      and CALLS.read_text() == '' and json.loads(p.stdout)['reload'] is False)
reset()
(RUN / 'state.json').write_text('{"state":"stopped"}')
before = CONFIG.read_bytes()
p = call(XR_RC='23')
check('stopped selection still preflights and refuses bad target', p.returncode == 1
      and CONFIG.read_bytes() == before and CALLS.read_text() == '')
p = call()
check('stopped valid target commits without reload', p.returncode == 0
      and json.loads(p.stdout)['reload'] is False and CALLS.read_text() == '')
for name, env in [('unknown', {'XR_BANNER': 'unknown'}), ('empty', {'XR_BANNER': ''}),
                  ('version-failed', {'XR_VERSION_RC': '7'})]:
    reset()
    p = call(XR_RC='23', **env)
    check('preflight skips ' + name + ' version', p.returncode == 0 and XRLOG.read_text() == ''
          and CALLS.read_text() == 'reload\n')
reset(BASE.replace(str(XR), str(T / 'missing-xray')))
p = call()
check('preflight skips missing Xray', p.returncode == 0 and XRLOG.read_text() == '')

# Real Xray catches the deliberately opaque bad PQV, then accepts the corrected node.
for binary in Path('/workspace/openwrt/ci-spike/tools').glob('xray-*/xray'):
    reset(BASE.replace(str(XR), str(binary)))
    p = call()
    check(binary.parent.name + ' actual PQV refusal is transactional', p.returncode == 1
          and json.loads(p.stdout)['code'] == 'CONFIG_INVALID' and 'mldsa65Verify' in json.loads(p.stdout)['detail']
          and IDS[0] in CONFIG.read_text().split('config node')[0] and CALLS.read_text() == '')
    reset(BASE.replace(str(XR), str(binary)).replace(" option reality_pqv 'GARBAGE'\n", ''))
    p = call()
    check(binary.parent.name + ' actual legal target passes', p.returncode == 0 and CALLS.read_text() == 'reload\n')
