# T15.6 isolated bootstrap startup

Authority: original task `a30d796`, revised resource contract `8e4d6a2`.

```sh
bash tests/bootstrap-startup/run.sh
bash tests/bootstrap-startup/run.sh --mutations
```

The entry builds the pinned aether-dns source snapshot **inside this directory's
ignored `.build/`**, offline and locked; it reads the existing fixed chinadns-ng
asset and verifies its SHA256. No downloads, package installs, real system DNS,
nft/route changes, init changes or router access. Missing assets fail rather than
printing a synthetic PASS. Provenance and temporary negative-control logs go in
`.logs/`; runtime roots are removed after experiments.

## Evidence classes

- **Real DNS engines, sockets and production modules:** `real`, `parallel`,
  `query_loss`, and the real-engine portions of `failures` use production
  `bootstrap.uc`, B1, B2 and `supervise.uc` against actual proc/FD/socket state.
  Both engines exchange with controlled loopback UDP/TCP upstreams. The suite
  verifies DNS-first/LKG, literal bypass, full stop, callback authorization,
  no respawn, sibling isolation, FD stability, unsupported aether TLS, real port
  competition and disappearance. TLS transport for the wolfssl fallback remains
  the S15.3 evidence; no new PKI/DoT claim is made here.
- **Actual daemon + synthetic proc fixture:** `c1/c4/c7/c8/c9/c10/c11/stop_block`
  run the real daemon, frozen rendering, supervisors, B1 and readiness calls.
  `tests/stubs/daemon-bin` substitutes nft/ip/dnsmasq/Xray/formal DNS. Xray and
  formal DNS ownership tables are explicitly rooted fixtures; private query
  sockets are real. No fixture borrows host proc to satisfy rooted B2 readiness.
  Private lifecycle/residue identity uses real proc, as supervision does.
- **Explicit fault fixtures:** `unconfirmed` and `stop_block` withhold completion
  delivery even though the real child has exited/reaped. This demonstrates the
  bounded failure/evidence-retention branch, not a real D-state experiment.
  PID reuse is a consistent metadata fixture pointing to a real unrelated
  same-argv-name process with another starttime, not forced kernel PID reuse.
  PID/config write failures and forced first/always-occupied candidates change
  only temporary source copies at the OS boundary/endpoint selection. All
  resource, resolver and readiness decisions still execute production code.
- **Pure contracts:** `tests/unit/bootstrap.uc` checks complete boot syntax/order
  and absence of ordinary groups/lists/sets/handoff. It is not network evidence.
- **Minimal installed-module execution:** a copy offers only fs/log/socket/uci/
  uloop, restricts compile-time and runtime search paths and rejects both struct
  require/import. The same environment actually executes private start/B1/stop;
  the existing B2 minimal entry also reruns its endian/ELF/FD negative controls.
- **Queued native interval/stop sampling:** original T9.46 field/time and late-write
  oracles run in normal, wall-boundary-before-TERM and delayed-consumer variants,
  not three retries to obtain a pass. The predicate returns its matched snapshot;
  no second read may confuse final stopped with stopping. Fields are compared
  against an independently recorded last publication at TERM handler entry.
  A complete timestamped write trajectory and both controller/handler snapshots
  are saved on failure. The daemon's existing cancelled-interval retention fix
  remains unchanged; no host/library rebuild or LD_PRELOAD is used by acceptance.
  See `evidence/README.md` for the real-daemon counterexample and negative controls.

C8 deliberately leaves the real orphan alive while production cleanup and the
next daemon refuse it. Historical PIDs receive **no production signals**. Only
the harness then ends its isolated experiment session; that action is not a
production recovery PASS and is never described as non-parent wait. Owned files
are cleaned only after old execution has ceased; incomplete records/external
entries stay retained. Explicit cleanup must still release owned DNS handoff
when init's manual stop/disable has cleared restart intent, while returning a
private-residue failure rather than falsely publishing stopped.

Private output is explicitly inherited (`respawn:false, inherit_output:true`),
so a private generation owns exactly one engine child and no background awk
reader/FIFO. Formal log filtering and crash backoff remain the old defaults.

## Negative controls

`mutations.py` temporarily changes actual production source, demands the exact
named assertion, always restores originals, then reruns the complete entry:

1. early formal DNS -> C4 referenced-socket ordering;
2. system resolver instead of isolated startup -> C1;
3. early restart intent clear -> C10;
4. remove real-exit confirmation before deletion -> C6;
5. permit a live historical orphan to continue -> C8.

A generic crash or unrelated assertion is not accepted as a negative PASS.

## Full regressions (run separately, in addition to this entry)

```sh
tests/host/ucode tests/run.uc
bash tests/bootstrap-dns/run.sh
bash tests/xray-ready/run.sh
bash tests/daemon/run.sh
bash tests/reload/run.sh
bash tests/monitor/run.sh
bash tests/stubs/procd/run.sh
# Additional non-card regression: original schedule fixture predates B3.
python3 tests/bootstrap-startup/schedule-compat.py
# T9.46 sampling and field/time negative controls:
python3 tests/bootstrap-startup/t946-controls.py
CI_TOOLS_DIR=/workspace/openwrt/ci-spike/tools bash tests/review.sh
```

The old B1 Q11 startup-disconnected and B2 W7 old-order assertions are replaced
only at the startup boundary. Runtime reload/monitor/probe resolution and the
original `resolve_node()` body remain frozen and independently checked. No
formal golden or shared runner/host/review infrastructure is changed.

The extra raw `bash tests/schedule/run.sh` command still has its old startup
resolver environment control and an end-of-suite custom DNS without private
query/owned-ready support. The compatibility driver changes only those fixture
boundaries in an ignored temporary script and verifies every ok/bad/expect oracle
line is unchanged. `tests/schedule/` is not edited. Its raw failure and the adapted
run are separately reported; the latter is not presented as the raw command passing.
The inherited last-fraction-of-wall-clock stop case was timing-sensitive in an
initial adapted run (46/1, then unchanged 47/0); this optional run is not the sole
cancellation evidence. The specified C7 and original T9.46 deadline/stop oracles
are separately required and are not skipped or weakened.
