#!/usr/bin/env python3
"""T9.20 docs/10: shared node/mode transaction, reload and failure semantics."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT, T = map(Path, sys.argv[1:])
CONF = T / 'etc/config'
RUN = T / 'var/run/aether-proxy'
INIT = T / 'etc/init.d/aether-proxy'
SESSION = T / 'session'
TRACE = T / 'commits.jsonl'
CALLS = T / 'init.log'
CONFIG = CONF / 'aetherproxy'
STATE = RUN / 'state.json'
IDS = ['n_' + f'{i:032x}' for i in range(1, 4)]
for directory in (CONF, RUN, INIT.parent, SESSION):
    directory.mkdir(parents=True, exist_ok=True)
INIT.write_text('#!/bin/sh\nprintf "reload\\n" >> "' + str(CALLS)
                + '"\nexit "${USE_INIT_RC:-0}"\n')
INIT.chmod(0o755)
BASE = ("\nconfig main 'main'\n\toption enabled '1'\n\toption mode 'bypass_cn'\n"
        f"\toption node '{IDS[0]}'\n\tlist lan_ifaces 'br-lan'\n\tlist lan_ifaces 'guest'\n")
for node in IDS[:2]:
    BASE += f"\nconfig node '{node}'\n\toption label 'keep me'\n"
BASE = (BASE + '\n').encode()


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T9.20 ' + name, flush=True)


def reset(state='running'):
    CONFIG.write_bytes(BASE)
    STATE.write_text(json.dumps({'state': state, 'node_id': 'still-old'}))
    TRACE.write_text('')
    CALLS.write_text('')


def expected(node=IDS[0], mode='bypass_cn'):
    return BASE.replace(IDS[0].encode(), node.encode(), 1).replace(b"'bypass_cn'", f"'{mode}'".encode(), 1)


def commits():
    return [json.loads(line) for line in TRACE.read_text().splitlines()]


def ap(*args, rc=0, real=False, human=False, env=None):
    entry = 'aether-proxy/src/aether-proxy' if real else 'tests/node/use-driver.uc'
    result = subprocess.run([
        str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / entry), '--', *args,
        *([] if human else ['--json']), '--confdir', str(CONF), '--sys-root', str(T)
    ], text=True, capture_output=True, env={**os.environ, 'USE_SAVEDIR': str(SESSION),
                                         'USE_TRACE': str(TRACE), **(env or {})})
    assert result.returncode == rc, (args, result.returncode, result.stdout, result.stderr)
    assert result.stderr == '', result.stderr
    return result.stdout if human else json.loads(result.stdout)


# Real saved deltas deliberately conflict with both requested values; a third
# unrelated option proves no session edit was accidentally included in commit.
reset()
subprocess.run([str(ROOT / 'tests/host/ucode'), '-e', '''
import * as uci from 'uci';
let c = uci.cursor(ARGV[0], ARGV[1]);
if (!c.set('aetherproxy', 'main', 'node', ARGV[2]) ||
    !c.set('aetherproxy', 'main', 'mode', 'global') ||
    !c.set('aetherproxy', 'main', 'enabled', '0') || !c.save('aetherproxy')) exit(1);
''', '--', str(CONF), str(SESSION), IDS[2]], check=True)
delta = (SESSION / 'aetherproxy').read_bytes()
reply = ap('mode', 'use', 'gfw')
check('mode use running: only mode committed once, one reload, session unchanged',
      reply == dict(ok=True, mode='gfw', previous='bypass_cn', reload=True)
      and CONFIG.read_bytes() == expected(mode='gfw')
      and commits() == [dict(node=IDS[0], mode='gfw')]
      and CALLS.read_text() == 'reload\n' and (SESSION / 'aetherproxy').read_bytes() == delta)
check('mode use returns without daemon completion', json.loads(STATE.read_text())['node_id'] == 'still-old')

for args, fields in [(('mode', 'use', 'bypass_cn'), dict(mode='bypass_cn', previous='bypass_cn')),
                     (('node', 'use', IDS[0], '--mode', 'bypass_cn'),
                      dict(node=IDS[0], previous=IDS[0], mode='bypass_cn', previous_mode='bypass_cn'))]:
    reset()
    stamp = (CONFIG.stat().st_ino, CONFIG.stat().st_mtime_ns)
    reply = ap(*args)
    check(args[0] + ' use same: exact reply, no commit, no rewrite, no reload',
          reply == dict(ok=True, reload=False, **fields) and CONFIG.read_bytes() == BASE
          and stamp == (CONFIG.stat().st_ino, CONFIG.stat().st_mtime_ns)
          and commits() == [] and CALLS.read_text() == '')

for node in IDS[:2]:
    reset()
    reply = ap('node', 'use', node, '--mode', 'global')
    check(('combined both changed' if node == IDS[1] else 'combined mode-only changed')
          + ': exact reply, one atomic commit, one reload, session unchanged',
          reply == dict(ok=True, node=node, previous=IDS[0], mode='global',
                        previous_mode='bypass_cn', reload=True)
          and CONFIG.read_bytes() == expected(node=node, mode='global')
          and commits() == [dict(node=node, mode='global')] and CALLS.read_text() == 'reload\n'
          and (SESSION / 'aetherproxy').read_bytes() == delta)

reset()
reply = ap('node', 'use', IDS[1], '--mode', 'bypass_cn')
check('combined node-only changed: one commit and one reload',
      reply['reload'] is True and CONFIG.read_bytes() == expected(node=IDS[1])
      and commits() == [dict(node=IDS[1], mode='bypass_cn')] and CALLS.read_text() == 'reload\n')

invalid = [('mode', 'use'), ('mode', 'use', 'gfw', 'extra'), ('mode', 'use', '--mode', 'gfw'),
           ('node', 'use', IDS[1], '--mode'),
           ('node', 'use', IDS[1], '--mode', 'gfw', '--mode', 'global'),
           ('node', 'parse', 'trojan://pw@host:443', '--mode', 'gfw'),
           ('node', 'import', 'trojan://pw@host:443', '--mode', 'gfw'),
           ('node', 'use', IDS[2], '--mode', 'global')]
for mode in ('foo', 'GFW', '', '--json', 'global;reboot'):
    invalid.extend([('mode', 'use', mode), ('node', 'use', IDS[1], '--mode', mode)])
for args in invalid:
    reset()
    stamp = CONFIG.stat().st_mtime_ns
    reply = ap(*args, rc=2)
    check('invalid ' + repr(args) + ': USAGE without any configuration write',
          reply['ok'] is False and reply['code'] == 'USAGE' and CONFIG.read_bytes() == BASE
          and CONFIG.stat().st_mtime_ns == stamp and commits() == [] and CALLS.read_text() == '')

for args in [('mode', 'use', 'gfw'), ('node', 'use', IDS[1], '--mode', 'global')]:
    label = args[0] + ' use'
    for state in ('starting', 'running', 'degraded', 'failsafe', 'stopped', 'error', None):
        reset(state)
        if state is None:
            STATE.unlink()
        reply = ap(*args)
        running = state in ('starting', 'running', 'degraded', 'failsafe')
        want = expected(mode='gfw') if args[0] == 'mode' else expected(node=IDS[1], mode='global')
        check(f'{label} state {state}: committed selection and correct reload',
              reply['reload'] == running and CONFIG.read_bytes() == want
              and len(commits()) == 1 and CALLS.read_text() == ('reload\n' if running else ''))
    reset()
    STATE.write_text('{broken')
    reply = ap(*args, rc=1)
    check(label + ' corrupt state: FS_FAILED read before commit',
          reply['code'] == 'FS_FAILED' and reply['op'] == 'read'
          and CONFIG.read_bytes() == BASE and commits() == [] and CALLS.read_text() == '')
    reset()
    STATE.unlink()
    STATE.mkdir()
    reply = ap(*args, rc=1)
    check(label + ' unreadable state: FS_FAILED read before commit',
          reply['code'] == 'FS_FAILED' and reply['op'] == 'read'
          and CONFIG.read_bytes() == BASE and commits() == [] and CALLS.read_text() == '')
    STATE.rmdir()
    reset()
    reply = ap(*args, rc=1, env={'USE_COMMIT_FAIL': '1'})
    check(label + ' commit failure: FS_FAILED uci-commit and no reload',
          reply['code'] == 'FS_FAILED' and reply['op'] == 'uci-commit'
          and CONFIG.read_bytes() == BASE and len(commits()) == 1 and CALLS.read_text() == '')
    reset()
    reply = ap(*args, rc=1, env={'USE_INIT_RC': '7'})
    check(label + ' reload failure: CMD_FAILED with selection already committed',
          reply['code'] == 'CMD_FAILED' and 'exit 7' in reply['detail']
          and CONFIG.read_bytes() == want and len(commits()) == 1 and CALLS.read_text() == 'reload\n')

# Also exercise the actual lazy command entry, not just the instrumented function.
for args in [('mode', 'use', 'gfw'), ('node', 'use', IDS[1], '--mode', 'global')]:
    reset()
    reply = ap(*args, real=True)
    want = expected(mode='gfw') if args[0] == 'mode' else expected(node=IDS[1], mode='global')
    check(args[0] + ' actual CLI dispatch: correct reply, committed configuration and one reload',
          reply['ok'] is True and reply['reload'] is True
          and CONFIG.read_bytes() == want and CALLS.read_text() == 'reload\n')

reset()
check('legacy node use human same output unchanged',
      ap('node', 'use', IDS[0], human=True, real=True) == f'already using {IDS[0]}\n')
check('legacy node use human changed output unchanged',
      ap('node', 'use', IDS[1], human=True, real=True) == f'selected {IDS[1]}\n')
check('selection outcomes never append events', not (RUN / 'events.jsonl').exists())
