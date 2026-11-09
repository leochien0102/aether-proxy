#!/usr/bin/env python3
"""T15.10: real init + supplied rc.common order; real local shell TERM, not procd.

Only child PIDs owned by Popen receive signals. No device, service, historical PID,
DNS engine or firmware-wide claim. run.sh retains the handoff business model.
"""
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
INIT = Path(os.environ.get('CONTRACT_INIT', ROOT / 'aether-proxy/files/aether-proxy.init'))
SHELL = os.environ.get('CONTRACT_SHELL', '/bin/sh')
passed = failed = 0


def check(name, condition, detail=''):
    global passed, failed
    if condition:
        passed += 1
        print('PASS  ' + name, flush=True)
    else:
        failed += 1
        print('FAIL  ' + name + ': ' + str(detail), flush=True)


class Case:
    def __init__(self, mode='stop', fault='none', cleanup=0, enabled=1,
                 running=1, intent=False, signals=False, start_rc=0):
        self.tmp = tempfile.TemporaryDirectory(prefix='.contract-', dir=HERE)
        self.path = Path(self.tmp.name)
        run = self.path / 'run'
        run.mkdir()
        if intent:
            (run / 'restart-intent').write_text('restart\n')
        if fault == 'mark-create':
            (run / 'stopped-by-user').mkdir()
        (self.path / 'trace').touch()
        proxy = self.path / 'aether-proxy'
        proxy.write_text('#!/bin/sh\nprintf "cleanup %s\\n" "$*" >> "$CASE_DIR/trace"\n'
                         'exit "$CLEANUP_RC"\n')
        proxy.chmod(0o755)
        self.env = dict(os.environ, INIT=str(INIT), FIXTURE=str(HERE / 'rc-common-stop.sh'),
                        CASE_DIR=str(self.path), AETHER_PROXY_RUN_DIR=str(run),
                        MODE=mode, FAULT=fault, CLEANUP_RC=str(cleanup),
                        TEST_ENABLED=str(enabled), RUNNING=str(running),
                        SIGNALS=str(int(signals)), START_RC=str(start_rc))

    def trace(self):
        return (self.path / 'trace').read_text().splitlines()

    def run(self):
        result = subprocess.run([SHELL, str(HERE / 'contract-driver.sh')], env=self.env,
                                capture_output=True, text=True, timeout=10)
        print(f'TRACE mode={self.env["MODE"]} fault={self.env["FAULT"]} '
              f'cleanup={self.env["CLEANUP_RC"]} rc={result.returncode} events={self.trace()}', flush=True)
        return result.returncode, self.trace(), result.stderr

    def close(self):
        self.tmp.cleanup()


def ordered(trace):
    events = [x for x in trace if x in ('lock', 'kill', 'open-service',
                                       'trigger aetherproxy', 'close-service') or x.startswith('cleanup ')]
    return events == ['lock', 'kill', 'cleanup cleanup --wait 35', 'open-service',
                      'trigger aetherproxy', 'close-service']


# I2/I3: deterministic command failure or a directory at the exact mark path.
for fault in ('intent', 'mark-create'):
    for cleanup in (0, 3, 37):
        case = Case(fault=fault, cleanup=cleanup, intent=True)
        rc, trace, stderr = case.run()
        check(f'I2 {fault} cleanup={cleanup}: external stop rc', rc == (cleanup or 1), (rc, trace))
        check(f'I2 {fault} cleanup={cleanup}: kill cleanup trigger order', ordered(trace), trace)
        message = 'cannot remove' if fault == 'intent' else 'cannot write'
        check(f'I2 {fault} cleanup={cleanup}: original log', any(message in x for x in trace), trace)
        case.close()

for cleanup in (0, 3, 37):
    case = Case(cleanup=cleanup)
    rc, trace, _ = case.run()
    check(f'I3 cleanup={cleanup}: exact original status and full closure', rc == cleanup and ordered(trace), trace)
    case.close()

case = Case(mode='reset', fault='intent', intent=True)
rc, trace, _ = case.run()
check('I3 same shell: failure consumed, second stop and independent callback succeed',
      rc == 0 and all(x in trace for x in ('first 1', 'after-failure-callback 0', 'second 0', 'independent 0')), trace)
