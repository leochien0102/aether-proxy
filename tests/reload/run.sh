#!/usr/bin/env bash
# Exercise incremental reload transactions, validation budgets and docs/04 events.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The daemon filters child output with the packaged script (docs/09); point it at the source copy.
export AETHER_PROXY_TEST_LOGFILTER="$ROOT/aether-proxy/files/aether-proxy-logfilter.awk"
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

# Count only rendered-table validation, not precheck's separate kernel-feature probe.
artifact_checks() { grep -Ec 'nft -c -f .*/aether-proxy\.nft$' "$LOG"; }
reload_checkpoint() {
	applied_before=$(count_calls "$EVENTS" 'RELOAD_APPLIED')
	tests_before=$(count_calls "$LOG" 'xray run -test')
	checks_before=$(artifact_checks)
	pre_before=$(count_calls "$LOG" 'ip rule help')
	loads_before=$(count_calls "$LOG" 'nft -f ')
	xray_starts_before=$(count_calls "$SYSROOT/calls.log" 'xray run -c ')
	dns_starts_before=$(count_calls "$SYSROOT/calls.log" 'chinadns-ng -C ')
	hups_before=$(count_calls "$LOG" 'killall -HUP dnsmasq')
}
assert_applied() {
	local label="$1" from="$2" to="$3" actions="$4"
	wait_count "$EVENTS" 'RELOAD_APPLIED' "$((applied_before + 1))" \
		&& ok "T9.8 $label emits RELOAD_APPLIED" || bad "T9.8 $label emits RELOAD_APPLIED"
	expect "T9.8 $label emits exactly one success event" "$((applied_before + 1))" \
		"$(count_calls "$EVENTS" 'RELOAD_APPLIED')"
	if python3 "$ROOT/tests/reload/assert-event.py" "$EVENTS" "$from" "$to" "$actions" "${5:-0}" \
		> "$T/$label-event.json"; then
		ok "T9.8 $label event nodes actions notice and nonnegative integer timings"
		printf 'TRACE T9.8 %s: %s\n' "$label" "$(< "$T/$label-event.json")"
	else
		bad "T9.8 $label event nodes actions notice and nonnegative integer timings"
	fi
	local nft_delta=0 xray_delta=0 dns_delta=0
	case ",$actions," in *,nft_replace,*) nft_delta=1 ;; esac
	case ",$actions," in *,restart_xray,*) xray_delta=1 ;; esac
	case ",$actions," in *,restart_chinadns,*) dns_delta=1 ;; esac
	expect "T9.8 $label actions match actual nft loads" "$((loads_before + nft_delta))" \
		"$(count_calls "$LOG" 'nft -f ')"
	expect "T9.8 $label actions match actual Xray starts" "$((xray_starts_before + xray_delta))" \
		"$(count_calls "$SYSROOT/calls.log" 'xray run -c ')"
	expect "T9.8 $label actions match actual chinadns starts" "$((dns_starts_before + dns_delta))" \
		"$(count_calls "$SYSROOT/calls.log" 'chinadns-ng -C ')"
	expect "T9.8 $label chinadns action matches dnsmasq HUP" "$((hups_before + dns_delta))" \
		"$(count_calls "$LOG" 'killall -HUP dnsmasq')"
}

