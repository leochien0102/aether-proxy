#!/usr/bin/env bash
# Exercise subscription/update scheduling and stale-cache auto-install gating (docs/06, docs/08).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The daemon filters child output with the packaged script (docs/09); point it at the source copy.
export AETHER_PROXY_TEST_LOGFILTER="$ROOT/aether-proxy/files/aether-proxy-logfilter.awk"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"
STUB_SRC="$ROOT/tests/stubs/daemon-bin"
T="$(mktemp -d "$ROOT/tests/schedule/tmp.XXXXXX")"
QUIET="$T/cleanup.stderr"
DAEMON_PID=''
pass=0
fail=0

cleanup_children() {
	local root="$1" f pid
	for f in "$root"/xray.pid "$root"/chinadns.pid; do
		[ -f "$f" ] || continue
		read -r pid < "$f"
		if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>>"$QUIET"; then
			kill -TERM "$pid" 2>>"$QUIET"
			for _ in {1..20}; do
				kill -0 "$pid" 2>>"$QUIET" || break
				sleep 0.05
			done
			if kill -0 "$pid" 2>>"$QUIET"; then kill -KILL "$pid" 2>>"$QUIET"; fi
		fi
	done
}

cleanup() {
	if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>>"$QUIET"; then
		kill -TERM "$DAEMON_PID" 2>>"$QUIET"
		for _ in {1..200}; do
			kill -0 "$DAEMON_PID" 2>>"$QUIET" || break
			sleep 0.05
		done
		if kill -0 "$DAEMON_PID" 2>>"$QUIET"; then kill -KILL "$DAEMON_PID" 2>>"$QUIET"; fi
		wait "$DAEMON_PID" 2>>"$QUIET"
	fi
	for root in "$T"/root*; do [ -d "$root" ] && cleanup_children "$root"; done
	if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept schedule-test temp: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
jget() { "$UCODE" "$JGET" -- "$1"; }

setup_tools() {
	mkdir -p "$T/bin" "$T/data" "$T/base" "$T/custom"
	for name in nft ip resolveip killall curl xray chinadns-ng kill; do
		cp "$STUB_SRC/$name" "$T/bin/$name"
	done
	for name in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$name.txt"; done
	printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
	printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"
	cat > "$T/bin/aether-proxy" <<'EOF'
#!/bin/sh
printf 'aether-proxy %s\n' "$*" >> "$SCHEDULE_LOG"
[ "$1" = job ] && [ "$2" = start ] || exit 64
if [ "$3" = update ]; then
	case "$4" in
		data) exit "${SCHEDULE_DATA_RC:-0}" ;;
		check)
			count_file="$SYSROOT/update-check-count"
			count=0; [ -f "$count_file" ] && read -r count < "$count_file"
			count=$((count + 1)); echo "$count" > "$count_file"
			[ "$count" -eq 1 ] && exit "${SCHEDULE_CHECK_FIRST_RC:-0}"
			exit "${SCHEDULE_CHECK_RC:-0}" ;;
		package) exit "${SCHEDULE_PACKAGE_RC:-0}" ;;
		*) exit 64 ;;
	esac
fi
[ "$3" = sub ] && [ "$4" = update ] || exit 64
if [ "${SCHEDULE_JOB_RC:-0}" -eq 3 ]; then exit 3; fi
name="$5"
state_dir="$SYSROOT/etc/aether-proxy/state"
mkdir -p "$state_dir"
now=$(date +%s)
"$SCHEDULE_UCODE" -e 'import * as fs from "fs"; import * as sys from "aetherproxy.sys"; let path=ARGV[0], name=ARGV[1], now=+ARGV[2]; let text=fs.readfile(path); let state={}; if (text!=null) { let old=json(text); if (type(old)=="object") state=old; } state[name]={last_attempt:now,last_ok:now,nodes:1,skipped:{},error:null}; if (!sys.write_atomic(path,sprintf("%.J",state))) die(sys.error() ?? "cannot update subscription status");' \
	-- "$state_dir/sub.json" "$name" "$now"
