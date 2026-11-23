#!/usr/bin/env python3
"""Real-daemon usage lifecycle regressions, with pipe-ordered competing quota writers.

--source selects a production tree (entry point and modules), not test helpers.
Only private module copies are instrumented: sampling inputs and write/lock
observations. No test calls monitor.flush_usage/pause_usage/stop_usage or retries
usage.flush. Quota writers call the real usage.set_quota in separate processes;
the write barrier is after read/merge, while the real sidecar flock is held.
"""
from datetime import datetime, timezone
import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument('--source', type=Path, default=ROOT)
PARSER.add_argument('--case', choices=['term', 'recovery', 'recovery-failure', 'reload', 'reload-short',
                                       'reload-stop', 'reload-stop-failure', 'parse-failure',
                                       'lock-error', 'cross-day', 'clean'])
ARGS = PARSER.parse_args()
SOURCE = ARGS.source.resolve()
UCODE = ROOT / 'tests/host/prefix/bin/ucode'
DAY = '2026-11-18'
NEXT = '2026-11-19'
EPOCH = int(datetime(2026, 11, 18, 12, tzinfo=timezone.utc).timestamp())
QUOTA = {'bytes': 123000000000, 'set_at': 177}
ON = "\nconfig stats 'stats'\n\toption heatmap_enabled '1'\n"


def check(name, condition, detail=''):
    if not condition:
        raise AssertionError(name + (': ' + str(detail) if detail else ''))
    print('PASS usage-lifecycle: ' + name, flush=True)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise AssertionError('private instrumentation anchor changed: ' + old)
    return text.replace(old, new, 1)