case.close()
case = Case(mode='service_stopped', cleanup=37)
rc, trace, _ = case.run()
check('I3 independent callback preserves cleanup rc', rc == 37, trace)
case.close()

for fault, cleanup, running, intent, expected in (
        ('intent', 0, 1, True, 1), ('mark-create', 0, 1, True, 1),
        ('none', 37, 1, True, 37), ('mark-remove', 0, 1, True, 1),
        ('mark-remove', 37, 1, True, 37), ('none', 0, 0, True, 0),
        ('none', 0, 0, False, 0), ('mark-remove', 0, 0, False, 1)):
    case = Case(mode='reload_service', fault=fault, cleanup=cleanup, enabled=0,
                running=running, intent=intent)
    rc, trace, _ = case.run()
    label = f'I4 {fault} cleanup={cleanup} running={running} intent={intent}'
    check(label + ': status', rc == expected, (rc, trace))
    should_stop = running or intent
    check(label + ': original closure/no-op boundary', ordered(trace) if should_stop else 'kill' not in trace, trace)
    check(label + ': trailing mark removal attempted',
          ('fail-mark-remove' in trace) if fault == 'mark-remove' else
          (not (case.path / 'run/stopped-by-user').exists() or
           any('cannot remove' in x and 'stopped-by-user' in x for x in trace)), trace)
    case.close()

for enabled in (0, 1):
    for cleanup, start_rc in ((37, 0), (0, 23)):
        case = Case(mode='restart', cleanup=cleanup, enabled=enabled, start_rc=start_rc)
        rc, trace, _ = case.run()
        check(f'I1 restart enabled={enabled} cleanup={cleanup}: stop failure skips start / start rc preserved',
              rc == (cleanup or start_rc) and (('start' in trace) == (cleanup == 0)), (rc, trace))
        case.close()


def ready(proc, phase):
    readable, _, _ = select.select([proc.stdout], [], [], 5)
    line = proc.stdout.readline().strip() if readable else '<timeout>'
    return line == f'ready {phase} {proc.pid}', line


def signal_case(enabled, cleanup, ordinary=False):
    case = Case(mode='stop' if ordinary else 'restart', enabled=enabled,
                cleanup=cleanup, signals=True)
    proc = subprocess.Popen([SHELL, str(HERE / 'contract-driver.sh')], env=case.env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    label = f'I5 enabled={enabled} cleanup={cleanup}'
    try:
        valid, line = ready(proc, 'stop')
        check(label + ': owned PID ready at stop', valid, line)
        if not valid:
            return
        proc.send_signal(signal.SIGTERM)
        if ordinary:
            out, err = proc.communicate('continue\n', timeout=5)
            check('I5 ordinary stop: TERM remains default', proc.returncode == -signal.SIGTERM,
                  (proc.returncode, out, err, case.trace()))
            return
        try:
            proc.stdin.write('continue\n')
            proc.stdin.flush()
        except BrokenPipeError:
            pass
        next_phase = 'returned' if cleanup else 'start'
        valid, line = ready(proc, next_phase)
        trace = case.trace()
        check(label + ': TERM ignored during stop (resumed trace)',
              valid and 'resumed stop' in trace, (line, trace))
        if not valid:
            return
        check(label + ': phase before restored TERM',
              ('result 37' in trace and 'start' not in trace) if cleanup else 'start' in trace, trace)
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate('continue\n', timeout=5)
        check(label + ': default TERM restored at ' + next_phase,
              proc.returncode == -signal.SIGTERM and f'resumed {next_phase}' not in case.trace(),
              (proc.returncode, out, err, case.trace()))
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=5)
        print(f'TRACE TERM enabled={enabled} cleanup={cleanup} ordinary={ordinary} '
              f'owned_pid={proc.pid} exit={proc.returncode} events={case.trace()}', flush=True)
        case.close()


for enabled in (0, 1):
    for cleanup in (0, 37):
        signal_case(enabled, cleanup)
signal_case(1, 0, ordinary=True)
print(f'init contract ({SHELL}): {passed} passed, {failed} failed', flush=True)
raise SystemExit(bool(failed))