exit "${SCHEDULE_JOB_RC:-0}"
EOF
	chmod +x "$T/bin/"*
}

make_root() {
	local root="$1"
	mkdir -p "$root/etc/config" "$root/etc/init.d" "$root/etc/aether-proxy/state" \
		"$root/var/lock" "$root/var/etc" "$root/var/run/aether-proxy" "$root/tmp/dnsmasq.d" \
		"$root/proc/net" "$root/sys/class/net/br-lan"
	cat > "$root/var/etc/dnsmasq.conf.cfg01411c" <<'EOF'
interface=br-lan
conf-dir=/tmp/dnsmasq.d,*.conf
EOF
	cat > "$root/etc/init.d/dnsmasq" <<'EOF'
#!/bin/sh
printf 'dnsmasq %s\n' "$*" >> "$STUB_LOG"
exit 0
EOF
	chmod +x "$root/etc/init.d/dnsmasq"
	printf 'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$root/proc/net/tcp"
	printf 'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$root/proc/net/tcp6"
	: > "$root/ip-rules"
	: > "$root/ip-routes"
	: > "$root/conflicts"
	: > "$root/curl-count"
	: > "$root/calls.log"
	: > "$root/schedule-calls.log"
	cat > "$root/etc/config/aetherproxy" <<'EOF'
config global 'main'
	option enabled '1'
	option mode 'gfw'
	option node 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	option fail_open '1'

config update 'update'
	option data_auto '1'
	option data_hour '4'
	option xray_auto 'notify'

config subscription 's_00000001'
	option enabled '1'
	option name 'scheduled test'
	option url 'https://subscription.example/list'
	option fetch_via 'direct'
	option interval_hours '1'

config node 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	option label 'scheduled node'
	option source 'manual'
	option protocol 'vless'
	option address 'node.example.com'
	option port '443'
	option uuid '11111111-2222-4333-8444-555555555555'
	option transport 'raw'
	option security 'tls'
	option encryption 'none'
EOF
}

args_for() {
	local root="$1"
	echo --sys-root "$root" --bin-dir "$T/bin" --confdir "$root/etc/config" \
		--data-dir "$T/data" --baseline-dir "$T/base" --custom-dir "$T/custom"
}

start_daemon() {
	local root="$1"; shift
	(
		export STUB_LOG="$root/calls.log" SYSROOT="$root" STUB_CURL_COUNT_FILE="$root/curl-count"
		export SCHEDULE_LOG="$root/schedule-calls.log" SCHEDULE_UCODE="$UCODE" PATH="$T/bin:$PATH"
		export STUB_RESOLVE_FAIL="${SCHEDULE_RESOLVE_FAIL:-1}" AETHER_PROXY_TEST_SCHEDULE_INTERVAL_MS=20
		export AETHER_PROXY_TEST_SCHEDULE_HOUR_SECS="${SCHEDULE_HOURS:-0.1}"
		exec "$UCODE" -S "$ENTRY" -- daemon $(args_for "$root") "$@"
	) > "$root/daemon.stdout" 2> "$root/daemon.stderr" &
	DAEMON_PID=$!
}

wait_for_text() {
	local file="$1" text="$2" attempts="${3:-300}"
	for _ in $(seq 1 "$attempts"); do
		[ -e "$file" ] && grep -Fq -- "$text" "$file" && return 0
		if ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then return 1; fi
		sleep 0.02
	done
	return 1
}

wait_monitor_state() {
	local wanted="$1" value
	for _ in {1..600}; do
		if [ -s "$R/var/run/aether-proxy/state.json" ]; then
			value=$(jget state < "$R/var/run/aether-proxy/state.json")
			[ "$value" = "$wanted" ] && return 0
		fi
		if ! kill -0 "$DAEMON_PID" 2>>"$QUIET"; then return 1; fi
		sleep 0.02
	done
	return 1
}

