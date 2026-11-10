#!/usr/bin/env python3
"""Small signed engine asset variants, using the existing channel fixture format."""
import hashlib
import json
from pathlib import Path
import sys

root, scenario = Path(sys.argv[1]), sys.argv[2]
for channel in ('ch1', 'ch2'):
    directory = root / channel
    path = directory / 'manifest.json'
    manifest = json.loads(path.read_text())
    engine = manifest['packages']['aether-dns']
    if scenario == 'recovery':
        release = engine['previous']
        release['version'] = '2026.11.04-r2'
        for arch, formats in release['assets'].items():
            for fmt, asset in formats.items():
                filename = (f'aether-dns_2026.11.04-r2_{arch}.ipk' if fmt == 'ipk'
                            else f'aether-dns-2026.11.04-r2_{arch}.apk')
                content = b'exact original engine package and metadata\n'
                (directory / filename).write_bytes(content)
                asset.update(url=filename, size=len(content), sha256=hashlib.sha256(content).hexdigest())
    elif scenario.startswith('T4'):
        for formats in engine['current']['assets'].values():
            for asset in formats.values():
                if scenario == 'T4-hash':
                    asset['sha256'] = '0' * 64
                else:
                    (directory / asset['url']).unlink(missing_ok=True)
    elif scenario == 'T12':
        manifest['packages']['future-unknown-package'] = {'unrecognized': True}
    path.write_text(json.dumps(manifest))
