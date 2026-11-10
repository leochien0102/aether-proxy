#!/usr/bin/env python3
"""M4-04: observe real updater boundaries in isolated package/init stubs."""
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['UPDATE_EVENT_ROOT'])
kind, original, *args = sys.argv[1:]
events = root / 'run/events.jsonl'
if kind == 'package' and args and args[0] in ('install', 'add'):
    filename = Path(args[-1]).name.removeprefix('new-')
    packages = ('luci-i18n-aether-proxy-zh-cn', 'luci-app-aether-proxy',
                'aether-proxy', 'aether-xray', 'aether-dns')
    package = next(p for p in packages if filename.startswith(p + '_') or filename.startswith(p + '-'))
    with events.open('a') as stream:
        stream.write(json.dumps({'code': 'TEST_INSTALL', 'args': {'package': package}}) + '\n')
if kind == 'init' and args == ['restart']:
    # The isolated init stub models the daemon's lifecycle events; no device is restarted.
    with events.open('a') as stream:
        for code in ('SERVICE_STOPPED', 'SERVICE_STARTED'):
            stream.write(json.dumps({'code': code, 'args': {}}) + '\n')
os.execv(original, [original, *args])