def wait_for(predicate, child=None, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        if child is not None and child.poll() is not None:
            raise AssertionError(f'daemon exited early: {child.returncode}')
        # Predicate polling, not a delay used to establish ordering.
        select.select([], [], [], .02)
    raise AssertionError('bounded predicate wait timed out')


class Pipe:
    def __init__(self, path):
        self.path = path
        os.mkfifo(path)
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.buffer = b''
        self.history = []

    def send(self, value):
        os.write(self.fd, (json.dumps(value) + '\n').encode())

    def receive(self, predicate=lambda value: True, timeout=12):
        deadline = time.monotonic() + timeout
        while True:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                value = json.loads(line)
                self.history.append(value)
                if predicate(value):
                    return value
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise AssertionError(f'bounded FIFO wait timed out: {self.path}; events={self.history}')
            self.buffer += os.read(self.fd, 65536)

    def close(self):
        os.close(self.fd)


# Private sys hook observes writes and lock acquisition failures. It does not
# alter flock semantics, atomic write return values, or daemon retry decisions.
SYS_HOOK = r'''
function lifecycle_event(value) {
    let f = fs.open(getenv('LIFECYCLE_EVENTS'), 'w');
    f.write(sprintf('%J\n', value)); f.close();
}
'''
WRITE_HOOK = r'''
    if (path == getenv('LIFECYCLE_USAGE')) {
        lifecycle_event({ kind: 'write', role: getenv('LIFECYCLE_ROLE'), document: json(content) });
        if (getenv('LIFECYCLE_ROLE') == 'quota') {
            let gate = fs.open(getenv('LIFECYCLE_RELEASE'), 'r');
            gate.read('line'); gate.close();
        }
    }
'''
SAMPLE_HOOK = r'''
    if (daemon.snapshot?.stats?.heatmap_enabled === true) {
        let input = fs.open(getenv('LIFECYCLE_INPUT'), 'r');
        lifecycle_sample = json(input.read('line')); input.close();
    }
'''


class Fixture:
    def __init__(self, base, name):
        self.root = base / name
        self.run = self.root / 'var/run/aether-proxy'
        self.usage = self.root / 'etc/aether-proxy/usage.json'
        self.pending = self.run / 'usage-pending.json'
        self.conf = self.root / 'etc/config'
        for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
                          'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
                          'var/run/aether-proxy', 'etc/config'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.config = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
        self.set_enabled(True)
        (self.root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
        dns = self.root / 'etc/init.d/dnsmasq'
        dns.write_text('#!/bin/sh\nexit 0\n')
        dns.chmod(0o755)
        subprocess.run(['python3', str(ROOT / 'tests/xray-ready/proc_fixture.py'), str(self.root)], check=True)
        (self.root / 'proc/net/tcp').write_text('  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
        for name in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count'):
            (self.root / name).touch()
        self.usage.write_text(json.dumps({'schema': 1, 'days': {}, 'quota': {'bytes': 100000000000, 'set_at': 1}}))
        self.input = Pipe(self.root / 'sample.fifo')
        self.events = Pipe(self.root / 'events.fifo')
        self.release = Pipe(self.root / 'release.fifo')
        self.modules = self.root / 'modules/aetherproxy'
        shutil.copytree(SOURCE / 'aether-proxy/src/lib', self.modules)
        sysfile = self.modules / 'sys.uc'
        text = replace_once(sysfile.read_text(), 'function write_atomic(path, content, metadata) {',
                            SYS_HOOK + '\nfunction write_atomic(path, content, metadata) {')
        text = replace_once(text, 'function write_atomic(path, content, metadata) {',
                            'function write_atomic(path, content, metadata) {' + WRITE_HOOK)
        text = replace_once(text, "if (!fp.lock('xn')) {", "if (!fp.lock('xn')) {\n"
                            "        if (path == getenv('LIFECYCLE_USAGE') + '.lock')\n"
                            "            lifecycle_event({ kind: 'lock-failed', role: getenv('LIFECYCLE_ROLE') });")
        sysfile.write_text(text)
        usage = self.modules / 'usage.uc'
        text = replace_once(usage.read_text(), 'export function flush(path, state, previous, now) {',
                            '''export function flush(path, state, previous, now) {
    let observation = fs.open(getenv('LIFECYCLE_FLUSHES'), 'a');
    observation.write('flush\\n'); observation.close();''')
        usage.write_text(text)
        monitor = self.modules / 'monitor.uc'
        text = monitor.read_text()
        # Replace only usage's clock sources; real shutdown retry deadlines remain real.
        start = text.index('function sample_usage(daemon, obs) {')
        end = text.index('\ntick = function', start)
        section = text[start:end]
        section = replace_once(section, 'function sample_usage(daemon, obs) {',
                               'function sample_usage(daemon, obs) {' + SAMPLE_HOOK)
        section = section.replace('time()', 'lifecycle_sample.now')
        section = replace_once(section, 'let now_ms = monotonic_ms();', 'let now_ms = lifecycle_sample.mono;')
        section = replace_once(section, 'counters.proxy_counters(daemon.ctx)',
                               '{ tx_bytes: lifecycle_sample.tx, rx_bytes: lifecycle_sample.rx }')
        closing = section.rindex('};')
        section = section[:closing] + "    lifecycle_observe(daemon);\n" + section[closing:]
        text = text[:start] + section + text[end:]
        observe_hook = r'''
function lifecycle_observe(daemon) {
    let f = fs.open(getenv('LIFECYCLE_EVENTS'), 'w');
    f.write(sprintf('%J\n', { kind: 'sample', usage: daemon.usage, pending: daemon.usage_pending }));
    f.close();
}
'''
        text = replace_once(text, 'function sample_usage(daemon, obs) {',
                            observe_hook + '\nfunction sample_usage(daemon, obs) {')
        # The initial machine and published live date must agree with controlled sampling.
        text = text.replace('time()', 'lifecycle_sample.now')
        text = replace_once(text, "'use strict';", "'use strict';\nlet lifecycle_sample = { now: " + str(EPOCH) + ", mono: 0, tx: 0, rx: 0 };\n")
        monitor.write_text(text)
        self.env = dict(os.environ, TZ='UTC', SYSROOT=str(self.root),
                        STUB_LOG=str(self.root / 'stub.log'),
                        STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
                        LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
                        PATH=str(base / 'bin') + ':' + os.environ['PATH'],
                        AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
                        LIFECYCLE_USAGE=str(self.usage), LIFECYCLE_EVENTS=str(self.events.path),
                        LIFECYCLE_INPUT=str(self.input.path), LIFECYCLE_RELEASE=str(self.release.path),
                        LIFECYCLE_ROLE='daemon', LIFECYCLE_FLUSHES=str(self.root / 'flushes'))
        self.command = [str(UCODE), '-L', str(self.root / 'modules/*.uc'), '-S',
                        str(SOURCE / 'aether-proxy/src/aether-proxy'), '--', 'daemon',
                        '--sys-root', str(self.root), '--bin-dir', str(base / 'bin'),
                        '--confdir', str(self.conf), '--data-dir', str(base / 'data'),
                        '--baseline-dir', str(base / 'base'), '--custom-dir', str(base / 'custom')]
        self.children = []
        self.logs = []
        self.mono = 0
        self.now = EPOCH

    def set_enabled(self, enabled, main_enabled=True):
        config = self.config if main_enabled else replace_once(
            self.config, "option enabled '1'", "option enabled '0'")
        (self.conf / 'aetherproxy').write_text(config + (ON if enabled else ''))

    def flush_count(self):
        path = self.root / 'flushes'
        return len(path.read_text().splitlines()) if path.exists() else 0

    def request_stop(self, child, hup=False):
        if hup:
            self.set_enabled(False, main_enabled=False)
        child.send_signal(signal.SIGHUP if hup else signal.SIGTERM)

    def state(self):
        path = self.run / 'state.json'
        return json.loads(path.read_text()) if path.is_file() else {}

    def document(self):
        return json.loads(self.usage.read_text())

    def event(self, kind):
        return self.events.receive(lambda event: event['kind'] == kind)

    def queue(self, tx=0, rx=0, next_day=False):
        if next_day:
            self.now = EPOCH + 86400
        self.mono += 1000
        self.input.send(dict(now=self.now, mono=self.mono, tx=tx, rx=rx))

    def start(self):
        self.queue()
        for stream in ('stdout', 'stderr'):
            self.logs.append((self.root / stream).open('a'))
        child = subprocess.Popen(self.command, env=self.env, stdout=self.logs[-2], stderr=self.logs[-1], start_new_session=True)
        self.children.append(child)
        self.event('sample')
        wait_for(lambda: self.state().get('state') == 'running', child)
        return child

    def sample(self, child, tx=0, rx=0, next_day=False):
        self.queue(tx, rx, next_day)
        child.send_signal(signal.SIGUSR1)
        value = self.event('sample')
        # Complete publication, so a subsequent signal cannot coalesce with this tick.
        expected = value['usage']
        wait_for(lambda: self.state().get('usage_today', {}).get('tx') == expected['tx']
                 and self.state().get('usage_today', {}).get('date') == expected['day'], child)
        return value

    def writer(self):
        script = self.root / 'quota.uc'
        script.write_text("import * as usage from 'aetherproxy.usage';\n"
                          "let result = usage.set_quota(ARGV[0], 123000000000, 177);\n"
                          "print(sprintf('%J\\n', result)); exit(result.ok ? 0 : 1);\n")
        child = subprocess.Popen([str(UCODE), '-L', str(self.root / 'modules/*.uc'), str(script), str(self.usage)],
                                 env=dict(self.env, LIFECYCLE_ROLE='quota'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(child)
        value = self.events.receive(lambda event: event['kind'] == 'write' and event['role'] == 'quota')
        check('quota writer paused after real read/merge, before atomic replacement', value['document']['quota'] == QUOTA)
        with Path(str(self.usage) + '.lock').open('a') as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                held = True
            else:
                held = False
                fcntl.flock(probe, fcntl.LOCK_UN)
        check('independent quota process really holds usage.json.lock', held)
        return child

    def unlock(self, writer):
        self.release.send('release')
        out, err = writer.communicate(timeout=5)
        check('independent quota writer committed and released sidecar', writer.returncode == 0, (out, err))

    def stop(self, child):
        child.terminate()
        child.wait(timeout=8)
        check('real TERM exits cleanly', child.returncode == 0 and self.state().get('state') == 'stopped')

    def assert_days(self, days):
        document = self.document()
        check('quota bytes and set_at preserved exactly', document['quota'] == QUOTA, document)
        check('current/completed day counters preserved exactly', document['days'] == days, document)

    def close(self):
        for child in self.children:
            if child.poll() is None:
                # Avoid a cleanup deadlock if an assertion failed at a sampling barrier.
                self.queue()
                self.release.send('cleanup')
                if child.args == self.command:
                    os.killpg(child.pid, signal.SIGKILL)
                else:
                    child.kill()
                child.wait()
        for pipe in (self.input, self.events, self.release):
            pipe.close()
        for fp in self.logs:
            fp.close()


def totals(tx, rx, observed):
    return dict(tx=tx, rx=rx, observed=observed, healthy=observed)


def term(f):
    child = f.start()
    f.sample(child, 150, 40)
    writer = f.writer()
    child.terminate()
    f.event('lock-failed')
    f.unlock(writer)
    child.wait(timeout=8)
    check('TERM retries automatically after quota releases lock', child.returncode == 0)
    f.assert_days({DAY: totals(150, 40, 1)})
    check('successful TERM leaves no recovery file', not f.pending.exists())


def recovery(f, hup=False):
    child = f.start()
    f.sample(child, 150, 40)
    writer = f.writer()
    f.sample(child, 200, 60, next_day=True)
    f.sample(child, 207, 63)
    started = time.monotonic()
    f.request_stop(child, hup)
    child.wait(timeout=8)
    check('HUP main+heatmap disable exits cleanly' if hup else 'real TERM exits cleanly',
          child.returncode == 0 and f.state().get('state') == 'stopped', f.state())
    check('quota writer remains locked through daemon exit', writer.poll() is None)
    elapsed = time.monotonic() - started
    check('persistent contention stop is bounded (2s budget plus teardown)', elapsed < 7, elapsed)
    check('contended stop atomically preserves pending state', f.pending.is_file())
    pending = json.loads(f.pending.read_text())
    check('pending contains exact completed day and current day (no quota snapshot)',
          pending.get('schema') == 1 and pending.get('days') == {
              DAY: totals(200, 60, 2), NEXT: totals(7, 3, 1)}
          and 'quota' not in pending, pending)
    check('pending has private mode 0600', f.pending.stat().st_mode & 0o777 == 0o600)
    stopped = [json.loads(line) for line in (f.run / 'events.jsonl').read_text().splitlines()
               if json.loads(line).get('code') == 'SERVICE_STOPPED']
    check('stop event exposes pending recovery path',
          stopped[-1]['args'].get('usage_pending') == str(f.pending), stopped)
    check('no atomic pending residue', not list(f.run.glob('usage-pending.json.tmp.*')))
    f.unlock(writer)
    f.set_enabled(True)
    child = f.start()
    wait_for(lambda: f.document()['days'].get(DAY) == totals(200, 60, 2), child)
    f.assert_days({DAY: totals(200, 60, 2), NEXT: totals(7, 3, 1)})
    wait_for(lambda: not f.pending.exists(), child)
    f.stop(child)
    f.assert_days({DAY: totals(200, 60, 2), NEXT: totals(7, 3, 1)})


def recovery_failure(f, hup=False):
    child = f.start()
    f.sample(child, 150, 40)
    writer = f.writer()
    before = f.usage.read_bytes()
    # Actual exclusive-create failure; no mocked sys.write_atomic return value.
    collision = f.run / f'usage-pending.json.tmp.{child.pid}'
    collision.mkdir()
    f.request_stop(child, hup)
    child.wait(timeout=8)
    check('quota writer remains locked through failed recovery exit', writer.poll() is None)
    check('recovery write failure causes observable nonzero exit', child.returncode != 0)
    events = [json.loads(line) for line in (f.run / 'events.jsonl').read_text().splitlines()]
    check('recovery write failure emits FS_FAILED usage_recovery', any(
        event.get('code') == 'FS_FAILED' and event.get('args', {}).get('op') == 'usage_recovery'
        for event in events), events)
    check('failed recovery never claims a recoverable snapshot', not f.pending.exists())
    check('failed recovery leaves old ledger byte-for-byte intact', f.usage.read_bytes() == before)
    f.unlock(writer)
    check('quota writer survives failed recovery without changing history',
          f.document()['days'] == {} and f.document()['quota'] == QUOTA)


def reload(f):
    child = f.start()
    f.sample(child, 150, 40)
    writer = f.writer()
    f.set_enabled(False)
    child.send_signal(signal.SIGHUP)
    wait_for(lambda: f.state().get('last_reload', {}).get('ok') is not None, child)
    check('HUP disable rejects failed flush', f.state()['last_reload']['ok'] is False, f.state())
    events = [json.loads(line) for line in (f.run / 'events.jsonl').read_text().splitlines()]
    check('failed disable reports the usage flush step', any(
        event.get('code') == 'START_FAILED' and event.get('args', {}).get('step') == 'reload:usage_flush'
        for event in events), events)
    # Successful sampling proves the active old snapshot is still enabled.
    sampled = f.sample(child, 175, 50)
    check('failed heatmap-only disable continues sampling the old enabled snapshot',
          sampled['usage']['tx'] == 175 and sampled['usage']['rx'] == 50, sampled)
    f.unlock(writer)
    old_reload = f.state()['last_reload']
    child.send_signal(signal.SIGHUP)
    wait_for(lambda: f.state().get('last_reload') != old_reload and f.state().get('last_reload', {}).get('ok') is True, child)
    f.assert_days({DAY: totals(175, 50, 2)})
    before = f.usage.read_bytes()
    f.stop(child)
    check('disabled TERM does not rewrite ledger', f.usage.read_bytes() == before)


def reload_short(f):
    child = f.start()
    f.sample(child, 150, 40)
    writer = f.writer()
    f.sample(child, 200, 60, next_day=True)
    f.sample(child, 207, 63)
    f.set_enabled(False)
    child.send_signal(signal.SIGHUP)
    f.event('lock-failed')
    f.unlock(writer)
    wait_for(lambda: f.state().get('last_reload', {}).get('ok') is not None, child)
    check('original HUP retries automatically then disables heatmap',
          f.state()['last_reload']['ok'] is True, f.state())
    f.assert_days({DAY: totals(200, 60, 2), NEXT: totals(7, 3, 1)})
    before = f.usage.read_bytes()
    identity = f.usage.stat().st_ino
    f.stop(child)
    check('successful disable leaves no dirty TERM rewrite',
          f.usage.read_bytes() == before and f.usage.stat().st_ino == identity)


def nonretryable_failure(f, corrupt=False):
    child = f.start()
    f.sample(child, 150, 40)
    if corrupt:
        # Real malformed ledger input, not an injected usage.flush failure.
        f.usage.write_text('{broken JSON\n')
    else:
        # Opening a directory as the sidecar fails with EISDIR, not EAGAIN.
        # chmod would not reliably fail when this host test runs as root.
        lock = Path(str(f.usage) + '.lock')
        lock.unlink(missing_ok=True)
        lock.mkdir()
    before = f.usage.read_bytes()
    flushes = f.flush_count()
    started = time.monotonic()
    f.stop(child)
    elapsed = time.monotonic() - started
    check('nonretryable failure makes exactly one lifecycle flush (no 2s retry loop)',
          f.flush_count() - flushes == 1,
          {'flushes': f.flush_count() - flushes, 'elapsed': elapsed})
    events = [json.loads(line) for line in (f.run / 'events.jsonl').read_text().splitlines()]
    op = 'parse' if corrupt else 'lock'
    check('real IO failure reports FS_FAILED ' + op, any(
        event.get('code') == 'FS_FAILED' and event.get('args', {}).get('op') == op
        for event in events), events)
    check('nonretryable failure preserves ledger byte-for-byte', f.usage.read_bytes() == before)
    pending = json.loads(f.pending.read_text())
    check('nonretryable failure still preserves exact pending counters',
          pending.get('days') == {DAY: totals(150, 40, 1)}, pending)
    print(f'EVIDENCE usage-lifecycle: {op} failure flushes=1 elapsed={elapsed:.3f}s', flush=True)


def cross_day(f):
    child = f.start()
    f.sample(child, 150, 40)
    writer = f.writer()
    f.sample(child, 200, 60, next_day=True)
    f.unlock(writer)
    # This is a normal monitor round, not an explicit flush/retry invocation.
    f.sample(child, 207, 63)
    f.assert_days({DAY: totals(200, 60, 2), NEXT: totals(7, 3, 1)})
    f.stop(child)
    f.assert_days({DAY: totals(200, 60, 2), NEXT: totals(7, 3, 1)})


def clean(f):
    child = f.start()
    # Cross-date forces one successful checkpoint even with zero counters.
    f.sample(child, next_day=True)
    before = f.usage.read_bytes()
    identity = f.usage.stat().st_ino
    f.stop(child)
    check('no-dirty TERM does not call atomic writer',
          f.usage.read_bytes() == before and f.usage.stat().st_ino == identity)


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix='usage-lifecycle-') as temp:
        base = Path(temp)
        shutil.copytree(ROOT / 'tests/stubs/daemon-bin', base / 'bin')
        for directory in ('data', 'base', 'custom'):
            (base / directory).mkdir()
        for name in ('gfwlist', 'chnlist', 'apple'):
            (base / 'base' / (name + '.txt')).write_text('example.com\n')
        (base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
        (base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')
        for name, scenario in [
                ('term', term), ('recovery', recovery), ('recovery-failure', recovery_failure),
                ('reload', reload), ('reload-short', reload_short),
                ('reload-stop', lambda f: recovery(f, hup=True)),
                ('reload-stop-failure', lambda f: recovery_failure(f, hup=True)),
                ('parse-failure', lambda f: nonretryable_failure(f, corrupt=True)),
                ('lock-error', nonretryable_failure), ('cross-day', cross_day), ('clean', clean)]:
            if ARGS.case and name != ARGS.case:
                continue
            fixture = Fixture(base, name)
            try:
                scenario(fixture)
            except Exception as error:
                failures.append(name)
                print(f'FAIL usage-lifecycle [{name}] source={SOURCE}: {error}', flush=True)
                print((fixture.root / 'stderr').read_text() if (fixture.root / 'stderr').exists() else '', flush=True)
            finally:
                fixture.close()
    if failures:
        raise SystemExit('failed cases: ' + ', '.join(failures))


if __name__ == '__main__':
    main()
