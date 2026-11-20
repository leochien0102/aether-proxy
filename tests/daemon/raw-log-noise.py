#!/usr/bin/env python3
"""Check raw-log startup filtering during follow and when logread reaches EOF."""
import difflib
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


def decorated(msg):
    return f'\033[1;32m2026-11-19 12:00:00 \t  {msg}\033[0m'


def summary(n):
    return f'aether-proxy: chinadns-ng startup: {n} info lines suppressed'


def check(shell, env, messages, expected, eof=False):
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        (base / 'feed').write_text(''.join(PREFIX + msg + '\n' for msg in messages),
                                   encoding='utf-8')
        logread = base / 'logread'
        logread.write_text(f'''#!/usr/bin/env python3
from pathlib import Path
import signal, sys
assert sys.argv[1:] == ['-f', '-e', 'aether-proxy']
if Path('first-follow').exists():
    Path('reconnected').touch()
    signal.pause()
else:
    Path('first-follow').touch()
    print(Path(__file__).with_name('feed').read_text(encoding='utf-8'), end='', flush=True)
    if not {eof!r}:
        signal.pause()
''')
        logread.chmod(0o700)
        run = base / 'run'
        raw = run / 'raw.log'
        # Use a no-op logger so the readiness probes never reach host syslog.
        with subprocess.Popen([*shell, str(COLLECTOR), str(run), str(logread), '/bin/true'],
                              env=env, stderr=subprocess.PIPE, text=True) as proc:
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and proc.poll() is None:
                    done = ((run / 'reconnected').exists() if eof else
                            raw.exists() and expected[-1] + '\n' in raw.read_text(encoding='utf-8'))
                    if done:
                        break
                    time.sleep(.01)
                else:
                    raise AssertionError('logread did not reach the expected follow state')
                actual = raw.read_text(encoding='utf-8').splitlines(keepends=True)
                wanted = [line + '\n' for line in expected]
                assert actual == wanted, '\n' + ''.join(difflib.unified_diff(
                    [repr(line) + '\n' for line in wanted],
                    [repr(line) + '\n' for line in actual], 'expected', 'raw.log'))
            finally:
                proc.terminate()
                proc.communicate(timeout=5)


def cases():
    sources = ['main.zig', 'dnl.c', 'groups.zig']
    noise = [f'I [{sources[i % len(sources)]}:{i} on_start] config detail {i}' for i in range(1, 14)]
    noisy = [line for msg in noise for line in (msg, decorated(msg))]
    tags = ['I [dnl.c:534 dnl_init] tag:chn loaded:109671 added:109626 cost:2212.789k',
            'I [dnl.c:534 dnl_init] tag:gfw loaded:4381 added:4381 cost:91.722k']
    l2 = 'I [dnl.c:545 dnl_init] L2 items:1358 lists:989 buckets:2048 cost:8.000k'
    listen = 'I [main.zig:90 on_start] local listen addr: 127.0.0.1#5353'
    warning = 'W [Upstream.zig:102 connect] connect failed'
    xray = ['[Warning] core: Xray started', '[Info] infra/conf/serial: Reading config',
            'A unified platform…']
    protected = ['I [main.zig:2 on_start] load failed', 'I [dnl.c:3 dnl_init] [Warning] stale list',
                 'I [groups.c:4 on_start] [Error] invalid group', 'E [main.zig:5 on_start] bad port']
    yield 'live follow', noisy + tags + [l2] + list(map(decorated, [listen, warning])) + xray, (
        [summary(26)] + [PREFIX + msg for msg in tags] + [summary(1)] +
        [PREFIX + msg for msg in [listen, warning] + xray]), False
    yield 'EOF and reconnect', list(map(decorated, protected)) + [protected[-1]] + noisy[:2], (
        [PREFIX + msg for msg in protected] + [summary(2),
         'aether-proxy: raw log: 1 duplicate line(s) folded']), True


class RawLogNoise(unittest.TestCase):
    def check_cases(self, shell, env):
        for name, messages, expected, eof in cases():
            with self.subTest(name):
                check(shell, env, messages, expected, eof)

    def test_host_sh_awk(self):
        self.check_cases(['/bin/sh'], os.environ)

    def test_busybox_ash_awk(self):
        busybox = shutil.which('busybox')
        self.assertIsNotNone(busybox, 'BusyBox is required; add it to PATH')
        with tempfile.TemporaryDirectory() as applets:
            (Path(applets) / 'awk').symlink_to(Path(busybox).resolve())
            self.check_cases([busybox, 'ash'], dict(os.environ, PATH=f'{applets}:{os.environ["PATH"]}'))


if __name__ == '__main__':
    unittest.main()
