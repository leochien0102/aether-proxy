# T15.5 reference-driven Xray readiness

Run from the worktree: `bash tests/xray-ready/run.sh`.
Requires the existing host ucode bootstrap and Python 3; no root, external DNS,
service changes, downloads or fixed host ports.

- `run.py` + `driver.uc`: the real production `xray_ready` module observes real
  loopback listeners, child PID/starttime and `/proc/PID/fd` inodes. `listener.py`
  only binds/listens/accepts without payload; it never implements the gate.
  Dynamic addresses/ports are also exercised through renderer-artifact mapping
  in the pure unit case. No production constants are overridden.
- Explicitly labelled proc-fixture subcases cover TCP non-LISTEN states, missing
  FD/inode, malformed tables and PID reuse. Both ownership and network tables
  come from the same rooted fixture, never a mixture with the host.
- `lifecycle.py`: actual daemon/supervise/reload/monitor flows, but **synthetic
  proc/socket data** from `tests/stubs/daemon-bin/xray`, not real Xray sockets.
  It accelerates only the monitor refresh schedule and injects one state-write
  failure in copied modules. Startup, tier choice, rendering, child replacement,
  requirements, ownership checks, cancellation and rollback remain production.
  Tests hold referenced DNS absent/delayed, rather than prewriting ready markers.
- `tests/unit/xray_ready.uc`: automatically discovered renderer-reference and
  strict tcp/tcp6/udp/udp6 parsing tests.

`python3 tests/xray-ready/mutations.py` temporarily mutates only this worktree's
`xray_ready.uc`, requires the exact named assertion failure for each mutation,
restores it in `finally`, then reruns the entire entry point. Do not run it
concurrently with any other suite. Logs go to ignored `.logs/`.

`evidence/` contains the final independent entry point and mutation summaries.
The task report records separate legacy suite outcomes and formal review.
None of these results constitute device acceptance or the later B3 startup
reordering/bootstrap implementation.