stop_daemon() {
	local pid="$DAEMON_PID"
	[ -n "$pid" ] || return 0
	kill -TERM "$pid" 2>>"$QUIET"
	for _ in {1..300}; do
		if ! kill -0 "$pid" 2>>"$QUIET"; then break; fi
		sleep 0.02
	done
	if kill -0 "$pid" 2>>"$QUIET"; then kill -KILL "$pid" 2>>"$QUIET"; fi
	wait "$pid" 2>>"$QUIET"
	DAEMON_PID=''
}

setup_tools

if tests/host/ucode tests/schedule/update_test.uc; then
	ok "update schedule pure-function cases"
else
	bad "update schedule pure-function cases"
fi

# Due subscription scheduling runs independently of the monitor interval.
make_root "$T/root1"
R="$T/root1"
start_daemon "$R"
if wait_for_text "$R/schedule-calls.log" 'job start sub update s_00000001' 400; then
	ok "due subscription starts a job"
	sleep 0.2
	if grep -Fq 'job start update ' "$R/schedule-calls.log"; then bad "missing update record does not schedule at daemon start"; else ok "missing update record does not schedule at daemon start"; fi
	grep -Fq -- "--confdir $R/etc/config" "$R/schedule-calls.log" \
		&& grep -Fq -- "--run-dir $R/var/run/aether-proxy" "$R/schedule-calls.log" \
		&& ok "scheduler passes config and run directories" || bad "scheduler passes config and run directories"
	grep -Fq -- "--sys-root $R" "$R/schedule-calls.log" \
		&& grep -Fq -- "--bin-dir $T/bin" "$R/schedule-calls.log" \
		&& ok "scheduler passes system and binary roots" || bad "scheduler passes system and binary roots"
else
	bad "due subscription starts a job" "$(cat "$R/daemon.stderr")"
fi
stop_daemon

# Daily data scheduling precedes package checks; BUSY (3) is retried without recording.
make_root "$T/root-update-order"
R="$T/root-update-order"
printf '{"data":{"last_attempt":0},"check":{"last_attempt":0}}\n' > "$R/etc/aether-proxy/state/update-schedule.json"
export SCHEDULE_CHECK_FIRST_RC=3
start_daemon "$R"
if wait_for_text "$R/schedule-calls.log" 'job start update check' 400; then
	ok "update scheduler starts due data before check"
	first_data=$(grep -n 'job start update data' "$R/schedule-calls.log" | head -n 1 | cut -d: -f1)
	first_check=$(grep -n 'job start update check' "$R/schedule-calls.log" | head -n 1 | cut -d: -f1)
	[ -n "$first_data" ] && [ -n "$first_check" ] && [ "$first_data" -lt "$first_check" ] \
		&& ok "data is scheduled before package check" || bad "data is scheduled before package check"
	for _ in {1..200}; do
		count=$(cat "$R/update-check-count")
		[ "$count" -ge 2 ] && break
		sleep 0.02
	done
	[ "$count" -ge 2 ] && ok "check exit 3 is retried without recording" || bad "check exit 3 is retried without recording" "calls=$count"
	last_data=$(jget data.last_attempt < "$R/etc/aether-proxy/state/update-schedule.json")
	last_check=$(jget check.last_attempt < "$R/etc/aether-proxy/state/update-schedule.json")
	[ "$last_data" -gt 0 ] && ok "data attempt timestamp recorded" || bad "data attempt timestamp recorded" "$last_data"
	[ "$last_check" -gt 0 ] && ok "successful check attempt timestamp recorded" || bad "successful check attempt timestamp recorded" "$last_check"
else
	bad "update scheduler starts due data before check" "$(cat "$R/daemon.stderr") $(cat "$R/schedule-calls.log")"
fi
stop_daemon
unset SCHEDULE_CHECK_FIRST_RC

