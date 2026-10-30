#!/usr/bin/env python3
"""T9.41 B-F1: validate the table's entire accepted/rejected set with cached real Xray."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT, T = map(Path, sys.argv[1:3])
T.mkdir(parents=True, exist_ok=True)
p = subprocess.run([str(ROOT / 'tests/host/ucode'), '-e',
                    "import * as t from './tests/unit/t941_inputs.uc'; "
                    "printf('%.J', map(filter(t.cases, c => c.extra != null), c => "
                    "({ name:c.name, expected:c.expect, artifact:t.artifact(c) })));"],
                   cwd=ROOT, text=True, capture_output=True, check=True)
rows = json.loads(p.stdout)
cache = Path(os.environ.get('CI_TOOLS_DIR', '/workspace/openwrt/ci-spike/tools'))
binaries = sorted(cache.glob('xray-*/xray'))
if not binaries:
    print('SKIP  T9.41 real Xray value oracle: no cached binary')
for binary in binaries:
    count = 0
    for row in rows:
        name = row['name']
        # Opaque encoding is intentionally delegated to preflight.py; inactive fields are tested by ucode.
        if 'opaque' in name or 'inactive' in name:
            continue
        expected = row['expected'] is None
        if binary.parent.name == 'xray-26.3.27':
            if any(fp in name for fp in ['hellofirefox_148', 'hellochrome_133', 'hellosafari_26_3']):
                expected = False
            if '2022-blake3-' in name and ('bytes 17' in name or 'bytes 33' in name):
                expected = True  # Old implementation accepts an oversized key; 26.9.30 does not.
            if 'raw key fallback' in name:
                expected = False  # The raw-key fallback is newer than the minimum release.
        config = T / 'xray.json'
        config.write_text(row['artifact'])
        p = subprocess.run([str(binary), 'run', '-test', '-c', str(config)], capture_output=True, text=True)
        assert (p.returncode == 0) == expected, (binary, name, p.returncode, p.stdout, p.stderr)
        count += 1
    print(f'PASS  T9.41 {binary.parent.name} real Xray value oracle: {count} enumerations/boundaries')
