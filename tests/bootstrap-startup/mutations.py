#!/usr/bin/env python3
"""Five exact negative controls; production text is always restored, then rerun."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DAEMON = ROOT / 'aether-proxy/src/lib/daemon.uc'
BOOTSTRAP = ROOT / 'aether-proxy/src/lib/bootstrap.uc'
originals = {p: p.read_text() for p in (DAEMON, BOOTSTRAP)}
resolve = '\tlet resolution = bootstrap.resolve(ctx, snapshot, dns_path, signal_pending);'
stop_guard = ("\t\tif (!handle.reaped)\n"
              "\t\t\treturn failure(`bootstrap exit unconfirmed; retained ${handle.path}`, { cleanup_failed: true });")
orphan_guard = ("\t\tif (!gone)\n"
                "\t\t\treturn failure(`bootstrap old lifecycle still executing; retained ${path}`);")
mutations = [
    ('early-formal', DAEMON, resolve,
     "\tchildren.dns = child_options(ctx, C.CHINADNS_COMPONENT, "
     "[ dns_path, '-C', `${current}/${C.ARTIFACT_FILES.chinadns}` ]);\n"
     '\tchildren.dns.start();\n' + resolve, 'c4',
     'C4 formal DNS dataplane handoff and probes wait for referenced Xray DNS'),
    ('system-resolver', DAEMON, resolve,
     '\tlet resolution = apply.resolve_node(ctx, snapshot.nodes[snapshot.main.node].address);', 'c1',
     'C1 domain without LKG resolves through private endpoint before formal DNS exists'),
    ('early-intent', DAEMON, resolve, '\tapply.restart_intent_clear(ctx);\n' + resolve, 'c10',
     'C10 failed Xray startup keeps intent fragment and zero handoff installs'),
    ('unconfirmed-delete', BOOTSTRAP, stop_guard, '', 'c6',
     'C6 withheld-exit-callback fixture bounded failure preserves generation'),
    ('orphan-continue', BOOTSTRAP, orphan_guard, '\t\tif (!gone) continue;', 'c8',
     'C8 actual daemon SIGKILL orphan retained cleanup fails without signals'),
]
try:
    for name, path, old, new, case, expected in mutations:
        assert originals[path].count(old) == 1, old
        path.write_text(originals[path].replace(old, new))
        result = subprocess.run(['python3', str(HERE / 'run.py')], cwd=ROOT,
            env=dict(os.environ, B3_CASE=case), capture_output=True, text=True, timeout=80)
        (HERE / '.logs' / f'mutation-{name}.log').write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and f'AssertionError: {expected}' in result.stderr, (
            name, result.returncode, result.stdout, result.stderr)
        print(f'PASS  negative {name}: AssertionError: {expected}', flush=True)
        path.write_text(originals[path])
finally:
    for path, text in originals.items():
        path.write_text(text)
restored = subprocess.run(['bash', str(HERE / 'run.sh')], cwd=ROOT, capture_output=True, text=True, timeout=180)
(HERE / '.logs/restored.log').write_text(restored.stdout + restored.stderr)
assert restored.returncode == 0, restored.stdout + restored.stderr
print('PASS  restored full bootstrap-startup entry', flush=True)
