#!/usr/bin/env bash
# CLI scenarios for check/render (docs/tasks/m1 T1.7) and immediate health checks
# (docs/10 Dashboard part 2, T8.12b); private check scratch lifecycle (docs/10, T8.17).
# Runs the real entry point on the host through the test-only options of docs/10, so nothing
# outside a mktemp directory is touched. Needs tests/host/bootstrap.sh to have run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"
FIX="$ROOT/tests/fixtures"

T="$(mktemp -d)"
SERVER_PID=''
cleanup() {
	if [ -n "$SERVER_PID" ]; then
		if kill -0 "$SERVER_PID"; then kill "$SERVER_PID"; fi
		wait "$SERVER_PID"
	fi
	rm -rf "$T"
}
trap cleanup EXIT

pass=0
fail=0

ap() { "$UCODE" -S "$ENTRY" -- "$@"; }
jget() { "$UCODE" "$JGET" -- "$1"; }

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }

# expect <name> <expected> <actual>
expect() {
	if [ "$2" == "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# Rule data: baseline holds everything, data dir starts empty.
mkdir -p "$T/data" "$T/base" "$T/custom"
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"

# opts <confdir> <rundir>
opts() {
	echo --confdir "$1" --data-dir "$T/data" --baseline-dir "$T/base" --custom-dir "$T/custom" --run-dir "$2"
}

check_clean() {
	if compgen -G "$2/check.*" > /dev/null; then
		bad "$1: no check scratch remains"
	else
		ok "$1: no check scratch remains"
	fi
}

no_staging() {
	[ ! -e "$2/staging" ] && ok "$1: no daemon staging created" || bad "$1: no daemon staging created"
}

# Validators observe the scratch files before check removes them. The barrier forces both
# concurrent checks to keep precheck.nft live at once, reproducing the old shared-file race.
PC="$T/precheck"
mkdir -p "$PC/bin" "$PC/root/sys/class/net/br-lan"
cat > "$PC/bin/nft" <<'SH'
#!/bin/sh
file="$3"
case "$file" in
	*/precheck.nft)
		if [ -n "${CHECK_BARRIER:-}" ]; then
			touch "$CHECK_BARRIER/$(basename "$(dirname "$file")")"
			attempt=0
			while [ "$(find "$CHECK_BARRIER" -type f | wc -l)" -lt 2 ]; do
				attempt=$((attempt + 1))
				if [ "$attempt" -ge 100 ]; then
					echo 'concurrent prechecks did not overlap' >&2
					exit 9
				fi
				sleep 0.05
			done
		fi
		if [ "${CHECK_PRECHECK_FAIL:-0}" = 1 ]; then
			echo 'injected precheck failure' >&2
			exit 6
		fi
		;;
	*)
		if [ -n "${CHECK_CAPTURE:-}" ]; then
			cp "$(dirname "$file")/"* "$CHECK_CAPTURE/" || exit 8
		fi
		if [ "${CHECK_NFT_FAIL:-0}" = 1 ]; then
			echo 'injected render validation failure' >&2
			exit 7
		fi
		;;
