#!/usr/bin/env python3
"""B24: exercise check/start gates through the shared component selector (docs/05, 08)."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('version_gate', ROOT / 'tests/daemon/version-gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T10.73 ' + name, flush=True)


with tempfile.TemporaryDirectory(prefix='.aether-xray-', dir=ROOT / 'tests/cli') as temp:
    for mode in ('preferred-new', 'preferred-old', 'fallback', 'explicit'):
        f = gate.Fixture(Path(temp), mode, 'xray', '26.3.26')
        preferred = f.bin / 'aether-xray'
        preferred.write_text('#!/bin/sh\nif [ "$1" = version ]; then\n'
                             + ' printf "Xray ' + ('26.3.26' if mode == 'preferred-old' else '26.10.21')
                             + '\\n"\nelse\n exec "$(dirname "$0")/xray-original" "$@"\nfi\n')
        preferred.chmod(0o755)
        if mode == 'fallback':
            preferred.unlink()
        if mode == 'preferred-old':
            (f.root / 'xray-banner').write_text('Xray 99.1.1\n')
        if mode == 'explicit':
            config = f.root / 'etc/config/aetherproxy'
            config.write_text(config.read_text().replace("config main 'main'\n",
                              "config main 'main'\n option xray_bin '" + str(f.bin / 'xray') + "'\n"))
        old = mode != 'preferred-new'
        selected = preferred if mode.startswith('preferred') else f.bin / 'xray'
        result = subprocess.run([str(gate.UCODE), '-S', str(gate.ENTRY), '--', 'check', '--json',
                                 *f.args, '--run-dir', str(f.run)], env=f.env,
                                capture_output=True, text=True, timeout=16)
        value = json.loads(result.stdout)
        check(mode + ' check succeeds', result.returncode == 0 and value['ok'] and not result.stderr)
        check(mode + ' check validates actual binary', value['validation']['xray']['path'] == str(selected))
        warnings = [w for w in value['warnings'] if w['code'] == 'COMPONENT_TOO_OLD']
        check(mode + ' check gates actual version', bool(warnings) == old)
        with f.daemon() as child:
            f.wait_started(child)
            state = f.state()
            check(mode + ' daemon gates actual binary', state['state'] == ('error' if old else 'running'))
            if not old:
                component = state['components']['xray']
                check(mode + ' daemon persists owned path and base version',
                      component['path'] == str(selected) and component['version'] == '26.10.21')
            else:
                check(mode + ' daemon reports actual old version', any(
                    e['code'] == 'COMPONENT_TOO_OLD' and e['args']['version'] == '26.3.26'
                    for e in f.events()))

# The node preflight must keep delegating discovery instead of gaining its own stale path rule.
node = (ROOT / 'aether-proxy/src/lib/cmd/node.uc').read_text()
check('node preflight delegates actual binary selection',
      'check.find_component(C.XRAY_COMPONENT,' in node and "[ binary.path, 'run', '-test'" in node)
