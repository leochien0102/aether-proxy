#!/usr/bin/env python3
"""T13.4: real CLI truncation, failures and system-log isolation in private tmpfs-like dirs."""
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FILES = ('raw.log', 'raw.log.1', 'events.jsonl')

with tempfile.TemporaryDirectory(prefix='ap-log-clear-') as tmp:
    base = Path(tmp)
    bin_dir = base / 'bin'
    bin_dir.mkdir()
    marker = base / 'logread-called'
    logread = bin_dir / 'logread'
    logread.write_text('#!/bin/sh\nprintf called > "$LOGREAD_MARKER"\nexit 99\n')
    logread.chmod(0o755)
    env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', LOGREAD_MARKER=str(marker))

    def invoke(run_dir, *args):
        result = subprocess.run(
            [str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
             '--', 'log', 'clear', '--run-dir', str(run_dir), *args],
            env=env, text=True, capture_output=True, check=False)
        assert not result.stderr, result.stderr
        return result.returncode, json.loads(result.stdout)

    subsets = [subset for count in range(4) for subset in itertools.combinations(FILES, count)]
    for index, present in enumerate(subsets):
        run = base / f'files-{index}'
        run.mkdir()
        sentinel = run / 'system.log'
        sentinel.write_text('system log unchanged')
        inodes = {}
        for name in present:
            path = run / name
            path.write_text('old data\n')
            path.chmod(0o600)
            inodes[name] = path.stat().st_ino
        assert invoke(run) == (0, {'ok': True})
        for name in FILES:
            path = run / name
            if name in inodes:
                assert path.read_bytes() == b''
                assert path.stat().st_ino == inodes[name]
                assert path.stat().st_mode & 0o777 == 0o600
            else:
                assert not path.exists()
        assert sentinel.read_text() == 'system log unchanged'
        print(f'PASS T13.4 clear subset {index} {present}: empty, same inode/mode, missing untouched')

    assert invoke(base / 'missing-directory') == (0, {'ok': True})
    print('PASS T13.4 missing directory succeeds')
    for name in FILES:
        run = base / f'failure-{name}'
        run.mkdir()
        (run / name).mkdir()
        code, reply = invoke(run, '--json')
        assert code == 1 and reply['ok'] is False and reply['code'] == 'FS_FAILED', reply
        assert str(run / name) in reply['detail'], reply
    # A writable descriptor whose backing device refuses ftruncate exercises
    # the write failure separately from open failures, without touching logd.
    run = base / 'truncate-failure'
    run.mkdir()
    (run / 'raw.log').symlink_to('/dev/null')
    code, reply = invoke(run)
    assert code == 1 and reply['code'] == 'FS_FAILED' and 'clear ' in reply['detail'], reply
    print('PASS T13.4 truncate failure returns explicit FS_FAILED')
    # ENOTDIR must not be mistaken for a missing file.
    code, reply = invoke(base / 'files-1/raw.log')
    assert code == 1 and reply['code'] == 'FS_FAILED'
    print('PASS T13.4 open/read-write failures identify path with FS_FAILED')
    code, reply = invoke(base, '--source', 'all')
    assert code == 2 and reply['code'] == 'USAGE'
    print('PASS T13.4 clear rejects read-only options')
    assert not marker.exists(), 'logread was called'
    source = (ROOT / 'aether-proxy/src/lib/cmd/log.uc').read_text()
    assert 'logread' not in source and '/var/log' not in source
    print('PASS T13.4 no logread invocation or system-log path')