# data_auto=0 suppresses only the data job.
make_root "$T/root-data-disabled"
R="$T/root-data-disabled"
sed -i "s/option data_auto '1'/option data_auto '0'/" "$R/etc/config/aetherproxy"
printf '{"data":{"last_attempt":0},"check":{"last_attempt":0}}\n' > "$R/etc/aether-proxy/state/update-schedule.json"
start_daemon "$R"
if wait_for_text "$R/schedule-calls.log" 'job start update check' 400; then
	if grep -Fq 'job start update data' "$R/schedule-calls.log"; then bad "data_auto=0 suppresses data job"; else ok "data_auto=0 suppresses data and schedules check"; fi
else
	bad "data_auto=0 schedules package check" "$(cat "$R/daemon.stderr")"
fi
stop_daemon

# Auto installation runs only while running, records a version once, then accepts a newer one.
make_root "$T/root-auto-install"
R="$T/root-auto-install"
sed -i "s/option xray_auto 'notify'/option xray_auto 'auto'/" "$R/etc/config/aetherproxy"
now=$(date +%s)
printf '{"data":{"last_attempt":%s},"check":{"last_attempt":%s}}\n' "$now" "$now" > "$R/etc/aether-proxy/state/update-schedule.json"
printf '{"packages":{"xray-core":{"newer":true,"available":"26.10-r1","asset":"xray.ipk"}}}\n' > "$R/var/run/aether-proxy/updates.json"
SCHEDULE_RESOLVE_FAIL=0 start_daemon "$R"
wait_for_text "$R/var/run/aether-proxy/state.json" '"state"' 400
for _ in {1..40}; do
	[ "$(jget state < "$R/var/run/aether-proxy/state.json" 2>/dev/null)" = running ] && break
	kill -USR1 "$DAEMON_PID" 2>>"$QUIET" || break
	sleep 0.05
done
if wait_for_text "$R/schedule-calls.log" 'job start update package xray-core' 400; then
	ok "auto policy starts xray package job while running"
	version=$(jget auto_install.version < "$R/etc/aether-proxy/state/update-schedule.json")
	[ "$version" = '26.10-r1' ] && ok "auto install version is recorded" || bad "auto install version is recorded" "$version"
	sleep 0.4
	count=$(grep -c 'job start update package xray-core' "$R/schedule-calls.log")
	[ "$count" -eq 1 ] && ok "same version is not auto-installed again" || bad "same version is not auto-installed again" "calls=$count"
	printf '{"packages":{"xray-core":{"newer":true,"available":"26.11-r1","asset":"xray.ipk"}}}\n' > "$R/var/run/aether-proxy/updates.json"
	for _ in {1..200}; do
		count=$(grep -c 'job start update package xray-core' "$R/schedule-calls.log")
		[ "$count" -ge 2 ] && break
		sleep 0.02
	done
	[ "$count" -ge 2 ] && ok "new available version triggers another auto install" || bad "new available version triggers another auto install" "calls=$count"
else
	bad "auto policy starts xray package job while running" "$(cat "$R/daemon.stderr") $(cat "$R/var/run/aether-proxy/state.json" 2>/dev/null)"
fi
stop_daemon

# T9.6: exercise the real daemon while healthy and auto-enabled. The same cache must
# become eligible when only the selected database mtime changes back to checked.
for manager in opkg apk; do
	make_root "$T/root-stale-$manager"
	R="$T/root-stale-$manager"
	sed -i -e "s/option xray_auto 'notify'/option xray_auto 'auto'/" \
		-e "s/option interval_hours '1'/option interval_hours '0'/" "$R/etc/config/aetherproxy"
	now=$(date +%s)
	printf '{"data":{"last_attempt":%s},"check":{"last_attempt":%s},"auto_install":{"version":"old","at":1}}\n' \
		"$now" "$now" > "$R/etc/aether-proxy/state/update-schedule.json"
	cp "$R/etc/aether-proxy/state/update-schedule.json" "$T/stale-record"
	cat > "$R/var/run/aether-proxy/updates.json" <<EOF
{"pm":"$manager","checked":1760400000,
 "packages":{"xray-core":{"newer":true,"available":"26.10-r1","asset":"xray.ipk"}}}
