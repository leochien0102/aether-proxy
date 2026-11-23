#!/usr/bin/env python3
"""T16.50: deterministic, independent-process ledger writers (no timing sleeps).

--source selects a production source tree; --race-only also runs against the old
baseline (it must fail with an exact lost-update diff, not an absent flush API).
Only disposable module copies are instrumented: load pauses after the read,
write_atomic pauses after read/merge, and load can inject a read failure. Pipes carry
all scheduling decisions; select timeouts are deadlock guards, not scheduling.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NOW = 1795000000
DAY = '2026-11-17'
NEXT = '2026-11-18'
ENTRY = dict(tx=100, rx=20, observed=30, healthy=10)
INITIAL = dict(schema=1, days={DAY: ENTRY}, updated_at=123,
               quota=dict(bytes=50000000000, set_at=111), extension={'keep': True})

DRIVER = r'''
import * as fs from 'fs';
import * as usage from 'aetherproxy.usage';
import * as monitor from 'aetherproxy.monitor';
import * as sys from 'aetherproxy.sys';
let root = getenv('CASE_ROOT');
let path = root + '/etc/aether-proxy/usage.json';
let input = fs.open('/dev/stdin', 'r');
function emit(value) { printf('%J\n', value); fs.stdout.flush(); };
let state = json(getenv('USAGE_STATE'));
let daemon = { ctx: { root, run_dir: '/run' },
    snapshot: { stats: { heatmap_enabled: true } },
    usage: state, usage_days: json(getenv('PREVIOUS')), usage_warned: false };
function attempt() {
    let result;
    if (getenv('ROLE') == 'flush') {
        monitor.flush_usage(daemon, getenv('CROSS') == '1' ? '2026-11-17' : null);
        result = { watermark: daemon.usage_days, pending: daemon.usage.days };
    }
    else if (getenv('ROLE') == 'write')
        result = usage.write(path, state.days, 1795000000);
    else
        result = usage.set_quota(path, getenv('ACTION') == 'set' ? 200000000000 : null, 1795000000);
    emit({ event: 'result', result });
};
if (getenv('ROLE') == 'holder') {
    let held = sys.lock(path + '.lock');
    if (held == null) die('cannot hold test lock');
    emit({ event: 'held' }); input.read('line'); held.close();
}
else {
    attempt();
    while (input.read('line') == 'retry\n') attempt();
}
'''


class Worker:
    def __init__(self, suite, case, role, state, **extra):
        env = dict(os.environ, LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib'),
                   CASE_ROOT=str(case), ROLE=role, USAGE_STATE=json.dumps(state),
                   PREVIOUS=json.dumps(INITIAL['days']), TZ='UTC', **extra)
        self.process = subprocess.Popen(suite.command, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        suite.workers.append(self)

    def event(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(10):
                raise AssertionError('writer did not answer within bounded 10s guard')
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError('writer exited: ' + self.process.stderr.read())
        return json.loads(line)

    def send(self, command='continue'):
        self.process.stdin.write(command + '\n')
        self.process.stdin.flush()

    def finish(self):
        self.send('done')
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.stderr.read()


class Suite:
    def __init__(self, base, source):
        self.base = base
        self.workers = []
        modules = base / 'aetherproxy'
        shutil.copytree(source / 'aether-proxy/src/lib', modules)
        sysfile = modules / 'sys.uc'
        source_text = sysfile.read_text()
        needle = 'function write_atomic(path, content, metadata) {'
        assert source_text.count(needle) == 1
        sysfile.write_text(source_text.replace(needle, needle + r'''
    if (path == getenv('CASE_ROOT') + '/etc/aether-proxy/usage.json') {
        if (getenv('PAUSE_WRITE') == '1') {
            printf('%J\n', { event: 'before-write' }); fs.stdout.flush();
            let gate = fs.open('/dev/stdin', 'r'); gate.read('line');
        }
        if (fs.stat(getenv('CASE_ROOT') + '/fail-write') != null) {
            // Exercise the real exclusive-open failure, leaving old bytes intact.
            fs.mkdir(`${path}.tmp.${fs.readlink('/proc/self')}`);
        }
    }
'''))
        usage = modules / 'usage.uc'
        needle = 'export function load(path) {'
        source_text = usage.read_text()
        assert source_text.count(needle) == 1
        source_text = source_text.replace(needle, 'function load_real(path) {')
        usage.write_text(source_text.replace('function load_real(path) {', 'function load_real(path) {' + r'''
    if (fs.stat(getenv('CASE_ROOT') + '/fail-read') != null)
        return { days: {}, error: 'T16.50 injected read failure', op: 'read', updated_at: null };
''').replace('// collect(state, previous)', r'''
export function load(path) {
    let loaded = load_real(path);
    if (getenv('PAUSE_READ') == '1') {
        printf('%J\n', { event: 'after-read' }); fs.stdout.flush();
        let gate = fs.open('/dev/stdin', 'r'); gate.read('line');
    }
    return loaded;
};
// collect(state, previous)'''))
        monitor = modules / 'monitor.uc'
        # Deterministic timestamp only, not a replacement persistence implementation.
        monitor.write_text(monitor.read_text().replace('time()', str(NOW)))
        script = base / 'driver.uc'
        script.write_text(DRIVER)
        self.command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(base / '*.uc'), str(script)]

    def case(self, name, cross):
        case = self.base / name
        ledger = case / 'etc/aether-proxy/usage.json'
        ledger.parent.mkdir(parents=True)
        ledger.write_text(json.dumps(INITIAL) + '\n')
        (case / 'run').mkdir()
        state = dict(day=NEXT if cross else DAY, tx=150, rx=40, observed=45,
                     healthy=20, days={DAY: dict(tx=130, rx=15, observed=35, healthy=8)} if cross else {})
        expected = copy.deepcopy(INITIAL)
        expected['days'] = {DAY: dict(tx=130, rx=20, observed=35, healthy=10),
                            NEXT: dict(tx=150, rx=40, observed=45, healthy=20)} if cross else {
                                DAY: dict(tx=150, rx=40, observed=45, healthy=20)}
        expected['updated_at'] = NOW
        return case, ledger, state, expected

    def close(self):
        for worker in self.workers:
            if worker.process.poll() is None:
                worker.process.kill()
            worker.process.wait()
            for stream in (worker.process.stdin, worker.process.stdout, worker.process.stderr):
                stream.close()

    def race(self, action, first, cross, point):
        name = f'{point}-{action}-{first}-{"cross" if cross else "same"}'
        case, ledger, state, expected = self.case(name, cross)
        expected['quota'] = dict(bytes=200000000000 if action == 'set' else None,
                                 set_at=NOW if action == 'set' else None)
        roles = [first, 'quota' if first == 'flush' else 'flush']
        pause = {'PAUSE_READ' if point == 'after-read' else 'PAUSE_WRITE': '1'}
        one = Worker(self, case, roles[0], state, ACTION=action, CROSS=str(int(cross)), **pause)
        ready = one.event()
        assert ready['event'] == point, ready
        # After-read proves that the lock starts before loading; before-write
        # proves it extends through replacement. Neither permits a stale read.
        # The independent second process must return BUSY at both boundaries.
        two = Worker(self, case, roles[1], state, ACTION=action, CROSS=str(int(cross)))
        second = two.event()['result']
        blocked = second.get('ok') is False if roles[1] == 'quota' else second['watermark'] == INITIAL['days']
        if blocked:
            assert ledger.read_text() == json.dumps(INITIAL) + '\n'
        one.send()
        one.event()
        # The paused writer has only one attempt; finish its command loop now.
        one.finish()
        if blocked:
            two.send('retry')
            retry = two.event()['result']
            if roles[1] == 'quota':
                assert retry['ok'] is True, retry
            else:
                assert retry['watermark'] == expected['days'], retry
        two.finish()
        actual = json.loads(ledger.read_text())
        assert actual == expected, f'{name}: LOST UPDATE\nexpected={expected}\nactual={actual}'
        assert blocked, f'{name}: second writer falsely succeeded while lock was held'
        assert ledger.stat().st_mode & 0o777 == 0o600
        print(f'PASS T16.50 {name}: busy -> retry; exact JSON {json.dumps(actual, sort_keys=True)}')

    def failure(self, fault, role, cross):
        name = f'{fault}-{role}-{"cross" if cross else "same"}'
        case, ledger, state, expected = self.case(name, cross)
        valid_original = ledger.read_bytes()
        if fault == 'corrupt':
            ledger.write_bytes(valid_original[:-3])
        original = ledger.read_bytes()
        holder = None
        if fault == 'busy':
            holder = Worker(self, case, 'holder', state)
            assert holder.event()['event'] == 'held'
        elif fault != 'corrupt':
            (case / f'fail-{fault}').touch()
        worker = Worker(self, case, role, state, ACTION='set', CROSS=str(int(cross)))
        failed = worker.event()['result']
        assert ledger.read_bytes() == original, f'{name}: old bytes changed'
        if role == 'flush':
            assert failed['watermark'] == INITIAL['days'], f'{name}: watermark advanced'
            assert failed['pending'] == state['days'], f'{name}: pending completed day changed'
        else:
            assert failed['ok'] is False and failed['error'], failed
        if holder:
            holder.send()
            holder.process.wait(timeout=10)
            assert holder.process.returncode == 0
        elif fault == 'corrupt':
            ledger.write_bytes(valid_original)
        else:
            (case / f'fail-{fault}').unlink()
            if fault == 'write':
                Path(f'{ledger}.tmp.{worker.process.pid}').rmdir()
        worker.send('retry')
        retried = worker.event()['result']
        if role == 'quota':
            expected = copy.deepcopy(INITIAL)
            expected['quota'] = dict(bytes=200000000000, set_at=NOW)
            assert retried['ok'] is True, retried
        elif role == 'write':
            expected = copy.deepcopy(INITIAL)
            expected.update(days=state['days'], updated_at=NOW)
            assert retried['ok'] is True, retried
        else:
            assert retried['watermark'] == expected['days'], retried
        assert json.loads(ledger.read_text()) == expected, name
        worker.finish()
        retained = 'old bytes/watermark/pending' if role == 'flush' else 'old bytes/error'
        print(f'PASS T16.50 {name}: {retained} retained; exact retry JSON')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT)
    parser.add_argument('--race-only', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='.usage-lock-', dir=ROOT / 'tests/monitor') as temp:
        suite = Suite(Path(temp), args.source.resolve())
        try:
            for point in ('after-read', 'before-write'):
                for action in ('set', 'clear'):
                    for first in ('quota', 'flush'):
                        for cross in (False, True):
                            suite.race(action, first, cross, point)
            if not args.race_only:
                for fault in ('busy', 'write', 'read', 'corrupt'):
                    for role in ('flush', 'quota', 'write'):
                        for cross in (False, True) if role == 'flush' else (False,):
                            suite.failure(fault, role, cross)
        finally:
            suite.close()
    print(f'PASS T16.50 deterministic usage lock suite: {16 if args.race_only else 32} cases')


if __name__ == '__main__':
    main()
