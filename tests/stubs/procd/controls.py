#!/usr/bin/env python3
"""Three precise reverse controls, only in temporary copies of the packaged init."""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
source = (ROOT / 'aether-proxy/files/aether-proxy.init').read_text()
controls = (
    ('hook-masked', '\t[ "$rc" -ne 0 ] || rc="$_AETHER_PROXY_STOPPED_HOOK_RC"\n', '',
     ('FAIL  I2 intent cleanup=0: external stop rc',
      'FAIL  I2 mark-create cleanup=0: external stop rc')),
    ('no-stop-term-mask', "\ttrap '' TERM\n", '',
     ('FAIL  I5 enabled=0 cleanup=0: TERM ignored during stop (resumed trace)',
      'FAIL  I5 enabled=1 cleanup=37: TERM ignored during stop (resumed trace)')),
    ('no-term-restore', '\ttrap - TERM\n', '',
     ('FAIL  I5 enabled=0 cleanup=0: default TERM restored at start',
      'FAIL  I5 enabled=1 cleanup=37: default TERM restored at returned')),
)
for name, old, new, assertions in controls:
    assert old in source, name
    # replace all covers both enabled restart branches, without touching source/worktree init.
    with tempfile.TemporaryDirectory(prefix='.control-', dir=HERE) as tmp:
        init = Path(tmp) / 'init'
        init.write_text(source.replace(old, new))
        result = subprocess.run(['python3', str(HERE / 'contract.py')],
                                env=dict(os.environ, CONTRACT_INIT=str(init)),
                                capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    (HERE / 'evidence' / (name + '.log')).write_text(output)
    if result.returncode != 1 or not all(item in output for item in assertions):
        print(f'FAIL  reverse control {name}: exit={result.returncode}\n{output}')
        raise SystemExit(1)
    if 'Traceback' in output or '<timeout>' in output:
        raise SystemExit(f'FAIL  reverse control {name}: unrelated harness error')
    print(f'PASS  reverse control {name}: exit=1, exact assertions:')
    for item in assertions:
        print('  ' + item)
