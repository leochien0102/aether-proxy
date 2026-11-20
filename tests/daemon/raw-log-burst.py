#!/usr/bin/env python3
"""A streaming logread can emit a whole burst before the collector has read a byte."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
COLLECTOR = ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'
PREFIX = 'Thu Nov 19 12:00:00 2026 daemon.info aether-proxy[1]: '
N = 40
with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    logread = base / 'logread'
    burst = ''.join(f'{PREFIX}burst {i:02d}\n' for i in range(N))
    # The duplicate must not delay any later live record or leak a summary mid-stream.
    (base / 'burst').write_text(f'{PREFIX}burst 00\n' + burst)
    logread.write_text(f'''#!/usr/bin/env python3
from pathlib import Path
import sys, time
assert sys.argv[1:] == ['-f', '-e', 'aether-proxy']
print(Path(__file__).with_name('burst').read_text(), end='', flush=True)
i = 0
while True:
    time.sleep(1)
    print({PREFIX!r} + f'tick {{i}}', flush=True)
    i += 1
''')
    logread.chmod(0o700)
    run = base / 'run'
    raw = run / 'raw.log'
    env = dict(os.environ, PATH=f'{base}:{os.environ["PATH"]}')
    # Do not send probes to the host syslog during the standalone test.
    logger = base / 'logger'
    logger.write_text('#!/bin/sh\nexit 0\n')
    logger.chmod(0o700)
    shell = ['/bin/sh']
    if os.environ.get('RAW_LOG_BUSYBOX') == '1':
        busybox = shutil.which('busybox')
        assert busybox, 'BusyBox not on PATH'
        shell = [busybox, 'ash']
        (base / 'awk').symlink_to(Path(busybox).resolve())
    proc = subprocess.Popen([*shell, str(COLLECTOR), str(run), str(logread)], env=env)
    try:
        start = time.monotonic()
        deadline = start + 5
        while time.monotonic() < deadline and (
                not raw.exists() or f'{PREFIX}tick 1\n' not in raw.read_text()):
            time.sleep(.01)
        expected = (burst + f'{PREFIX}tick 0\n{PREFIX}tick 1\n').splitlines()
        assert raw.read_text().splitlines()[:N + 2] == expected, raw.read_text()
        assert proc.poll() is None, 'burst must be visible without EOF'
        assert (run / 'raw-log.ready').is_file()
        assert not (run / 'raw.log.1').exists()
        print(f'PASS raw.log ({"BusyBox ash + awk" if len(shell) > 1 else "host sh + awk"}): '
              f'{N}/{N} distinct burst lines + two 1s ticks, live after '
              f'{time.monotonic() - start:.2f}s')
    finally:
        proc.terminate()
        proc.wait(timeout=5)
    assert not (run / 'raw-log.ready').exists(), 'collector left a stale readiness marker'
