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
  strict tcp/tcp6/udp/udp6 parsing tests, including explicit boolean byte order,
  little/big-endian IPv4/IPv6 and invalid/missing parameter rejection.
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
In addition to the original four gate mutations it restores a static struct import,
accepts default parser endian, forces little-endian, skips ELF magic validation,
and ignores close failure; each must hit its exact named negative assertion. Do not run it
concurrently with any other suite. Logs go to ignored `.logs/`.

`evidence/` contains the final independent entry point and mutation summaries.
The task report records separate legacy suite outcomes and formal review.
None of these results constitute device acceptance or the later B3 startup
reordering/bootstrap implementation.
