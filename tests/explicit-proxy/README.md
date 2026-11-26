# Offline real-Xray explicit-proxy acceptance

This test uses **real UCI parsing, `config.load()`, the production Xray renderer,
the real CLI, and real Xray processes**. It never patches production modules or
filters out the existing transparent/DNS/diagnostic inbounds. No network downloads,
router, firewall changes, external DNS, or public target service are needed.

## Run

Prerequisites: Linux `/proc`, Python 3.8+, curl with SOCKS5/HTTP proxy support,
OpenSSL, the host ucode/UCI modules (`tests/host/bootstrap.sh`), and a real ELF Xray.
The unmodified transparent inbound needs the host's transparent-socket privileges;
on this host, run with `sudo -n`. Fixed production ports 31080–31083 must be free;
all explicit, upstream, and target ports are dynamically allocated on loopback.
Concurrent runs in the same network namespace are not supported.

From the repository root:

```sh
sudo -n env XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  python3 -B tests/explicit-proxy/acceptance.py

# Also verified against the older real engine, without changing the config:
sudo -n env XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.9.30/xray \
  python3 -B tests/explicit-proxy/acceptance.py
```

`acceptance.py` is executable. Without `XRAY_BIN`, it checks PATH, then existing
`/tmp/ci-tools/xray-*/xray` and `/workspace/openwrt/ci-spike/tools/xray-*/xray`.
Shell-script stubs are rejected. Missing tools, unavailable privileges, occupied
ports, validation errors, and failed assertions exit nonzero; there are no silent
skips or automatic downloads. Select the intended engine explicitly for repeatable
CI runs.

## Real daemon/reload regression (T16.108)

Run **sequentially**, not concurrently with `acceptance.py` or another real-Xray
suite (the unchanged production inbounds share fixed ports):

```sh
sudo -n env XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.3.27/xray \
  python3 -B tests/explicit-proxy/reload.py
```

`reload.py` reuses `acceptance.py` traffic/process helpers and
`tests/reload/dns-ready.py`'s rooted daemon fixture. It drives the production
UCI loader, renderer, validation, daemon, SIGHUP reload transaction, and rollback;
it does not call the renderer directly or replace the rendered config. The real
Xray child retains all transparent, DNS, and diagnostic inbounds. The local
upstream is another real authenticated Xray SOCKS proxy, with a local HTTP target.
No router, public network, host firewall, route, or interface changes are made:
DNS, nft, ip, dnsmasq and other system commands stay rooted fixtures.

**Native observation boundary:** rooted readiness deliberately refuses native
IPv6 dual-stack evidence. In a temporary module copy only, an exactly matched,
single `published()` call passes `root: ''` to the existing Xray `wait()` function,
after reading the real published artifacts from the fixture root. Thus the
unchanged readiness predicates read genuine child `/proc`, ownership/generation,
native ELF identity, and socket-diag evidence. Formal DNS retains rooted readiness.
The fixture monitor's global `tcp6` file is a read-only link to `/proc/net/tcp6`,
replacing the shell Xray stub's synthetic TPROXY health row. No production source
file is edited. All instrumentation anchors require exactly one source match.

Evidence is deliberately split:

- **Real Xray:** double-off → HTTP → both → SOCKS → double-off, proving a new
  daemon-owned Xray generation, enabled sockets at exactly `127.0.0.1`, disabled
  sockets absent and unconnectable, authenticated HTTP traffic through each
  enabled frontend, and rejection of unauthenticated traffic. Each successful
  reload records `last_reload.ok` and exactly one new `RELOAD_APPLIED`.
- **Real Xray failures:** HTTP → add occupied SOCKS and SOCKS → add occupied HTTP.
  A separate process owns the proposed port before reload and retains the same
  PID/socket inode/binding afterward. Reload records failure, publishes no
  `RELOAD_APPLIED`, restores the previous config bytes and render hashes, stays
  running, emits a failure event, and serves authenticated traffic through the
  restored proxy. Runtime output/logs/events/state are checked for all random
  credential sentinels without dumping secret-bearing output.
- **Labelled proc-visibility fault fixture, not delayed real socket creation:**
  an additional temporary snapshot-I/O hook hides explicit-port rows from the
  otherwise genuine `/proc` snapshot. It does not replace requirements, ownership
  checks, readiness predicates, result, or timeout. Startup with HTTP and reload
  to both first use a separate, unmodified native gate to prove every required
  non-explicit socket is ready for the same Xray generation. Only the three
  explicit not-ready daemon evaluations after that observation count; generation
  identity must remain unchanged. Neither startup nor reload success may be published; removing
  the barrier allows success and real authenticated requests. Polling sleeps only
  schedule observations; no fixed sleep is evidence of non-publication.
