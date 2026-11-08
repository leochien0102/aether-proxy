#!/usr/bin/env python3
"""Explicitly archive selected diagnostics; acceptance never rewrites these files."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DEST = HERE / 'evidence'
DEST.mkdir(exist_ok=True)


def concatenated(text):
    values = []
    decoder = json.JSONDecoder()
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        values.append(value)
        text = text[end:]
    return values


for name, filename in [('old-second-read', 't946-control-old-second-read.log'),
                       ('matched-snapshot', 't946-fixed-sampling.log')]:
    output = (HERE / '.logs' / filename).read_text()
    directory = Path(re.search(r'T9.46 (?:failure|success) evidence: (.+)', output)[1])
    observation = json.loads((directory / 'observation.json').read_text())
    term = [json.loads(s) for s in (directory / 'term-handled.jsonl').read_text().splitlines()]
    trajectory = [json.loads(s) for s in (directory / 'state-events.jsonl').read_text().splitlines()]
    writes = concatenated((directory / 'writes.jsonl').read_text())
    stopping = next(e['value'] for e in trajectory if e['kind'] == 'write_completed' and
                    e['result'] and e['value']['state'] == 'stopping')
    before = observation['before']
    unchanged = lambda value: {k: v for k, v in value.items() if k not in ('state', 'since')}
    files = ['observation.json', 'term-handled.jsonl', 'state-events.jsonl', 'writes.jsonl',
             'stdout', 'stderr', 'calls.log']
    bundle = dict(production_baseline='830cc8e', variant=name,
        conditions=dict(actual_daemon=True, synthetic_proc_fixture=True, wall_boundary_before_TERM=True,
                        consumer_paused_until_stopped=True, production_source_mutated=False),
        normalization='Only absolute worktree prefix replaced with $WORKTREE; values/times not altered.',
        observation=observation, term_handler_events=term, full_state_trajectory=trajectory,
        actual_write_values=writes,
        stdout=(directory / 'stdout').read_text(), stderr=(directory / 'stderr').read_text(),
        calls=(directory / 'calls.log').read_text(),
        raw_sha256={f: hashlib.sha256((directory / f).read_bytes()).hexdigest() for f in files},
        interpretation=dict(production_stopping_preserves_all_other_fields=unchanged(stopping) == unchanged(before),
            original_since_bound_holds=observation['term_at'] <= stopping['since'] <= observation['term_at'] + 1,
            controller_before_equals_handler_before=observation['controller_before'] == before,
            matched_state=observation['matched_stopping']['state'],
            compared_state=observation['stopping']['state'], final_state=observation['final_state']['state']))
    text = json.dumps(bundle, indent=2).replace(str(ROOT), '$WORKTREE') + '\n'
    (DEST / f't946-{name}.json').write_text(text)
    print(name, bundle['interpretation'])
