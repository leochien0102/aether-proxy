#!/usr/bin/env bash
# CLI scenario tests for `aether-proxy check` and `render` (docs/tasks/m1 T1.7).
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

# --- 1. enabled=1 without a node: configuration error, exit 2, nothing staged
out="$(ap check --json --no-precheck $(opts "$FIX/t11-err-enabled-no-node" "$T/run1") 2>"$T/check-fail.stderr")"; rc=$?
expect "no node: exit code 2" 2 "$rc"
expect "check --json failure: stderr empty" "" "$(cat "$T/check-fail.stderr")"
expect "no node: ok false" false "$(echo "$out" | jget ok)"
expect "no node: code" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "no node: error field" main.node "$(echo "$out" | jget errors.0.field)"
expect "no node: error code" required "$(echo "$out" | jget errors.0.code)"
[ ! -e "$T/run1" ] && ok "no node: run dir untouched" || bad "no node: run dir untouched"

# --- 2. valid config: exit 0, staging files equal render output byte for byte
out="$(ap check --json --no-precheck $(opts "$FIX/sample" "$T/run2") 2>"$T/check-ok.stderr")"; rc=$?
expect "valid: exit code 0" 0 "$rc"
expect "check --json success: stderr empty" "" "$(cat "$T/check-ok.stderr")"
expect "valid: ok true" true "$(echo "$out" | jget ok)"
expect "valid: staging path" "$T/run2/staging" "$(echo "$out" | jget staging)"

declare -A FILES=( [nft]=aether-proxy.nft [chinadns]=chinadns.conf [dnsmasq]=dnsmasq.conf [xray]=xray.json )
for name in nft chinadns dnsmasq xray; do
	ap render "$name" $(opts "$FIX/sample" "$T/run2") > "$T/render-$name" 2>/dev/null; rc=$?
	expect "render $name: exit code 0" 0 "$rc"
	if cmp -s "$T/render-$name" "$T/run2/staging/${FILES[$name]}" && [ -s "$T/render-$name" ]; then
		ok "render $name: identical to staged ${FILES[$name]}"
	else
		bad "render $name: identical to staged ${FILES[$name]}"
	fi
done
[ "$(ls "$T/run2" | tr '\n' ' ')" == "staging " ] && ok "valid: only staging created in run dir" || bad "valid: only staging created in run dir"
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
grep -F "chnlist-file" "$T/run3/staging/chinadns.conf" | grep -qF "$T/data/chnlist.txt" \
	&& ok "data dir overrides baseline: chnlist from data dir" || bad "data dir overrides baseline: chnlist from data dir"
grep -F "chnlist-file" "$T/run3/staging/chinadns.conf" | grep -qF "$T/base/apple.txt" \
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
