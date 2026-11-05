#!/usr/bin/env python3
"""Raw-log collector liveness, bounds, supervisor and CLI isolation."""
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
SCRIPT = ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'


def until(fn, timeout=5):
    for _ in range(int(timeout / .01)):
        try:
            if fn():
                return
        except FileNotFoundError:
            pass  # Rotation briefly renames the live segment before recreating it.
        time.sleep(.01)
    raise AssertionError('timed out')


def line(message):
    return f'Thu Oct 16 12:00:00 2026 daemon.notice aether-proxy[123]: {message}\n'


with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    feed = base / 'feed'
    feed.write_text('')
    stub = base / 'logread'
    stub.write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
base = Path(__file__).parent
assert sys.argv[1:] == ['-f', '-e', 'aether-proxy'], sys.argv
with (base / 'calls').open('a') as f: f.write('follow\\n')
with (base / 'attempts').open('a') as f:
    f.write(f'{time.monotonic()} {os.getpid()}\\n')
(base / 'reader.pid').write_text(str(os.getpid()))
if (base / 'fail').exists(): sys.exit(5)
if (base / 'eof').exists():
    sys.stdout.write((base / 'feed').read_text()); sys.stdout.flush()
    sys.exit(0)
with (base / 'feed').open() as f:
    while True:
        text = f.read()
        if text: sys.stdout.write(text); sys.stdout.flush()
        time.sleep(.005)
