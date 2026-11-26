# Explicit proxy acceptance: offline logical LAN and real Xray

## Primary acceptance (T16.112)

From the repository root, run without sudo:

```sh
XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  unshare -Urnm --propagation private python3 -B tests/explicit-proxy/lan.py
```

Prerequisites: Linux unprivileged user/network/mount namespaces, `unshare`,
`nsenter`, `ip`, Python 3.8+, curl with SOCKS5/HTTP support, OpenSSL, and
bootstrapped host ucode/UCI (`tests/host/bootstrap.sh`). The primary suite
requires real ELF Xray **26.11.9**. No downloads, skips or shell Xray substitutes
are allowed. Missing privileges/tools or failed assertions exit nonzero.

The outer command maps the caller to root **inside a new user namespace**, not
host root. `network.py` then re-execs inside `unshare --net --mount --propagation
private`, records the previous network namespace, and refuses network changes
if it is still in that namespace. An independent client network namespace is
kept alive by a child process (no named netns or `/run/netns` mount). A real veth
connects server `lan-test`, `192.0.2.1/24`, to client `lan-client`,
`192.0.2.2/24`. No default route, external DNS, internet, host firewall changes,
or host interface/route changes are needed. Namespace processes exit on cleanup.
Production transparent, DNS and diagnostic inbounds are retained, not filtered.

The client runs real curl via `nsenter -t CLIENT_PID -n`. Offline HTTP and
self-signed HTTPS targets bind to **server loopback**, unreachable from the
client directly (negative control). Production daemon-owned Xray exposes the
explicit listeners; another real authenticated Xray SOCKS server is the chosen
upstream. Successful responses therefore require both engines. The client has
no transparent interception. HTTP CONNECT protects the target TLS connection;
it does **not** make the client-to-HTTP-proxy transport TLS.

Assertions:

- Double off → SOCKS only → both → HTTP only → both → SOCKS retained → double off
  → HTTP. Each effective apply replaces the daemon-owned Xray generation and
  publishes exactly one `RELOAD_APPLIED` with `last_reload.ok`. Successful no-op
  compatibility reads do not require a restart or a `RELOAD_APPLIED` event.
- Both protocols use **one shared account** (`main.proxy_username/password`)
  and independent ports. SOCKS5 HTTP/TLS and HTTP forward/CONNECT-TLS return the
  exact offline body. Missing auth, wrong username and wrong password fail for
  both protocols and targets with **zero target TCP accepts**. Disabled
  listeners are also exercised from the client.
- Child socket inode ownership and `/proc/<pid>/net/tcp{,6}` prove enabled ports
  bind **exactly** the resolved logical-LAN IP, never loopback, wildcard or an
  extra IPv6 endpoint. Internal legacy loopback inbounds remain unchanged.
- Offline `ubus call network.interface dump` returns logical `lan` with
  `up:true` and `ipv4-address` candidates, plus a WAN/default-route decoy. The
  actual device is named `lan-test`, **not br-lan**. Empty/down/invalid LAN and
  multiple candidates without selection reject apply. A local other-interface
  WAN address and a nonlocal noncandidate cannot be selected. `status --json`
  must return exactly `explicit_lan:{interface:'lan',addresses:[...]}` for the
  initial, multiple, changed and empty candidate states.
- Identical old accounts or a single old account work for both protocols.
  Deliberately stale old `socks_listen/http_listen` addresses are ignored.
  Differing legacy accounts and either incomplete new replacement reject apply;
  a complete explicit shared replacement resolves ambiguity. Reload reading,
  success and validation failures never rewrite any UCI bytes.
- Same explicit ports and a conflict with internal port 31081 reject before bad
  publication. Invalid candidates/selection/credentials preserve config bytes,
  render hashes, running service and authenticated prior HTTP/CONNECT traffic.
- A different process occupies the newly added SOCKS port. Failed apply restores
  prior artifacts/hash/listeners, leaves its socket inode and ownership alone,
  and retains authenticated HTTP forward/CONNECT. This is a real bind failure
  and rollback, not only schema validation.
