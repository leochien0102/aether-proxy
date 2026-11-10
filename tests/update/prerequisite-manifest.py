#!/usr/bin/env python3
"""Small signed engine asset variants, using the existing channel fixture format."""
import hashlib
import json
from pathlib import Path
import sys

root, scenario = Path(sys.argv[1]), sys.argv[2]


def release(directory, name, version):
    assets = {}
    for arch in ('aarch64_generic', 'all'):
        assets[arch] = {}
        for fmt in ('ipk', 'apk'):
            filename = (f'{name}_{version}_{arch}.ipk' if fmt == 'ipk'
                        else f'{name}-{version}_{arch}.apk')
            content = f'{name} {version} {arch} {fmt}\n'.encode()
            (directory / filename).write_bytes(content)
            assets[arch][fmt] = dict(url=filename, size=len(content), sha256=hashlib.sha256(content).hexdigest())
    return dict(version=version, assets=assets)

for channel in ('ch1', 'ch2'):
    directory = root / channel
    path = directory / 'manifest.json'
    manifest = json.loads(path.read_text())
    if scenario == 'target':
        manifest['packages']['aether-proxy']['current'] = release(directory, 'aether-proxy', '1.0.0-r1')
        manifest['packages']['aether-dns'] = dict(current=release(directory, 'aether-dns', '1.0.0-r1'),
                                                 previous=release(directory, 'aether-dns', '1.0.0-r1'))
    elif scenario in ('T10', 'T14', 'T14-bridge'):
        target = '1.0.0-r1' if scenario == 'T10' else '0.7.1-r1'
        current = release(directory, 'aether-proxy', target)
        manifest['packages']['aether-proxy']['current'] = current
        if scenario != 'T10':
            del manifest['packages']['aether-dns']
        if scenario in ('T10', 'T14-bridge'):
            predecessor = '0.1.0-r1' if scenario == 'T10' else '0.7.0-r1'
            steps = [dict(current, min_from=predecessor, reason='Required backend bridge')]
            if scenario == 'T14-bridge':
                terminal = release(directory, 'aether-proxy', '1.1.0-r1')
                manifest['packages']['aether-proxy']['current'] = terminal
                steps.append(dict(terminal, min_from=target, reason='Later dns-engine transition'))
            manifest['compatibility'] = {'aether-proxy': dict(steps=steps,
                required_steps=[step['version'] for step in steps])}
    engine = manifest['packages'].get('aether-dns')
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
