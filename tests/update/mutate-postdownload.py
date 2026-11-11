#!/usr/bin/env python3
"""M4-07 A2/A5: removing either post-download gate must fail its specific probe."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
path = root / 'aether-proxy/src/lib/update.uc'
original = path.read_text()
logs = root / '.cache/m407'
logs.mkdir(parents=True, exist_ok=True)


def probe(mode, directory):
    return subprocess.run(
        ['tests/host/ucode', 'tests/update/walker-postdownload.uc', '--', str(path), str(directory), mode],
        cwd=root, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)


try:
    for label, function, mode in (
            ('A2', 'install_with_rollback', 'proxy'), ('A5', 'update_companion', 'companion')):
        start = original.index(f'function {function}(')
        # The initial proxy admission is unbraced; this selects only the post-download gate.
        gate = original.index('\tif (!budget_ready()) {', start)
        end = original.index("\n\tlog.event('notice', 'UPDATE_STARTED'", gate)
        removed = original[gate:end]
        assert 'downloaded.path' in removed and 'incomplete()' in removed, label
        path.write_text(original[:gate] + original[end:])
        with tempfile.TemporaryDirectory(prefix=f'postdownload-{label}-', dir=logs) as directory:
            result = probe(mode, directory)
        (logs / f'mutation-postdownload-{label}.log').write_text(result.stdout)
        expected = f'M4-07 opkg {mode} post-download: expected BRIDGE_INCOMPLETE after download'
        assert result.returncode != 0 and expected in result.stdout, (label, result.returncode, result.stdout)
        print(f'PASS  M4-07 mutation {label}: {mode} post-download probe turns red (exit={result.returncode})',
              flush=True)
finally:
    path.write_text(original)

for mode in ('proxy', 'companion'):
    with tempfile.TemporaryDirectory(prefix=f'postdownload-restored-{mode}-', dir=logs) as directory:
        result = probe(mode, directory)
    assert result.returncode == 0, (mode, result.stdout)
    print(result.stdout, end='', flush=True)
