#!/usr/bin/env python3
"""T10.70: real UCI transactions, with filesystem faults only in a private module copy."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT, T = map(Path, sys.argv[1:3])
CONF, RUN = T / 'etc/config', T / 'var/run/aether-proxy'
for directory in (CONF, RUN):
    directory.mkdir(parents=True, exist_ok=True)
CONFIG = CONF / 'aetherproxy'
BACKUP = T / 'etc/aether-proxy/config.backup'
IDS = ['n_' + str(i) * 32 for i in (1, 2)]
BASE = f"config main 'main'\n option enabled '0'\n option node '{IDS[0]}'\n option mode 'gfw'\n"
for node in IDS:
    BASE += f"config node '{node}'\n option protocol 'vmess'\n option address 'edge.example'\n option port '443'\n option uuid 'id'\n"
MODULES = T / 'modules'
shutil.copytree(ROOT / 'aether-proxy/src/lib', MODULES / 'aetherproxy', dirs_exist_ok=True)
SYS = MODULES / 'aetherproxy/sys.uc'
source = SYS.read_text().replace("import * as fs from 'fs';", """
import * as real_fs from 'fs';
let injected = false;
let backup_writes = 0;
let fault = getenv('ATOMIC_FAULT');
let target = getenv('ATOMIC_TARGET');
const fs = { ...real_fs,
 open: (path, mode, ...args) => {
  let selected = index(path, target + '.tmp.') == 0;
  if (selected && fault == 'open') return null;
  if (index(path, 'config.backup.tmp.') >= 0) {
   backup_writes++;
   if (fault == 'backup' || (fault == 'backup_final' && backup_writes == 2)) return null;
  }
  let fp = real_fs.open(path, mode, ...args);
  if (!fp || !selected) return fp;
  return {
   write: (text) => index(['write', 'unlink'], fault) >= 0
    ? null : fp.write(fault == 'short' ? substr(text, 0, 3) : text),
   close: () => { let ok = fp.close(); return fault == 'close' ? null : ok; }
  };
 },
 unlink: (path) => fault == 'unlink' && index(path, target + '.tmp.') == 0
  ? null : real_fs.unlink(path),
 chmod: (path, mode) => fault == 'metadata' && index(path, target + '.tmp.') == 0
  ? null : real_fs.chmod(path, mode),
 rename: (a, b) => {
  if (index(b, '/aetherproxy_sub') >= 0 && fault == 'killstage') exit(99);
  if (index(b, '/aetherproxy_sub') >= 0 && fault == 'pause') {
   let f = real_fs.open(target + '.paused', 'w'); f.close();
   while (!real_fs.access(target + '.release')) sleep(10);
  }
  if (b == target && fault == 'rename') return null;
  if (b == target && fault == 'kill') exit(99);
  if (b == target && fault == 'restore' && injected) return null;
  let ok = real_fs.rename(a, b);
  if (ok && b == target && index(['readback', 'restore'], fault) >= 0 && !injected) {
   injected = true;
   let f = real_fs.open(b, 'w'); f.write('corrupted readback'); f.close();
  }
  return ok;
 }
};
""")
SYS.write_text(source)
PREFIX = ROOT / 'tests/host/prefix'
ENV = {**os.environ, 'LD_LIBRARY_PATH': str(PREFIX / 'lib'), 'ATOMIC_TARGET': str(CONFIG)}


failures = []


def check(name, ok):
    if not ok:
        failures.append(name)
    print(('PASS' if ok else 'FAIL') + '  T10.70 ' + name)


def reset():
    CONFIG.write_text(BASE)
    CONFIG.chmod(0o640)
    if BACKUP.exists():
        BACKUP.unlink()


def argv(command=None):
    return [str(PREFIX / 'bin/ucode'), '-L', str(MODULES / '*.uc'),
            str(ROOT / 'aether-proxy/src/aether-proxy'), '--',
            *(command or ['node', 'use', IDS[1]]), '--json',
            '--confdir', str(CONF), '--sys-root', str(T)]


def call(fault='', command=None):
    result = subprocess.run(argv(command), capture_output=True, text=True,
                            env={**ENV, 'ATOMIC_FAULT': fault})
    return result, json.loads(result.stdout) if result.stdout else {}


reset()
p, reply = call()
check('success reports committed only after readback', p.returncode == 0 and reply.get('committed') is True)
check('success updates backup and preserves mode/owner', BACKUP.exists() and BACKUP.read_bytes() == CONFIG.read_bytes()
      and BACKUP.stat().st_mode & 0o777 == 0o600 and CONFIG.stat().st_mode & 0o777 == 0o640
      and CONFIG.stat().st_uid == os.getuid() and CONFIG.stat().st_gid == os.getgid())
for fault in ('open', 'write', 'short', 'close', 'rename', 'metadata', 'unlink', 'readback', 'backup', 'backup_final'):
    reset()
    p, reply = call(fault)
    check(f'{fault} failure preserves original bytes', p.returncode == 1 and reply.get('code') == 'FS_FAILED'
          and reply.get('committed') is False and CONFIG.read_text() == BASE
          and CONFIG.stat().st_mode & 0o777 == 0o640)
    if fault == 'unlink':
        check('cleanup failure remains visible in detail', 'unlink' in reply.get('detail', ''))
reset()
p, reply = call('restore')
check('failed restoration never claims uncommitted', p.returncode == 1 and 'committed' in reply
      and reply['committed'] is None and reply.get('code') == 'FS_FAILED'
      and 'restore' in reply.get('detail', '') and BACKUP.read_text() == BASE)
reset()
p, reply = call('kill')
check('killed before rename leaves original bytes', p.returncode == 99 and CONFIG.read_text() == BASE)
reset()
p, reply = call(command=['mode', 'use', 'global'])
check('mode success uses same backup transaction', p.returncode == 0 and reply.get('committed') is True
      and BACKUP.exists() and BACKUP.read_bytes() == CONFIG.read_bytes() and reply.get('previous_mode') == 'gfw')
# Pause a real node writer while it owns config; other writers must not wait.
reset()
paused, release = Path(str(CONFIG) + '.paused'), Path(str(CONFIG) + '.release')
writer = subprocess.Popen(argv(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          env={**ENV, 'ATOMIC_FAULT': 'pause'})
try:
    deadline = time.monotonic() + 5
    while not paused.exists() and writer.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    check('node writer reaches stage while holding config', paused.exists())
    for command in (['mode', 'use', 'global'], ['sub', 'update'],
                    ['node', 'import', 'vmess://eyJhZGQiOiJlZGdlLmV4YW1wbGUiLCJwb3J0Ijo0NDMsImlkIjoiaWQifQ==']):
        p, reply = call(command=command)
        check(command[0] + ' contends with node without blocking', p.returncode == 3
              and reply.get('code') == 'BUSY' and CONFIG.read_text() == BASE)
    external = BASE + '\n# external edit\n'
    CONFIG.write_text(external)
    release.touch()
    stdout, stderr = writer.communicate(timeout=5)
    reply = json.loads(stdout)
    check('external CAS modification is never overwritten', writer.returncode == 1 and not stderr
          and reply.get('committed') is False and CONFIG.read_text() == external)
    script = """import * as uci from 'uci'; import * as config from 'aetherproxy.config';