esac
[ -s "$file" ] || exit 5
SH
printf '#!/bin/sh\necho "Usage: ip rule [ fwmark FWMARK[/MASK] ]"\n' > "$PC/bin/ip"
printf '#!/bin/sh\nexit 0\n' > "$PC/bin/xray"
printf '#!/bin/sh\nexit 0\n' > "$PC/bin/chinadns-ng"
chmod +x "$PC/bin"/*

# --- 1. enabled=1 without a node: configuration error, exit 2, nothing staged
mkdir -p "$T/run1"
out="$(ap check --json --no-precheck $(opts "$FIX/t11-err-enabled-no-node" "$T/run1") 2>"$T/check-fail.stderr")"; rc=$?
expect "no node: exit code 2" 2 "$rc"
expect "check --json failure: stderr empty" "" "$(cat "$T/check-fail.stderr")"
expect "no node: ok false" false "$(echo "$out" | jget ok)"
expect "no node: code" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "no node: error field" main.node "$(echo "$out" | jget errors.0.field)"
expect "no node: error code" required "$(echo "$out" | jget errors.0.code)"
[ ! -e "$T/run1/staging" ] && ok "no node: no staging written" || bad "no node: no staging written"
check_clean 'no node' "$T/run1"
[ -s "$T/run1/events.jsonl" ] && ok "no node: structured failure event appended" || bad "no node: structured failure event appended"
expect "no node: event is one JSONL object" CONFIG_INVALID "$(head -n 1 "$T/run1/events.jsonl" | jget code)"
expect "no node: event severity" error "$(head -n 1 "$T/run1/events.jsonl" | jget level)"
[ -n "$(head -n 1 "$T/run1/events.jsonl" | jget ts)" ] \
	&& ok "no node: event timestamp present" || bad "no node: event timestamp present"

# --- 2. valid config: report the deleted private path, capture bytes inside a validator
out="$(ap check --json --no-precheck $(opts "$FIX/sample" "$T/run2") 2>"$T/check-ok.stderr")"; rc=$?
expect "valid: exit code 0" 0 "$rc"
expect "check --json success: stderr empty" "" "$(cat "$T/check-ok.stderr")"
expect "valid: ok true" true "$(echo "$out" | jget ok)"
stage="$(echo "$out" | jget staging)"
[[ "$stage" =~ ^$T/run2/check\.[0-9]+$ ]] \
	&& ok 'valid: staging path is check.<pid>' || bad 'valid: staging path is check.<pid>' "$stage"
check_clean 'valid skipped validators' "$T/run2"
no_staging 'valid skipped validators' "$T/run2"

mkdir -p "$T/captured"
checked="$(CHECK_CAPTURE="$T/captured" ap check --json $(opts "$FIX/sample" "$T/run2") \
	--sys-root "$PC/root" --bin-dir "$PC/bin" 2>"$T/captured.stderr")"; rc=$?
expect 'valid captured: exit code 0' 0 "$rc"
expect 'valid captured: stderr empty' '' "$(cat "$T/captured.stderr")"
expect 'valid captured: ok true' true "$(echo "$checked" | jget ok)"
check_clean 'valid captured' "$T/run2"
no_staging 'valid captured' "$T/run2"

declare -A FILES=( [nft]=aether-proxy.nft [chinadns]=chinadns.conf [dnsmasq]=dnsmasq.conf [xray]=xray.json )
for name in nft chinadns dnsmasq xray; do
	ap render "$name" $(opts "$FIX/sample" "$T/run2") > "$T/render-$name" 2>/dev/null; rc=$?
	expect "render $name: exit code 0" 0 "$rc"
	expect "valid: $name reports deleted scratch path" "$stage/${FILES[$name]}" "$(echo "$out" | jget "files.$name")"
	if cmp -s "$T/render-$name" "$T/captured/${FILES[$name]}" && [ -s "$T/render-$name" ]; then
		ok "render $name: identical to staged ${FILES[$name]}"
	else
		bad "render $name: identical to staged ${FILES[$name]}"
	fi
done
[ -z "$(ls -A "$T/run2")" ] && ok "valid: run dir is empty after check" || bad "valid: run dir is empty after check"
[ ! -e "$T/run2/boot.txt" ] && ok "valid: boot.txt not written" || bad "valid: boot.txt not written"

# render writes no files
ap render nft $(opts "$FIX/sample" "$T/run2b") >/dev/null 2>&1
[ ! -e "$T/run2b" ] && ok "render: writes nothing" || bad "render: writes nothing"

# chinadns config carries all six paths (the sample config uses the default mode)
cd_conf="$T/render-chinadns"
for needle in "$T/custom/proxy_domain.txt" "$T/custom/direct_domain.txt" "$T/run2/boot.txt"; do
	grep -qF "$needle" "$cd_conf" && ok "chinadns: references $needle" || bad "chinadns: references $needle"
done

# render --json wraps the same bytes
out="$(ap render nft --json $(opts "$FIX/sample" "$T/run2") 2>"$T/render-json.stderr")"
expect "render --json: stderr empty" "" "$(cat "$T/render-json.stderr")"
expect "render --json: ok" true "$(echo "$out" | jget ok)"
expect "render --json: file" aether-proxy.nft "$(echo "$out" | jget file)"

# T8.22: validate the actual shipped file, not a copied fixture that could drift from it.
# T9.28: the shipped config defaults to T1/domestic boot; explicit opt-in uses the single direct upstream.
mkdir -p "$T/install-conf"
cp "$ROOT/aether-proxy/files/aether-proxy.config" "$T/install-conf/aetherproxy"
out="$(ap check --json --no-precheck $(opts "$T/install-conf" "$T/install-run") \
	2>"$T/install-check.stderr")"; rc=$?
expect 'installed config: check --no-precheck exit code 0' 0 "$rc"
expect 'installed config: check ok true' true "$(echo "$out" | jget ok)"
expect 'installed config: check stderr empty' '' "$(cat "$T/install-check.stderr")"
check_clean 'installed config' "$T/install-run"
no_staging 'installed config' "$T/install-run"
ap render chinadns $(opts "$T/install-conf" "$T/install-run") \
	> "$T/install-chinadns.conf" 2>"$T/install-render.stderr"; rc=$?
expect 'installed config: render chinadns exit code 0' 0 "$rc"
expect 'installed config: render stderr empty' '' "$(cat "$T/install-render.stderr")"
expect 'installed config: default-off trust uses T1 tunnels' \
	'trust-dns tcp://127.0.0.1#31082,tcp://127.0.0.1#31083' "$(grep '^trust-dns ' "$T/install-chinadns.conf")"
expect 'installed config: default-off boot uses expanded china DNS' \
	"group-upstream $(awk '/^china-dns / { print $2 }' "$T/install-chinadns.conf")" \
	"$(awk '/^group boot$/ { boot = 1; next } boot && /^group-upstream / { print; exit }' "$T/install-chinadns.conf")"
expect 'installed config: direct DNS list contains only 9.9.9.9' \
	"$(printf "\tlist direct_dns 'tcp://9.9.9.9'")" "$(grep 'list direct_dns ' "$T/install-conf/aetherproxy")"
if grep -q 'direct_dns_enabled' "$T/install-conf/aetherproxy"; then
	bad 'installed config: switch is omitted to use schema default'
else
	ok 'installed config: switch is omitted to use schema default'
fi
mkdir -p "$T/install-enabled-conf"
sed "/^config dns /a\\\toption direct_dns_enabled '1'" \
	"$T/install-conf/aetherproxy" > "$T/install-enabled-conf/aetherproxy"
ap render chinadns $(opts "$T/install-enabled-conf" "$T/install-run") \
	> "$T/install-enabled-chinadns.conf" 2>"$T/install-enabled-render.stderr"; rc=$?
expect 'installed config: explicit opt-in render exits 0' 0 "$rc"
expect 'installed config: explicit opt-in stderr empty' '' "$(cat "$T/install-enabled-render.stderr")"
expect 'installed config: enabled T2 trust uses single direct default' \
	'trust-dns tcp://9.9.9.9' "$(grep '^trust-dns ' "$T/install-enabled-chinadns.conf")"
expect 'installed config: enabled boot uses single direct default' 'group-upstream tcp://9.9.9.9' \
	"$(awk '/^group boot$/ { boot = 1; next } boot && /^group-upstream / { print; exit }' "$T/install-enabled-chinadns.conf")"

# --- 3. rule data missing in both places: error, exit 2
rm "$T/base/chnlist.txt"
out="$(ap check --json --no-precheck $(opts "$FIX/sample" "$T/run3") 2>/dev/null)"; rc=$?
expect "missing data: exit code 2" 2 "$rc"
expect "missing data: ok false" false "$(echo "$out" | jget ok)"
expect "missing data: error code" missing_data "$(echo "$out" | jget errors.0.code)"
ap render chinadns $(opts "$FIX/sample" "$T/run3") >/dev/null 2>&1; rc=$?
expect "missing data: render exit code 2" 2 "$rc"

# the data directory takes priority over the baseline
printf 'example.org\n' > "$T/data/chnlist.txt"
mkdir -p "$T/conf_cn"
sed "s/option mode 'gfw'/option mode 'bypass_cn'/" "$FIX/sample/aetherproxy" > "$T/conf_cn/aetherproxy"
ap check --json --no-precheck $(opts "$T/conf_cn" "$T/run3") >/dev/null 2>&1; rc=$?
expect "data dir overrides baseline: exit code 0" 0 "$rc"
mkdir -p "$T/override-captured"
CHECK_CAPTURE="$T/override-captured" ap check --json $(opts "$T/conf_cn" "$T/run3") \
	--sys-root "$PC/root" --bin-dir "$PC/bin" > "$T/override.json" 2>"$T/override.stderr"; rc=$?
expect 'data dir overrides baseline: captured check exit code 0' 0 "$rc"
check_clean 'data override' "$T/run3"
no_staging 'data override' "$T/run3"
grep -F "chnlist-file" "$T/override-captured/chinadns.conf" | grep -qF "$T/data/chnlist.txt" \
	&& ok "data dir overrides baseline: chnlist from data dir" || bad "data dir overrides baseline: chnlist from data dir"
grep -F "chnlist-file" "$T/override-captured/chinadns.conf" | grep -qF "$T/base/apple.txt" \
	&& ok "data dir overrides baseline: apple from baseline" || bad "data dir overrides baseline: apple from baseline"

# --- 4. usage errors
ap render nosuch $(opts "$FIX/sample" "$T/run4") >/dev/null 2>&1; rc=$?
expect "render unknown name: exit code 2" 2 "$rc"
ap render $(opts "$FIX/sample" "$T/run4") >/dev/null 2>&1; rc=$?
expect "render without name: exit code 2" 2 "$rc"
out="$(ap render nosuch --json $(opts "$FIX/sample" "$T/run4") 2>/dev/null)"
expect "render unknown name --json: ok false" false "$(echo "$out" | jget ok)"
out="$(ap version --json 2>"$T/version-json.stderr")"; rc=$?
expect "version --json: exit code 0" 0 "$rc"
expect "version --json: stderr empty" "" "$(cat "$T/version-json.stderr")"
expect "version --json: parses as object" true "$(echo "$out" | jget ok)"
version="$(echo "$out" | jget version)"
[ -n "$version" ] && [ "$version" != '<missing>' ] \
	&& ok "version --json: version present" || bad "version --json: version present"
ap check --bogus >/dev/null 2>&1; rc=$?
expect "check unknown option: exit code 2" 2 "$rc"

# --- 5. runtime status/events are isolated to the test run directory
mkdir -p "$T/status-empty"
out="$(ap status --json --run-dir "$T/status-empty" 2>"$T/status-empty.stderr")"; rc=$?
expect "status missing file: exit code 0" 0 "$rc"
expect "status missing file: stderr empty" "" "$(cat "$T/status-empty.stderr")"
expect "status missing file: stopped default" stopped "$(echo "$out" | jget state)"

mkdir -p "$T/status-populated"
printf '{"state":"running","dns_tier":"T1","future_field":{"kept":true}}\n' > "$T/status-populated/state.json"
out="$(ap status --json --run-dir "$T/status-populated" 2>"$T/status-populated.stderr")"; rc=$?
expect "status existing file: exit code 0" 0 "$rc"
expect "status existing file: stderr empty" "" "$(cat "$T/status-populated.stderr")"
expect "status existing file: state" running "$(echo "$out" | jget state)"
expect "status existing file: unknown field preserved" true "$(echo "$out" | jget future_field.kept)"
echo "$out" | grep -q '"probe": null' && ok "status without probe.json: probe is null" || bad "status without probe.json: probe is null" "$out"
printf '{"at":1234,"nodes":{"n_a":{"ok":3,"fail":0},"n_b":{"ok":0,"fail":3,"error":"timeout"}}}\n' > "$T/status-populated/probe.json"
out="$(ap status --json --run-dir "$T/status-populated" 2>>"$T/status-populated.stderr")"
expect "status probe summary: total" 2 "$(echo "$out" | jget probe.total)"
expect "status probe summary: reachable" 1 "$(echo "$out" | jget probe.reachable)"
expect "status probe summary: at" 1234 "$(echo "$out" | jget probe.at)"
echo "$out" | grep -q '"updates_available": null' && ok "status updates_available is null before M7" || bad "status updates_available is null before M7" "$out"
printf '{broken' > "$T/status-populated/state.json"
ap status --json --run-dir "$T/status-populated" >/dev/null 2>&1; rc=$?
expect "status with a corrupt state.json fails cleanly" 1 "$rc"

mkdir -p "$T/events"
cat > "$T/events/events.jsonl" <<'EVENTS'
{"ts":100,"level":"notice","code":"SERVICE_STARTED","args":{"mode":"gfw"}}
{"ts":150,"level":"notice","code":"TRUNCATED"
not-json
{"ts":200,"level":"warn","code":"DNS_TIER_CHANGED","args":{"from":"T1","to":"T2"}}
{"ts":300,"level":"error","code":"XRAY_DOWN","args":{}}
EVENTS
out="$(ap events --json --run-dir "$T/events" 2>"$T/events-all.stderr")"; rc=$?
expect "events: exit code 0" 0 "$rc"
expect "events: stderr empty" "" "$(cat "$T/events-all.stderr")"
expect "events: first row" SERVICE_STARTED "$(echo "$out" | jget events.0.code)"
expect "events: third row" XRAY_DOWN "$(echo "$out" | jget events.2.code)"
expect "events: malformed lines skipped" 2 "$(echo "$out" | jget skipped)"

out="$(ap events --json --since 200 --run-dir "$T/events" 2>"$T/events-since.stderr")"; rc=$?
expect "events since: exit code 0" 0 "$rc"
expect "events since: stderr empty" "" "$(cat "$T/events-since.stderr")"
expect "events since: inclusive boundary" 200 "$(echo "$out" | jget events.0.ts)"
expect "events since: later event retained" 300 "$(echo "$out" | jget events.1.ts)"
expect "events since: earlier event removed" '<missing>' "$(echo "$out" | jget events.2.ts)"
expect "events since: malformed count preserved" 2 "$(echo "$out" | jget skipped)"

out="$(ap events --json --level warn --run-dir "$T/events" 2>"$T/events-level.stderr")"; rc=$?
expect "events level: exit code 0" 0 "$rc"
expect "events level: stderr empty" "" "$(cat "$T/events-level.stderr")"
expect "events level: warn selected" DNS_TIER_CHANGED "$(echo "$out" | jget events.0.code)"
expect "events level: more severe error included" XRAY_DOWN "$(echo "$out" | jget events.1.code)"
expect "events level: less severe notice excluded" '<missing>' "$(echo "$out" | jget events.2.ts)"
# --- 5. TCP node probes use a local ucode listener or TEST-NET only
cat > "$T/probe-listener.uc" <<'UCODE'
'use strict';
import * as socket from 'socket';
import * as fs from 'fs';
let server = socket.create(socket.AF_INET, socket.SOCK_STREAM);
if (server == null || !server.bind({ address: '127.0.0.1', port: 0 }) || !server.listen(32))
	exit(1);
let bound = server.sockname();
let port_file = fs.open(ARGV[0], 'w');
if (port_file == null)
	exit(1);
port_file.write(`${bound.port}\n`);
port_file.close();
while (true) {
	let peer = server.accept();
	if (peer != null)
		peer.close();
}
UCODE
"$UCODE" "$T/probe-listener.uc" "$T/probe.port" > "$T/probe-listener.stdout" 2>"$T/probe-listener.stderr" &
SERVER_PID=$!
for attempt in {1..50}; do
	[ -s "$T/probe.port" ] && break
	sleep 0.05
done
local_port="$(cat "$T/probe.port")"
[ -n "$local_port" ] && ok "probe listener: ucode bound random loopback port" || bad "probe listener: ucode bound random loopback port"

mkdir -p "$T/probe-local" "$T/probe-local-run"
cat > "$T/probe-local/aetherproxy" <<EOF
config main 'main'
	option enabled '0'
config probe 'probe'
	option node_timeout '1'
	option node_concurrency '8'
config node 'n_00000000000000000000000000000001'
	option protocol 'trojan'
	option address '127.0.0.1'
	option port '$local_port'
	option password 'test-password'
	option security 'tls'
EOF
out="$(ap probe nodes n_00000000000000000000000000000001 --json --confdir "$T/probe-local" --run-dir "$T/probe-local-run" 2>"$T/probe-local.stderr")"; rc=$?
expect "probe local listener: exit code 0" 0 "$rc"
expect "probe local listener: stderr empty" "" "$(cat "$T/probe-local.stderr")"
expect "probe local listener: three connects succeeded" 3 "$(echo "$out" | jget nodes.n_00000000000000000000000000000001.ok)"
expect "probe local listener: zero failures" 0 "$(echo "$out" | jget nodes.n_00000000000000000000000000000001.fail)"
expect "probe local listener: result persisted" 3 "$(tests/host/ucode "$JGET" -- nodes.n_00000000000000000000000000000001.ok < "$T/probe-local-run/probe.json")"
# --sys-root moves the default run dir; --bin-dir is accepted (job start forwards both).
mkdir -p "$T/probe-root/var/run/aether-proxy" "$T/probe-bin"
ap probe nodes n_00000000000000000000000000000001 --json --confdir "$T/probe-local" --sys-root "$T/probe-root" --bin-dir "$T/probe-bin" >/dev/null 2>"$T/probe-root.stderr"; rc=$?
expect "probe with --sys-root/--bin-dir: exit code 0" 0 "$rc"
[ -s "$T/probe-root/var/run/aether-proxy/probe.json" ] && ok "probe with --sys-root writes under the root" || bad "probe with --sys-root writes under the root" "$(cat "$T/probe-root.stderr")"

if kill -0 "$SERVER_PID"; then kill "$SERVER_PID"; fi
wait "$SERVER_PID"
SERVER_PID=''
out="$(ap probe nodes n_00000000000000000000000000000001 --json --confdir "$T/probe-local" --run-dir "$T/probe-local-run" 2>"$T/probe-refused.stderr")"; rc=$?
expect "probe closed loopback port: exit code 0" 0 "$rc"
expect "probe closed loopback port: refused" refused "$(echo "$out" | jget nodes.n_00000000000000000000000000000001.error)"

mkdir -p "$T/probe-one-net" "$T/probe-one-net-run"
cat > "$T/probe-one-net/aetherproxy" <<'EOF'
config main 'main'
	option enabled '0'
config probe 'probe'
	option node_timeout '1'
config node 'n_00000000000000000000000000000002'
	option protocol 'trojan'
	option address '192.0.2.1'
	option port '65000'
	option password 'test-password'
	option security 'tls'
EOF
start_ns=$(date +%s%N)
out="$(ap probe nodes n_00000000000000000000000000000002 --json --confdir "$T/probe-one-net" --run-dir "$T/probe-one-net-run" 2>"$T/probe-one-net.stderr")"; rc=$?
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
expect "probe one TEST-NET node: exit code 0" 0 "$rc"
reason="$(echo "$out" | jget nodes.n_00000000000000000000000000000002.error)"
case "$reason" in timeout|unreachable) ok "probe one TEST-NET node: timeout/unreachable";; *) bad "probe one TEST-NET node: timeout/unreachable" "got '$reason'";; esac
[ "$elapsed_ms" -lt 5000 ] && ok "probe one TEST-NET node: under 5 seconds" || bad "probe one TEST-NET node: under 5 seconds" "${elapsed_ms}ms"

mkdir -p "$T/probe-net" "$T/probe-net-run"
{
	cat <<'UCI'
config main 'main'
	option enabled '0'
config probe 'probe'
	option node_timeout '1'
	option node_concurrency '8'
UCI
	for octet in {1..10}; do
		id=$(printf 'n_%032x' "$((100 + octet))")
		cat <<UCI
config node '$id'
	option protocol 'trojan'
	option address '192.0.2.$octet'
	option port '65000'
	option password 'test-password'
	option security 'tls'
UCI
	done
} > "$T/probe-net/aetherproxy"
start_ns=$(date +%s%N)
out="$(ap probe nodes --json --confdir "$T/probe-net" --run-dir "$T/probe-net-run" 2>"$T/probe-net.stderr")"; rc=$?
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
expect "probe TEST-NET: exit code 0" 0 "$rc"
expect "probe TEST-NET: 10 nodes returned" 10 "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["nodes"]))' <<< "$out")"
reason="$(echo "$out" | jget nodes.n_00000000000000000000000000000065.error)"
case "$reason" in timeout|unreachable) ok "probe TEST-NET: timeout/unreachable classified";; *) bad "probe TEST-NET: timeout/unreachable classified" "got '$reason'";; esac
[ "$elapsed_ms" -lt 6000 ] && ok "probe concurrency: 10 nodes completed in ${elapsed_ms}ms" || bad "probe concurrency: 10 nodes under 6 seconds" "${elapsed_ms}ms"

mkdir -p "$T/fakebin" "$T/probe-dns" "$T/probe-dns-run"
cat > "$T/fakebin/resolveip" <<'SH'
#!/bin/sh
case "$*" in
	*nonexistent.invalid*) exit 1 ;;
	*) echo 127.0.0.1; exit 0 ;;
esac
SH
chmod +x "$T/fakebin/resolveip"
cat > "$T/probe-dns/aetherproxy" <<'EOF'
config main 'main'
	option enabled '0'
config probe 'probe'
	option node_timeout '1'
config node 'n_000000000000000000000000000000c9'
	option protocol 'trojan'
	option address 'nonexistent.invalid'
	option port '443'
	option password 'test-password'
	option security 'tls'
EOF
out="$(PATH="$T/fakebin:$PATH" ap probe nodes n_000000000000000000000000000000c9 --json --confdir "$T/probe-dns" --run-dir "$T/probe-dns-run" 2>"$T/probe-dns.stderr")"; rc=$?
expect "probe unresolved domain: exit code 0" 0 "$rc"
expect "probe unresolved domain: resolve_failed" resolve_failed "$(echo "$out" | jget nodes.n_000000000000000000000000000000c9.error)"

# --- full precheck regression: a historical undefined variable crashed check after precheck.
# Keep coverage for the CLI/LuCI response and forwarding of --sys-root/--bin-dir.
out="$(ap check --json $(opts "$FIX/sample" "$T/run-pc") --sys-root "$PC/root" --bin-dir "$PC/bin" 2>"$T/pc.stderr")"; rc=$?
expect "check with precheck: exit code 0" 0 "$rc"
expect "check with precheck: stderr empty" "" "$(cat "$T/pc.stderr")"
echo "$out" | grep -q '"precheck"' && echo "$out" | grep -q '"xray"' && ok "check with precheck: precheck and xray validation reported" || bad "check with precheck: precheck and xray validation reported" "$out"

check_clean 'check with precheck' "$T/run-pc"
no_staging 'check with precheck' "$T/run-pc"

# T8.17: early precheck return and failed rendered rules both discard private artifacts.
for failure in precheck validation; do
	pre_fail=0
	nft_fail=0
	if [ "$failure" = precheck ]; then pre_fail=1; else nft_fail=1; fi
	out="$(CHECK_PRECHECK_FAIL="$pre_fail" CHECK_NFT_FAIL="$nft_fail" \
		ap check --json $(opts "$FIX/sample" "$T/run-$failure") \
		--sys-root "$PC/root" --bin-dir "$PC/bin" 2>"$T/$failure.stderr")"; rc=$?
	if [ "$failure" = precheck ]; then
		expect 'failed precheck: exit code 1' 1 "$rc"
		expect 'failed precheck: code' PRECHECK_FAILED "$(echo "$out" | jget code)"
	else
		expect 'failed validation: exit code 4' 4 "$rc"
		expect 'failed validation: code' RENDER_INVALID "$(echo "$out" | jget code)"
	fi
	expect "failed $failure: ok false" false "$(echo "$out" | jget ok)"
	expect "failed $failure: stderr empty" '' "$(cat "$T/$failure.stderr")"
	check_clean "failed $failure" "$T/run-$failure"
	no_staging "failed $failure" "$T/run-$failure"
done

# Include real artifact names, nested files and precheck.nft: a successful check must not
# overwrite any daemon candidate, and neither configuration nor validator failures may do so.
DAEMON_RUN="$T/daemon-run"
mkdir -p "$DAEMON_RUN/staging/nested" "$T/daemon-before/nested"
for file in "${FILES[@]}" precheck.nft nested/keep; do
	printf 'daemon owns %s\n' "$file" > "$DAEMON_RUN/staging/$file"
done
cp -a "$DAEMON_RUN/staging/." "$T/daemon-before/"
for mode in success config-invalid validation-invalid; do
	conf="$FIX/sample"
	nft_fail=0
	expected_rc=0
	case "$mode" in
		config-invalid) conf="$FIX/t11-err-enabled-no-node"; expected_rc=2 ;;
		validation-invalid) nft_fail=1; expected_rc=4 ;;
	esac
	out="$(CHECK_NFT_FAIL="$nft_fail" ap check --json $(opts "$conf" "$DAEMON_RUN") \
		--sys-root "$PC/root" --bin-dir "$PC/bin" 2>"$T/daemon-$mode.stderr")"; rc=$?
	expect "daemon staging $mode: check exit" "$expected_rc" "$rc"
	if diff -r "$T/daemon-before" "$DAEMON_RUN/staging"; then
		ok "daemon staging $mode: all files unchanged"
	else
		bad "daemon staging $mode: all files unchanged"
	fi
	check_clean "daemon staging $mode" "$DAEMON_RUN"
done

# Start separate real entry processes against the same config and a not-yet-created run dir.
# Waiting for both unique barrier markers proves overlap, rather than two serial successes.
mkdir -p "$T/barrier"
concurrent_pids=()
for n in 1 2; do
	CHECK_BARRIER="$T/barrier" ap check --json $(opts "$FIX/sample" "$T/concurrent-run") \
		--sys-root "$PC/root" --bin-dir "$PC/bin" >"$T/concurrent-$n.json" 2>"$T/concurrent-$n.stderr" &
	concurrent_pids+=("$!")
done
for n in 1 2; do
	wait "${concurrent_pids[$((n - 1))]}"; rc=$?
	expect "concurrent check $n: exit code 0" 0 "$rc"
	expect "concurrent check $n: ok true" true "$(jget ok < "$T/concurrent-$n.json")"
	expect "concurrent check $n: stderr empty" '' "$(cat "$T/concurrent-$n.stderr")"
done
expect 'concurrent checks: two overlapping private prechecks' 2 "$(find "$T/barrier" -type f | wc -l | tr -d ' ')"
first_stage="$(jget staging < "$T/concurrent-1.json")"
second_stage="$(jget staging < "$T/concurrent-2.json")"
if [[ "$first_stage" =~ /check\.[0-9]+$ && "$second_stage" =~ /check\.[0-9]+$ ]] \
	&& [ "$first_stage" != "$second_stage" ]; then
	ok 'concurrent checks: distinct check.<pid> paths'
else
	bad 'concurrent checks: distinct check.<pid> paths'
fi
check_clean 'concurrent checks' "$T/concurrent-run"
no_staging 'concurrent checks' "$T/concurrent-run"

# T8.12b (docs/10 Dashboard part 2): exercise the real CLI with a recording ubus.
mkdir -p "$T/probe-now/bin" "$T/probe-now/run"
cat > "$T/probe-now/bin/ubus" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$PROBE_UBUS_ARGS"
exit "${PROBE_UBUS_RC:-0}"
SH
chmod +x "$T/probe-now/bin/ubus"
export PROBE_UBUS_ARGS="$T/probe-now/argv"
PN_RUN="$T/probe-now/run"
for state in starting running degraded failsafe; do
	printf '{"state":"%s"}\n' "$state" > "$PN_RUN/state.json"
	before=$(date +%s)
	out=$(ap probe now --json --run-dir "$PN_RUN" --bin-dir "$T/probe-now/bin"); rc=$?
	expect "probe now $state: exit 0" 0 "$rc"
	expect "probe now $state: ok true" true "$(echo "$out" | jget ok)"
	requested=$(echo "$out" | jget requested_at)
	[[ "$requested" =~ ^[0-9]+$ ]] && [ "$requested" -ge "$before" ] && [ "$requested" -le "$(date +%s)" ] \
		&& ok "probe now $state: requested_at is current seconds" \
		|| bad "probe now $state: requested_at is current seconds"
	expect "probe now $state: ubus method" "$(printf 'call\nservice\nsignal')" "$(head -n 3 "$PROBE_UBUS_ARGS")"
	request=$(awk 'NR >= 4' "$PROBE_UBUS_ARGS")
	expect "probe now $state: service name" aether-proxy "$(echo "$request" | jget name)"
	# Inspect JSON text too: jget alone would not distinguish 10 from the string "10".
	[[ "$request" =~ \"signal\"[[:space:]]*:[[:space:]]*10[[:space:]]*[,}] ]] \
		&& ok "probe now $state: signal is integer 10" || bad "probe now $state: signal is integer 10"
done
[ ! -e "$PN_RUN/events.jsonl" ] && ok 'probe now success: no events' || bad 'probe now success: no events'
for state in stopped error missing corrupt; do
	rm -f "$PROBE_UBUS_ARGS" "$PN_RUN/state.json"
	case "$state" in
		missing) ;;
		corrupt) printf 'broken JSON' > "$PN_RUN/state.json" ;;
		*) printf '{"state":"%s"}\n' "$state" > "$PN_RUN/state.json" ;;
	esac
	out=$(ap probe now --json --run-dir "$PN_RUN" --bin-dir "$T/probe-now/bin"); rc=$?
	expect "probe now $state: exit 1" 1 "$rc"
	expect "probe now $state: NOT_RUNNING" NOT_RUNNING "$(echo "$out" | jget code)"
	[ ! -e "$PROBE_UBUS_ARGS" ] && ok "probe now $state: no ubus" || bad "probe now $state: no ubus"
	[ ! -e "$PN_RUN/events.jsonl" ] && ok "probe now $state: no events" || bad "probe now $state: no events"
done
printf '{"state":"running"}\n' > "$PN_RUN/state.json"
out=$(PROBE_UBUS_RC=7 ap probe now --json --run-dir "$PN_RUN" --bin-dir "$T/probe-now/bin"); rc=$?
expect 'probe now ubus failure: exit 1' 1 "$rc"
expect 'probe now ubus failure: CMD_FAILED' CMD_FAILED "$(echo "$out" | jget code)"
expect 'probe now ubus failure: exactly one event' 1 "$(wc -l < "$PN_RUN/events.jsonl" | tr -d ' ')"
expect 'probe now ubus failure: event code' CMD_FAILED "$(jget code < "$PN_RUN/events.jsonl")"
expect 'probe now ubus failure: event exit code' 7 "$(jget args.rc < "$PN_RUN/events.jsonl")"

# T10.4: isolated installed-component discovery and shared daemon version reader.
if python3 "$ROOT/tests/cli/components.py"; then
	ok 'T10.4 components CLI scenarios'
else
	bad 'T10.4 components CLI scenarios'
fi

# T10.7: one native grep scan with the former line-count algorithm as an oracle.
if python3 "$ROOT/tests/cli/data-status.py"; then
	ok 'T10.7 data status CLI scenarios'
else
	bad 'T10.7 data status CLI scenarios'
fi

# T10.8: dispatch-table coverage and real CLI isolation from broken command modules.
if python3 "$ROOT/tests/cli/lazy-subcommands.py"; then
	ok 'T10.8 lazy subcommand CLI scenarios'
else
	bad 'T10.8 lazy subcommand CLI scenarios'
fi

# T9.25: bounded cleanup lock waits, silent retries and unchanged immediate BUSY behavior.
if python3 "$ROOT/tests/cli/cleanup-wait.py"; then
	ok 'T9.25 cleanup wait CLI scenarios'
else
	bad 'T9.25 cleanup wait CLI scenarios'
fi

# T9.23: real pipeline, sync-wan decisions, daemon publication and incremental DNS reload.
if python3 "$ROOT/tests/cli/wan-dns.py"; then
	ok 'T9.23 WAN DNS CLI and lifecycle scenarios'
else
	bad 'T9.23 WAN DNS CLI and lifecycle scenarios'
fi

# T9.28: real IPv4 DNS sockets and standalone CLI diagnostics, with private UCI savedirs.
if python3 "$ROOT/tests/cli/dns-test-direct.py"; then
	ok 'T9.28 DNS socket and CLI scenarios'
else
	bad 'T9.28 DNS socket and CLI scenarios'
fi

# T9.44: the same numeric comparator diagnoses old binaries without failing check.
if python3 "$ROOT/tests/daemon/version-gate.py" --check-only; then
	ok 'T9.44 check minimum-version CLI scenarios'
else
	bad 'T9.44 check minimum-version CLI scenarios'
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