EOF
	cp "$R/var/run/aether-proxy/updates.json" "$T/stale-cache"
	if [ "$manager" = opkg ]; then
		database="$R/usr/lib/opkg/status"
	else
		database="$R/lib/apk/db/installed"
	fi
	mkdir -p "$(dirname "$database")"
	touch -d @1760400010 "$database"
	SCHEDULE_RESOLVE_FAIL=0 start_daemon "$R"
	if wait_monitor_state running; then
		ok "T9.6 $manager stale auto setup reaches running"
		cp "$R/var/run/aether-proxy/events.jsonl" "$T/stale-events"
		sleep 0.4
		if grep -Fq 'job start update package xray-core' "$R/schedule-calls.log"; then
			bad "T9.6 $manager stale cache does not auto-install"
		else
			ok "T9.6 $manager stale cache does not auto-install"
		fi
		cmp -s "$T/stale-record" "$R/etc/aether-proxy/state/update-schedule.json" \
			&& ok "T9.6 $manager stale auto_install record unchanged" \
			|| bad "T9.6 $manager stale auto_install record unchanged"
		cmp -s "$T/stale-events" "$R/var/run/aether-proxy/events.jsonl" \
			&& ok "T9.6 $manager stale detection emits no events" \
			|| bad "T9.6 $manager stale detection emits no events"
		touch -d @1760400000 "$database"
		if wait_for_text "$R/schedule-calls.log" 'job start update package xray-core' 400; then
			ok "T9.6 $manager same cache fresh at equality auto-installs"
			# The stub logs before the daemon persists the record; wait for that write.
			if wait_for_text "$R/etc/aether-proxy/state/update-schedule.json" '26.10-r1' 200; then
				ok "T9.6 $manager fresh auto_install version recorded"
			else
				bad "T9.6 $manager fresh auto_install version recorded"
			fi
		else
			bad "T9.6 $manager same cache fresh at equality auto-installs" "$(< "$R/daemon.stderr")"
		fi
		cmp -s "$T/stale-cache" "$R/var/run/aether-proxy/updates.json" \
			&& ok "T9.6 $manager scheduler preserves cache bytes" \
			|| bad "T9.6 $manager scheduler preserves cache bytes"
	else
		bad "T9.6 $manager stale auto setup reaches running" "$(< "$R/daemon.stderr")"
	fi
	stop_daemon
done

# notify never installs, also while running (the degraded loop below cannot show that).
make_root "$T/root-notify-running"
R="$T/root-notify-running"
now=$(date +%s)
printf '{"data":{"last_attempt":%s},"check":{"last_attempt":%s}}\n' "$now" "$now" > "$R/etc/aether-proxy/state/update-schedule.json"
printf '{"packages":{"xray-core":{"newer":true,"available":"26.10-r1","asset":"xray.ipk"}}}\n' > "$R/var/run/aether-proxy/updates.json"
SCHEDULE_RESOLVE_FAIL=0 start_daemon "$R"
wait_for_text "$R/var/run/aether-proxy/state.json" '"state"' 400
for _ in {1..40}; do
	[ "$(jget state < "$R/var/run/aether-proxy/state.json" 2>/dev/null)" = running ] && break
	kill -USR1 "$DAEMON_PID" 2>>"$QUIET" || break
	sleep 0.05
done
if [ "$(jget state < "$R/var/run/aether-proxy/state.json" 2>/dev/null)" = running ]; then
	sleep 0.4
	grep -Fq 'job start update package' "$R/schedule-calls.log" \
		&& bad "notify policy does not install while running" || ok "notify policy does not install while running"
else
	bad "notify-running scheduler setup reaches running" "$(cat "$R/daemon.stderr")"
fi
stop_daemon

