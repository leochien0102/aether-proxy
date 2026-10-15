#!/usr/bin/env bash
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

mkdir -p "$T/data" "$T/base" "$T/custom" "$T/bin"
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"
cp "$STUB_SRC/nft" "$T/bin/nft"
cp "$STUB_SRC/ip" "$T/bin/ip"
cp "$STUB_SRC/resolveip" "$T/bin/resolveip"
cp "$STUB_SRC/killall" "$T/bin/killall"
cp "$STUB_SRC/xray" "$T/bin/xray"
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
	: > "$root/ip-rules"
	: > "$root/ip-routes"
	: > "$root/conflicts"
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
		export STUB_LOG="$log" SYSROOT="$root" PATH="$T/bin:$PATH"
		exec "$UCODE" -S "$ENTRY" -- daemon $(args_for "$root") "$@"
	) >"$root/daemon.stdout" 2>"$root/daemon.stderr" &
	DAEMON_PID=$!
}
wait_for() {
	local file="$1" pattern="$2" attempts="${3:-100}"
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
	for _ in {1..100}; do
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

# 1. Normal startup reaches starting with the required side-effect order.
R1="$T/sys1"; L1="$T/sys1/calls.log"; make_root "$R1"; : > "$L1"
L1_START="$T/sys1/startup.log"
printf '{"gfw4":["1.2.3.4"],"udirect4":[],"uproxy4":[]}\n' > "$R1/var/run/aether-proxy/sets.save"
start_daemon "$R1" "$L1"
if wait_for "$R1/var/run/aether-proxy/state.json" 'starting'; then
	ok "normal startup state is starting"
else
	bad "normal startup state is starting" "daemon stderr: $(cat "$R1/daemon.stderr")"
fi
grep -Fq '203.0.113.20' "$R1/var/run/aether-proxy/current/xray.json" \
	&& ok "runtime node IP reaches xray renderer" || bad "runtime node IP reaches xray renderer"
grep -Fq 'set gfw4' "$R1/var/run/aether-proxy/current/aether-proxy.nft" && \
	grep -Fq 'elements = { 1.2.3.4 }' "$R1/var/run/aether-proxy/current/aether-proxy.nft" \
	&& ok "saved dynamic sets reach nft renderer" || bad "saved dynamic sets reach nft renderer"
grep -Fq 'trust-dns tcp://8.8.8.8,tcp://1.1.1.1' "$R1/var/run/aether-proxy/current/chinadns.conf" \
	&& ok "startup chinadns config uses T2" || bad "startup chinadns config uses T2"
[ ! -e "$R1/var/run/aether-proxy/sets.save" ] && ok "sets.save is consumed after restoring" || bad "sets.save is consumed after restoring"
for command in 'chinadns-ng -C' 'dnsmasq restart' 'resolveip -4 -t 5' 'xray run -c' 'nft -f' 'ip rule add'; do
	has_line "$L1" "$command" && ok "normal call recorded: $command" || bad "normal call recorded: $command"
done
dns_line=$(line_no "$L1" 'chinadns-ng -C')
install_line=$(line_no "$L1" 'dnsmasq restart')
resolve_line=$(line_no "$L1" 'resolveip -4 -t 5')
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
cp "$L1" "$L1_START"

# SIGUSR1 ticks immediately; SIGHUP performs a full stop/start (T2.6 will make it incremental).
kill -USR1 "$DAEMON_PID"
sleep 0.1
kill -HUP "$DAEMON_PID"
restarts=0
for _ in {1..150}; do
	restarts=$(awk '/^xray run -c / { n++ } END { print n+0 }' "$L1")
	[ "$restarts" -ge 2 ] && break
	if ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then break; fi
	sleep 0.05
done
[ "$restarts" -ge 2 ] && ok "SIGHUP performs a full restart" || bad "SIGHUP performs a full restart" "xray launches=$restarts"
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

# 3. Repeated cleanup does not repeat destructive operations after the first pass.
R3="$T/sys3"; L3="$T/sys3/calls.log"; make_root "$R3"; : > "$L3"
touch "$R3/nft-table" "$R3/tmp/dnsmasq.d/aether-proxy.conf"
printf '900: from all fwmark 0x80000/0x80000 lookup 233\n' > "$R3/ip-rules"
printf 'local default dev lo table 233\n' > "$R3/ip-routes"
timeout 15s env STUB_LOG="$L3" SYSROOT="$R3" PATH="$T/bin:$PATH" \
	"$UCODE" -S "$ENTRY" -- cleanup $(args_for "$R3") >/dev/null 2>>"$QUIET"; rc1=$?
expect "first cleanup succeeds" 0 "$rc1"
first_lines=$(wc -l < "$L3")
timeout 15s env STUB_LOG="$L3" SYSROOT="$R3" PATH="$T/bin:$PATH" \
	"$UCODE" -S "$ENTRY" -- cleanup $(args_for "$R3") >/dev/null 2>>"$QUIET"; rc2=$?
expect "second cleanup succeeds" 0 "$rc2"
second_lines=$(wc -l < "$L3")
[ "$second_lines" -gt "$first_lines" ] && ok "cleanup performs read-only checks on repeated call" || bad "cleanup logs repeated checks"
after_first=$(awk '/^(nft delete table|ip rule del|ip route flush|dnsmasq restart)/ { n++ } END { print n+0 }' "$L3")
after_second=$(awk '/^(nft delete table|ip rule del|ip route flush|dnsmasq restart)/ { n++ } END { print n+0 }' "$L3")
expect "second cleanup adds no destructive calls" "$after_first" "$after_second"

# 4. Runtime nft load failure rolls back children and records error.
R4="$T/sys4"; L4="$T/sys4/calls.log"; make_root "$R4"; : > "$L4"
STUB_NFT_RC=1 start_daemon "$R4" "$L4"
exited4=0
for _ in {1..150}; do
	if ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then exited4=1; break; fi
	sleep 0.05
done
if [ "$exited4" -eq 1 ]; then
	wait "$DAEMON_PID"; rc4=$?; DAEMON_PID=''
else
	bad "nft failure daemon exits before scenario timeout"
	stop_daemon; rc4=124
fi
[ "$rc4" -ne 0 ] && ok "nft load failure exits nonzero" || bad "nft load failure exits nonzero" "rc=$rc4"
expect "nft failure records error state" error "$(jget state < "$R4/var/run/aether-proxy/state.json")"
expect "nft failure records failed step" nft_load "$(jget failed_step < "$R4/var/run/aether-proxy/state.json")"
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

# 6. Conflict is rejected before cleanup or any system-changing operation.
R6="$T/sys6"; L6="$T/sys6/calls.log"; make_root "$R6"; : > "$L6"
printf 'table inet ss_spec\n' > "$R6/conflicts"
timeout 15s env STUB_LOG="$L6" SYSROOT="$R6" PATH="$T/bin:$PATH" \
	"$UCODE" -S "$ENTRY" -- daemon $(args_for "$R6") >/dev/null 2>>"$QUIET"; rc6=$?
[ "$rc6" -ne 0 ] && ok "conflict exits nonzero" || bad "conflict exits nonzero" "rc=$rc6"
! has_line "$L6" 'nft -f ' && ok "conflict does not load nft" || bad "conflict does not load nft"
! has_line "$L6" 'dnsmasq restart' && ok "conflict does not restart dnsmasq" || bad "conflict does not restart dnsmasq"
[ ! -e "$R6/var/run/aether-proxy/state.json" ] && ok "conflict leaves state.json untouched" || bad "conflict leaves state.json untouched"

# 7. A second daemon sees BUSY while the first still holds its startup lock.
R7="$T/sys7"; L7="$T/sys7/calls.log"; make_root "$R7"; : > "$L7"
STUB_RESOLVE_DELAY=2 start_daemon "$R7" "$L7"
if wait_for "$L7" 'resolveip -4 -t 5' 200; then
	timeout 5s env STUB_LOG="$L7" SYSROOT="$R7" PATH="$T/bin:$PATH" \
		"$UCODE" -S "$ENTRY" -- daemon $(args_for "$R7") >/dev/null 2>>"$QUIET"; rc7=$?
	expect "second daemon exits BUSY" 3 "$rc7"
else
	bad "first daemon reaches held-lock window"
	rc7=1
fi
if ! wait_for "$R7/var/run/aether-proxy/state.json" 'starting' 200; then
	bad "first locked daemon reaches starting after lock release"
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
	if wait_for "$R8/var/run/aether-proxy/state.json" 'starting'; then
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

echo "daemon: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