- Add actual `192.0.2.3` to the server veth and select it once from two offline
  LAN candidates. Reapply: **both protocols bind the new address at distinct
  ports** and pass the full HTTP/TLS/auth matrix. Remove the old address, expose
  the sole new candidate, remove the selection, and reapply without persisting
  runtime `proxy_listen`. Renumber again to `192.0.2.4` with **byte-identical
  UCI**, exposing only that new candidate: reapply must rebind both real ports
  and pass the full auth/HTTP/TLS matrix. Requests to both old addresses fail.
  Double-off also works with no LAN candidate; re-enabling retains the shared
  account.
- Stopping the chosen upstream makes real proxy requests fail with zero target
  accepts: there is no direct fallback.
- Explicit-only success/failure and LAN reapply preserve nft artifact bytes,
  nft load/delete and fw4 call counts, and non-explicit Xray inbounds/outbounds/
  routing. `nft -c` prechecks may occur. This is **rooted command-fixture
  evidence, not real firewall or transparent-traffic testing**.

### Real versus fixture boundaries

`lan.py` reuses `reload.py`'s fixture, which reuses
`tests/reload/dns-ready.py`'s rooted production-daemon fixture **without changing
that shared fixture source**. UCI parsing, production rendering/validation,
SIGHUP transactions, rollback, Xray, sockets, veth/namespaces, curl requests and
target accepts are real. **LAN discovery is offline ubus JSON**, not real
OpenWrt netifd/ubus. The actual kernel interface/address setup is independent;
real Xray sockets prove the advertised addresses can actually bind. WAN/default
route entries must not become explicit listeners. DNS readiness, dnsmasq,
routing and nft side effects remain rooted fixtures; no real OpenWrt/fw4/DNS or
transparent-traffic claims are made.

A temporary module copy changes only the native observation context of Xray
readiness (`published()` passes `root:''` to `wait()`) so production ownership,
generation and socket predicates inspect real child `/proc` and socket-diag.
The monitor's TCP6 table links to namespace `/proc/net/tcp6`; formal DNS still
uses synthetic readiness. No production source is edited by the suite.

Credentials are random per run, passed to curl on stdin (not argv), and never
printed. Runtime logs/events/state and status replies are checked for sentinels.
Secret-bearing UCI/config files are private temporary files removed on exit.

## Compatibility suites

Run sequentially (no sudo, devices, internet or downloads):

```sh
XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  unshare -Urnm --propagation private python3 -B tests/explicit-proxy/acceptance.py
XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  unshare -Urnm --propagation private python3 -B tests/explicit-proxy/reload.py
python3 -B tests/explicit-proxy/diagnostics.py
```

- `acceptance.py`: omitted/off/SOCKS/HTTP/both real UCI → **pipeline.read** →
  renderer; compares CLI render bytes and validates/runs complete real Xray
  configs. Checks default ports 1080/8080, absent credentials and **no ubus LAN
  query while both off**, normalized flags, original diagnostic inbound, exact
  LAN binding, auth/HTTP/TLS/upstream-down and target counts. Requires atomic
  artifact mode **0600** under umask 000 and no CLI runtime artifacts. Requests
  originate in the server namespace; use `lan.py` for independent-client proof.
- `reload.py`: real daemon enable/reload and occupied-port rollback in both
  directions. Server-namespace requests, native Xray socket observation.
  Additional **labelled proc-visibility fault fixtures** hide explicit rows:
  repeated not-ready evaluations must block startup/reload publication until
  released. A temporary mutation removing only explicit requirements must be
  rejected as premature `RELOAD_APPLIED`. These are fault/mutation sensitivity,
  **not real delayed socket binding**.
- `diagnostics.py`: rootless offline **six cases** using malicious validator
  and canned logical-LAN ubus JSON. Enabled and disabled-retained shared
  credentials (quotes/backslashes included) must not leak raw or repeatedly
  JSON-escaped through check/node-use replies, stderr or events. Missing shared
  username/password must fail before validator execution. Node-use injects the
  offline ubus via PATH (its CLI has no `--bin-dir`). **No real engine/network
  evidence is claimed by this suite.**

`XRAY_BIN` selects an existing executable; fallback discovery checks PATH/local
CI caches and rejects non-ELF stubs. Use the explicit 26.11.9 path for repeatability.