# Degraded and failsafe states must not auto-install; notify never installs either.
for policy in auto notify; do
	make_root "$T/root-policy-$policy"
	R="$T/root-policy-$policy"
	sed -i "s/option xray_auto 'notify'/option xray_auto '$policy'/" "$R/etc/config/aetherproxy"
	now=$(date +%s)
	printf '{"data":{"last_attempt":%s},"check":{"last_attempt":%s}}\n' "$now" "$now" > "$R/etc/aether-proxy/state/update-schedule.json"
	printf '{"packages":{"xray-core":{"newer":true,"available":"26.10-r1","asset":"xray.ipk"}}}\n' > "$R/var/run/aether-proxy/updates.json"
	start_daemon "$R"
	if wait_monitor_state degraded; then
		sleep 0.4
		if grep -Fq 'job start update package xray-core' "$R/schedule-calls.log"; then
			bad "$policy policy suppresses package installation while degraded"
		else
			ok "$policy policy does not auto-install while degraded"
		fi
		# degraded still runs the daily data/check jobs (08 "调度"); only installation waits.
		printf '{"data":{"last_attempt":0},"check":{"last_attempt":%s}}\n' "$now" > "$R/etc/aether-proxy/state/update-schedule.json"
		wait_for_text "$R/schedule-calls.log" 'job start update data' 400 \
			&& ok "$policy: degraded still schedules due data" || bad "$policy: degraded still schedules due data"
	else
		bad "$policy degraded scheduler setup" "$(cat "$R/daemon.stderr")"
	fi
	stop_daemon
done

# Corrupt update records are treated as empty and reported once, not every timer tick.
make_root "$T/root-corrupt-update-record"
R="$T/root-corrupt-update-record"
printf '{broken\n' > "$R/etc/aether-proxy/state/update-schedule.json"
start_daemon "$R"
if wait_for_text "$R/var/run/aether-proxy/events.jsonl" 'invalid ' 400; then
	sleep 0.4
	count=$(grep -c 'FS_FAILED' "$R/var/run/aether-proxy/events.jsonl")
	[ "$count" -eq 1 ] && ok "corrupt update schedule record logs FS_FAILED once" || bad "corrupt update schedule record logs FS_FAILED once" "count=$count"
else
	bad "corrupt update schedule record is diagnosed" "$(cat "$R/daemon.stderr")"
fi
stop_daemon

# Adding a subscription through reload creates its jitter on first sight and schedules it.
make_root "$T/root4"
R="$T/root4"
sed -i "s/option interval_hours '1'/option interval_hours '0'/" "$R/etc/config/aetherproxy"
start_daemon "$R"
if wait_monitor_state degraded; then
	ok "reload-jitter test daemon enters degraded"
	sed -i "s/option interval_hours '0'/option interval_hours '1'/" "$R/etc/config/aetherproxy"
	cat >> "$R/etc/config/aetherproxy" <<'EOF'

config subscription 's_00000002'
	option enabled '1'
	option name 'added on reload'
	option url 'https://subscription.example/second'
	option fetch_via 'direct'
	option interval_hours '1'
EOF
	kill -HUP "$DAEMON_PID"
	if wait_for_text "$R/schedule-calls.log" 'job start sub update s_00000002' 400; then
		ok "added subscription is scheduled after reload"
		first=$(grep -n 'job start sub update s_00000001' "$R/schedule-calls.log" | head -n 1 | cut -d: -f1)
		second=$(grep -n 'job start sub update s_00000002' "$R/schedule-calls.log" | head -n 1 | cut -d: -f1)
		[ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] \
			&& ok "reload enables interval change and schedules due subscriptions in name order" \
			|| bad "reload enables interval change and schedules due subscriptions in name order"
	else
		bad "new subscription is scheduled after reload" "$(cat "$R/daemon.stderr")"
	fi
else
	bad "reload-jitter test daemon enters degraded" "$(cat "$R/daemon.stderr")"
fi
stop_daemon

# failsafe is not an eligible service state, even when the configured interval is due.
make_root "$T/root2"
R="$T/root2"
now=$(date +%s)
printf '{ "s_00000001": { "last_attempt": %s, "last_ok": null, "nodes": 0, "skipped": {}, "error": null } }\n' "$((now + 1000))" \
	> "$R/etc/aether-proxy/state/sub.json"