let c = uci.cursor(ARGV[0]); c.load(ARGV[0] + '/aetherproxy'); print(config.load(c).ok);
"""
    p = subprocess.run([str(ROOT / 'tests/host/ucode'), '-e', script, '--', str(CONF)],
                       capture_output=True, text=True)
    check('concurrent writers leave a normalizable complete package', p.returncode == 0 and p.stdout == 'true')
finally:
    release.touch()
    if writer.poll() is None:
        writer.kill()
        writer.communicate()
    paused.unlink(missing_ok=True)
    release.unlink(missing_ok=True)

# Real stale libuci deltas in the private savedirs must never leak into a stage
# or its normalized snapshot. Absolute loads disable delta replay even there.
reset()
for directory, package in ((RUN / 'sub-work', 'aetherproxy_sub'),
                           (RUN / 'sub-work/snapshot', 'aetherproxy_sub_snapshot')):
    delta = directory / '.delta'
    delta.mkdir(parents=True, exist_ok=True)
    (directory / package).write_text(BASE)
    script = """import * as uci from 'uci';
let c = uci.cursor(ARGV[0], ARGV[1]);
if (!c.set(ARGV[2], 'main', 'mode', 'global') || !c.save(ARGV[2])) exit(1);
"""
    subprocess.run([str(ROOT / 'tests/host/ucode'), '-e', script, '--',
                    str(directory), str(delta), package], check=True)
p, reply = call()
check('stage ignores real stale synthetic-package deltas', p.returncode == 0
      and "option mode 'gfw'" in CONFIG.read_text())
VALIDATE = T / 'validate.uc'
VALIDATE.write_text("""import * as sub from 'aetherproxy.sub'; import * as fs from 'fs';
let opts = sub.absolute_options({ sys_root: ARGV[0] });
print(sprintf('%J', sub.load_committed_config({root:ARGV[0], opts}, fs.readfile(ARGV[1]))));
""")
p = subprocess.run([str(PREFIX / 'bin/ucode'), '-L', str(MODULES / '*.uc'), str(VALIDATE),
                    '--', str(T), str(CONFIG)], capture_output=True, text=True, env=ENV)
check('normalization ignores real stale snapshot-package deltas', p.returncode == 0
      and json.loads(p.stdout)['snapshot']['main']['mode'] == 'gfw')

# The startup helper is the same boundary invoked by daemon.start_sequence.
PREPARE = T / 'prepare.uc'
PREPARE.write_text("""'use strict';
import * as sub from 'aetherproxy.sub';
import * as log from 'aetherproxy.log';
let opts = sub.absolute_options({ sys_root: ARGV[0] });
log.set_run_dir(opts.run_dir);
print(sprintf('%J', sub.prepare_config({ root: ARGV[0], opts })));
""")


def prepare(fault=''):
    p = subprocess.run([str(PREFIX / 'bin/ucode'), '-L', str(MODULES / '*.uc'),
                        str(PREPARE), '--', str(T)], capture_output=True, text=True,
                       env={**ENV, 'ATOMIC_FAULT': fault})
    assert p.returncode == 0 and not p.stderr, (p.stdout, p.stderr)
    return json.loads(p.stdout)


for fault in ('killstage', 'kill'):
    reset()
    p, reply = call(fault)
    check(fault + ' leaves original intact', p.returncode == 99 and CONFIG.read_text() == BASE)
    residue = Path(str(CONFIG) + '.tmp.killed')
    residue.write_text('partial')
    other_package = CONF / 'unrelated.tmp.keep'
    other_package.write_text('not ours')
    check('startup cleans killed-writer temporaries', prepare()['ok'] and not residue.exists()
          and other_package.read_text() == 'not ours'
          and not list((RUN / 'sub-work').rglob('*.tmp.*')) and CONFIG.read_text() == BASE)
reset()
BACKUP.parent.mkdir(parents=True, exist_ok=True)
BACKUP.write_text(BASE)
CONFIG.write_text('config invalid syntax !!\n')
check('startup recovery failure does not report success', not prepare('rename')['ok']
      and CONFIG.read_text() == 'config invalid syntax !!\n')
check('startup restores valid backup atomically', prepare()['ok'] and CONFIG.read_text() == BASE)
events = RUN / 'events.jsonl'
recovered = [json.loads(line) for line in events.read_text().splitlines()
             if json.loads(line)['code'] == 'CONFIG_RECOVERED']
check('recovery emits WARN CONFIG_RECOVERED with path once', len(recovered) == 1
      and recovered[0]['level'] == 'warn' and recovered[0]['args'] == {'path': str(CONFIG)})
prepare()
repeated = [line for line in events.read_text().splitlines() if 'CONFIG_RECOVERED' in line]
check('subsequent startup never repeats recovery event', len(repeated) == 1)
CONFIG.write_text('config invalid syntax !!\n')
BACKUP.write_text('config invalid backup !!\n')
invalid = prepare()
check('invalid backup preserves original configuration error', not invalid['ok']
      and invalid['code'] == 'CONFIG_INVALID' and invalid['errors'][0]['code'] == 'uci'
      and CONFIG.read_text() == 'config invalid syntax !!\n')
reset()
p, reply = call(command=['node', 'import', 'vmess://eyJhZGQiOiJvdGhlci5leGFtcGxlIiwicG9ydCI6NDQzLCJpZCI6ImlkIn0='])
check('import success updates validated backup', p.returncode == 0 and reply.get('node') is not None
      and BACKUP.read_bytes() == CONFIG.read_bytes())
sys.exit(bool(failures))
