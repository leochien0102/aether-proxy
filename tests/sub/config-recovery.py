#!/usr/bin/env python3
"""T16.112: legacy credential conflicts must not trigger startup backup recovery."""
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location('version_gate', ROOT / 'tests/daemon/version-gate.py')
fixture = module_from_spec(spec)
spec.loader.exec_module(fixture)
passed = 0


def check(name, ok):
    global passed
    assert ok, name
    passed += 1
    print('PASS  T16.112 recovery ' + name, flush=True)


def prepare(f):
    script = """import * as sub from 'aetherproxy.sub';
let opts = sub.absolute_options({ sys_root: ARGV[0] });
print(sprintf('%J', sub.prepare_config({ root: ARGV[0], opts })));
"""
    p = subprocess.run([str(fixture.UCODE), '-e', script, '--', str(f.root)],
                       env=f.env, capture_output=True, text=True, timeout=15)
    assert p.returncode == 0 and not p.stderr, 'prepare_config execution failed'
    return json.loads(p.stdout)


def conflict(errors):
    return any(e.get('field') == 'main.proxy_credentials'
               and e.get('code') == 'migration_conflict' for e in errors)


with tempfile.TemporaryDirectory(prefix='.config-recovery-', dir=ROOT / 'tests/sub') as temp:
    for name, http, extra in (
        ('different-pairs', "option http_username 'other'\n option http_password 'other-secret'", ''),
        ('partial-legacy', "option http_username 'legacy'", ''),
        ('partial-shared', "option http_username 'other'\n option http_password 'other-secret'",
         "option proxy_username 'chosen'"),
        ('other-error', "option http_username 'other'\n option http_password 'other-secret'",
         "option socks_port 'invalid'"),
    ):
        f = fixture.Fixture(Path(temp), name, 'xray', '26.3.27')
        config = f.root / 'etc/config/aetherproxy'
        backup = f.root / 'etc/aether-proxy/config.backup'
        base = config.read_text()
        legacy = """ option socks_enabled '1'
 option socks_username 'legacy'
 option socks_password 'legacy-secret'
"""
        # The backup has identical legacy pairs and is valid under the new contract.
        backup.write_text(base.replace("config main 'main'", "config main 'main'\n" + legacy
                          + " option http_username 'legacy'\n option http_password 'legacy-secret'"))
        config.write_text(base.replace("config main 'main'", "config main 'main'\n" + legacy
                          + ' ' + http + '\n ' + extra))
        original, saved = config.read_bytes(), backup.read_bytes()
        valid = subprocess.run([str(fixture.UCODE), '-e', """import * as sub from 'aetherproxy.sub';
import * as fs from 'fs';
let opts = sub.absolute_options({ sys_root: ARGV[0] });
print(sub.load_committed_config({root: ARGV[0], opts}, fs.readfile(ARGV[1])).ok);
""", '--', str(f.root), str(backup)], env=f.env, capture_output=True, text=True, timeout=15)
        check(name + ' backup is independently valid', valid.returncode == 0
              and valid.stdout == 'true' and not valid.stderr)
        for attempt in range(2):
            result = prepare(f)
            check(name + f' prepare attempt {attempt + 1} rejects conflict',
                  not result['ok'] and result['code'] == 'CONFIG_INVALID'
                  and conflict(result['errors']))
            check(name + f' prepare attempt {attempt + 1} preserves live and backup bytes',
                  config.read_bytes() == original and backup.read_bytes() == saved)
        with f.daemon() as child:
            f.wait_started(child)
            check(name + ' startup fails at config without recovery',
                  f.state().get('state') == 'error' and f.state().get('failed_step') == 'config'
                  and f.state().get('last_error') == 'CONFIG_INVALID'
                  and not any(e['code'] == 'CONFIG_RECOVERED' for e in f.events())
                  and any(e['code'] == 'CONFIG_INVALID'
                          and e['args'].get('field') == 'main.proxy_credentials'
                          and e['args'].get('reason') == 'migration_conflict' for e in f.events()))
            check(name + ' startup preserves live and backup without system commands',
                  config.read_bytes() == original and backup.read_bytes() == saved
                  and not f.calls.read_text() and not (f.run / 'current').exists())
        # A complete explicit shared pair resolves the ambiguity; normal backup resumes.
        resolved = original.decode().replace("config main 'main'", "config main 'main'\n"
                                            + " option proxy_username 'chosen'\n"
                                            + " option proxy_password 'chosen-secret'")
        if name == 'other-error':
            resolved = resolved.replace("option socks_port 'invalid'", "option socks_port '1080'")
        if name == 'partial-shared':
            # Avoid duplicate UCI options; keep the originally chosen username.
            resolved = resolved.replace(" option proxy_username 'chosen'", '', 1)
        config.write_text(resolved)
        check(name + ' explicit resolution permits normal validated backup',
              prepare(f)['ok'] and backup.read_bytes() == config.read_bytes())

print(f'T16.112 recovery: {passed} passed, 0 failed', flush=True)
