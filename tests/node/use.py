#!/usr/bin/env python3
"""T9.10 docs/10 node use: real libuci commits, isolated init and session savedir."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(sys.argv[1])
T = Path(sys.argv[2])
CONF = T / 'etc/config'
RUN = T / 'var/run/aether-proxy'
INIT = T / 'etc/init.d/aether-proxy'
CALLS = T / 'init.log'
IDS = ['n_' + f'{i:032x}' for i in range(1, 4)]
for directory in (CONF, RUN, INIT.parent):
    directory.mkdir(parents=True, exist_ok=True)
INIT.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(CALLS) + '"\nexit "${USE_INIT_RC:-0}"\n')
INIT.chmod(0o755)
CALLS.write_text('')
CONFIG = CONF / 'aetherproxy'
# Canonical libuci layout lets an exact comparison detect every non-node change.
BASE = "\nconfig main 'main'\n\toption enabled '1'\n\toption mode 'gfw'\n\toption node '{}'\n".format(IDS[0])
BASE += "\tlist lan_ifaces 'br-lan'\n\tlist lan_ifaces 'guest'\n"
for node in IDS[:2]:
    BASE += f"\nconfig node '{node}'\n\toption label 'keep me'\n"
    BASE += "\toption protocol 'vmess'\n\toption address 'edge.example'\n\toption port '443'\n\toption uuid 'id'\n"
CONFIG.write_text(BASE + '\n')
BASE = CONFIG.read_bytes()
EVENTS = RUN / 'events.jsonl'
EVENTS.write_text('existing events\n')


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  ' + name)


def ap(*args, rc=0, env=None):
    entry = 'tests/node/use-driver.uc' if env and 'USE_SAVEDIR' in env else 'aether-proxy/src/aether-proxy'
    result = subprocess.run([
        str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / entry), '--',
        'node', 'use', *args, '--json', '--confdir', str(CONF), '--sys-root', str(T)
    ], text=True, capture_output=True, env={**os.environ, **(env or {})})
    assert result.returncode == rc, (args, result.returncode, result.stdout, result.stderr)
    assert result.stderr == '', result.stderr
    return json.loads(result.stdout)


(RUN / 'state.json').write_text('{"state":"running","node_id":"old","last_probe":{"ok":true}}\n')
state_before = (RUN / 'state.json').read_bytes()
stamp = CONFIG.stat().st_mtime_ns
reply = ap(IDS[0])
check('node use same: exact reply, no write and no init',
      reply == dict(ok=True, node=IDS[0], previous=IDS[0], reload=False, committed=True, previous_mode='gfw')
      and CONFIG.read_bytes() == BASE and CONFIG.stat().st_mtime_ns == stamp and CALLS.read_text() == '')
reply = ap(IDS[1])
check('node use running: committed only main.node and reloaded exactly once',
      reply == dict(ok=True, node=IDS[1], previous=IDS[0], reload=True, committed=True, previous_mode='gfw')
      and CONFIG.read_bytes() == BASE.replace(IDS[0].encode(), IDS[1].encode(), 1)
      and CALLS.read_text() == 'reload\n')
check('node use returns before daemon completion: state untouched', (RUN / 'state.json').read_bytes() == state_before)

for service_state in ('starting', 'degraded', 'failsafe', 'stopped', 'error', None):
    CONFIG.write_bytes(BASE)
    CALLS.write_text('')
    if service_state is None:
        (RUN / 'state.json').unlink()
    else:
        (RUN / 'state.json').write_text(json.dumps(dict(state=service_state)))
    reply = ap(IDS[1])
    running = service_state in ('starting', 'degraded', 'failsafe')
    check(f'node use {service_state}: correct reload and committed node',
          reply['reload'] == running and CALLS.read_text() == ('reload\n' if running else '')
          and CONFIG.read_bytes() == BASE.replace(IDS[0].encode(), IDS[1].encode(), 1))

CONFIG.write_bytes(BASE)
CALLS.write_text('')
for value in (IDS[2], 'n_bad', 'n_' + 'A' * 32, 'main', IDS[0] + ';reboot'):
    reply = ap(value, rc=2)
    check(f'node use rejects {value}: USAGE without side effects',
          reply['code'] == 'USAGE' and CONFIG.read_bytes() == BASE and CALLS.read_text() == '')

# Real savedir (same API as uci -P / rpcd session staging), not a mock delta file.
SAVEDIR = T / 'session'
SAVEDIR.mkdir()
subprocess.run([str(ROOT / 'tests/host/ucode'), '-e', '''
import * as uci from 'uci';
let c = uci.cursor(ARGV[0], ARGV[1]);
if (!c.set('aetherproxy', 'main', 'mode', 'global') ||
    !c.set('aetherproxy', 'main', 'node', ARGV[2]) || !c.save('aetherproxy')) exit(1);
''', '--', str(CONF), str(SAVEDIR), IDS[2]], check=True)
delta_before = (SAVEDIR / 'aetherproxy').read_bytes()
reply = ap(IDS[1])
check('node use session delta: only committed main.node changes; session remains staged',
      CONFIG.read_bytes() == BASE.replace(IDS[0].encode(), IDS[1].encode(), 1)
      and (SAVEDIR / 'aetherproxy').read_bytes() == delta_before and reply['previous'] == IDS[0])

# Force the command's cursor to see the session delta path. Absolute-path loading
# must bypass even an inherited savedir; a normal package load would leak mode/global.
CONFIG.write_bytes(BASE)
reply = ap(IDS[1], env={'USE_SAVEDIR': str(SAVEDIR)})
check('node use inherited savedir: absolute load bypasses real libuci deltas',
      CONFIG.read_bytes() == BASE.replace(IDS[0].encode(), IDS[1].encode(), 1)
      and (SAVEDIR / 'aetherproxy').read_bytes() == delta_before and reply['previous'] == IDS[0])

# A missing main section fails at set(), before commit; no config or init change.
CONFIG.write_text(f"config node '{IDS[1]}'\n option label 'keep'\n")
before = CONFIG.read_bytes()
reply = ap(IDS[1], rc=1)
check('node use failed UCI write: FS_FAILED op uci-commit and no init',
      reply['code'] == 'FS_FAILED' and reply['op'] == 'uci-commit'
      and CONFIG.read_bytes() == before and CALLS.read_text() == '')
CONFIG.write_bytes(BASE)
(RUN / 'state.json').write_text('{"state":"running"}')
reply = ap(IDS[1], rc=1, env={'USE_INIT_RC': '7'})
check('node use reload failure: CMD_FAILED exit 1, configuration remains committed',
      reply['code'] == 'CMD_FAILED' and 'exit 7' in reply['detail']
      and reply['committed'] is True and reply['previous'] == IDS[0] and reply['previous_mode'] == 'gfw'
      and CONFIG.read_bytes() == BASE.replace(IDS[0].encode(), IDS[1].encode(), 1))
CONFIG.write_bytes(BASE)
CALLS.write_text('')
(RUN / 'state.json').write_text('{broken')
reply = ap(IDS[1], rc=1)
check('node use corrupt state: refuse before committing',
      reply['code'] == 'FS_FAILED' and CONFIG.read_bytes() == BASE and CALLS.read_text() == '')
check('node use all outcomes: no events appended', EVENTS.read_text() == 'existing events\n')
