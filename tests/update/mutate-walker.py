#!/usr/bin/env python3
"""W7: temporarily break handoff / hop cap / progress and require real assertions to fail."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
path = root / 'aether-proxy/src/lib/update.uc'
original = path.read_text()
logs = root / '.cache/m407'
logs.mkdir(parents=True, exist_ok=True)
mutations = {
    'handoff': [(
        'return continue_chain(opts, ctx, name, installed.version, plan.next.version, limit - 1);',
        'return result;')],
    'cap': [
        ('if (limit <= 0)', 'if (false)'),
        ('if (!version_newer(installed, before) || remaining <= 0)',
         'if (!version_newer(installed, before))')],
    'progress': [(
        "if (!installed.ok || type(installed.version) != 'string' || !version_newer(installed.version, before))",
        'if (!installed.ok)')],
}
expected = {
    'handoff': 'FAIL  M4-07 W1 inventory, handoff, events and result',
    'cap': 'FAIL  M4-07 W7-cap inventory, handoff, events and result',
    'progress': 'FAIL  M4-07 W7-progress inventory, handoff, events and result',
}
try:
    for name, changes in mutations.items():
        modified = original
        for old, new in changes:
            assert modified.count(old) == 1, (name, old)
            modified = modified.replace(old, new)
        path.write_text(modified)
        result = subprocess.run(['bash', 'tests/update/run.sh'], cwd=root,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                timeout=300)
        (logs / f'mutation-{name}.log').write_text(result.stdout)
        assert result.returncode != 0 and expected[name] in result.stdout, (name, result.returncode)
        print(f'PASS  M4-07 W7 mutation {name}: exit={result.returncode}; {expected[name]}', flush=True)
finally:
    path.write_text(original)
