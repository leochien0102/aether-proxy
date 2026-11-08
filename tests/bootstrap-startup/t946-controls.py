#!/usr/bin/env python3
"""Causal sampling/field/timestamp controls, using real daemon and unchanged bounds.

Only temporary fixture/module copies change. No live product source mutation,
new signal protocol, model daemon, clock setting or increased sleep is involved.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
FIXTURE = ROOT / 'tests/daemon/stop-state.py'
EXPECTED = 'AssertionError: probe: stopping preserves every other field and TERM timestamp'
ENV = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', T946_SCENARIO='probe',
           T946_FORCE_WALL_BOUNDARY='1', T946_DELAY_STOP_SAMPLE='1')


def execute(script, env, label):
    result = subprocess.run(['python3', str(script)], cwd=ROOT, env=env,
                            text=True, capture_output=True, timeout=90)
    (HERE / '.logs' / f't946-control-{label}.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 1 and EXPECTED in result.stderr, (
        label, result.returncode, result.stdout, result.stderr)
    print('PASS  T9.46 negative ' + label + ': ' + EXPECTED, flush=True)


with tempfile.TemporaryDirectory(prefix='.runtime-t946-', dir=HERE) as temporary:
    base = Path(temporary)
    # Restore only the old second read after a successful state predicate. The
    # consumer pause deterministically makes that old read observe stopped.
    source = FIXTURE.read_text()
    root = 'ROOT = Path(__file__).resolve().parents[2]'
    assert source.count(root) == 1
    source = source.replace(root, f'ROOT = Path({str(ROOT)!r})')
    boundary = "\t\t\t\tterm_events = [json.loads(line) for line in"
    assert source.count(boundary) == 1
    source = source.replace(boundary,
        "\t\t\t\tstopping = fixture.state()\n"
        "\t\t\t\tfixture.observations.update(stopping=stopping, stopping_sampled=stamp())\n" + boundary)
    old_sampler = base / 'old-sampler.py'
    old_sampler.write_text(source)
    execute(old_sampler, ENV, 'old-second-read')

    # Both mutations must still fail the original equality/timestamp assertion;
    # using a handler-entry snapshot must not make the oracle self-fulfilling.
    for label, old, new in (
            ('drop-components', "\tobj.state = 'stopping';", "\tobj.state = 'stopping';\n\tdelete obj.components;"),
            ('wrong-since', '\tobj.since = received_at;', '\tobj.since = received_at + 2;')):
        modules = base / label
        shutil.copytree(ROOT / 'aether-proxy/src/lib', modules)
        daemon = modules / 'daemon.uc'
        text = daemon.read_text()
        assert text.count(old) == 1
        daemon.write_text(text.replace(old, new))
        execute(FIXTURE, dict(ENV, T946_SOURCE_DIR=str(modules)), label)

result = subprocess.run(['python3', str(FIXTURE)], cwd=ROOT, env=ENV,
                        capture_output=True, text=True, timeout=90)
(HERE / '.logs/t946-control-restored.log').write_text(result.stdout + result.stderr)
assert result.returncode == 0, result.stdout + result.stderr
print('PASS  T9.46 restored matched-snapshot oracle under the same delayed consumer and wall boundary', flush=True)
