#!/usr/bin/env python3
"""T16.55 old-baseline diagnostic evidence; deliberately not an acceptance oracle."""
import json
from pathlib import Path
import sys

root, manager, mode, scenario, rc, output, start1, start2 = sys.argv[1:]
root = Path(root)
record = dict(manager=manager, mode=mode, scenario=scenario, exit=int(rc),
              result=json.loads(output),
              installs=(root / 'package-calls').read_text().splitlines(),
              inventory={p.name: p.read_text().strip()
                         for p in sorted((root / 'package-inventory').iterdir())},
              requests=[line for n, start in ((1, start1), (2, start2))
                        for line in (root / f'http{n}').read_text().splitlines()[int(start):]
                        if 'GET ' in line])
with (root / 'terminal-evidence.jsonl').open('a') as stream:
    stream.write(json.dumps(record, ensure_ascii=False) + '\n')
print('T16.55 EVIDENCE ' + json.dumps(record, ensure_ascii=False))
