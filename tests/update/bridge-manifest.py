#!/usr/bin/env python3
"""Signed bridge-chain fixtures for bridge-chain.sh (both package managers)."""
import copy
import hashlib
import json
from pathlib import Path
import sys

root, scenario = Path(sys.argv[1]), sys.argv[2]
backend = 'aether-proxy'
versions = ['0.6.3-r1', '0.6.4-r1', '0.6.6-r1', '0.6.8-r1']


def release(name, version):
    assets = {}
    for arch in ('aarch64_generic', 'all'):
        assets[arch] = {}
        for fmt in ('ipk', 'apk'):
            filename = (f'{name}_{version}_{arch}.ipk' if fmt == 'ipk'
                        else f'{name}-{version}_{arch}.apk')
            content = f'{name} {version} {arch} {fmt}\n'.encode()
            for channel in ('ch1', 'ch2'):
                (root / channel / filename).write_bytes(content)
            assets[arch][fmt] = dict(url=filename, size=len(content),
                                     sha256=hashlib.sha256(content).hexdigest())
    return dict(version=version, assets=assets)


packages = {}
for name in (backend, 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'):
    packages[name] = dict(current=release(name, versions[-1]),
                          previous=release(name, versions[0]))
packages['aether-dns'] = dict(current=release('aether-dns', '1.0.0-r1'),
                              previous=release('aether-dns', '1.0.0-r1'))
steps = []
for prior, version in zip(versions, versions[1:]):
    steps.append(dict(release(backend, version), min_from=prior,
                      reason=f'Compatibility migration from {prior} to {version}'))
chain = dict(required_steps=versions[1:], steps=steps)
if scenario == 'installed-version-mismatch':
    steps[0]['assets'] = release(backend, '0.6.5-r1')['assets']
elif scenario == 'missing':
    steps.pop(1)
elif scenario == 'reordered':
    steps[0], steps[1] = steps[1], steps[0]
elif scenario == 'rejoined':
    steps.pop(1)
    steps[1]['min_from'] = steps[0]['version']
elif scenario == 'wrong-version':
    steps[1]['version'] = '0.6.5-r1'
elif scenario == 'wrong-terminal':
    packages[backend]['current']['version'] = '0.6.8-r2'
elif scenario == 'no-reason':
    steps[1].pop('reason')
elif scenario == 'blank-reason':
    steps[1]['reason'] = '  '
elif scenario == 'later-platform-missing':
    steps[-1]['assets'] = {'other_arch': steps[-1]['assets']['aarch64_generic']}
elif scenario == 'bad-metadata':
    steps[-1]['assets']['aarch64_generic']['ipk']['sha256'] = 'not-a-sha256'
elif scenario in ('bad-hash', 'bad-bytes', 'download-missing'):
    for formats in steps[0]['assets'].values():
        for asset in formats.values():
            if scenario == 'bad-hash':
                asset['sha256'] = '0' * 64
            else:
                for channel in ('ch1', 'ch2'):
                    path = root / channel / asset['url']
                    if scenario == 'download-missing':
                        path.unlink()
                    else:
                        path.write_bytes(b'X' * asset['size'])
elif scenario == 'rollback-unmatched':
    packages[backend]['previous'] = release(backend, '0.6.2-r1')
elif scenario == 'rollback-previous-target':
    packages[backend]['previous'] = copy.deepcopy(packages[backend]['current'])
manifest = dict(schema=2, generated='2026-10-15T00:00:00Z', packages=packages,
                data={}, compatibility={backend: chain})
if scenario == 'null-chain':
    manifest['compatibility'][backend] = None
elif scenario == 'empty-chain':
    manifest['compatibility'][backend] = {}
for channel in ('ch1', 'ch2'):
    (root / channel / 'manifest.json').write_text(json.dumps(manifest))
