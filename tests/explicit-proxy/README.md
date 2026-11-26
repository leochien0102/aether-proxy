# Explicit proxy acceptance: isolated LAN and real Xray

## Primary acceptance (T16.110)

From the repository root, run:

```sh
sudo -n env XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  python3 -B tests/explicit-proxy/lan.py
```

Prerequisites: Linux network/mount namespace privileges, `unshare`, `nsenter`,
`ip`, Python 3.8+, curl with SOCKS5/HTTP support, OpenSSL, and bootstrapped host
ucode/UCI (`tests/host/bootstrap.sh`). The primary suite requires real ELF Xray
**26.11.9**; no downloads, skips or shell Xray substitutes are allowed. Missing
privileges/tools or failed assertions exit nonzero.

`network.py` first re-execs the test inside `unshare --net --mount --propagation
private` and refuses network changes if it is still in the original network
namespace. An independent client network namespace is kept alive by a child
process (no named netns or `/run/netns` mount). A real veth connects server
`br-lan`, `192.0.2.1/24`, to client `lan-client`, `192.0.2.2/24`. There is no
default route, external DNS, internet dependency or host firewall/interface/route
change. Namespace processes are terminated on exit. The production transparent,
DNS and diagnostic inbounds are retained, not filtered out.

The client runs actual curl via `nsenter -t CLIENT_PID -n`. Targets are offline
HTTP and self-signed HTTPS servers bound to **server loopback**, unreachable from
the client directly (negative control). The production daemon-owned Xray listens
on the configured LAN address; another real authenticated Xray SOCKS server is
the selected upstream. Therefore successful responses require the explicit
frontend and the configured upstream. The client has no transparent interception.

Assertions:

- Double off → SOCKS only → both → HTTP only → both → SOCKS retained → double off
  → HTTP for rollback. Each successful reload replaces the daemon-owned Xray
  generation and publishes exactly one `RELOAD_APPLIED` with `last_reload.ok`.
- SOCKS5 HTTP and TLS, HTTP forward GET and HTTP CONNECT/TLS return the exact
  offline body. Missing credentials, wrong username and wrong password fail for
  both protocols and both targets with **zero target TCP accepts**. Disabled
  listeners are also exercised from the client.
- `/proc/<pid>/fd` socket inodes and that process's TCP tables prove each enabled
  explicit port belongs to the current daemon-owned Xray at **exactly
  `192.0.2.1`**, with no extra loopback, wildcard or IPv6 binding at that port.
  Internal legacy loopback inbounds are not forbidden or changed.
- Reloads with empty/malformed/wildcard/loopback/IPv6 addresses, a nonlocal LAN
  subnet address, and an address actually local on **another interface** fail.
  Published config bytes/render hashes and running state survive; authenticated
  HTTP forward and CONNECT/TLS still work from the LAN client.
- A different process (the test controller) occupies the newly added SOCKS port.
  Reload fails without disturbing its socket inode/binding. The rolled-back
  Xray does not own that port, and prior authenticated HTTP and CONNECT remain
  usable. Stopping the selected upstream then makes real requests fail with
  zero target accepts: there is no direct fallback.
- Explicit-only successful/failed reloads preserve nft artifact bytes and do not
  add nft load/delete or fw4 command calls. Non-explicit Xray inbounds, outbounds
  and routing (excluding only explicit inbound tags) remain identical. `nft -c`
  prechecks may occur. This is
  **rooted command-fixture evidence, not real firewall testing**.

### Real network versus rooted fixture boundaries

`lan.py` reuses `reload.py`'s `Fixture`, which in turn reuses
`tests/reload/dns-ready.py`'s rooted production-daemon fixture. UCI parsing,
production rendering/validation, daemon SIGHUP transactions, rollback, Xray,
sockets, veth/network namespaces, curl requests and target TCP accepts are real.
DNS readiness, dnsmasq, routing and nft side effects remain rooted fixtures.

The fake `ip` executable delegates **only** the read-only production query
`ip -j -4 addr show dev br-lan` to the native ip binary inside the server network
namespace. Thus live LAN-address validation sees the actual namespace interface
and addresses, not canned address claims; all mutating routing commands retain
the rooted stub. A temporary module copy changes only the native observation
context of Xray readiness (`published()` passes `root: ''` to `wait()`) so the
production ownership/generation/socket predicates inspect real child `/proc` and
socket-diag. The fixture monitor's TCP6 table links to namespace `/proc/net/tcp6`.
Formal DNS still uses synthetic readiness. No production source is edited by the
suite. Do not describe this as real OpenWrt/fw4/DNS/transparent-traffic evidence.

Credentials are random per run, sent to curl on stdin (not argv), and never
printed. Runtime logs/events/state are checked for all credential sentinels.
Secret-bearing UCI/configs are private temporary files removed on exit.

## Compatibility suites

These run sequentially as below; each real-Xray test now creates its own disposable
network namespaces and sets explicit `main.socks_listen` / `main.http_listen` to
`192.0.2.1`, with `main.lan_ifaces=br-lan`. No implicit `127.0.0.1` default remains.

```sh
sudo -n env XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  python3 -B tests/explicit-proxy/acceptance.py
sudo -n env XRAY_BIN=/workspace/openwrt/ci-spike/tools/xray-26.11.9/xray \
  python3 -B tests/explicit-proxy/reload.py
python3 -B tests/explicit-proxy/diagnostics.py
```

- `acceptance.py`: omitted/off/SOCKS/HTTP/both real UCI → loader → renderer,
  compares CLI render bytes, validates and runs complete real Xray configs;
  checks normalized flags, original diagnostic inbound, exact LAN bindings,
  auth/HTTP/TLS/upstream-down and target accept counts. It also requires production
  `sys.write_atomic()` mode **0600** under umask 000 and no CLI runtime artifacts.
  Its request generator is in the **server namespace**, not the independent LAN
  client; use `lan.py` for real remote-client evidence.
- `reload.py`: real daemon reload/occupied-port rollback regression, with native
  Xray socket observation. Its requests are also from the server namespace.
  Additional **labelled proc-visibility fault fixtures** hide explicit-port rows
  from snapshots; repeated not-ready evaluations must block startup/reload
  publication until released. A temporary mutation removing only the explicit
  requirements loop must be rejected as premature `RELOAD_APPLIED`. These cases
  are fault-fixture/mutation sensitivity, **not real delayed socket binding**.
- `diagnostics.py`: rootless, offline eight-case CLI diagnostic regression using
  malicious validator and canned LAN-address JSON. Enabled and disabled-retained
  credentials (quotes/backslashes included) must not leak raw or repeatedly
  JSON-escaped through check/node selection replies, stderr or events. Four missing
  credential cases must fail before validator execution. **No real engine or
  network evidence is claimed by this suite.**

All runtime prerequisites fail closed rather than silently skipping. `XRAY_BIN`
selects an existing executable; fallback discovery checks PATH and local CI tool
caches, rejecting non-ELF stubs. Use the explicit 26.11.9 path for reproducibility.
