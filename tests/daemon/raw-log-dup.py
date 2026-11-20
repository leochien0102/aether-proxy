#!/usr/bin/env python3
"""Check raw.log adjacent duplicate accounting, EOF and segment boundaries."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
COLLECTOR = ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'
PREFIX = 'Thu Nov 19 12:00:00 2026 daemon.info aether-proxy[1]: '
LIMIT = 1048576
NOISE = 'I [main.zig:91 on_start] startup detail'
LISTEN = 'I [main.zig:90 on_start] local listen addr: 127.0.0.1#5353'
SUPPRESSED = 'aether-proxy: chinadns-ng startup: 1 info lines suppressed\n'


def line(message):
    return PREFIX + message + '\n'


def folded(n):
    return f'aether-proxy: raw log: {n} duplicate line(s) folded\n'


def compact(segment):
    return [row.removeprefix(PREFIX) for row in segment.splitlines()]


class RawLogDup(unittest.TestCase):
    def check(self, seed, messages, expected, rotated=''):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            run = base / 'run'
            run.mkdir()
            raw = run / 'raw.log'
            old = run / 'raw.log.1'
            raw.write_text(seed)
            feed = base / 'feed'
            input_text = ''.join(map(line, messages))
            feed.write_text(input_text)
            reader = base / 'logread'
            reader.write_text('''#!/bin/sh
[ "$*" = '-f -e aether-proxy' ] || exit 2
if [ -e first-follow ]; then
    : > reconnected
    exec sleep 30
fi
: > first-follow
exec cat "${0%/*}/feed"
''')
            reader.chmod(0o700)
            shell = ['/bin/sh']
            env = os.environ.copy()
            if env.get('RAW_LOG_BUSYBOX') == '1':
                busybox = shutil.which('busybox')
                self.assertIsNotNone(busybox, 'BusyBox is required; add it to PATH')
                shell = [busybox, 'ash']
                (base / 'awk').symlink_to(Path(busybox).resolve())
                env['PATH'] = f'{base}:{env["PATH"]}'
            with subprocess.Popen([*shell, str(COLLECTOR), str(run), str(reader), '/bin/true'],
                                  env=env, stderr=subprocess.PIPE) as proc:
                try:
                    deadline = time.monotonic() + 5
                    while not (run / 'reconnected').exists():
                        self.assertLess(time.monotonic(), deadline, 'collector did not reconnect after EOF')
                        self.assertIsNone(proc.poll())
                        time.sleep(.01)
                    actual = raw.read_text()
                    self.assertEqual(actual, expected)
                    self.assertEqual(old.exists(), bool(rotated))
                    previous = old.read_text() if old.exists() else ''
                    self.assertEqual(previous, rotated)
                finally:
                    proc.terminate()
                    proc.communicate(timeout=5)
        mode = 'BusyBox awk' if len(shell) > 1 else 'host awk'
        old_tail = compact(previous.removeprefix(seed)) if previous else []
        print(f'{mode} {self._testMethodName}: in={compact(input_text)!r}; '
              f'raw.log.1 tail={old_tail!r}; raw.log={compact(actual)!r}', flush=True)

    def test_adjacent_only(self):
        self.check('', list('AABBBA'), line('A') + line('B') + line('A') + folded(3))

    def test_normalized(self):
        self.check('', ['\033[31m2026-11-19 12:00:01 A\033[0m', 'A',
                        '\033[32m2026-11-19 12:00:02 A\033[0m'], line('A') + folded(2))

    def test_exempt_and_suppressed(self):
        self.check('', [LISTEN, NOISE, LISTEN, LISTEN, NOISE],
                   line(LISTEN) + SUPPRESSED + SUPPRESSED + folded(2))

    def test_line_rotation(self):
        seed = ''.join(line(f'seed {i}') for i in range(1998))
        self.check(seed, ['A', 'A', 'B', 'B', 'B'], line('B') + folded(2),
                   seed + line('A') + folded(1))

    def test_byte_rotation(self):
        seed = line('x' * (LIMIT - len(line('')) - 200))
        incoming = 'B' * 160
        self.check(seed, ['A', 'A', NOISE, incoming], line(incoming),
                   seed + line('A') + SUPPRESSED + folded(1))


if __name__ == '__main__':
    unittest.main()
