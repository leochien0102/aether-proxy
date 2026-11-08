#!/usr/bin/env python3
"""T15.8 controls in disposable source copies; never mutate the working suite.

Runs the formal entry, removes each fixture adaptation independently, then uses
its legacy alias for restoration. Observations do not alter scheduling oracles.
"""
from pathlib import Path
from contextlib import nullcontext
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / 'tests/schedule/evidence'
MAPPING = '''	# Startup now queries the private B3 fixture; retain the old flag for runtime resolveip.
	if [ "${SCHEDULE_RESOLVE_FAIL:-1}" = 1 ]; then
		touch "$root/resolve-always-fail"
	else
		rm -f "$root/resolve-always-fail"
	fi
'''
SLOW = '''# Reuse B3 private query/owned-proc support and delay only the formal DNS stop.
# The shared stub executes this real sleep in its TERM handler, not in the harness.
printf '0.8\\n' > "$R/dns-stop-delay"'''
original = subprocess.check_output(
    ['git', 'show', '6c3a0ca:tests/schedule/run.sh'], cwd=ROOT, text=True)
source = (ROOT / 'tests/schedule/run.sh').read_text()
old_slow = original[original.index('cat > "$T/bin/chinadns-ng"'):original.index(
    'SCHEDULE_HOURS=0.1 start_daemon')].rstrip()
assert source.count(MAPPING) == source.count(SLOW) == 1
# Compare all bytes outside the two authorized fixture adaptations, not just PASS labels.
assert source.replace(MAPPING, '').replace(SLOW, old_slow) == original
EVIDENCE.mkdir(exist_ok=True)
notes = ['All bytes outside the two fixture adaptations equal 6c3a0ca.']


def observe_sleep(tree, done):
    """Read-only observation of the formal DNS TERM handler's actual child."""
    seen = {}
    while not done.is_set():
        for pidfile in (tree / 'tests/schedule').glob('tmp.*/root3/chinadns.pid'):
            try:
                parent = int(pidfile.read_text())
                children = Path(f'/proc/{parent}/task/{parent}/children').read_text().split()
                for pid in children:
                    command = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                    if command[:2] == [b'sleep', b'0.8'] and pid not in seen:
                        seen[pid] = time.monotonic()
                        notes.append(f'formal DNS pid={parent} child={pid}: actual sleep 0.8 observed')
            except (FileNotFoundError, ProcessLookupError):
                continue
        for pid, started in list(seen.items()):
            if not Path(f'/proc/{pid}').exists():
                notes.append(f'sleep child={pid} observed lifetime={time.monotonic() - started:.3f}s')
                del seen[pid]
        done.wait(.01)


def run(name, text, alias=False):
    control = name not in ('fixed', 'restored-compat')
    context = (tempfile.TemporaryDirectory(prefix='.t15.8-', dir=ROOT / 'tests/schedule')
               if control else nullcontext(ROOT))
    with context as directory:
        tree = Path(directory)
        if control:
            # Tracked sources only; host binaries are read-only reused, not rebuilt/modified.
            archive = subprocess.Popen(['git', 'archive', 'HEAD'], cwd=ROOT, stdout=subprocess.PIPE)
            subprocess.run(['tar', '-x', '-C', str(tree)], stdin=archive.stdout, check=True)
            archive.stdout.close()
            assert archive.wait() == 0
            (tree / 'tests/host/prefix').symlink_to(ROOT / 'tests/host/prefix')
            (tree / 'tests/schedule/run.sh').write_text(text)
            shutil.copyfile(ROOT / 'tests/bootstrap-startup/schedule-compat.py',
                            tree / 'tests/bootstrap-startup/schedule-compat.py')
        done = threading.Event()
        observer = threading.Thread(target=observe_sleep, args=(tree, done))
        observer.start()
        command = ['python3', 'tests/bootstrap-startup/schedule-compat.py'] if alias else [
            'bash', 'tests/schedule/run.sh']
        try:
            with (EVIDENCE / f't15.8-{name}.log').open('w') as log:
                result = subprocess.run(command, cwd=tree, stdout=log, stderr=subprocess.STDOUT)
        finally:
            done.set()
            observer.join()
        output = (EVIDENCE / f't15.8-{name}.log').read_text()
        notes.append(f'{name}: exit={result.returncode}')
        if name in ('fixed', 'restored-compat'):
            assert result.returncode == 0 and 'schedule: 47 passed, 0 failed' in output
        elif name == 'no-bootstrap-map':
            assert result.returncode == 1
            for policy in ('auto', 'notify'):
                assert f'FAIL  {policy} degraded scheduler setup' in output
        else:
            assert result.returncode == 1
            assert 'FAIL  stop-timer test daemon enters degraded: state=error' in output
            assert 'bootstrap.conf/calls.log: Directory nonexistent' in output
        # The suite's trap owns process cleanup; no temporary roots should survive it.
        assert not list((tree / 'tests/schedule').glob('tmp.*'))
        assert not list((tree / 'tests/schedule').glob('tmp.*/root*/chinadns.pid'))
        print(notes[-1], flush=True)


run('fixed', source)
run('no-bootstrap-map', source.replace(MAPPING, ''))
run('old-slow-stub', source.replace(SLOW, old_slow))
run('restored-compat', source, alias=True)
(EVIDENCE / 't15.8-fixture-observations.log').write_text('\n'.join(notes) + '\n')
print('Fixture controls/restoration passed; original business oracles unchanged.')
