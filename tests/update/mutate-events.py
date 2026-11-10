#!/usr/bin/env python3
"""M4-04 V8: three temporary mutations; restore bytes even on failed assertions."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
update = root / 'aether-proxy/src/lib/update.uc'
logs = root / 'luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/model/logs.js'
start = "\tlog.event('notice', 'UPDATE_STARTED', { package: name, version: asset.version });"
install = '\tlet installed = install_package(ctx, pm, downloaded.path, previous == true);'
original_update, original_logs = update.read_text(), logs.read_text()
env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
mutations = [
    ('after-install', update, original_update.replace(start + '\n' + install, install + '\n' + start),
     ['bash', 'tests/update/run.sh'], 'FAIL  M4-04 V3-hash event contract'),
    ('old-finish', logs, original_logs.replace('Update finished: {package} {version}',
                                              'Installed {package} version {version}'),
     ['node', '--test', 'tests/luci/logs-update-events.test.js'],
     'M4-04 V6: exact Chinese and English start/finish templates and unknown fallback'),
    ('proxy-only', update, original_update.replace(start, "\tif (name == C.PROG)\n\t\t" + start.lstrip()).replace(
         "\tlog.event('notice', 'UPDATE_STARTED', { package: 'aether-dns', version: asset.version });\n", ''),
     ['bash', 'tests/update/run.sh'], 'FAIL  M4-04 V1 event contract'),
]
try:
    for name, target, changed, command, failure in mutations:
        baseline = target.read_text()
        assert changed != baseline, name
        target.write_text(changed)
        try:
            result = subprocess.run(command, cwd=root, env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert result.returncode != 0 and failure in result.stdout, (name, result.stdout[-3000:])
            print(f'PASS V8 {name}: exit {result.returncode}; {failure}')
            if name == 'old-finish':
                assert '已完成更新：aether-proxy 1.0.0-r1' in result.stdout, result.stdout
        finally:
            target.write_text(baseline)
finally:
    assert update.read_text() == original_update
    assert logs.read_text() == original_logs
print('PASS V8: all production files restored byte-for-byte')