mkdir -p "$T/bin" "$T/conf" "$T/data" "$T/base" "$T/custom"
cp "$STUB_SRC/"* "$T/bin/"
HOST_SHA256=$(command -v sha256sum)
# Delay exactly one live-current hash to prove elapsed_ms includes work before reload.run().
cat > "$T/bin/sha256sum" <<'EOF'
#!/bin/sh
case "$1" in
	*/current/*)
		if [ -f "$SYSROOT/delay-live-hash" ]; then
			rm "$SYSROOT/delay-live-hash"
			sleep 1
		fi
		;;
esac
exec "$HOST_SHA256" "$@"
EOF
chmod +x "$T/bin/"*
cp "$FIX/aetherproxy" "$T/conf/aetherproxy"
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"

SYSROOT="$T/sysroot"
LOG="$SYSROOT/var/run/aether-proxy/calls.log"
EVENTS="$SYSROOT/var/run/aether-proxy/events.jsonl"
NODE_A=n_00000000000000000000000000000001
NODE_B=n_00000000000000000000000000000002
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
STUB_LOG="$LOG" SYSROOT="$SYSROOT" HOST_SHA256="$HOST_SHA256" PATH="$T/bin:$PATH" \
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

# No-change reload still runs prerequisites and nft validation, but neither Xray test nor actions.
reload_checkpoint
kill -HUP "$DAEMON_PID"
wait_count "$LOG" 'ip rule help' "$((pre_before + 1))"
sleep 0.3
expect 'T9.8 unchanged reload has no success event' "$applied_before" "$(count_calls "$EVENTS" 'RELOAD_APPLIED')"
expect 'T9.8 unchanged reload skips Xray test' "$tests_before" "$(count_calls "$LOG" 'xray run -test')"
expect 'T9.8 unchanged reload validates artifact once' "$((checks_before + 1))" "$(artifact_checks)"
expect 'T9.8 unchanged reload prechecks once' "$((pre_before + 1))" "$(count_calls "$LOG" 'ip rule help')"

# Mode change: nft and chinadns outputs change; Xray's process must retain its pid.
reload_checkpoint
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
assert_applied mode "$NODE_A" "$NODE_A" nft_replace,restart_chinadns
expect 'T9.8 mode reload skips Xray test' "$tests_before" "$(count_calls "$LOG" 'xray run -test')"
expect 'T9.8 mode reload prechecks exactly once' "$((pre_before + 1))" "$(count_calls "$LOG" 'ip rule help')"
# See TODO(design) at the second validation: mode changes nft, so both passes are mandatory.
expect 'T9.8 mode reload validates nft twice per docs/04' "$((checks_before + 2))" "$(artifact_checks)"
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
reload_checkpoint
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

assert_applied node "$NODE_A" "$NODE_B" nft_replace,restart_xray
expect 'T9.8 node switch tests Xray exactly once' "$((tests_before + 1))" "$(count_calls "$LOG" 'xray run -test')"
expect 'T9.8 node switch prechecks exactly once' "$((pre_before + 1))" "$(count_calls "$LOG" 'ip rule help')"
expect 'T9.8 node switch validates nft exactly twice' "$((checks_before + 2))" "$(artifact_checks)"

touch "$SYSROOT/resolve-always-fail"
sed -i "s/option node 'n_00000000000000000000000000000002'/option node 'n_00000000000000000000000000000001'/" \
	"$T/conf/aetherproxy"
old_calls=$(count_calls "$LOG" 'resolveip -4 -t 3 node.example.com')
reload_checkpoint
touch "$SYSROOT/delay-live-hash"
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

assert_applied signal-timing "$NODE_B" "$NODE_A" nft_replace,restart_xray 900
[ ! -e "$SYSROOT/delay-live-hash" ] \
	&& ok 'T9.8 elapsed includes delayed live hashing after SIGHUP' \
	|| bad 'T9.8 elapsed includes delayed live hashing after SIGHUP'

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

# Live gfw4 elements make the rough plan differ only in nft; the export re-render then matches,
# so the final plan is empty. A path change must still refresh metadata on that branch too.
printf '["198.51.100.1"]\n' > "$SYSROOT/gfw4-elem"
reload_checkpoint
nft_before=$(count_calls "$LOG" 'nft -f ')
sed -i "s/option mode 'bypass_cn'/option mode 'gfw'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_count "$LOG" 'nft -f ' "$((nft_before + 1))" \
	&& ok 'T9.5 mode reload embeds live gfw4 elements' || bad 'T9.5 mode reload embeds live gfw4 elements'
grep -Fq 'elements = { 198.51.100.1 }' "$SYSROOT/var/run/aether-proxy/current/aether-proxy.nft" \
	&& ok 'T9.5 running nft carries the live element' || bad 'T9.5 running nft carries the live element'
# nft is installed before the state and event commit; do not sample the next baseline early.
wait_count "$EVENTS" 'RELOAD_APPLIED' "$((applied_before + 1))" \
	&& ok 'T9.8 live-set setup has committed' || bad 'T9.8 live-set setup has committed'
nft_before=$(count_calls "$LOG" 'nft -f ')
reload_checkpoint
rm "$T/bin/xray"
sed -i "/config main 'main'/a\\\toption xray_bin '$T/bin/xray-alt'" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_field components.xray.version 26.10.10 \
	&& ok 'T9.5 path change refreshes version when only live set elements differ' \
	|| bad 'T9.5 path change refreshes version when only live set elements differ'
expect 'T9.5 live-element reload does not replace nft' "$nft_before" "$(count_calls "$LOG" 'nft -f ')"
expect 'T9.8 live-set no-op has no success event' "$applied_before" "$(count_calls "$EVENTS" 'RELOAD_APPLIED')"
expect 'T9.8 live-set no-op skips Xray test' "$tests_before" "$(count_calls "$LOG" 'xray run -test')"

# Failure paths now belong to the daemon, rather than init's discarded check output.
# Compare installed artifacts and child pids as well as node_id to detect partial application.
cp "$T/conf/aetherproxy" "$T/good-config"
failure_checkpoint() {
	reload_checkpoint
	failure_events_before=$(count_calls "$EVENTS" "$1")
	nft_loads_before=$(count_calls "$LOG" 'nft -f ')
	state_before=$("$UCODE" "$ROOT/tests/cli/jget.uc" -- node_id < "$SYSROOT/var/run/aether-proxy/state.json")
	xray_before=$(< "$SYSROOT/xray.pid")
	dns_before=$(< "$SYSROOT/chinadns.pid")
	sha256sum "$SYSROOT/var/run/aether-proxy/current/"* > "$T/current-before"
}
assert_failed() {
	local code="$1" label="$2"
	wait_count "$EVENTS" "$code" "$((failure_events_before + 1))" \
		&& ok "T9.8 $label records $code" || bad "T9.8 $label records $code"
	sleep 0.2
	# A persistent apply failure also logs the failed primitive and failed rollback.
	if [ "$label" != action-failure ]; then
		expect "T9.8 $label has exactly one $code" "$((failure_events_before + 1))" \
			"$(count_calls "$EVENTS" "$code")"
	fi
	expect "T9.8 $label has no success event" "$applied_before" "$(count_calls "$EVENTS" 'RELOAD_APPLIED')"
	expect "T9.8 $label keeps node_id" "$state_before" \
		"$("$UCODE" "$ROOT/tests/cli/jget.uc" -- node_id < "$SYSROOT/var/run/aether-proxy/state.json")"
	expect "T9.8 $label keeps Xray pid" "$xray_before" "$(< "$SYSROOT/xray.pid")"
	expect "T9.8 $label keeps chinadns pid" "$dns_before" "$(< "$SYSROOT/chinadns.pid")"
	sha256sum "$SYSROOT/var/run/aether-proxy/current/"* > "$T/current-after"
	cmp -s "$T/current-before" "$T/current-after" \
		&& ok "T9.8 $label keeps current artifacts" || bad "T9.8 $label keeps current artifacts"
	if [ "$label" != action-failure ]; then
		expect "T9.8 $label never loads nft" "$nft_loads_before" "$(count_calls "$LOG" 'nft -f ')"
	fi
	cp "$T/good-config" "$T/conf/aetherproxy"
}

failure_checkpoint CONFIG_INVALID
sed -i "s/option mode 'gfw'/option mode 'invalid'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
assert_failed CONFIG_INVALID invalid-config

failure_checkpoint PRECHECK_FAILED
chmod -x "$T/bin/xray-alt"
kill -HUP "$DAEMON_PID"
assert_failed PRECHECK_FAILED missing-component
chmod +x "$T/bin/xray-alt"

failure_checkpoint RENDER_INVALID
printf '1\n' > "$SYSROOT/xray-test-rc"
sed -i "s/option port '445'/option port '446'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
assert_failed RENDER_INVALID invalid-xray
expect 'T9.8 failed Xray validation was attempted once' "$((tests_before + 1))" "$(count_calls "$LOG" 'xray run -test')"
rm "$SYSROOT/xray-test-rc"

failure_checkpoint NODE_RESOLVE_FAILED
sed -i "s/option address 'node.example.com'/option address 'uncached-failure.example'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
assert_failed NODE_RESOLVE_FAILED unresolved-node

failure_checkpoint RENDER_INVALID
printf '2\n' > "$SYSROOT/nft-check-fail-after"
sed -i "s/option mode 'gfw'/option mode 'bypass_cn'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
assert_failed RENDER_INVALID invalid-restored-nft
expect 'T9.8 restored nft fails on second artifact check' "$((checks_before + 2))" "$(artifact_checks)"
grep 'RENDER_INVALID' "$EVENTS" | grep -Fq '"artifact": "nft"' \
	&& ok 'T9.8 restored nft error names artifact nft' || bad 'T9.8 restored nft error names artifact nft'
expect 'T9.8 restored nft failure does not repeat precheck' "$((pre_before + 1))" "$(count_calls "$LOG" 'ip rule help')"
rm "$SYSROOT/nft-check-fail-after"

failure_checkpoint START_FAILED
touch "$SYSROOT/nft-load-fail"
sed -i "s/option mode 'gfw'/option mode 'bypass_cn'/" "$T/conf/aetherproxy"
kill -HUP "$DAEMON_PID"
assert_failed START_FAILED action-failure
grep 'START_FAILED' "$EVENTS" | grep -Fq '"step": "reload:actions"' \
	&& ok 'T9.8 action failure retains reload step prefix' || bad 'T9.8 action failure retains reload step prefix'
rm "$SYSROOT/nft-load-fail"

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
