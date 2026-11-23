#!/usr/bin/env python3
"""Real quota CLI, real flock; private observer provides a first-result barrier.

No sleeps order the contenders. The observer only reports completed transactions
and pauses after the first result, before the CLI decides whether to retry.
"""
import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/prefix/bin/ucode'
OBSERVER = r'''
	let trace = fs.open(getenv('QUOTA_TRACE'), 'a');
	trace.write(sprintf('%J\n', { ok: result.ok, op: result.op, retryable: result.retryable }));
	trace.close();
	if (!quota_test_seen) {
		quota_test_seen = true;
		let ready = fs.open(getenv('QUOTA_READY'), 'w');
		ready.write('ready\n'); ready.close();
		let gate = fs.open(getenv('QUOTA_GATE'), 'r');
		gate.read('line'); gate.close();
	}
'''


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS ' + name)


def run_case(base, modules, action, scenario):
    case = base / (action[0] + '-' + scenario)
    file = case / 'etc/aether-proxy/usage.json'
    run = case / 'run'
    file.parent.mkdir(parents=True)
    run.mkdir()
    seed = {'schema': 1, 'days': {'2026-11-17':
            {'tx': 123, 'rx': 456, 'observed': 30, 'healthy': 20}},
            'updated_at': 17, 'future': {'keep': True},
            'quota': {'bytes': 50000000000, 'set_at': 1}}
    original = b'{broken JSON\x00\n' if scenario == 'parse' else json.dumps(seed).encode()
    file.write_bytes(original)
    sidecar = Path(str(file) + '.lock')
    held = None
    if scenario in ('short', 'busy', 'busy-parse'):
        held = sidecar.open('a')
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    elif scenario == 'lock-open':
        sidecar.mkdir()  # Not EAGAIN: must not be retried, even by root.
    elif scenario == 'read':
        file.unlink()
        file.mkdir()
    ready_r, ready_w = os.pipe()
    gate_r, gate_w = os.pipe()
    trace = case / 'attempts.jsonl'
    env = dict(os.environ, LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib')
               + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
               QUOTA_USAGE=str(file), QUOTA_BLOCK_WRITE='1' if scenario == 'write' else '0',
               QUOTA_TRACE=str(trace), QUOTA_READY=f'/proc/self/fd/{ready_w}',
               QUOTA_GATE=f'/proc/self/fd/{gate_r}')
    argv = [str(UCODE), '-L', str(modules.parent / '*.uc'),
            str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'stats', 'quota',
            *action, '--json', '--sys-root', str(case), '--run-dir', str(run)]
    proc = subprocess.Popen(argv, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            pass_fds=(ready_w, gate_r))
    os.close(ready_w)
    os.close(gate_r)
    try:
        assert select.select([ready_r], [], [], 5)[0], 'first transaction barrier timed out'
        assert os.read(ready_r, 100) == b'ready\n', 'CLI exited before first transaction'
        first = json.loads(trace.read_text())
        if held:
            check(f'{action[0]} {scenario}: first transaction is confirmed contention',
                  first == {'ok': False, 'op': 'lock', 'retryable': True})
            check(f'{action[0]} {scenario}: no premature error or write',
                  not (run / 'events.jsonl').exists() and file.read_bytes() == original)
        if scenario in ('short', 'busy-parse'):
            if scenario == 'busy-parse':
                original = b'{other writer left invalid JSON\n'
                file.write_bytes(original)
            fcntl.flock(held, fcntl.LOCK_UN)
        started = time.monotonic()
        os.write(gate_w, b'continue\n')
        stdout, stderr = proc.communicate(timeout=5)
        elapsed = time.monotonic() - started
        attempts = [json.loads(line) for line in trace.read_text().splitlines()]
        events_file = run / 'events.jsonl'
        events = [json.loads(line) for line in events_file.read_text().splitlines()] if events_file.exists() else []
        value = json.loads(stdout)
        check(f'{action[0]} {scenario}: one JSON reply and empty stderr', stderr == '')
        if scenario == 'short':
            expected = None if action[0] == 'clear' else 100000000000
            document = json.loads(file.read_text())
            check(f'{action[0]} short: original command succeeds on second transaction without FS_FAILED',
                  proc.returncode == 0 and value['ok'] is True and len(attempts) == 2
                  and events == [] and value['quota']['bytes'] == expected)
            check(f'{action[0]} short: preserves ledger and publishes 0600 quota',
                  all(document[k] == v for k, v in seed.items() if k != 'quota')
                  and document['quota'] == value['quota']
                  and file.stat().st_mode & 0o777 == 0o600)
        else:
            op = {'busy': 'lock', 'parse': 'parse', 'busy-parse': 'parse',
                  'lock-open': 'lock', 'read': 'read', 'write': 'write'}[scenario]
            count = 11 if scenario == 'busy' else 2 if scenario == 'busy-parse' else 1
            check(f'{action[0]} {scenario}: terminal FS_FAILED exactly once with actual op={op}',
                  proc.returncode == 1 and value['code'] == 'FS_FAILED'
                  and len(events) == 1 and events[0]['code'] == 'FS_FAILED'
                  and events[0]['level'] == 'error' and events[0]['args']['op'] == op
                  and events[0]['args']['path'] == str(file)
                  and events[0]['args']['detail'] == value['detail'])
            check(f'{action[0]} {scenario}: bounded attempts={count}, no ledger overwrite',
                  len(attempts) == count and elapsed < 3
                  and (file.is_dir() if scenario == 'read' else file.read_bytes() == original))
            if scenario == 'busy':
                check(f'{action[0]} busy: real bounded retry delay', 0.8 <= elapsed < 3)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()
        if held:
            held.close()
        os.close(ready_r)
        os.close(gate_w)


with tempfile.TemporaryDirectory(prefix='aether-quota-retry-') as directory:
    base = Path(directory)
    modules = base / 'modules/aetherproxy'
    shutil.copytree(ROOT / 'aether-proxy/src/lib', modules)
    usage = modules / 'usage.uc'
    source = usage.read_text()
    anchor = '\treturn { ...result, quota };'
    assert source.count(anchor) == 1
    source = source.replace(anchor, OBSERVER + anchor)
    source = source.replace("'use strict';", "'use strict';\nlet quota_test_seen = false;", 1)
    usage.write_text(source)
    # A residue directory at the exclusive temp path causes a real write failure,
    # including on root hosts, without mocking write_atomic's return value.
    sysfile = modules / 'sys.uc'
    source = sysfile.read_text()
    anchor = 'function write_atomic(path, content, metadata) {'
    assert source.count(anchor) == 1
    source = source.replace(anchor, anchor + r'''
    if (getenv('QUOTA_BLOCK_WRITE') == '1' && path == getenv('QUOTA_USAGE'))
        fs.mkdir(path + '.tmp.' + fs.readlink('/proc/self'));
''')
    sysfile.write_text(source)
    for action in [('set', '100G'), ('clear',)]:
        for scenario in ('short', 'busy', 'parse', 'busy-parse', 'lock-open', 'read', 'write'):
            run_case(base, modules, action, scenario)
print('quota retry: all scenarios passed')
