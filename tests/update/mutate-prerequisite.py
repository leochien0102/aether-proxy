#!/usr/bin/env python3
"""T13: run three deliberately broken implementations, always restore the source."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
source = root / 'aether-proxy/src/lib/update.uc'
original = source.read_bytes()
mutations = [
    ('pkg_ok', 'return run_ok && pkg_ok;', 'return run_ok;',
     'FAIL  M4-03b T3 prerequisite transaction'),
    ('exact_recovery', 'if (prior == null || prior.version != installed.version)',
     'if (prior == null)', 'FAIL  M4-03b T7 prerequisite transaction'),
    ('engine_order', 'let transaction = prerequisite_prepare(opts, selected, plat);',
     'let transaction = { ok: true };', 'FAIL  M4-03b T10 prerequisite transaction'),
]
try:
    for name, before, after, expected in mutations:
        text = original.decode()
        assert text.count(before) == 1, name
        text = text.replace(before, after)
        if name == 'engine_order':
            anchor = 'let result = transaction.ok ? install() : transaction;'
            assert text.count(anchor) == 1
            text = text.replace(anchor, anchor + '\n\ttransaction = prerequisite_prepare(opts, selected, plat);'
                                + '\n\tprerequisite = transaction.prerequisite ?? fallback;')
        source.write_text(text)
        outcome = subprocess.run(['bash', 'tests/update/run.sh'], cwd=root, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        assert outcome.returncode != 0 and expected in outcome.stdout, outcome.stdout
        print(f'PASS  M4-03b T13 {name}: exit {outcome.returncode}; {expected}', flush=True)
        source.write_bytes(original)
        assert source.read_bytes() == original
        print(f'PASS  M4-03b T13 {name}: original bytes restored', flush=True)
finally:
    source.write_bytes(original)
