# T15.5 reference-driven Xray readiness

## T15.7 passive TCPv6 evidence

`bash tests/xray-ready/passive.sh` calls production `socket_diag` and
`xray_ready`, first against the real Linux kernel/child proc/loopback listeners,
then against explicitly labelled transport-only injected wire faults in copied
modules. `listener.py` counts real TCP accepts; 50 supported waits must leave
count zero, followed by a counted ordinary-connect instrumentation control.
The existing five-module isolation executes this path with both struct negative
controls. A cached real Xray also runs `-test`, starts, passes owned readiness
and terminates. This is not H28K validation and absence of Error is not the proof.

`diag_socket.uc` only replaces transport in a copied `socket_diag`: real FD
allocation/close, synthetic receive bytes/errors/poll timing. Production parser,
PID/starttime/proc/FD checks, cancellation, deadline and legacy IPv4 compatibility
connect remain intact. The working real dual-stack listener makes any accidental
fallback measurable. Correctly classified unsupported/denied/missing-attribute
cases must create exactly one counted handshake; bad data, v6only=1, cancellation,
changed generation, unknown errors and exhausted budgets must not.
Pure `tests/unit/socket_diag.uc` checks LE/BE multipart, attribute alignment,
unknown extensions and clean completion; BE is a fixture, not a device claim.
Rooted proc fixtures cannot obtain host netlink or connect evidence.

`handler_faults()` additionally tests missing TCPv6 DUMP handlers: a correlated
full-echo NLMSG_ERROR(-ENOENT) and multipart NLMSG_DONE(-ENOENT) each permit exactly
one counted legacy handshake, but only before any socket evidence. Wrong echo/seq,
bad framing, partial/contradictory records, v6only=1, normal empty DONE, transport
ENOENT, timeout/cancellation/generation changes and competing IPv4 ownership remain
negative controls. Pure fixtures cover both byte orders and valid capped echoes.
These are injected transport statuses, not a claim that the host lacks a handler.

`python3 tests/xray-ready/passive_mutations.py` requires nine exact assertion
failures: the original four (old active branch, ignored v6only, bad-message
fallback, post-budget probe), plus disabled handler ERROR/DONE compatibility,
global ENOENT classification, accepted partial evidence and ignored error echo.
It restores both production sources in `finally`, then reruns the passive entry.

The probe-after-budget control runs `PASSIVE_CASE=budget` under both deleted and
restored guards for 10 paired rounds, requiring the exact named AssertionError
(not any nonzero exit) for deletion and the same assertion's PASS after restoration.
In isolated source copies only, observation assignments expose the original
calculated deadline and diag query return; no clock, deadline, branch or guard is
changed by the instrumentation. The transport holds the final legal missing-attr
DONE receive result until at least deadline+1ms, looping across early uloop wakeups.
Every pair verifies a successful fallback result actually returned after that
original deadline, using the unchanged 110ms short budget. The new case additionally
requires <250ms elapsed; no existing timing limit or cancellation check is relaxed.
`probe_socket.uc` counts entry to real socket.connect and delegates create/connect/
poll/getopt/close unchanged. A timely compatibility positive control must produce
one observed connect and one real accept. Late results require zero connects AND
zero additional accepts; the mutation is caught even if accept scheduling misses
an attempted connect. Full timestamps/counters for every pair are retained in logs.
Production files have no permanent change for this test.

Do not run mutations concurrently with any other suite. Original B2 12 controls
remain in `mutations.py`; both sets must run for this card. Logs: `.logs/`.

## Original B2 coverage

Run from the worktree: `bash tests/xray-ready/run.sh`.
Requires the existing host ucode bootstrap and Python 3; no root, external DNS,
service changes, downloads or fixed host ports.

- `run.py` + `driver.uc`: the real production `xray_ready` module observes real
  loopback listeners, child PID/starttime and `/proc/PID/fd` inodes. `listener.py`
  only binds/connects/listens/accepts without payload; it never implements the gate.
  IPv4/IPv6 connected-UDP negatives prove the child owns the exact local tuple
  and connected peer via real kernel tables/FDs, then require the ucode gate to
  reject it. An unconnected socket on the same local tuple is a success control.
  UDP connect only establishes local socket state; no DNS/payload is sent.
  Dynamic addresses/ports are also exercised through renderer-artifact mapping
  in the pure unit case. No production constants are overridden.
- Explicitly labelled proc-fixture subcases cover TCP non-LISTEN states, missing
  FD/inode, malformed tables and PID reuse. UDP fixtures independently reject
  connected state, nonzero remote address and nonzero remote port, in both families.
  Both ownership and network tables
  come from the same rooted fixture, never a mixture with the host.
- `lifecycle.py`: actual daemon/supervise/reload/monitor flows, but **synthetic
  proc/socket data** from `tests/stubs/daemon-bin/xray`, not real Xray sockets.
  It accelerates only the monitor refresh schedule and injects one state-write
  failure in copied modules. Startup, tier choice, rendering, child replacement,
  requirements, ownership checks, cancellation and rollback remain production.
  Tests hold referenced DNS absent/delayed, rather than prewriting ready markers.
- `tests/unit/xray_ready.uc`: automatically discovered renderer-reference and
  strict tcp/tcp6/udp/udp6 parsing tests, including explicit boolean byte order,
  little/big-endian IPv4/IPv6 local and remote addresses, remote port retention,
  and invalid/missing parameter rejection.
- `minimal.py` + `minimal.uc`: approved review-A acceptance, not the earlier
  exploratory prototype. Restrict both compiler module_search_path and runtime
  REQUIRE_SEARCH_PATH to a copied source tree and only fs/log/socket/uci/uloop
  native modules. Both require('struct') and static import 'struct' must fail;
  imports of net/config/renderers/readiness/daemon/reload/monitor/B1 must succeed.
  The repaired readiness really runs against real TCP/UDP sockets without struct,
  including 50 repeats with FD accounting. Explicit rooted ELF/proc fixtures cover
  both ELF classes and byte orders, bad/missing/unreadable ELF and stable failure FDs.
- `fault_fs.uc`: a test-only fs boundary in a copied xray_ready module delegates
  to real file handles while injecting open/read/close return failures. No gate,
  parser, deadline or cancellation code is substituted. Tests count real opens
  and closes, inject real SIGTERM with ELF open, and hold the read past five
  seconds to prove it consumes the original budget. This is API fault injection,
  not a claim to have caused kernel close failures.
- `proc_fixture.py`: creates only an ELF identification matching the legacy
  synthetic little-endian proc tables. It writes no ready/socket marker. Rooted
  fixtures must supply it explicitly; production never falls back to host ELF.

Big-endian fixtures do not constitute a real big-endian device test. The ELF ABI
contract targets native Linux/OpenWrt, not cross-endian user emulation.

`python3 tests/xray-ready/mutations.py` temporarily mutates only this worktree's
`xray_ready.uc` and `net.uc`, requires the exact named assertion failure for each mutation,
restores both readiness and net in `finally`, then reruns the entire entry point.
UDP-specific mutations remove the inbound guard, peer check or connection-state
check. Each must hit the real connected-socket negative or the corresponding proc
fixture assertion. In addition to the original four gate mutations it restores a static struct import,
accepts default parser endian, forces little-endian, skips ELF magic validation,
and ignores close failure; each must hit its exact named negative assertion. Do not run it
concurrently with any other suite. Logs go to ignored `.logs/`.

`evidence/` contains the final independent entry point and mutation summaries.
The task report records separate legacy suite outcomes and formal review.
None of these results constitute device acceptance or the later B3 startup
reordering/bootstrap implementation.
