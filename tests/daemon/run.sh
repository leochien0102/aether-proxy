#!/usr/bin/env bash
# Exercise startup, shutdown and signal-driven monitoring with isolated command stubs.
# Design: docs/04 lifecycle and docs/10 Dashboard part 2 (reload-triggered probes).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"
FIX="$ROOT/tests/fixtures/sample"
STUB_SRC="$ROOT/tests/stubs/daemon-bin"
T="$(mktemp -d)"
QUIET="$T/cleanup.stderr"
DAEMON_PID=''
NETWORK_PID=''
pass=0
fail=0

cleanup_children() {
	local root="$1" f pid
	for f in "$root"/xray.pid "$root"/chinadns.pid; do
		[ -f "$f" ] || continue
		read -r pid < "$f"
		if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>>"$QUIET"; then
			kill -TERM "$pid" 2>>"$QUIET"
			for _ in {1..10}; do
				if ! kill -0 "$pid" 2>>"$QUIET"; then break; fi
				sleep 0.1
			done
			if kill -0 "$pid" 2>>"$QUIET"; then kill -KILL "$pid" 2>>"$QUIET"; fi
		fi
	done
}

cleanup() {
	local d
	if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>>"$QUIET"; then
		kill -TERM "$DAEMON_PID" 2>>"$QUIET"
		for _ in {1..50}; do
			if ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then break; fi
			sleep 0.1
		done
		if kill -0 "$DAEMON_PID" 2>>"$QUIET"; then kill -KILL "$DAEMON_PID" 2>>"$QUIET"; fi
		wait "$DAEMON_PID" 2>>"$QUIET"
	fi
	if [ -n "$NETWORK_PID" ] && kill -0 "$NETWORK_PID" 2>>"$QUIET"; then
		kill -TERM "$NETWORK_PID" 2>>"$QUIET"
		wait "$NETWORK_PID" 2>>"$QUIET"
	fi
	for d in "$T"/sys*; do [ -d "$d" ] && cleanup_children "$d"; done
	if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept daemon-test temp: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
has_line() { grep -Fq -- "$2" "$1"; }
line_no() { awk -v needle="$2" 'index($0, needle) { print NR; exit }' "$1"; }
jget() { "$UCODE" "$JGET" -- "$1"; }
count_calls() { awk -v needle="$2" 'index($0, needle) { n++ } END { print n+0 }' "$1"; }
wait_count() {
	local file="$1" needle="$2" wanted="$3"
	for _ in {1..200}; do
		[ "$(count_calls "$file" "$needle")" -ge "$wanted" ] && return 0
		if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then return 1; fi
		sleep 0.05
	done
	return 1
}

mkdir -p "$T/data" "$T/base" "$T/custom" "$T/bin"
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"
cp "$STUB_SRC/nft" "$T/bin/nft"
cp "$STUB_SRC/ip" "$T/bin/ip"
cp "$STUB_SRC/resolveip" "$T/bin/resolveip"
cp "$STUB_SRC/killall" "$T/bin/killall"
cp "$STUB_SRC/curl" "$T/bin/curl-original"
# Record real invocation times without changing the shared stubs used by other cards.
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
read -r uptime rest < /proc/uptime
printf '%s\n' "$uptime" >> "$SYSROOT/curl-times"
if [ ! -f "$SYSROOT/first-probe-chinadns.conf" ]; then
	cp "$SYSROOT/var/run/aether-proxy/current/chinadns.conf" "$SYSROOT/first-probe-chinadns.conf" || exit 1
fi
exec "$(dirname "$0")/curl-original" "$@"
EOF
cp "$STUB_SRC/xray" "$T/bin/xray-original"
# Keep delayed-listener controls local to this suite, not in shared infrastructure.
cat > "$T/bin/xray" <<'EOF'
#!/bin/sh
if [ "$1" = run ] && [ "$2" = -c ]; then
	root=${3%/var/run/aether-proxy/current/*}
	if [ -f "$root/xray-listen-delay" ]; then
		read -r uptime rest < /proc/uptime
		printf '%s\n' "$uptime" >> "$root/xray-launch-times"
		sleep 1
	fi
fi
if [ "$1" = run ] && [ "$2" = -test ]; then
	root=${4%/var/run/aether-proxy/staging/*}
	if [ -f "$root/xray-test-delay" ]; then sleep 2; fi
fi
exec "$(dirname "$0")/xray-original" "$@"
EOF
cp "$STUB_SRC/chinadns-ng" "$T/bin/chinadns-ng"
cp "$STUB_SRC/kill" "$T/bin/kill"
chmod +x "$T/bin/"*

make_root() {
	local root="$1"
	mkdir -p "$root/etc/init.d" "$root/var/etc" "$root/tmp/dnsmasq.d" \
		"$root/proc/net" "$root/sys/class/net/br-lan" "$root/var/run/aether-proxy" \
		"$root/var/lock" "$root/etc/aether-proxy/state" "$root/etc/config"
	cat > "$root/var/etc/dnsmasq.conf.cfg01411c" <<EOF
interface=br-lan
conf-dir=/tmp/dnsmasq.d,*.conf
EOF
	cat > "$root/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
printf 'dnsmasq %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_DNSMASQ_RC:-0}"
EOF
	chmod +x "$root/etc/init.d/dnsmasq"
	printf 'local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' > "$root/proc/net/tcp"
	# The DNS substitute stays alive but opens no socket; expose its listener so the
	# new startup tick plus a signal tick do not falsely exercise DNS fail-safe.
	printf '  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n' \
		>> "$root/proc/net/tcp"
	: > "$root/ip-rules"
	: > "$root/ip-routes"
	: > "$root/conflicts"
	: > "$root/curl-count"
}

ap() { "$UCODE" -S "$ENTRY" -- "$@"; }
args_for() {
	local root="$1"
	echo --sys-root "$root" --bin-dir "$T/bin" --confdir "$FIX" \
		--data-dir "$T/data" --baseline-dir "$T/base" --custom-dir "$T/custom"
}
start_daemon() {
	local root="$1" log="$2"; shift 2
	: > "$log"
	(
		export STUB_LOG="$log" SYSROOT="$root" STUB_CURL_COUNT_FILE="$root/curl-count" PATH="$T/bin:$PATH"
		export STUB_NFT_FAIL_ONCE="${STUB_NFT_FAIL_ONCE:-0}"
		export AETHER_PROXY_TEST_RETRY_DELAY="${AETHER_PROXY_TEST_RETRY_DELAY:-}"
		exec "$UCODE" -S "$ENTRY" -- daemon $(args_for "$root") "$@"
	) >"$root/daemon.stdout" 2>"$root/daemon.stderr" &
	DAEMON_PID=$!
}
wait_for() {
	local file="$1" pattern="$2" attempts="${3:-400}"	# 20 s: a loaded host is slow, a hit returns at once
	for _ in $(seq 1 "$attempts"); do
		[ -e "$file" ] && { [ -z "$pattern" ] || grep -Fq -- "$pattern" "$file"; } && return 0
		if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then return 1; fi
		sleep 0.05
	done
	return 1
}
stop_daemon() {
	local pid="$DAEMON_PID"
	[ -n "$pid" ] || return 0
	kill -TERM "$pid"
	# Up to 30 s (procd's term_timeout): SIGTERM waits for the synchronous part of a running
	# monitor round, which some scenarios stretch on purpose (STUB_RESOLVE_DELAY).
	for _ in {1..600}; do
		if ! kill -0 "$pid" 2>>"$QUIET"; then break; fi
		sleep 0.05
	done
	if kill -0 "$pid" 2>>"$QUIET"; then
		bad "daemon exited after SIGTERM" "still alive"
		kill -KILL "$pid"
	fi
	wait "$pid"; local rc=$?
	DAEMON_PID=''
	return "$rc"
}
assert_no_children() {
	local root="$1" f pid
	for f in "$root"/xray.pid "$root"/chinadns.pid; do
		if [ -f "$f" ]; then
			read -r pid < "$f"
			if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>>"$QUIET"; then
				bad "no surviving stub child: $f" "pid $pid is alive"
				continue
			fi
		fi
		ok "no surviving stub child: $(basename "$f")"
	done
}

start_loopback_listener() {
	local portfile="$1" accepted="$2"
	cat > "$T/network-listener.uc" <<'UCODE'
'use strict';
import * as fs from 'fs';
import * as socket from 'socket';
let server = socket.create(socket.AF_INET, socket.SOCK_STREAM);
if (server == null || !server.bind({ address: '127.0.0.1', port: 0 }) || !server.listen(8))
	exit(1);
let bound = server.sockname();
let p = fs.open(ARGV[0], 'w');
if (p == null) exit(1);
p.write(`${bound.port}\n`); p.close();
while (true) {
	let peer = server.accept();
	if (peer != null) {
		peer.close();
		let f = fs.open(ARGV[1], 'a');
		if (f != null) { f.write('accepted\n'); f.close(); }
	}
}
UCODE
	"$UCODE" "$T/network-listener.uc" "$portfile" "$accepted" >"$T/network-listener.stdout" 2>"$T/network-listener.stderr" &
	NETWORK_PID=$!
	for _ in {1..100}; do [ -s "$portfile" ] && return 0; sleep 0.05; done
	return 1
}

# 1. Startup begins on T2, then the first immediate success reaches running/T1 within 5 s.
R1="$T/sys1"; L1="$T/sys1/calls.log"; make_root "$R1"; : > "$L1"
L1_START="$T/sys1/startup.log"
printf '{"gfw4":["1.2.3.4"],"udirect4":[],"uproxy4":[]}\n' > "$R1/var/run/aether-proxy/sets.save"
read -r startup_time rest < /proc/uptime
start_daemon "$R1" "$L1"
if wait_for "$R1/var/run/aether-proxy/state.json" '"state": "running"' 100; then
	read -r running_time rest < /proc/uptime
	read -r first_curl_time < "$R1/curl-times"
	printf 'TIMING uptime seconds: startup=%s first-curl=%s running=%s\n' \
		"$startup_time" "$first_curl_time" "$running_time"
	awk -v start="$startup_time" -v probe="$first_curl_time" -v running="$running_time" \
		'BEGIN { exit !(probe >= start && probe - start < 5 && running - start < 5) }' \
		&& ok 'startup curl and running state arrive within 5 seconds' \
		|| bad 'startup curl and running state arrive within 5 seconds'
else
	bad 'startup curl and running state arrive within 5 seconds' "daemon stderr: $(cat "$R1/daemon.stderr")"
fi
expect 'startup first success selects T1' T1 "$(jget dns_tier < "$R1/var/run/aether-proxy/state.json")"
expect 'startup needs exactly one successful curl' 1 "$(count_calls "$L1" 'curl ')"
grep -Fq '203.0.113.20' "$R1/var/run/aether-proxy/current/xray.json" \
	&& ok "runtime node IP reaches xray renderer" || bad "runtime node IP reaches xray renderer"
grep -Fq 'set gfw4' "$R1/var/run/aether-proxy/current/aether-proxy.nft" && \
	grep -Fq 'elements = { 1.2.3.4 }' "$R1/var/run/aether-proxy/current/aether-proxy.nft" \
	&& ok "saved dynamic sets reach nft renderer" || bad "saved dynamic sets reach nft renderer"
grep -Fq 'trust-dns tcp://9.9.9.9,tcp://8.8.8.8' "$R1/first-probe-chinadns.conf" \
	&& ok "startup chinadns config uses T2" || bad "startup chinadns config uses T2"
[ ! -e "$R1/var/run/aether-proxy/sets.save" ] && ok "sets.save is consumed after restoring" || bad "sets.save is consumed after restoring"
for command in 'chinadns-ng -C' 'dnsmasq restart' 'resolveip -4 -t 3' 'xray run -c' 'nft -f' 'ip rule add'; do
	has_line "$L1" "$command" && ok "normal call recorded: $command" || bad "normal call recorded: $command"
done
dns_line=$(line_no "$L1" 'chinadns-ng -C')
install_line=$(line_no "$L1" 'dnsmasq restart')
resolve_line=$(line_no "$L1" 'resolveip -4 -t 3')
xray_line=$(line_no "$L1" 'xray run -c')
nft_line=$(line_no "$L1" 'nft -f ')
rule_line=$(line_no "$L1" 'ip rule add')
if [ -n "$dns_line$install_line$resolve_line$xray_line$nft_line$rule_line" ] && \
	[ "$dns_line" -lt "$install_line" ] && [ "$install_line" -lt "$resolve_line" ] && \
	[ "$resolve_line" -lt "$xray_line" ] && [ "$xray_line" -lt "$nft_line" ] && [ "$nft_line" -lt "$rule_line" ]; then
	ok "normal startup side effects are in required order"
else
	bad "normal startup side effects are in required order" "${dns_line},${install_line},${resolve_line},${xray_line},${nft_line},${rule_line}"
fi
start_event=$(grep '"code": "SERVICE_STARTED"' "$R1/var/run/aether-proxy/events.jsonl" | head -n 1)
elapsed_field=$(printf '%s\n' "$start_event" | jget args.elapsed_ms)
dns_step_field=$(printf '%s\n' "$start_event" | jget args.steps.start_chinadns)
dataplane_step_field=$(printf '%s\n' "$start_event" | jget args.steps.restore_nft_route)
[ "$elapsed_field" != '<missing>' ] && [ "$elapsed_field" -ge 0 ] \
	&& ok "SERVICE_STARTED includes elapsed_ms" || bad "SERVICE_STARTED includes elapsed_ms"
[ "$dns_step_field" != '<missing>' ] && [ "$dataplane_step_field" != '<missing>' ] \
	&& ok "SERVICE_STARTED includes step timings" || bad "SERVICE_STARTED includes step timings"
cp "$L1" "$L1_START"

# T8.9a: inspect persisted component metadata, not only banner command calls.
expect 'component xray path' "$T/bin/xray" "$(jget components.xray.path < "$R1/var/run/aether-proxy/state.json")"
expect 'component xray version' '26.9.30' "$(jget components.xray.version < "$R1/var/run/aether-proxy/state.json")"
expect 'component chinadns path' "$T/bin/chinadns-ng" \
	"$(jget components.chinadns-ng.path < "$R1/var/run/aether-proxy/state.json")"
expect 'component chinadns version' '2025.06.20' \
	"$(jget components.chinadns-ng.version < "$R1/var/run/aether-proxy/state.json")"

# SIGUSR1 ticks immediately; SIGHUP with an unchanged config is an incremental no-op (T2.6).
kill -USR1 "$DAEMON_PID"
sleep 0.1
kill -HUP "$DAEMON_PID"
sleep 1
restarts=$(awk '/^xray run -c / { n++ } END { print n+0 }' "$L1")
expect "SIGHUP with unchanged config keeps xray" 1 "$restarts"
[ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>>"$QUIET" \
	&& ok "daemon survives SIGHUP and USR1" || bad "daemon survives SIGHUP and USR1"

# 2. SIGTERM exports the sets, tears down in order, persists stopped, and reaps children.
stop_daemon; stop_rc=$?
expect "SIGTERM exits successfully" 0 "$stop_rc"
expect "SIGTERM state is stopped" stopped "$(jget state < "$R1/var/run/aether-proxy/state.json")"
[ -f "$R1/var/run/aether-proxy/sets.save" ] && ok "SIGTERM writes sets.save" || bad "SIGTERM writes sets.save"
stop_table_line=$(awk '/nft list table inet aetherproxy/ { line=NR } END { print line }' "$L1")
STOP_LOG="$T/sys1/stop.log"
sed -n "${stop_table_line},\$p" "$L1" > "$STOP_LOG"
export_line=$(line_no "$STOP_LOG" 'nft -j list set')
delete_line=$(line_no "$STOP_LOG" 'nft delete table')
route_line=$(line_no "$STOP_LOG" 'ip rule del')
stop_dns_line=$(line_no "$STOP_LOG" 'dnsmasq restart')
if [ -n "$export_line$delete_line$route_line$stop_dns_line" ] && \
	[ "$export_line" -lt "$delete_line" ] && [ "$delete_line" -lt "$route_line" ] && [ "$route_line" -lt "$stop_dns_line" ]; then
	ok "SIGTERM teardown order recorded"
else
	bad "SIGTERM teardown order recorded" "${export_line},${delete_line},${route_line},${stop_dns_line}"
fi
assert_no_children "$R1"
echo 'CALL SEQUENCE scenario 1 (startup):'
cat "$L1_START"
echo 'CALL SEQUENCE scenario 2 (SIGTERM teardown):'
cat "$STOP_LOG"

# SIGUSR2 restarts only the supervised Xray child and schedules an immediate monitor round.
R2U="$T/sys2usr2"; L2U="$T/sys2usr2/calls.log"; make_root "$R2U"; : > "$L2U"
start_daemon "$R2U" "$L2U"
if wait_for "$R2U/var/run/aether-proxy/state.json" '"state": "running"'; then
	old_xray=$(cat "$R2U/xray.pid"); old_dns=$(cat "$R2U/chinadns-ng.pid" 2>/dev/null || cat "$R2U/chinadns.pid")
	old_curl=$(count_calls "$L2U" 'curl ')
	printf 'Xray 26.10.10 (replacement)\n' > "$R2U/xray-version"
	# Changing the DNS banner too proves SIGUSR2 does not query DNS again.
	printf 'ChinaDNS-NG SHOULD-NOT-REFRESH\n' > "$R2U/chinadns-version"
	kill -USR2 "$DAEMON_PID"
	for _ in {1..200}; do
		new_xray=$(cat "$R2U/xray.pid" 2>/dev/null || :)
		[ -n "$new_xray" ] && [ "$new_xray" != "$old_xray" ] && break
		sleep 0.05
	done
	new_dns=$(cat "$R2U/chinadns-ng.pid" 2>/dev/null || cat "$R2U/chinadns.pid" 2>/dev/null || :)
	[ -n "$new_xray" ] && [ "$new_xray" != "$old_xray" ] && ok 'SIGUSR2 changes Xray pid' || bad 'SIGUSR2 changes Xray pid'
	expect 'SIGUSR2 keeps chinadns pid' "$old_dns" "$new_dns"
	wait_for "$R2U/var/run/aether-proxy/state.json" '26.10.10' 200 \
		&& ok 'SIGUSR2 refreshes xray version' || bad 'SIGUSR2 refreshes xray version'
	expect 'SIGUSR2 preserves chinadns version' '2025.06.20' \
		"$(jget components.chinadns-ng.version < "$R2U/var/run/aether-proxy/state.json")"
	expect 'SIGUSR2 does not query chinadns again' 1 "$(count_calls "$L2U" 'chinadns-ng -V')"
	wait_count "$L2U" 'curl ' "$((old_curl + 1))" && ok 'SIGUSR2 immediately runs monitor' || bad 'SIGUSR2 immediately runs monitor'
else
	bad 'SIGUSR2 test daemon starts' "$(cat "$R2U/daemon.stderr")"
fi
stop_daemon; expect 'SIGUSR2 daemon stops cleanly' 0 "$?"; assert_no_children "$R2U"

# T8.12b (docs/10 Dashboard part 2): node identity and IP changes each trigger a probe.
# The existing timer is 10 s while starting/degraded and 30 s while running.
# A separate 5 s bound prevents the periodic timer from making this test pass by accident.
wait_reload_probe() {
	local wanted="$1"
	for _ in {1..100}; do
		[ "$(count_calls "$LP" 'curl ')" -ge "$wanted" ] && return 0
		sleep 0.05
	done
	return 1
}
RP="$T/sys-probe-reload"; LP="$RP/calls.log"; make_root "$RP"
P_CONF="$T/probe-reload-conf"; mkdir -p "$P_CONF"
cp "$FIX/aetherproxy" "$P_CONF/aetherproxy"
cat >> "$P_CONF/aetherproxy" <<'CONF'

config node 'n_00000000000000000000000000000002'
	option protocol 'trojan'
	option security 'tls'
	option address 'node.example.com'
	option port '443'
	option password 'other-secret'
CONF
touch "$RP/xray-listen-delay"
start_daemon "$RP" "$LP" --confdir "$P_CONF"
wait_for "$RP/var/run/aether-proxy/events.jsonl" 'SERVICE_STARTED' \
	&& ok 'probe reload: startup completed' || bad 'probe reload: startup completed'
# Startup now probes without signals; wait for it before measuring reload-only probes.
wait_for "$RP/var/run/aether-proxy/state.json" '"state": "running"' 40 \
	&& ok 'probe reload: service is running before changes' || bad 'probe reload: service is running before changes'
probe_count=$(count_calls "$LP" 'curl ')
# The new node resolves to the same IP, proving node identity alone is sufficient.
sed -i "0,/option node /s/00000000000000000000000000000001/00000000000000000000000000000002/" "$P_CONF/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_reload_probe "$((probe_count + 1))" \
	&& ok 'probe reload: node change probes within 5 seconds' \
	|| bad 'probe reload: node change probes within 5 seconds'
sleep 0.3
expect 'probe reload: node change adds exactly one probe' "$((probe_count + 1))" "$(count_calls "$LP" 'curl ')"
expect 'delayed reload: node change leaves no missing-listener count' 0 \
	"$(jget monitor.xray_down_count < "$RP/var/run/aether-proxy/state.json")"
printf 'TRACE delayed node reload: xray_down_count=%s\n' \
	"$(jget monitor.xray_down_count < "$RP/var/run/aether-proxy/state.json")"

probe_count=$(count_calls "$LP" 'curl ')
# Change only the current node's address; a literal IP bypasses the fixed DNS substitute.
sed -i "s/option address 'node.example.com'/option address '203.0.113.21'/g" "$P_CONF/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_reload_probe "$((probe_count + 1))" \
	&& ok 'probe reload: IP change probes within 5 seconds' || bad 'probe reload: IP change probes within 5 seconds'
sleep 0.3
expect 'probe reload: IP change adds exactly one probe' "$((probe_count + 1))" "$(count_calls "$LP" 'curl ')"
expect 'probe reload: new node IP persisted' '203.0.113.21' "$(jget node_ip < "$RP/var/run/aether-proxy/state.json")"
expect 'delayed reload: IP change leaves no missing-listener count' 0 \
	"$(jget monitor.xray_down_count < "$RP/var/run/aether-proxy/state.json")"
if has_line "$RP/var/run/aether-proxy/events.jsonl" 'XRAY_DOWN_FAILOPEN'; then
	bad 'delayed reload: planned restarts never emit XRAY_DOWN_FAILOPEN'
else
	ok 'delayed reload: planned restarts never emit XRAY_DOWN_FAILOPEN'
fi
printf 'TRACE delayed IP reload: xray_down_count=%s state=%s\n' \
	"$(jget monitor.xray_down_count < "$RP/var/run/aether-proxy/state.json")" \
	"$(jget state < "$RP/var/run/aether-proxy/state.json")"

probe_count=$(count_calls "$LP" 'curl ')
validation_count=$(count_calls "$LP" 'xray run -test')
sed -i "/option mode 'gfw'/a\\\toption log_level 'debug'" "$P_CONF/aetherproxy"
kill -HUP "$DAEMON_PID"
# Wait for validation rather than merely sleeping before the reload could have started.
wait_count "$LP" 'xray run -test' "$((validation_count + 1))" \
	&& ok 'probe reload: unrelated reload validated' || bad 'probe reload: unrelated reload validated'
sleep 1
expect 'probe reload: unrelated reload adds no probe' "$probe_count" "$(count_calls "$LP" 'curl ')"

# Failed reloads must not trigger an extra probe either.
probe_count=$(count_calls "$LP" 'curl ')
sed -i "s/option port '443'/option port '0'/g" "$P_CONF/aetherproxy"
kill -HUP "$DAEMON_PID"
wait_for "$RP/var/run/aether-proxy/events.jsonl" 'CONFIG_INVALID' \
	&& ok 'probe reload: invalid reload rejected' || bad 'probe reload: invalid reload rejected'
sleep 0.3
expect 'probe reload: failed reload adds no probe' "$probe_count" "$(count_calls "$LP" 'curl ')"

# Restore valid on-disk UCI after the negative reload test: the failsafe DNS render
# reads it too, and otherwise fails validation rather than committing the transition.
sed -i "s/option port '0'/option port '443'/g" "$P_CONF/aetherproxy"
# A real child exit must still count two missing samples, before its 5 s crash restart.
read -r xray_pid < "$RP/xray.pid"
kill -TERM "$xray_pid"
for _ in {1..60}; do
	if ! grep -Fq ':7968 ' "$RP/proc/net/tcp6"; then break; fi
	sleep 0.05
done
kill -USR1 "$DAEMON_PID"
wait_for "$RP/var/run/aether-proxy/state.json" '"xray_down_count": 1' 40 \
	&& ok 'real Xray exit: first round counts one missing listener' \
	|| bad 'real Xray exit: first round counts one missing listener'
expect 'real Xray exit: first round keeps running' running \
	"$(jget state < "$RP/var/run/aether-proxy/state.json")"
# Let the first signal handler return before sending a distinct second signal.
sleep 0.2
kill -USR1 "$DAEMON_PID"
wait_for "$RP/var/run/aether-proxy/events.jsonl" 'XRAY_DOWN_FAILOPEN' 40 \
	&& ok 'real Xray exit: second round emits XRAY_DOWN_FAILOPEN' \
	|| bad 'real Xray exit: second round emits XRAY_DOWN_FAILOPEN'
expect 'real Xray exit: second round enters failsafe' failsafe \
	"$(jget state < "$RP/var/run/aether-proxy/state.json")"
stop_daemon
expect 'probe reload: daemon stops cleanly' 0 "$?"
assert_no_children "$RP"

# A periodic deadline expires during validation. wait_stopped/readiness pump uloop,
# but the reload transaction must remain the only owner until its post-apply probe.
RB="$T/sys-reload-busy"; LB="$RB/calls.log"; make_root "$RB"
B_CONF="$T/reload-busy-conf"; mkdir -p "$B_CONF"
cp "$FIX/aetherproxy" "$B_CONF/aetherproxy"
start_daemon "$RB" "$LB" --confdir "$B_CONF"
if wait_for "$RB/var/run/aether-proxy/state.json" '"state": "running"'; then
	# Running uses a real 30 s period; do not change production constants for this test.
	sleep 29
	touch "$RB/xray-test-delay" "$RB/xray-listen-delay"
	sed -i "s/option address 'node.example.com'/option address '203.0.113.22'/g" "$B_CONF/aetherproxy"
	tables_before=$(count_calls "$LB" 'nft list table inet aetherproxy')
	probes_before=$(count_calls "$LB" 'curl ')
	kill -HUP "$DAEMON_PID"
	wait_count "$LB" 'curl ' "$((probes_before + 1))" \
		&& ok 'reload busy: new route is probed after readiness' \
		|| bad 'reload busy: new route is probed after readiness'
	sleep 0.2
	# One reload sets-export check plus one post-reload observation, no nested monitor.
	expect 'reload busy: overdue periodic callback cannot observe inside reload' 2 \
		"$(( $(count_calls "$LB" 'nft list table inet aetherproxy') - tables_before ))"
	expect 'reload busy: exactly one post-apply health probe' "$((probes_before + 1))" "$(count_calls "$LB" 'curl ')"
else
	bad 'reload busy: daemon starts'
fi
stop_daemon

# 3. Repeated cleanup does not repeat destructive operations after the first pass.
R3="$T/sys3"; L3="$T/sys3/calls.log"; make_root "$R3"; : > "$L3"
touch "$R3/nft-table" "$R3/tmp/dnsmasq.d/aether-proxy.conf"
printf '900: from all fwmark 0x80000/0x80000 lookup 233\n' > "$R3/ip-rules"
printf 'local default dev lo table 233\n' > "$R3/ip-routes"
timeout 15s env STUB_LOG="$L3" SYSROOT="$R3" PATH="$T/bin:$PATH" \
	STUB_GFW4_ELEM='["198.51.100.1",{"prefix":{"addr":"198.51.100.64","len":26}}]' \
	"$UCODE" -S "$ENTRY" -- cleanup $(args_for "$R3") >/dev/null 2>>"$QUIET"; rc1=$?
expect "first cleanup succeeds" 0 "$rc1"
# Like the daemon's stop, cleanup saves the dynamic sets before deleting the table (04).
saved="$R3/var/run/aether-proxy/sets.save"
grep -q '198.51.100.1"' "$saved" 2>>"$QUIET" && grep -q '198.51.100.64/26' "$saved" 2>>"$QUIET" \
	&& ok "cleanup saves the dynamic sets of a table it deletes" || bad "cleanup saves the dynamic sets of a table it deletes" "$(cat "$saved" 2>&1)"
first_lines=$(wc -l < "$L3")
timeout 15s env STUB_LOG="$L3" SYSROOT="$R3" PATH="$T/bin:$PATH" \
	"$UCODE" -S "$ENTRY" -- cleanup $(args_for "$R3") >/dev/null 2>>"$QUIET"; rc2=$?
expect "second cleanup succeeds" 0 "$rc2"
second_lines=$(wc -l < "$L3")
[ "$second_lines" -gt "$first_lines" ] && ok "cleanup performs read-only checks on repeated call" || bad "cleanup logs repeated checks"
after_first=$(awk '/^(nft delete table|ip rule del|ip route flush|dnsmasq restart)/ { n++ } END { print n+0 }' "$L3")
after_second=$(awk '/^(nft delete table|ip rule del|ip route flush|dnsmasq restart)/ { n++ } END { print n+0 }' "$L3")
expect "second cleanup adds no destructive calls" "$after_first" "$after_second"

# 4. Runtime nft fails once: daemon remains in error, schedules a retry, then starts.
R4="$T/sys4"; L4="$T/sys4/calls.log"; make_root "$R4"; : > "$L4"
STUB_NFT_FAIL_ONCE=1 AETHER_PROXY_TEST_RETRY_DELAY=1 start_daemon "$R4" "$L4"
if wait_for "$R4/var/run/aether-proxy/state.json" '"state": "error"' 200; then
	ok "failed startup records error state"
else
	bad "failed startup records error state" "$(cat "$R4/daemon.stderr")"
fi
expect "failed startup records failed step" nft_load "$(jget failed_step < "$R4/var/run/aether-proxy/state.json")"
if kill -0 "$DAEMON_PID" 2>>"$QUIET"; then ok "daemon stays alive after startup failure"; else bad "daemon stays alive after startup failure"; fi
has_line "$R4/var/run/aether-proxy/events.jsonl" '"code": "START_RETRY"' && ok "retry event is appended" || bad "retry event is appended"
assert_no_children "$R4"
if wait_count "$L4" 'nft -f ' 2 && wait_for "$R4/var/run/aether-proxy/events.jsonl" '"code": "SERVICE_STARTED"' 200; then
	ok "retry succeeds and enters monitor"
	if grep 'set gfw4 ' "$R4/var/run/aether-proxy/current/aether-proxy.nft" | grep -qv 'elements'; then
		ok "startup without sets.save renders empty dynamic set"
	else
		bad "startup without sets.save renders empty dynamic set"
	fi
else
	bad "retry succeeds and enters monitor" "$(cat "$R4/daemon.stderr")"
fi
stop_daemon; expect "retried daemon stops successfully" 0 "$?"
assert_no_children "$R4"

# 5. Node DNS failure enters degraded with DNS service retained and no proxy dataplane.
R5="$T/sys5"; L5="$T/sys5/calls.log"; make_root "$R5"; : > "$L5"
STUB_RESOLVE_FAIL=1 start_daemon "$R5" "$L5"
if wait_for "$R5/var/run/aether-proxy/state.json" 'degraded'; then
	ok "unresolved node enters degraded"
else
	bad "unresolved node enters degraded" "$(cat "$R5/daemon.stderr")"
fi
[ -f "$R5/tmp/dnsmasq.d/aether-proxy.conf" ] && ok "degraded mode keeps dnsmasq fragment" || bad "degraded mode keeps dnsmasq fragment"
has_line "$L5" 'chinadns-ng -C' && ok "degraded mode keeps chinadns running" || bad "degraded mode keeps chinadns running"
! has_line "$L5" 'xray run -c' && ok "degraded mode skips xray" || bad "degraded mode skips xray"
! has_line "$L5" 'nft -f ' && ok "degraded mode skips nft load" || bad "degraded mode skips nft load"
stop_daemon; expect "degraded daemon stops successfully" 0 "$?"
assert_no_children "$R5"

# 5b. Same, with fail_open=0: interception stays installed (proxy targets fail, no leak), Xray stays down.
R5B="$T/sys5b"; L5B="$T/sys5b/calls.log"; make_root "$R5B"; : > "$L5B"
FO_CONF="$T/failopen-off-conf"; mkdir -p "$FO_CONF"
sed "/option enabled '1'/a\\	option fail_open '0'" "$FIX/aetherproxy" > "$FO_CONF/aetherproxy"
STUB_RESOLVE_FAIL=1 start_daemon "$R5B" "$L5B" --confdir "$FO_CONF"
if wait_for "$R5B/var/run/aether-proxy/state.json" 'degraded'; then
	ok "fail_open=0: unresolved node enters degraded"
else
	bad "fail_open=0: unresolved node enters degraded" "$(cat "$R5B/daemon.stderr")"
fi
wait_for "$L5B" 'ip rule add' >/dev/null
! has_line "$L5B" 'xray run -c' && ok "fail_open=0 degraded skips xray" || bad "fail_open=0 degraded skips xray"
has_line "$L5B" 'nft -f ' && ok "fail_open=0 degraded still loads nft" || bad "fail_open=0 degraded still loads nft"
has_line "$L5B" 'ip rule add' && ok "fail_open=0 degraded still adds the ip rule" || bad "fail_open=0 degraded still adds the ip rule"
stop_daemon; expect "fail_open=0 degraded daemon stops successfully" 0 "$?"
assert_no_children "$R5B"

# 6. Conflict is rejected before cleanup or any system-changing operation.
R6="$T/sys6"; L6="$T/sys6/calls.log"; make_root "$R6"; : > "$L6"
printf 'table inet ss_spec\n' > "$R6/conflicts"
STUB_LOG="$L6" SYSROOT="$R6" AETHER_PROXY_TEST_RETRY_DELAY=30 PATH="$T/bin:$PATH" \
	start_daemon "$R6" "$L6"
if wait_for "$R6/var/run/aether-proxy/state.json" '"state": "error"'; then
	ok "conflict records error state and waits to retry"
else
	bad "conflict records error state and waits to retry" "$(cat "$R6/daemon.stderr")"
fi
expect "conflict records precheck step" precheck "$(jget failed_step < "$R6/var/run/aether-proxy/state.json")"
! has_line "$L6" 'nft -f ' && ok "conflict does not load nft" || bad "conflict does not load nft"
! has_line "$L6" 'dnsmasq restart' && ok "conflict does not restart dnsmasq" || bad "conflict does not restart dnsmasq"
kill -0 "$DAEMON_PID" 2>>"$QUIET" && ok "conflict leaves daemon waiting" || bad "conflict leaves daemon waiting"
stop_daemon; expect "conflict daemon stops" 0 "$?"

# 7. A second daemon sees BUSY while the first still holds its startup lock.
R7="$T/sys7"; L7="$T/sys7/calls.log"; make_root "$R7"; : > "$L7"
STUB_RESOLVE_DELAY=2 start_daemon "$R7" "$L7"
if wait_for "$L7" 'resolveip -4 -t 3' 200; then
	timeout 5s env STUB_LOG="$L7" SYSROOT="$R7" PATH="$T/bin:$PATH" \
		"$UCODE" -S "$ENTRY" -- daemon $(args_for "$R7") >/dev/null 2>>"$QUIET"; rc7=$?
	expect "second daemon exits BUSY" 3 "$rc7"
else
	bad "first daemon reaches held-lock window"
	rc7=1
fi
if ! wait_for "$R7/var/run/aether-proxy/events.jsonl" 'SERVICE_STARTED' 200; then
	bad "first locked daemon finishes startup after lock release"
fi
stop_daemon; expect "first locked daemon stops" 0 "$?"
assert_no_children "$R7"

# 8. Boot wait succeeds using only a local loopback TCP listener.
R8="$T/sys8"; L8="$T/sys8/calls.log"; BOOT_CONF="$T/boot-conf"; make_root "$R8"; : > "$L8"
mkdir -p "$BOOT_CONF"
sed "/option enabled '1'/a\\	option boot_wait_timeout '15'\n\tlist boot_check_targets '127.0.0.1:1'" \
	"$FIX/aetherproxy" > "$BOOT_CONF/aetherproxy"
if start_loopback_listener "$T/listener.port" "$T/listener.accepted"; then
	port=$(cat "$T/listener.port")
	sed -i "s/127.0.0.1:1/127.0.0.1:$port/" "$BOOT_CONF/aetherproxy"
	start_daemon "$R8" "$L8" --boot --confdir "$BOOT_CONF"
	if wait_for "$R8/var/run/aether-proxy/state.json" '"state": "running"'; then
		ok "--boot continues after local TCP target succeeds"
	else
		bad "--boot local TCP target succeeds" "$(cat "$R8/daemon.stderr")"
	fi
	if wait_for "$L8" 'ip rule add'; then
		ok "--boot finishes the startup sequence"
	else
		bad "--boot finishes the startup sequence" "$(cat "$R8/daemon.stderr")"
	fi
	if wait_for "$R8/var/run/aether-proxy/events.jsonl" 'SERVICE_STARTED'; then
		ok "--boot publishes service-started after setup"
	else
		bad "--boot publishes service-started after setup" "$(cat "$R8/daemon.stderr")"
	fi
	[ -s "$T/listener.accepted" ] && ok "--boot connected to loopback listener" || bad "--boot connected to loopback listener"
	stop_daemon; expect "--boot daemon stops" 0 "$?"
	assert_no_children "$R8"
	kill -TERM "$NETWORK_PID" 2>>"$QUIET"; wait "$NETWORK_PID" 2>>"$QUIET"; NETWORK_PID=''
else
	bad "loopback listener starts" "$(cat "$T/network-listener.stderr")"
fi

# 9. SIGHUP cancels the long retry timer and triggers a prompt attempt.
R9="$T/sys9"; L9="$T/sys9/calls.log"; make_root "$R9"; : > "$L9"
# Preserve the source through a failed nft load, then consume it only after HUP succeeds.
saved9="$R9/var/run/aether-proxy/sets.save"
printf '{"gfw4":["198.51.100.19"],"udirect4":[],"uproxy4":[]}\n' > "$saved9"
cp "$saved9" "$T/sets9.expected"
STUB_NFT_FAIL_ONCE=1 start_daemon "$R9" "$L9"
if wait_for "$R9/var/run/aether-proxy/events.jsonl" '"code": "START_RETRY"' 200; then
	expect "saved-set startup failure enters error" error "$(jget state < "$R9/var/run/aether-proxy/state.json")"
	cmp -s "$saved9" "$T/sets9.expected" \
		&& ok "failed startup preserves sets.save byte for byte" \
		|| bad "failed startup preserves sets.save byte for byte"
	SECONDS_BEFORE_HUP=$SECONDS
	kill -HUP "$DAEMON_PID"
	if wait_for "$R9/var/run/aether-proxy/events.jsonl" '"code": "SERVICE_STARTED"' 100; then
		elapsed=$((SECONDS - SECONDS_BEFORE_HUP))
		[ "$elapsed" -lt 5 ] && ok "SIGHUP retries immediately" || bad "SIGHUP retries immediately" "elapsed=${elapsed}s"
	else
		bad "SIGHUP retries immediately" "$(cat "$R9/daemon.stderr")"
	fi
	wait_count "$L9" 'nft -f ' 2 && ok "SIGHUP retry loads nft" || bad "SIGHUP retry loads nft"
	has_line "$R9/var/run/aether-proxy/current/aether-proxy.nft" '198.51.100.19' \
		&& ok "SIGHUP retry renders preserved dynamic elements" \
		|| bad "SIGHUP retry renders preserved dynamic elements"
	[ ! -e "$saved9" ] && ok "successful SIGHUP retry removes sets.save" \
		|| bad "successful SIGHUP retry removes sets.save"
	stop_daemon; expect "SIGHUP-retried daemon stops" 0 "$?"
	assert_no_children "$R9"
else
	bad "SIGHUP scenario reaches retry wait" "$(cat "$R9/daemon.stderr")"
	stop_daemon
fi

# T8.9a: failure and timeout are informational; use degraded startup to avoid monitor timing races.
for mode in fail malformed delay; do
	RV="$T/sys-version-$mode"; LV="$RV/calls.log"
	make_root "$RV"; : > "$LV"
	case "$mode" in
		fail) touch "$RV/xray-version-fail" ;;
		malformed) printf 'Xray\n' > "$RV/xray-version" ;;
		delay) touch "$RV/xray-version-delay" ;;
	esac
	version_start=$SECONDS
	STUB_RESOLVE_FAIL=1 start_daemon "$RV" "$LV"
	if wait_for "$RV/var/run/aether-proxy/state.json" 'degraded' 240; then
		ok "version $mode still reaches degraded"
	else
		bad "version $mode still reaches degraded" "$(cat "$RV/daemon.stderr")"
	fi
	version_elapsed=$((SECONDS - version_start))
	# jget treats missing and null alike; explicitly require the version key as well as JSON null.
	if "$UCODE" -e '
		import * as fs from "fs";
		let component = json(fs.stdin.read("all"))?.components?.xray;
		exit(type(component) == "object" && index(keys(component), "version") >= 0 &&
			component.version == null ? 0 : 1);
	' < "$RV/var/run/aether-proxy/state.json"; then
		ok "version $mode persists null"
	else
		bad "version $mode persists null"
	fi
	expect "version $mode keeps DNS version" '2025.06.20' \
		"$(jget components.chinadns-ng.version < "$RV/var/run/aether-proxy/state.json")"
	# A missing quiet:true would add CMD_FAILED containing the failing banner invocation.
	if grep -Eq 'CMD_FAILED|version query|xray.*version' "$RV/var/run/aether-proxy/events.jsonl"; then
		bad "version $mode emits no query events"
	else
		ok "version $mode emits no query events"
	fi
	if [ "$mode" = delay ]; then
		[ "$version_elapsed" -ge 5 ] && [ "$version_elapsed" -lt 12 ] \
			&& ok 'version timeout bounds startup to 5-12 seconds' \
			|| bad 'version timeout bounds startup to 5-12 seconds' "elapsed=${version_elapsed}s"
	fi
	stop_daemon
	expect "version $mode daemon stops" 0 "$?"
	assert_no_children "$RV"
done

echo "daemon: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
