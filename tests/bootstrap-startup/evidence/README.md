# T9.46 probe sampling investigation

Production baseline: `830cc8e`. No production source changed in this follow-up.

- `t946-old-second-read.json`: a real daemon + rooted proc fixture with only the
  previous second-read sampling restored. After the state predicate matched
  `stopping`, the controller was held until the legitimate final `stopped`
  publication. This deterministically models controller descheduling, not a
  fake state write. The unchanged field/time assertion failed. Both the old
  controller-before and handler-before snapshots agree in this capture.
- `t946-matched-snapshot.json`: the same wall-boundary and delayed-consumer
  conditions with the corrected matching-snapshot consumer; all original
  stop-state oracles pass.

Both contain full before/matched/compared/final snapshots, recursive field
changes, TERM send/return/handler times, complete request/entry/completion state
write trajectory, attempted-but-blocked state requests, original committed
write values, calls/stdout/stderr and raw artifact SHA256s. Only the absolute
worktree prefix is normalized to `$WORKTREE`; state values and times are not
edited. Raw artifacts remain under the local ignored `.logs/` paths recorded by
the diagnostic runs. These are controlled causal counterexamples, not a claim
that the reviewer's exact naturally occurring failure was independently captured.

The old consumer compared `stopped` against `running` and reported missing
components/node/monitor/render/probe fields. The actual intervening `stopping`
write preserved every non-state/since field and satisfied the original since
window. This distinguishes the demonstrated sampling race from a product
stopping-state regression or a wall-clock-bound failure.

Reproduce the causal controls (temporary copies only):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/bootstrap-startup/t946-controls.py
```

This requires three precise assertion failures: old second read, product
`components` deletion, and product `since + 2`; then requires the unmodified
product to pass with matched sampling under the same pause. Nothing weakens or
skips the original equality/timestamp assertions or increases their deadlines.

Positive adversarial run with evidence capture:

```sh
PYTHONDONTWRITEBYTECODE=1 T946_SCENARIO=probe \
T946_FORCE_WALL_BOUNDARY=1 T946_DELAY_STOP_SAMPLE=1 T946_SAVE_SUCCESS=1 \
python3 tests/daemon/stop-state.py
```

The wall-boundary control holds the already-held synchronous probe until a wall
second changes **before TERM is sent**. It does not extend the one-second stop
observation or the original timestamp window. The consumer pause is after the
successful stopping observation, explicitly waiting for final stopped to prove
that observation is retained. This pause shares the original 12-second exit
budget with the final child wait; it does not add another exit-time allowance.
The old arbitrary 0.1-second post-send sleep is
removed; no extra sleep is used to obtain success.

`collect-t946-evidence.py` explicitly archives selected local evidence; normal
acceptance never overwrites the committed JSON files.
