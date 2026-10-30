#!/usr/bin/env python3
"""T10.70: exercise recovery through actual daemon startup, not only its helper."""
from importlib.util import module_from_spec, spec_from_file_location
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location('version_gate', ROOT / 'tests/daemon/version-gate.py')
fixture = module_from_spec(spec)
spec.loader.exec_module(fixture)


def check(name, ok):
    assert ok, name
    print('PASS  T10.70 daemon ' + name, flush=True)


with tempfile.TemporaryDirectory(prefix='.recovery-', dir=ROOT / 'tests/daemon') as temp:
    for valid_backup in (True, False):
        f = fixture.Fixture(Path(temp), str(valid_backup), 'xray', '26.3.27')
        config = f.root / 'etc/config/aetherproxy'
        backup = f.root / 'etc/aether-proxy/config.backup'
        original = config.read_bytes()
        backup.write_bytes(original if valid_backup else b'config invalid backup !!\n')
        config.write_text("config global 'main'\n option enabled '1'\n")
        invalid = config.read_bytes()
        residue = config.with_name(config.name + '.tmp.dead')
        residue.write_text('partial')
        with f.daemon() as child:
            f.wait_started(child)
            events = [e for e in f.events() if e['code'] == 'CONFIG_RECOVERED']
            if valid_backup:
                check('valid backup resumes running', f.state().get('state') == 'running'
                      and config.read_bytes() == original and not residue.exists())
                check('recovery logs one WARN path', len(events) == 1 and events[0]['level'] == 'warn'
                      and events[0]['args'] == {'path': str(config)})
                for _ in range(2):
                    p = subprocess.run([str(fixture.UCODE), '-S', str(fixture.ENTRY), '--', 'status',
                                        '--json', *f.args[:6], '--run-dir', str(f.run)],
                                       env=f.env, text=True, capture_output=True, timeout=15)
                    assert p.returncode == 0, p.stderr
                check('status polling never repeats recovery',
                      len([e for e in f.events() if e['code'] == 'CONFIG_RECOVERED']) == 1)
            else:
                check('invalid backup retains original CONFIG_INVALID', not events
                      and config.read_bytes() == invalid and f.state().get('last_error') == 'CONFIG_INVALID'
                      and any(e['code'] == 'CONFIG_INVALID' and e['args']['field'] == 'main.node'
                              for e in f.events()))