''')
    stub.chmod(0o755)
    run = base / "run ' directory"
    run.mkdir()
    env = dict(os.environ, PATH=f'{base}:{os.environ["PATH"]}')

    def cli(*args):
        result = subprocess.run([str(UCODE), '-S', str(ENTRY), '--', 'log',
                                 '--run-dir', str(run), '--json', *args],
                                env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr + result.stdout
        assert result.stderr == '', result.stderr
        return json.loads(result.stdout)['lines']

    assert cli() == []  # Missing files; must not call system logread.
    assert not (base / 'calls').exists()
    p = subprocess.Popen(['/bin/sh', str(SCRIPT), str(run), str(stub)], env=env)
    until(lambda: (base / 'reader.pid').exists())
    reader_pid = int((base / 'reader.pid').read_text())
    try:
        assert (run / 'raw-log.pipe').stat().st_mode & 0o777 == 0o600
        feed.write_text(line('first') + line('[main.zig:1 main] DNS') +
                        line('2026/10/16 12:00:00.123 [Warning] xray') +
                        'Thu Oct 16 12:00:00 2026 daemon.info other[1]: aether-proxy[2]: fake\n')
        until(lambda: (run / 'raw.log').exists() and (run / 'raw.log').read_text().count('\n') == 3)
        assert len(cli()) == 3
        assert len(cli('--source', 'dns')) == 1
        assert len(cli('--source', 'xray')) == 1
        assert cli('--lines', '1')[0]['source'] == 'xray'
        with feed.open('a') as f:
            f.write(''.join(line(f'row {i}') for i in range(1997)))
        until(lambda: (run / 'raw.log.1').exists())
        assert (run / 'raw.log.1').read_text().count('\n') == 2000
        until(lambda: (run / 'raw.log').stat().st_size == 0)
        with feed.open('a') as f:
            f.write(line('after rotation'))
        until(lambda: (run / 'raw.log').stat().st_size > 0)
        assert len(cli('--lines', '2000')) == 2000
        combined = cli('--lines', '2')
        assert combined[0]['text'].endswith('row 1996')
        assert combined[1]['text'].endswith('after rotation')
        # Overflow by bytes before 2000 lines; then replace the old segment again.
        with feed.open('a') as f:
            f.write(''.join(line('x' * 600000) for _ in range(3)))
        until(lambda: (run / 'raw.log').stat().st_size > 600000)
        until(lambda: (run / 'raw.log.1').stat().st_size > 600000)
        time.sleep(.1)
        for path in (run / 'raw.log', run / 'raw.log.1'):
            assert path.stat().st_size <= 1048576
            assert path.read_bytes().count(b'\n') <= 2000
            assert path.stat().st_mode & 0o777 == 0o600
        assert not (run / 'raw.log.2').exists()
    finally:
        p.terminate()
        p.wait(timeout=5)
    assert not Path(f'/proc/{reader_pid}').exists(), 'logread not reaped'
    assert not (run / 'raw-log.pipe').exists()
    for path in run.glob('raw.log*'):
        path.write_text('')
    assert cli() == []
    assert (base / 'calls').read_text() == 'follow\n', 'CLI called system logread'
    print('PASS collector append, rotation, bounds, permissions, sources, CLI isolation, stop/reap')

    # Exact byte limit and an oversized whole record; old data survives collector restart.
    exact = line('x' * (1048576 - len(line(''))))
    assert len(exact.encode()) == 1048576
    (run / 'raw.log').write_text(line('preserved'))
    feed.write_text(exact + line('y' * 1048576) + line('small'))
    p = subprocess.Popen(['/bin/sh', str(SCRIPT), str(run), str(stub)], env=env)
    try:
        until(lambda: (run / 'raw.log.1').stat().st_size == 1048576)
        until(lambda: (run / 'raw.log').read_text() == line('small'))
        assert len(cli('--lines', '2')) == 2
    finally:
        p.terminate()
        p.wait(timeout=5)
    assert not (run / 'raw-log.pipe').exists()
    print('PASS exact 1 MiB boundary, oversized-line rejection and restart counting')


    # Transient reader failure stays inside the collector, not the supervisor.
    for failure in (False, True):
        feed.write_text(line('supervised'))
        if failure:
            (base / 'fail').touch()
        subprocess.run([str(UCODE), str(ROOT / 'tests/daemon/raw-log.uc'),
                        str(run), str(SCRIPT), str(stub)], env=env,
                       check=True, capture_output=True, timeout=10)
        events = json.loads((run / 'observed.json').read_text())
        assert sum(e['kind'] == 'started' for e in events) == 1
        assert not any(e['kind'] == 'crashed' for e in events)
        event_file = run / 'events.jsonl'
        warnings = [json.loads(row) for row in event_file.read_text().splitlines()] if event_file.exists() else []
        assert not any(event['code'] == 'CHILD_CRASHED' for event in warnings)
        assert not (run / 'raw-log.pid').exists()
        assert not Path('/proc/' + (base / 'reader.pid').read_text()).exists()
    (base / 'fail').unlink()
    print('PASS supervised start/stop and transient reader failure without CHILD_CRASHED')

    def attempts():
        return [row.split() for row in (base / 'attempts').read_text().splitlines()]

    def children(pid):
        return [int(v) for v in Path(f'/proc/{pid}/task/{pid}/children').read_text().split()]

    def stop_cleanly(proc, sig=signal.SIGTERM):
        owned = children(proc.pid)
        proc.send_signal(sig)
        assert proc.wait(timeout=2) == 0
        assert not (run / 'raw-log.pipe').exists()
        assert all(not Path(f'/proc/{pid}').exists() for pid in owned), owned

    # Normal EOF must reconnect, append later service events, and preserve counts.
    (base / 'eof').touch()
    feed.write_text(line('SERVICE_STARTED'))
    before = len(attempts())
    p = subprocess.Popen(['/bin/sh', str(SCRIPT), str(run), str(stub)], env=env)
    try:
        until(lambda: len(attempts()) > before)
        until(lambda: 'SERVICE_STARTED' in (run / 'raw.log').read_text())
        size = (run / 'raw.log').stat().st_size
        feed.write_text(line('PROXY_HEALTHY'))
        until(lambda: 'PROXY_HEALTHY' in (run / 'raw.log').read_text())
        assert (run / 'raw.log').stat().st_size > size
        assert p.poll() is None
        stop_cleanly(p)
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=5)
    (base / 'eof').unlink()
    print('PASS normal EOF reconnects and collects later SERVICE_STARTED/PROXY_HEALTHY')

    # Exit 5 repeatedly: measure real delays through the cap, then stop during sleep.
    (base / 'fail').touch()
    before = len(attempts())
    p = subprocess.Popen(['/bin/sh', str(SCRIPT), str(run), str(stub)], env=env)
    try:
        until(lambda: len(attempts()) >= before + 7, timeout=25)
        rows = attempts()[before:]
        assert len(rows) == 7, rows
        gaps = [float(b[0]) - float(a[0]) for a, b in zip(rows, rows[1:])]
        for gap, expected in zip(gaps, [1, 2, 3, 4, 5, 5]):
            assert expected - .1 <= gap < expected + 1, gaps
        until(lambda: not (run / 'raw-log.pipe').exists())
        stop_cleanly(p)
        assert all(not Path(f'/proc/{row[1]}').exists() for row in rows)
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=5)
    print('PASS consecutive failures back off 1,2,3,4,5,5s; TERM interrupts sleep/reaps')

    # A nonzero reader exit is recoverable without restarting the collector process.
    before = len(attempts())
    p = subprocess.Popen(['/bin/sh', str(SCRIPT), str(run), str(stub)], env=env)
    try:
        until(lambda: len(attempts()) > before)
        until(lambda: not (run / 'raw-log.pipe').exists())
        (base / 'fail').unlink()
        feed.write_text(line('PROXY_HEALTHY after failure'))
        until(lambda: 'PROXY_HEALTHY after failure' in (run / 'raw.log').read_text())
        assert p.poll() is None
        stop_cleanly(p)
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=5)
    print('PASS exit 5 recovers and collects later health event in the same collector')

    # A dead awk must not leave its still-following reader or FIFO behind.
    feed.write_text(line('writer restart'))
    before = len(attempts())
    p = subprocess.Popen(['/bin/sh', str(SCRIPT), str(run), str(stub)], env=env)
    try:
        until(lambda: len(attempts()) > before)
        reader = int(attempts()[-1][1])
        until(lambda: len(children(p.pid)) == 2)
        writer = next(pid for pid in children(p.pid) if pid != reader)
        os.kill(writer, signal.SIGTERM)
        until(lambda: len(attempts()) >= before + 2)
        assert not Path(f'/proc/{reader}').exists()
        assert not Path(f'/proc/{writer}').exists()
        until(lambda: len(children(p.pid)) == 2)
        stop_cleanly(p, signal.SIGINT)
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=5)
    for path in run.glob('raw.log*'):
        assert path.stat().st_mode & 0o777 == 0o600
        assert path.stat().st_size <= 1048576
        assert path.read_bytes().count(b'\n') <= 2000
    print('PASS awk exit reconnects, old pair reaped, INT cleans live pair/FIFO, bounds retained')