- **Mutation sensitivity:** a separate temporary module copy removes only the
  explicit-requirements loop (the original omission). It starts double-off
  normally, then reloads to HTTP behind the same visibility barrier. Premature
  `RELOAD_APPLIED` must be detected as the expected assertion failure. Unrelated
  failures are not accepted as proof of sensitivity.

Validated locally against the minimum real engine **26.3.27**, followed by all
five `acceptance.py` cases and all eight `diagnostics.py` cases. These tests do
not claim live-device/firewall or real delayed-bind evidence.

## Offline diagnostic regressions (no real Xray or root required)

With Python 3.8+ and the host ucode/UCI modules already bootstrapped, run from the
repository root:

```sh
python3 -B tests/explicit-proxy/diagnostics.py
```

This separate eight-case suite drives the actual `check --json` CLI with private
`nft`, `ip`, ChinaDNS-NG, and malicious Xray validator stubs plus a fake `br-lan`
sysroot. The validator reads the production-rendered enabled SOCKS/HTTP accounts,
verifies their exact values (including quotes, apostrophes, and backslashes),
emits raw and JSON-escaped credentials to **both stdout and stderr**, and exits 1.
For disabled-but-retained main credentials, which are absent from rendered accounts,
it verifies that absence and emits environment-provided sentinels instead.

Both cases must return `RENDER_INVALID` (exit 4), preserve a useful generic Xray
failure, and expose no raw or repeatedly JSON-escaped credentials in the reply,
stderr, or `events.jsonl`. The same malicious validator also exercises actual
`node use --json` preflight for both cases: selection must fail with
`CONFIG_INVALID`, leave configuration/state/event history unchanged, and clean
its scratch directory without exposing credentials. Four more `check --json`
cases omit each SOCKS/HTTP username/password in turn and require secret-free
`CONFIG_INVALID` diagnostics (exit 2) without invoking the validator.

No network, engine downloads, listeners, root privileges, or live firewall changes
are used. All stubs, UCI packages, artifacts, and logs live in a private temporary
directory removed on exit. This is a CLI diagnostic regression test, not a real
engine acceptance test or daemon/reload/subscription/monitor lifecycle test.

## Acceptance matrix

Each case writes a private real UCI package, loads it through `render.uc`, compares
the resulting bytes with `aether-proxy render xray`, validates the complete output
with `xray run -test`, and starts that complete config in real Xray:

| UCI case | Explicit listeners |
| --- | --- |
| Fields omitted | Neither; no new fields in the normalized legacy snapshot |
| Both booleans false | Neither; rendered config identical to omitted case |
| SOCKS enabled | SOCKS only |
| HTTP enabled | HTTP only |
| Both enabled | SOCKS and HTTP |

The test checks normalized enabled values are booleans; configured ports and tags
are preserved; each enabled inbound routes to `proxy`; and the original unauthenticated
`http-in` at `127.0.0.1:31081` remains unchanged. `/proc/<xray-pid>/fd` socket inodes
and TCP tables verify that the **actual** enabled explicit listeners bind only
`127.0.0.1`, and disabled explicit listeners do not exist.

Traffic uses a second real Xray as an authenticated local SOCKS upstream, then a
local HTTP target or a self-signed TLS target. For every enabled frontend:

- Correct credentials deliver the expected body over HTTP and HTTPS: SOCKS5
  authentication/tunneling, HTTP proxy GET, and HTTP CONNECT with TLS all work.
- Missing credentials, wrong username, and wrong password fail for both targets.
- After stopping and waiting for the upstream process, correct-auth requests fail
  through every enabled frontend for both targets (no direct/freedom fallback).
- Every denied, disabled-listener, and upstream-down request causes **zero TCP
  accepts at either target**, not merely zero successful HTTP responses.
- Direct requests before and after the failure tests prove both targets are live.

Credentials are randomly generated per run. They are sent to curl over stdin,
never command-line arguments, and captured subprocess output is never printed.
All temporary UCI, certificate, and Xray files are removed; Xray processes and
local target threads are stopped on exit.

## Artifact permissions and boundaries

`render.uc` writes the rendered Xray config with production `sys.write_atomic()`
(the daemon's artifact-writing helper). Even with caller umask `000`, the test
requires mode `0600`. CLI output must exactly match that private artifact, have no
stderr, and create no runtime/log directory. The CLI intentionally prints the
requested secret-bearing artifact to stdout; callers must protect redirections.
This is not a daemon lifecycle/check-staging permission test, a CLI status/dump
redaction audit, or an OpenWrt firewall/TPROXY traffic test.

Validated locally: Xray **26.11.9** and **26.9.30**, all five cases passed on each.