start_daemon "$R"
if wait_monitor_state degraded; then
	ok "unresolved current node enters degraded for failsafe test"
	kill -USR1 "$DAEMON_PID"
	for _ in {1..100}; do
		count=$(jget monitor.xray_down_count < "$R/var/run/aether-proxy/state.json")
		[ "$count" = 1 ] && break
		sleep 0.02
	done
	kill -USR1 "$DAEMON_PID"
	if wait_monitor_state failsafe; then
		ok "two failed listener rounds enter failsafe"
	else
		bad "two failed listener rounds enter failsafe" "$(cat "$R/daemon.stderr")"
	fi
	now=$(date +%s)
	printf '{ "s_00000001": { "last_attempt": %s, "last_ok": null, "nodes": 0, "skipped": {}, "error": null } }\n' "$((now - 1000))" \
		> "$R/etc/aether-proxy/state/sub.json"
	printf '{"data":{"last_attempt":0},"check":{"last_attempt":0}}\n' > "$R/etc/aether-proxy/state/update-schedule.json"
	sleep 1.3
	[ ! -s "$R/schedule-calls.log" ] && ok "failsafe suppresses due subscription and update jobs" || bad "failsafe suppresses due subscription and update jobs" "$(cat "$R/schedule-calls.log")"
else
	bad "unresolved current node enters degraded for failsafe test" "$(cat "$R/daemon.stderr")"
fi
stop_daemon

# Stop during the last fraction of a schedule deadline; the timer must be cancelled before
# shutdown waits for its child, otherwise it would launch the now-due job during teardown.
make_root "$T/root3"
R="$T/root3"
now=$(date +%s)
printf '{ "s_00000001": { "last_attempt": %s, "last_ok": null, "nodes": 0, "skipped": {}, "error": null } }\n' "$((now + 1000))" \
	> "$R/etc/aether-proxy/state/sub.json"
cat > "$T/bin/chinadns-ng" <<'EOF'
#!/bin/sh
config=''
while [ "$#" -gt 0 ]; do
	if [ "$1" = -C ]; then shift; config="$1"; break; fi
	shift
done
SYSROOT=${config%/var/run/aether-proxy/current/*}
STUB_LOG="$SYSROOT/calls.log"
printf 'slow-chinadns %s\n' "$*" >> "$STUB_LOG"
echo "$$" > "$SYSROOT/chinadns.pid"
child=''
on_stop() {
	if [ -n "$child" ]; then /bin/kill -TERM "$child"; fi
	sleep 0.8
	rm -f "$SYSROOT/chinadns.pid"
	exit 0
}
trap on_stop TERM INT
while :; do sleep 1 & child=$!; wait "$child"; child=''; done
EOF
chmod +x "$T/bin/chinadns-ng"
SCHEDULE_HOURS=0.1 start_daemon "$R"
if wait_monitor_state degraded; then
	ok "stop-timer test daemon enters degraded"
	# Rebase the due time to this second, then stop while the schedule timer is still armed.
	for _ in {1..200}; do
		phase=$(date +%N)
		[ "$phase" -lt 200000000 ] && break
		sleep 0.01
	done
	now=$(date +%s)
	printf '{ "s_00000001": { "last_attempt": %s, "last_ok": null, "nodes": 0, "skipped": {}, "error": null } }\n' "$now" \
		> "$R/etc/aether-proxy/state/sub.json"
	for _ in {1..100}; do
		phase=$(date +%N)
		[ "$phase" -ge 800000000 ] && break
		sleep 0.01
	done
	stop_daemon
	sleep 1.2
	[ ! -s "$R/schedule-calls.log" ] && ok "stopped daemon does not fire the schedule timer" || bad "stopped daemon does not fire the schedule timer" "$(cat "$R/schedule-calls.log")"
else
	bad "stop-timer test daemon enters degraded" "state=$(jget state < "$R/var/run/aether-proxy/state.json" 2>&1) stderr=$(cat "$R/daemon.stderr") stdout=$(cat "$R/daemon.stdout")"
	stop_daemon
fi

echo "schedule: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
