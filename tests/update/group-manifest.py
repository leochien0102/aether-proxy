#!/usr/bin/env python3
"""T9.38 signed-channel variants; leave unrelated fixture capabilities intact."""
import json
from pathlib import Path
import sys

root, scenario = Path(sys.argv[1]), sys.argv[2]
app = 'luci-app-aether-proxy'
i18n = 'luci-i18n-aether-proxy-zh-cn'
for channel in ('ch1', 'ch2'):
    directory = root / channel
    path = directory / 'manifest.json'
    manifest = json.loads(path.read_text())
    if scenario == 'backend-no-asset':
        manifest['packages']['aether-proxy']['current']['assets'] = {}
    if scenario == 'app-no-current':
        manifest['packages'][app]['current'] = None
    if scenario == 'i18n-no-asset':
        manifest['packages'][i18n]['current']['assets'] = {}
    if scenario == 'app-all-asset':
        del manifest['packages'][app]['current']['assets']['aarch64_generic']
    if scenario == 'app-download-fails':
        for assets in manifest['packages'][app]['current']['assets'].values():
            for asset in assets.values():
                (directory / asset['url']).unlink()
    corrupt = {'i18n-hash-fails': i18n, 'first-failure': i18n,
               'backend-hash-fails': 'aether-proxy'}.get(scenario)
    if corrupt:
        for assets in manifest['packages'][corrupt]['current']['assets'].values():
            for asset in assets.values():
                asset['sha256'] = '0' * 64
    path.write_text(json.dumps(manifest))
