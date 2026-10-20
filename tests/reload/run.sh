#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
FIX="$ROOT/tests/fixtures/sample"
STUB_SRC="$ROOT/tests/stubs/daemon-bin"
T="$(mktemp -d)"
DAEMON_PID=''
pass=0
fail=0

cleanup() {
	local f pid
	if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then
		kill -TERM "$DAEMON_PID" 2>>"$T/quiet.err"
		for _ in {1..100}; do
			if ! kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then break; fi
			sleep 0.05
		done
		if kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then kill -KILL "$DAEMON_PID" 2>>"$T/quiet.err"; fi
		wait "$DAEMON_PID" 2>>"$T/quiet.err"
	fi
	for f in "$T/sysroot/xray.pid" "$T/sysroot/chinadns.pid"; do
		[ -f "$f" ] || continue
		read -r pid < "$f"
		if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>>"$T/quiet.err"; then
			kill -TERM "$pid" 2>>"$T/quiet.err"
			for _ in {1..15}; do
				if ! kill -0 "$pid" 2>>"$T/quiet.err"; then break; fi
				sleep 0.1
			done
			if kill -0 "$pid" 2>>"$T/quiet.err"; then kill -KILL "$pid" 2>>"$T/quiet.err"; fi
		fi
	done
	if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept reload-test temp: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
count_calls() { awk -v needle="$2" 'index($0,needle) { n++ } END { print n+0 }' "$1"; }
wait_count() {
	local file="$1" token="$2" expected="$3"
	for _ in {1..200}; do
		[ "$(count_calls "$file" "$token")" -ge "$expected" ] && return 0
		if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then return 1; fi
		sleep 0.05
	done
	return 1
}

# Wait for committed state, not merely a restarted child: publication follows readiness.
wait_field() {
	local field="$1" wanted="$2" got=''
	for _ in {1..200}; do
		if [ -s "$SYSROOT/var/run/aether-proxy/state.json" ]; then
			got=$("$UCODE" "$ROOT/tests/cli/jget.uc" -- "$field" < "$SYSROOT/var/run/aether-proxy/state.json")
		fi
		[ "$got" = "$wanted" ] && return 0
		sleep 0.05
	done
	return 1
}

mkdir -p "$T/bin" "$T/conf" "$T/data" "$T/base" "$T/custom"
cp "$STUB_SRC/"* "$T/bin/"
chmod +x "$T/bin/"*
cp "$FIX/aetherproxy" "$T/conf/aetherproxy"
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"

SYSROOT="$T/sysroot"
LOG="$SYSROOT/var/run/aether-proxy/calls.log"
mkdir -p "$SYSROOT/etc/init.d" "$SYSROOT/var/etc" "$SYSROOT/tmp/dnsmasq.d" \
	"$SYSROOT/proc/net" "$SYSROOT/sys/class/net/br-lan" "$SYSROOT/etc/aether-proxy/state" \
	"$SYSROOT/var/run/aether-proxy/current" "$SYSROOT/var/lock"
cat > "$SYSROOT/var/etc/dnsmasq.conf.cfg01411c" <<'EOF'
interface=br-lan
conf-dir=/tmp/dnsmasq.d,*.conf
EOF
cat > "$SYSROOT/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
printf 'dnsmasq %s\n' "$*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$SYSROOT/etc/init.d/dnsmasq"
: > "$LOG"
: > "$SYSROOT/ip-rules"
: > "$SYSROOT/ip-routes"
: > "$SYSROOT/conflicts"
touch "$SYSROOT/nft-table"
printf 'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$SYSROOT/proc/net/tcp"
printf '  0: 0100007F:7968 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n' >> "$SYSROOT/proc/net/tcp"
printf '  1: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n' >> "$SYSROOT/proc/net/tcp"

args=(--sys-root "$SYSROOT" --bin-dir "$T/bin" --confdir "$T/conf" \
	--data-dir "$T/data" --baseline-dir "$T/base" --custom-dir "$T/custom")
STUB_LOG="$LOG" SYSROOT="$SYSROOT" PATH="$T/bin:$PATH" \
	"$UCODE" -S "$ENTRY" -- daemon "${args[@]}" >"$T/daemon.stdout" 2>"$T/daemon.stderr" &
DAEMON_PID=$!
for _ in {1..200}; do
	if [ -s "$SYSROOT/var/run/aether-proxy/state.json" ] && grep -q '"state": "starting"' "$SYSROOT/var/run/aether-proxy/state.json" && \
		[ -f "$SYSROOT/xray.pid" ] && [ -f "$SYSROOT/chinadns.pid" ]; then break; fi
	if ! kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then break; fi
	sleep 0.05
done
if [ ! -f "$SYSROOT/xray.pid" ] || [ ! -f "$SYSROOT/chinadns.pid" ]; then
	bad "daemon startup before reload scenarios" "$(cat "$T/daemon.stderr")"
	if kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then kill -TERM "$DAEMON_PID" 2>>"$T/quiet.err"; wait "$DAEMON_PID" 2>>"$T/quiet.err"; fi
	DAEMON_PID=''
	echo "reload: $pass passed, $fail failed"
	exit 1
fi

wait_field state running && ok 'T9.5 startup reaches running' || bad 'T9.5 startup reaches running'
versions_before=$("$UCODE" "$ROOT/tests/cli/jget.uc" -- components < "$SYSROOT/var/run/aether-proxy/state.json")

# Mode change: nft and chinadns outputs change; Xray's process must retain its pid.
xray_before=$(cat "$SYSROOT/xray.pid")
nft_before=$(count_calls "$LOG" 'nft -f ')
dns_before=$(cat "$SYSROOT/chinadns.pid")
sed -i "s/option mode 'gfw'/option mode 'bypass_cn'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_count "$LOG" 'nft -f ' "$((nft_before + 1))" && ok "mode reload replaces nft" || bad "mode reload replaces nft" "$(cat "$SYSROOT/daemon.stderr")"
dns_after=''
for _ in {1..200}; do
	if [ -f "$SYSROOT/chinadns.pid" ]; then read -r dns_after < "$SYSROOT/chinadns.pid"; fi
	[ -n "$dns_after" ] && [ "$dns_after" != "$dns_before" ] && break
	if ! kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then break; fi
	sleep 0.05
done
[ -n "$dns_after" ] && [ "$dns_after" != "$dns_before" ] && ok "mode reload restarts chinadns" \
	|| bad "mode reload restarts chinadns" "old=$dns_before new=$dns_after"
xray_after=$(cat "$SYSROOT/xray.pid")
expect "mode reload leaves xray pid unchanged" "$xray_before" "$xray_after"
# Change live banners: unchanged paths must preserve the original version, not re-query.
printf 'Xray SHOULD-NOT-REFRESH\n' > "$SYSROOT/xray-version"
printf 'ChinaDNS-NG SHOULD-NOT-REFRESH\n' > "$SYSROOT/chinadns-version"

# Node-only change: the rendered Xray artifact changes, while nft/chinadns do not.
nft_before=$(count_calls "$LOG" 'nft -f ')
dns_before=$(count_calls "$SYSROOT/calls.log" 'chinadns-ng ')
xray_before=$(cat "$SYSROOT/xray.pid")
sed -i "s/option port '443'/option port '444'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
for _ in {1..200}; do
	xray_after=''
	if [ -f "$SYSROOT/xray.pid" ]; then read -r xray_after < "$SYSROOT/xray.pid"; fi
	[ -n "$xray_after" ] && [ "$xray_after" != "$xray_before" ] && break
	if ! kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then break; fi
	sleep 0.05
done
[ "$xray_after" != "$xray_before" ] && ok "node-only reload restarts xray" || bad "node-only reload restarts xray"
expect "node-only reload does not replace nft" "$nft_before" "$(count_calls "$LOG" 'nft -f ')"
expect "node-only reload does not restart chinadns" "$dns_before" "$(count_calls "$SYSROOT/calls.log" 'chinadns-ng ')"

# Custom list content only: chinadns.conf names the list by path, so the text is unchanged;
# the artifact hash covers the list content and chinadns-ng must still restart (04).
nft_before=$(count_calls "$LOG" 'nft -f ')
dns_before=$(count_calls "$SYSROOT/calls.log" 'chinadns-ng ')
xray_before=$(cat "$SYSROOT/xray.pid")
printf 'example-proxy.test\n' >> "$T/custom/proxy_domain.txt"
kill -HUP "$DAEMON_PID"
for _ in {1..200}; do
	[ "$(count_calls "$SYSROOT/calls.log" 'chinadns-ng ')" -gt "$dns_before" ] && break
	sleep 0.05
done
[ "$(count_calls "$SYSROOT/calls.log" 'chinadns-ng ')" -gt "$dns_before" ] && ok "list-only reload restarts chinadns" || bad "list-only reload restarts chinadns"
expect "list-only reload does not replace nft" "$nft_before" "$(count_calls "$LOG" 'nft -f ')"
expect "list-only reload leaves xray pid unchanged" "$xray_before" "$(cat "$SYSROOT/xray.pid")"

# Node address change: the bootstrap IP is re-resolved, so node_ip4 (nft) and Xray both change.
nft_before=$(count_calls "$LOG" 'nft -f ')
xray_before=$(cat "$SYSROOT/xray.pid")
sed -i "s/option address 'node.example.com'/option address '198.51.100.7'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_count "$LOG" 'nft -f ' $((nft_before + 1))
for _ in {1..200}; do
	xray_after=''
	if [ -f "$SYSROOT/xray.pid" ]; then read -r xray_after < "$SYSROOT/xray.pid"; fi
	[ -n "$xray_after" ] && [ "$xray_after" != "$xray_before" ] && break
	sleep 0.05
done
[ "$(count_calls "$LOG" 'nft -f ')" -gt "$nft_before" ] && ok "address reload replaces nft" || bad "address reload replaces nft"
grep -q '198.51.100.7' "$SYSROOT/var/run/aether-proxy/current/aether-proxy.nft" \
	&& ok "address reload puts the new IP in node_ip4" || bad "address reload puts the new IP in node_ip4"
grep -q '203.0.113.20' "$SYSROOT/var/run/aether-proxy/current/aether-proxy.nft" \
	&& bad "address reload drops the old node IP" || ok "address reload drops the old node IP"
[ "$xray_after" != "$xray_before" ] && ok "address reload restarts xray" || bad "address reload restarts xray"

# T9.5: switch to an unseen domain with a transient failure, then back with DNS fully down.
# Startup already seeded the original domain; resolving B must not overwrite A's cache entry.
wait_field node_ip 198.51.100.7 \
	&& ok 'T9.5 previous address reload committed' || bad 'T9.5 previous address reload committed'
expect 'T9.5 reload preserves both component versions at unchanged paths' "$versions_before" \
	"$("$UCODE" "$ROOT/tests/cli/jget.uc" -- components < "$SYSROOT/var/run/aether-proxy/state.json")"
expect 'T9.5 unchanged paths do not query Xray version again' 1 "$(count_calls "$LOG" 'xray version')"
expect 'T9.5 unchanged paths do not query ChinaDNS version again' 1 "$(count_calls "$LOG" 'chinadns-ng -V')"

cat >> "$T/conf/aetherproxy" <<'CONF'

config node 'n_00000000000000000000000000000002'
	option protocol 'trojan'
	option security 'tls'
	option address 'new-node.example'
	option port '443'
	option password 'new-secret'
CONF
sed -i "s/option address '198.51.100.7'/option address 'node.example.com'/;\
	s/option node 'n_00000000000000000000000000000001'/option node 'n_00000000000000000000000000000002'/" \
	"$T/conf/aetherproxy"
printf '1\n' > "$SYSROOT/resolve-failures"
printf '198.51.100.8\n' > "$SYSROOT/resolve-ip"
kill -HUP "$DAEMON_PID"
wait_field node_id n_00000000000000000000000000000002 \
	&& ok 'T9.5 unseen node switches successfully after transient DNS failure' \
	|| bad 'T9.5 unseen node switches successfully after transient DNS failure'
expect 'T9.5 unseen node uses exactly two bounded DNS attempts' 2 \
	"$(count_calls "$LOG" 'resolveip -4 -t 3 new-node.example')"
expect 'T9.5 unseen node persists its resolved IP' 198.51.100.8 \
	"$("$UCODE" "$ROOT/tests/cli/jget.uc" -- node_ip < "$SYSROOT/var/run/aether-proxy/state.json")"
expect 'T9.5 transient DNS failure emits no resolve events' 0 \
	"$(count_calls "$SYSROOT/var/run/aether-proxy/events.jsonl" 'NODE_RESOLVE_')"

touch "$SYSROOT/resolve-always-fail"
sed -i "s/option node 'n_00000000000000000000000000000002'/option node 'n_00000000000000000000000000000001'/" \
	"$T/conf/aetherproxy"
old_calls=$(count_calls "$LOG" 'resolveip -4 -t 3 node.example.com')
kill -HUP "$DAEMON_PID"
wait_field node_id n_00000000000000000000000000000001 \
	&& ok 'T9.5 switches back to original node using retained LKG during DNS outage' \
	|| bad 'T9.5 switches back to original node using retained LKG during DNS outage'
expect 'T9.5 switch back exhausts three DNS attempts before LKG' "$((old_calls + 3))" \
	"$(count_calls "$LOG" 'resolveip -4 -t 3 node.example.com')"
expect 'T9.5 switch back persists original IP' 203.0.113.20 \
	"$("$UCODE" "$ROOT/tests/cli/jget.uc" -- node_ip < "$SYSROOT/var/run/aether-proxy/state.json")"
expect 'T9.5 switch back records exactly one fallback' 1 \
	"$(count_calls "$SYSROOT/var/run/aether-proxy/events.jsonl" 'NODE_RESOLVE_FALLBACK')"
expect 'T9.5 switch back never records resolve failure' 0 \
	"$(count_calls "$SYSROOT/var/run/aether-proxy/events.jsonl" 'NODE_RESOLVE_FAILED')"

# A new executable plus a rendered port change exercises apply_plan's fresh version lookup.
# --bin-dir intentionally takes precedence over UCI, so remove the default fixture name.
cp "$T/bin/xray" "$T/bin/xray-original"
rm "$T/bin/xray"
cat > "$T/bin/xray-alt" <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then
	printf 'xray-alt version\n' >> "$STUB_LOG"
	printf 'Xray 26.10.10 (alternate binary)\n'
	exit 0
fi
exec "$(dirname "$0")/xray-original" "$@"
EOF
chmod +x "$T/bin/xray-alt"
sed -i "/config main 'main'/a\\\toption xray_bin '$T/bin/xray-alt'" "$T/conf/aetherproxy"
sed -i "s/option port '444'/option port '445'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_field components.xray.version 26.10.10 \
	&& ok 'T9.5 changed executable path refreshes Xray version on applied reload' \
	|| bad 'T9.5 changed executable path refreshes Xray version on applied reload'
expect 'T9.5 new executable version queried exactly once' 1 "$(count_calls "$LOG" 'xray-alt version')"
expect 'T9.5 changed Xray path preserves ChinaDNS version' 2025.06.20 \
	"$("$UCODE" "$ROOT/tests/cli/jget.uc" -- components.chinadns-ng.version \
	< "$SYSROOT/var/run/aether-proxy/state.json")"

# Path-only overrides do not change rendered outputs, but must still refresh metadata.
printf 'Xray 26.11.1 (original path replaced)\n' > "$SYSROOT/xray-version"
cp "$T/bin/xray-original" "$T/bin/xray"
sed -i '/option xray_bin /d' "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_field components.xray.version 26.11.1 \
	&& ok 'T9.5 path-only reload refreshes component metadata without renderer changes' \
	|| bad 'T9.5 path-only reload refreshes component metadata without renderer changes'
expect 'T9.5 path-only reload records discovered path' "$T/bin/xray" \
	"$("$UCODE" "$ROOT/tests/cli/jget.uc" -- components.xray.path < "$SYSROOT/var/run/aether-proxy/state.json")"

# Disable: the pure plan returns stop alone and daemon follows the normal stop path.
sed -i "s/option enabled '1'/option enabled '0'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
for _ in {1..150}; do
	if ! kill -0 "$DAEMON_PID" 2>>"$T/quiet.err"; then break; fi
	sleep 0.05
done
wait "$DAEMON_PID"; rc=$?; DAEMON_PID=''
expect "disable reload exits through stop" 0 "$rc"
expect "disable reload writes stopped state" stopped "$("$UCODE" "$ROOT/tests/cli/jget.uc" -- state < "$SYSROOT/var/run/aether-proxy/state.json")"

echo "reload: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
