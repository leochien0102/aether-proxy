#!/usr/bin/env python3
"""T10.4: real CLI inventory, isolated binaries/config/events; no router needed."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'aether-proxy/src/lib'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
PREFIX = ROOT / 'tests/host/prefix'


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T10.4 components: ' + name, flush=True)


with tempfile.TemporaryDirectory(prefix='.components-', dir=ROOT / 'tests/cli') as temp:
    base = Path(temp)
    binaries = base / 'bin'
    config = base / 'config'
    run = base / 'run'
    for directory in (binaries, config, run):
        directory.mkdir()

    # Copy modules, changing only the runtime constant so an accidental event write
    # is observed in our private directory instead of touching the host's /var/run.
    modules = base / 'modules/aetherproxy'
    shutil.copytree(LIB, modules)
    constants = modules / 'const.uc'
    text = constants.read_text()
    text, count = re.subn(r"export const RUN_DIR = '[^']+';",
                          f"export const RUN_DIR = '{run}';", text)
    assert count == 1
    # Keep the production absolute-path ordering without touching the host /usr/bin.
    text = text.replace("'/usr/bin/aether-xray'", repr(str(binaries / 'aether-xray')))
    text = text.replace("'/usr/bin/xray'", repr(str(binaries / 'xray')))
    constants.write_text(text)
    env = dict(os.environ, LD_LIBRARY_PATH=str(PREFIX / 'lib'), PATH=str(binaries))
    command = [str(PREFIX / 'bin/ucode'), '-L', str(base / 'modules/*.uc'),
               '-L', str(PREFIX / 'lib/ucode/*.so'), '-S', str(ENTRY), '--', 'components']

    def binary(name, body):
        file = binaries / name
        file.write_text('#!/bin/sh\n' + body + '\n')
        file.chmod(0o755)
        return str(file)

    def invoke(*extra, expected=0):
        # sys.run needs standard shell tools; binary lookup remains isolated by PATH
        # through a dedicated helper directory containing no real proxy binaries.
        result = subprocess.run(command + ['--json', '--confdir', str(config), *extra],
                                env=env, capture_output=True, text=True, timeout=12)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        assert result.stderr == '', result.stderr
        # json.loads rejects an extra object or any stray output on stdout.
        value = json.loads(result.stdout)
        assert isinstance(value, dict)
        assert list(run.iterdir()) == [], 'read-only discovery wrote an event/runtime file'
        return value

    # sys.run invokes these by name, but no system proxy binary can leak into lookup.
    for tool in ('sh', 'sleep', 'setsid', 'mktemp', 'rm', 'cat', 'kill'):
        executable = shutil.which(tool)
        if executable:
            (binaries / tool).symlink_to(executable)

    xray = binary('xray', '[ "$1" = version ] || exit 8\nprintf "Xray 26.9.30 extra\\nignored line\\n"')
    dns = binary('chinadns-ng', '[ "$1" = -V ] || exit 9\nprintf "chinadns-ng 2025.06.20 extra\\n"')
    both = invoke('--bin-dir', str(binaries))
    check('both found with exact paths and parsed versions', both == {
        'ok': True, 'components': {
            'xray': {'found': True, 'path': xray, 'version': '26.9.30'},
            'chinadns-ng': {'found': True, 'path': dns, 'version': '2025.06.20'}
        }
    })
    check('T10.73 xray alone remains a read-only fallback',
          invoke()['components']['xray'] == both['components']['xray'])
    check('missing configuration uses default component paths', invoke() == both)
    (config / 'aetherproxy').write_text('not a valid UCI file\n')
    check('unreadable configuration uses default component paths', invoke() == both)
    (config / 'aetherproxy').unlink()
    (binaries / 'chinadns-ng').unlink()
    missing = invoke('--bin-dir', str(binaries))['components']['chinadns-ng']
    check('missing chinadns-ng has null path/version', missing == {
        'found': False, 'path': None, 'version': None
    })

    configured = base / 'configured-xray'
    configured.write_text('#!/bin/sh\nprintf "Xray configured\\n"\n')
    configured.chmod(0o755)
    (config / 'aetherproxy').write_text(f"config main 'main'\n\toption xray_bin '{configured}'\n")
    check('configured executable takes precedence over PATH', invoke()['components']['xray'] == {
        'found': True, 'path': str(configured), 'version': 'configured'
    })
    configured.chmod(0o644)
    check('configured non-executable is not found despite PATH binary', invoke()['components']['xray'] == {
        'found': False, 'path': None, 'version': None
    })
    (config / 'aetherproxy').unlink()

    preferred = binary('aether-xray', 'printf "Xray 26.10.21 extra\\n"')
    check('T10.73 both binaries prefer aether-xray path and base version',
          invoke('--bin-dir', str(binaries))['components']['xray'] == {
              'found': True, 'path': preferred, 'version': '26.10.21'
          })
    check('T10.73 absolute owned path precedes a PATH fallback',
          invoke()['components']['xray'] == {
              'found': True, 'path': preferred, 'version': '26.10.21'
          })
    (config / 'aetherproxy').write_text(f"config main 'main'\n\toption xray_bin '{configured}'\n")
    configured.chmod(0o755)
    check('T10.73 explicit path overrides both binaries even with bin-dir',
          invoke('--bin-dir', str(binaries))['components']['xray']['path'] == str(configured))
    (config / 'aetherproxy').unlink()
    (binaries / 'xray').unlink()
    check('T10.73 aether-xray alone is found',
          invoke('--bin-dir', str(binaries))['components']['xray']['path'] == preferred)
    binary('aether-xray', 'exec sleep 30')
    started = time.monotonic()
    timed = invoke('--bin-dir', str(binaries))['components']['xray']
    check('T10.73 owned binary timeout preserves actual path and null version', timed == {
        'found': True, 'path': preferred, 'version': None
    } and 2.5 <= time.monotonic() - started < 5.5)
    (binaries / 'aether-xray').unlink()
    check('T10.73 neither binary has null path/version',
          invoke('--bin-dir', str(binaries))['components']['xray'] == {
              'found': False, 'path': None, 'version': None
          })

    binary('xray', 'printf "Xray invalid\\n"\nprintf "failure\\n" >&2\nexit 7')
    failed = invoke('--bin-dir', str(binaries))['components']['xray']
    check('nonzero version exit preserves found/path with null version', failed == {
        'found': True, 'path': xray, 'version': None
    })
    for output in ('', 'unparseable'):
        binary('xray', f'printf "{output}\\n"')
        check('unparseable banner preserves found/path (' + repr(output) + ')',
              invoke('--bin-dir', str(binaries))['components']['xray'] == failed)

    binary('xray', 'exec sleep 30')
    started = time.monotonic()
    timed = invoke('--bin-dir', str(binaries))['components']['xray']
    elapsed = time.monotonic() - started
    check('hung version times out at 3s with found true and null version',
          timed == failed and 2.5 <= elapsed < 5.5)
    print(f'INFO  T10.4 components: timeout elapsed {elapsed:.2f}s', flush=True)
    check('positional and unsupported options are USAGE', all(
        invoke(*args, expected=2).get('code') == 'USAGE'
        for args in [('unexpected',), ('--run-dir', str(run)), ('--no-precheck',), ('--confdir',)]
    ))
    check('every invocation emits one JSON object, empty stderr and no events', True)

source = (LIB / 'daemon.uc').read_text()
check('daemon delegates both version reads without defining a duplicate',
      not re.search(r'function\s+read_component_version\s*\(', source)
      and source.count('components_cmd.read_component_version(') == 2)
check('shared helper keeps daemon timeout and quiet behavior',
      'timeout ?? C.COMPONENT_VERSION_TIMEOUT_SECS, quiet: true' in (LIB / 'cmd/components.uc').read_text())
# docs/12 rule 1: command execution only in cmd/*, daemon, sys, state, data.
check('version parsing module stays free of commands',
      'aetherproxy.sys' not in (LIB / 'component_version.uc').read_text())
