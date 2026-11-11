#!/usr/bin/env python3
"""M4-07: build a signed two-hop itinerary, or extend it at a handoff."""
import hashlib
import json
from pathlib import Path
import sys

root, mode = Path(sys.argv[1]), sys.argv[2]
versions = ['0.6.3-r1', '0.7.0-r1', '1.0.0-r1']
if mode == 'extend':
    versions = ['0.6.3-r1', '0.7.0-r1', '0.8.0-r1', '1.0.0-r1']


def release(name, version):
    assets = {}
    for fmt in ('ipk', 'apk'):
        filename = (f'{name}_{version}_aarch64_generic.ipk' if fmt == 'ipk'
                    else f'{name}-{version}_aarch64_generic.apk')
        content = f'{name} {version}\n'.encode()
        for channel in ('ch1', 'ch2'):
            (root / channel / filename).write_bytes(content)
        assets[fmt] = dict(url=filename, size=len(content), sha256=hashlib.sha256(content).hexdigest())
    return dict(version=version, assets={'aarch64_generic': assets})


packages = {name: dict(current=release(name, '1.0.0-r1'), previous=None)
            for name in ('aether-proxy', 'aether-dns', 'luci-app-aether-proxy',
                         'luci-i18n-aether-proxy-zh-cn')}
steps = [dict(release('aether-proxy', version), min_from=prior, reason='Updater transition')
         for prior, version in zip(versions, versions[1:])]
if mode == 'broken':
    steps.reverse()
manifest = dict(schema=2, packages=packages, data={}, compatibility={
    'aether-proxy': dict(from_=versions[0], required_steps=versions[1:], steps=steps)})
# No new chain fields: use the existing signed `from` field.
chain = manifest['compatibility']['aether-proxy']
chain['from'] = chain.pop('from_')
for channel in ('ch1', 'ch2'):
    (root / channel / 'manifest.json').write_text(json.dumps(manifest))
