#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INIT="$ROOT/aether-proxy/files/aether-proxy.init"
HOTPLUG="$ROOT/aether-proxy/files/aether-proxy.hotplug"
DEFAULTS="$ROOT/aether-proxy/files/aether-proxy.uci-defaults"
T="$(mktemp -d)"
pass=0
fail=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
contains() { grep -Fq -- "$2" "$1"; }

cat > "$T/bin-aether-proxy" <<'EOF'
#!/bin/sh
printf 'aether-proxy %s\n' "$*" >> "$PROCD_LOG"
exit "${CHECK_RC:-0}"
EOF
chmod +x "$T/bin-aether-proxy"
# Replace only the OpenWrt library imports; retain every branch of the packaged hook.
sed '/^\. \/lib\/functions\.sh$/d; /^\. \/lib\/functions\/procd\.sh$/d' "$HOTPLUG" > "$T/hotplug.test.sh"

run_init() {
	local mode="$1" enabled="$2" check_rc="$3" log="$T/$4.log"
	: > "$log"
	(
		export PROCD_LOG="$log" TEST_ENABLED="$enabled" CHECK_RC="$check_rc"
		config_load() { return 0; }
		config_get_bool() { printf -v "$1" '%s' "$TEST_ENABLED"; }
		procd_open_instance() { printf 'open %s\n' "$*" >> "$PROCD_LOG"; }
		procd_set_param() { printf 'set %s\n' "$*" >> "$PROCD_LOG"; }
		procd_append_param() { printf 'append %s\n' "$*" >> "$PROCD_LOG"; }
		procd_close_instance() { printf 'close\n' >> "$PROCD_LOG"; }
		procd_open_service() { printf 'open_service %s\n' "$*" >> "$PROCD_LOG"; }
		# Like procd.sh: close_service adds service_triggers itself.
		procd_close_service() { service_triggers; printf 'close_service\n' >> "$PROCD_LOG"; }
		procd_add_reload_trigger() { printf 'trigger %s\n' "$*" >> "$PROCD_LOG"; }
		procd_send_signal() { printf 'signal %s\n' "$*" >> "$PROCD_LOG"; return "${SIGNAL_RC:-0}"; }
		logger() { printf 'logger %s\n' "$*" >> "$PROCD_LOG"; }
		start() { printf 'start\n' >> "$PROCD_LOG"; start_service "$@"; }
		stop() { printf 'stop\n' >> "$PROCD_LOG"; }
		procd_running() { [ "${TEST_RUNNING:-1}" = 1 ]; }
		. "$INIT"
		AETHER_PROXY="$T/bin-aether-proxy"
		case "$mode" in
			start) start_service ;;
			boot) boot ;;
			reload) reload_service ;;
			stop) service_stopped ;;
			triggers) service_triggers ;;
		esac
	)
}

# Disabled services do not run check or register a procd instance.
run_init start 0 0 init-disabled; rc=$?
expect "disabled start is a no-op" 0 "$rc"
! contains "$T/init-disabled.log" 'aether-proxy check' && ok "disabled start skips check" || bad "disabled start skips check"
! contains "$T/init-disabled.log" 'open aether-proxy' && ok "disabled start registers no instance" || bad "disabled start registers no instance"

# Enabled manual start registers immediately; validation belongs to the daemon (T9.27).
run_init start 1 0 init-start; rc=$?
expect "enabled start succeeds" 0 "$rc"
! contains "$T/init-start.log" 'aether-proxy check' && ok "T9.27 start never invokes check" || bad "T9.27 start never invokes check"
grep -Fxq "open aether-proxy" "$T/init-start.log" && ok "start opens named instance" || bad "start opens named instance"
grep -Fxq "set command $T/bin-aether-proxy daemon" "$T/init-start.log" && ok "start command is daemon" || bad "start command is daemon"
grep -Fxq 'set respawn 3600 5 5' "$T/init-start.log" && ok "respawn policy recorded" || bad "respawn policy recorded"
grep -Fxq 'set stdout 1' "$T/init-start.log" && grep -Fxq 'set stderr 1' "$T/init-start.log" \
	&& ok "stdout/stderr inherited by procd" || bad "stdout/stderr inherited by procd"

run_init boot 1 0 init-boot; rc=$?
expect "boot succeeds" 0 "$rc"
grep -Fxq "append command --boot" "$T/init-boot.log" && ok "boot appends --boot" || bad "boot appends --boot"

run_init start 1 7 init-check-fail; rc=$?
expect "T9.27 start ignores failing check substitute" 0 "$rc"
! contains "$T/init-check-fail.log" 'aether-proxy check' \
	&& contains "$T/init-check-fail.log" 'open aether-proxy' \
	&& ok "T9.27 failing check substitute cannot prevent daemon registration" \
	|| bad "T9.27 failing check substitute cannot prevent daemon registration"
! contains "$T/init-boot.log" 'aether-proxy check' \
	&& ok "T9.27 boot never invokes check" || bad "T9.27 boot never invokes check"

# A failing check substitute proves the running branch never invokes it at all.
run_init reload 1 7 init-reload-fail; rc=$?
expect "running reload bypasses check even when it would fail" 0 "$rc"
! contains "$T/init-reload-fail.log" 'aether-proxy check' \
	&& ok "running reload never invokes check" || bad "running reload never invokes check"
grep -Fxq 'signal aether-proxy * HUP' "$T/init-reload-fail.log" \
	&& ok "running reload sends HUP without check" || bad "running reload sends HUP without check"
SIGNAL_RC=9 run_init reload 1 0 init-signal-fail; rc=$?
expect "reload returns HUP delivery failure" 9 "$rc"
contains "$T/init-signal-fail.log" 'procd_send_signal HUP failed (rc=9)' \
	&& ok "reload logs HUP delivery failure" || bad "reload logs HUP delivery failure"
run_init reload 1 0 init-reload; rc=$?
expect "valid reload succeeds" 0 "$rc"
grep -Fxq "signal aether-proxy * HUP" "$T/init-reload.log" && ok "reload sends HUP" || bad "reload sends HUP"
run_init reload 0 0 init-reload-disabled; rc=$?
expect "reload with enabled=0 succeeds" 0 "$rc"
grep -Fxq stop "$T/init-reload-disabled.log" && ! contains "$T/init-reload-disabled.log" 'signal aether-proxy' \
	&& ok "reload with enabled=0 stops the service" || bad "reload with enabled=0 stops the service"
TEST_RUNNING=0 run_init reload 1 0 init-reload-start; rc=$?
expect "reload of a stopped service succeeds" 0 "$rc"
grep -Fxq start "$T/init-reload-start.log" && grep -Fxq 'open aether-proxy' "$T/init-reload-start.log" \
	&& ! contains "$T/init-reload-start.log" 'signal aether-proxy' \
	&& ok "reload of a stopped service starts it" || bad "reload of a stopped service starts it"
run_init stop 1 0 init-stop; rc=$?
expect "service_stopped cleanup succeeds" 0 "$rc"
grep -Fxq 'open_service aether-proxy /etc/init.d/aether-proxy' "$T/init-stop.log" \
	&& grep -Fxq 'trigger aetherproxy' "$T/init-stop.log" && grep -Fxq close_service "$T/init-stop.log" \
	&& ok "T9.32 service_stopped re-registers the service with triggers" \
	|| bad "T9.32 service_stopped re-registers the service with triggers"
grep -Fxq 'aether-proxy cleanup --wait 35' "$T/init-stop.log" \
	&& ok "service_stopped runs cleanup --wait 35" || bad "service_stopped runs cleanup --wait 35"
run_init stop 1 3 init-stop-busy; rc=$?
expect "service_stopped preserves cleanup failure status" 3 "$rc"
grep -Fxq close_service "$T/init-stop-busy.log" \
	&& ok "T9.32 service_stopped registers triggers even when cleanup fails" \
	|| bad "T9.32 service_stopped registers triggers even when cleanup fails"
contains "$T/init-stop-busy.log" 'aether-proxy cleanup failed (rc=3)' \
	&& ok "service_stopped logs cleanup failure" || bad "service_stopped logs cleanup failure"
run_init triggers 1 0 init-triggers; rc=$?
expect "service_triggers succeeds" 0 "$rc"
grep -Fxq 'trigger aetherproxy' "$T/init-triggers.log" && ok "reload trigger registered" || bad "reload trigger registered"

# T9.32: a stateful procd stand-in (registry file) so trigger registration, service deletion
# and the manual-stop marker can be asserted across a whole stop/reload/start sequence.
# Like rc.common in procd mode: start = open_service; start_service; close_service, and close_service
# itself adds service_triggers (procd.sh); a trigger added before close lands inside "instances";
# stop = stop_service; procd deletes the service (instances and triggers); service_stopped.
F="$T/flow"
mkdir -p "$F/run"
flow_reset() { rm -rf "$F/run" "$F/svc"; mkdir -p "$F/run"; : > "$F/log"; }
flow_op() {
	(
		export PROCD_LOG="$F/log" CHECK_RC=0
		export AETHER_PROXY_RUN_DIR="$F/run"
		initscript=/etc/init.d/aether-proxy
		config_load() { return 0; }
		config_get_bool() { printf -v "$1" '%s' "$(cat "$F/enabled")"; }
		procd_open_service() { printf 'open_service %s\n' "$*" >> "$F/log"; : > "$F/pending"; }
		procd_open_instance() { echo instance >> "$F/pending"; }
		procd_set_param() { :; }
		procd_append_param() { :; }
		procd_close_instance() { :; }
		procd_add_reload_trigger() {
			if [ "${_in_close:-0}" = 1 ]; then echo "trigger $*" >> "$F/pending"; else echo "misplaced_trigger $*" >> "$F/pending"; fi
		}
		procd_close_service() { _in_close=1; service_triggers; _in_close=0; cp "$F/pending" "$F/svc"; printf 'close_service\n' >> "$F/log"; }
		procd_running() { grep -Fxq instance "$F/svc" 2>/dev/null; }
		procd_send_signal() { printf 'signal %s\n' "$*" >> "$F/log"; }
		logger() { :; }
		. "$INIT"
		AETHER_PROXY="$T/bin-aether-proxy"
		start() { procd_open_service "$(basename "${basescript:-$initscript}")" "$initscript"; start_service "$@"; procd_close_service; }
		stop() { stop_service "$@"; rm -f "$F/svc"; printf 'service_deleted\n' >> "$F/log"; service_stopped "$@"; }
		restart() { stop "$@"; start "$@"; }
		"$1"
	)
}
flow_has() { grep -Fxq -- "$1" "$F/svc" 2>/dev/null; }
flow_no_instance() { [ -f "$F/svc" ] && ! flow_has instance; }
MARK="$F/run/stopped-by-user"

# Scenario 3: enabled=0 reload stops, yet the service stays registered with its trigger.
flow_reset; echo 1 > "$F/enabled"
flow_op start
flow_has instance && flow_has 'trigger aetherproxy' && ok "T9.32 flow: started service has instance and trigger" \
	|| bad "T9.32 flow: started service has instance and trigger"
echo 0 > "$F/enabled"; flow_op reload_service; rc=$?
expect "T9.32 flow: enabled=0 reload succeeds" 0 "$rc"
grep -Fxq service_deleted "$F/log" && ok "T9.32 flow: stop deleted the service (as procd does)" \
	|| bad "T9.32 flow: stop deleted the service (as procd does)"
flow_no_instance && flow_has 'trigger aetherproxy' \
	&& ok "T9.32 flow: after enabled=0 stop the service is registered again, no instance, with trigger" \
	|| bad "T9.32 flow: after enabled=0 stop the service is registered again, no instance, with trigger"
! grep -q misplaced_trigger "$F/svc" && ok "T9.32 flow: re-registration adds triggers only through close_service" \
	|| bad "T9.32 flow: re-registration adds triggers only through close_service"
[ ! -e "$MARK" ] && ok "T9.32 flow: enabled=0 branch leaves no manual-stop marker" \
	|| bad "T9.32 flow: enabled=0 branch leaves no manual-stop marker"
echo 1 > "$F/enabled"; flow_op reload_service
flow_has instance && ok "T9.32 flow: enabled=1 reload after enabled=0 starts the service" \
	|| bad "T9.32 flow: enabled=1 reload after enabled=0 starts the service"

# Scenario 4: manual stop keeps config edits from starting the service.
flow_op stop
[ -e "$MARK" ] && ok "T9.32 flow: init stop writes the manual-stop marker" || bad "T9.32 flow: init stop writes the manual-stop marker"
flow_no_instance && flow_has 'trigger aetherproxy' && ok "T9.32 flow: manual stop keeps the reload trigger" \
	|| bad "T9.32 flow: manual stop keeps the reload trigger"
flow_op reload_service; rc=$?
expect "T9.32 flow: reload after manual stop succeeds" 0 "$rc"
flow_no_instance && [ -e "$MARK" ] && ok "T9.32 flow: reload after manual stop does not start" \
	|| bad "T9.32 flow: reload after manual stop does not start"
flow_op start
flow_has instance && [ ! -e "$MARK" ] && ok "T9.32 flow: start clears the marker and starts" \
	|| bad "T9.32 flow: start clears the marker and starts"
flow_op stop; flow_op restart
flow_has instance && [ ! -e "$MARK" ] && ok "T9.32 flow: restart of a manually stopped service ends without marker" \
	|| bad "T9.32 flow: restart of a manually stopped service ends without marker"
flow_op restart
flow_has instance && [ ! -e "$MARK" ] && ok "T9.32 flow: restart of a running service ends without marker" \
	|| bad "T9.32 flow: restart of a running service ends without marker"
flow_op reload_service
grep -Fxq 'signal aether-proxy * HUP' "$F/log" && ok "T9.32 flow: running reload still sends HUP" \
	|| bad "T9.32 flow: running reload still sends HUP"
# enabled=0 clears a marker left by a manual stop, so off -> on starts afterwards.
flow_op stop; echo 0 > "$F/enabled"; flow_op reload_service
[ ! -e "$MARK" ] && ok "T9.32 flow: enabled=0 reload clears the marker of a manual stop" \
	|| bad "T9.32 flow: enabled=0 reload clears the marker of a manual stop"
echo 1 > "$F/enabled"; flow_op reload_service
flow_has instance && ok "T9.32 flow: off then on after a manual stop starts the service" \
	|| bad "T9.32 flow: off then on after a manual stop starts the service"

# Preserve the original monitor-wakeup cases; DNS synchronization is an independent
# background call, including on LAN. Only the harness waits for its logging substitute.
run_hotplug() {
	local device="$1" enabled="$2" ifaces="$3" output="$4" ubus_rc="${5:-0}"
	(
		export PROCD_LOG="$T/$output.log" TEST_ENABLED="$enabled" TEST_LAN_IFACES="$ifaces"
		export UBUS_RC="$ubus_rc" UBUS_OUTPUT="${6:-{\"aether-proxy\":{\"instances\":{\"main\":{\"running\":true}}}}}"
		: > "$PROCD_LOG"
		config_load() { return 0; }
		config_get_bool() { printf -v "$1" '%s' "$TEST_ENABLED"; }
		config_list_foreach() { local value; for value in $TEST_LAN_IFACES; do "$3" "$value"; done; }
		ubus() { printf 'ubus %s\n' "$*" >> "$PROCD_LOG"; printf '%s\n' "$UBUS_OUTPUT"; return "$UBUS_RC"; }
		procd_send_signal() { printf 'signal %s\n' "$*" >> "$PROCD_LOG"; return "${HOTPLUG_SIGNAL_RC:-0}"; }
		logger() { printf 'logger %s\n' "$*" >> "$PROCD_LOG"; }
		hook_pid=$BASHPID
		aether-proxy() {
			printf 'aether-proxy %s\n' "$*" >> "$PROCD_LOG"
			if [ "$BASHPID" != "$hook_pid" ]; then
				printf 'dns-background yes\n' >> "$PROCD_LOG"
			else
				printf 'dns-background no\n' >> "$PROCD_LOG"
			fi
		}
		ACTION="${7-ifup}" DEVICE="$device" INTERFACE=lan
		trap 'wait' EXIT
		. "$T/hotplug.test.sh"
	)
}

run_hotplug br-lan 1 'br-lan br-guest' hotplug-lan; rc=$?
expect "LAN ifup is ignored" 0 "$rc"
! contains "$T/hotplug-lan.log" 'signal aether-proxy' && ok "LAN does not send USR1" || bad "LAN does not send USR1"
grep -Fxq 'aether-proxy dns sync-wan' "$T/hotplug-lan.log" \
	&& ok "T9.23 LAN ifup still invokes dns sync-wan" || bad "T9.23 LAN ifup still invokes dns sync-wan"
run_hotplug pppoe-wan 0 'br-lan' hotplug-disabled; rc=$?
expect "disabled hotplug is a no-op" 0 "$rc"
! contains "$T/hotplug-disabled.log" 'ubus call' && ok "disabled hotplug skips service lookup" || bad "disabled hotplug skips service lookup"
! contains "$T/hotplug-disabled.log" 'signal aether-proxy' \
	&& ok "disabled hotplug does not send USR1" || bad "disabled hotplug does not send USR1"
run_hotplug pppoe-wan 1 'br-lan' hotplug-down 0 '{"aether-proxy":{"instances":{}}}'; rc=$?
expect "stopped service hotplug is a no-op" 0 "$rc"
! contains "$T/hotplug-down.log" 'signal aether-proxy' && ok "stopped service does not send USR1" || bad "stopped service does not send USR1"
run_hotplug pppoe-wan 1 'br-lan' hotplug-up; rc=$?
expect "WAN ifup succeeds" 0 "$rc"
grep -Fxq 'signal aether-proxy * USR1' "$T/hotplug-up.log" && ok "WAN sends USR1" || bad "WAN sends USR1"
run_hotplug pppoe-wan 1 'br-lan' hotplug-ubus-fail 9 '{}'; rc=$?
expect "ubus failure is returned" 9 "$rc"
contains "$T/hotplug-ubus-fail.log" 'ubus call service list failed (rc=9)' \
	&& ok "ubus failure is logged" || bad "ubus failure is logged"
HOTPLUG_SIGNAL_RC=8 run_hotplug pppoe-wan 1 'br-lan' hotplug-signal-fail; rc=$?
expect "USR1 delivery failure is returned" 8 "$rc"
contains "$T/hotplug-signal-fail.log" 'procd_send_signal USR1 failed (rc=8)' \
	&& ok "USR1 delivery failure is logged" || bad "USR1 delivery failure is logged"
run_hotplug '' 1 'br-lan' hotplug-no-device; rc=$?
expect "missing DEVICE exits successfully" 0 "$rc"
! contains "$T/hotplug-no-device.log" 'signal aether-proxy' \
	&& ok "missing DEVICE does not send USR1" || bad "missing DEVICE does not send USR1"

for action in ifup ifupdate; do
	run_hotplug pppoe-wan 1 'br-lan' "hotplug-$action" 0 \
		'{"aether-proxy":{"instances":{"main":{"running":true}}}}' "$action"; rc=$?
	expect "T9.23 hotplug $action exits successfully" 0 "$rc"
	expect "T9.23 hotplug $action invokes dns sync-wan" 1 \
		"$(grep -Fxc 'aether-proxy dns sync-wan' "$T/hotplug-$action.log")"
	grep -Fxq 'dns-background yes' "$T/hotplug-$action.log" \
		&& ok "T9.23 hotplug $action runs sync-wan in background" \
		|| bad "T9.23 hotplug $action runs sync-wan in background"
done
! contains "$T/hotplug-ifupdate.log" 'signal aether-proxy' \
	&& ok "T9.23 ifupdate does not send USR1" || bad "T9.23 ifupdate does not send USR1"
! contains "$T/hotplug-ifupdate.log" 'ubus call' \
	&& ok "T9.23 ifupdate skips service lookup" || bad "T9.23 ifupdate skips service lookup"
for action in ifdown iflink reload ''; do
	run_hotplug pppoe-wan 1 'br-lan' hotplug-other 0 '{}' "$action"; rc=$?
	expect "T9.23 hotplug other action '$action' exits successfully" 0 "$rc"
	[ ! -s "$T/hotplug-other.log" ] \
		&& ok "T9.23 hotplug other action '$action' makes no call" || bad "T9.23 hotplug other action '$action' makes no call"
done

run_defaults() {
	local name="$1" get_rc="$2" current="$3" od_value="$4" set_rc="$5" commit_rc="$6" log="$T/$1.log"
	: > "$log"
	(
		export PROCD_LOG="$log" TEST_UCI_GET_RC="$get_rc" TEST_UCI_VALUE="$current"
		export TEST_OD_VALUE="$od_value" TEST_UCI_SET_RC="$set_rc" TEST_UCI_COMMIT_RC="$commit_rc"
		uci() {
			printf 'uci %s\n' "$*" >> "$PROCD_LOG"
			case "$1:$2" in
				-q:get) [ "$TEST_UCI_GET_RC" -eq 0 ] && printf '%s\n' "$TEST_UCI_VALUE"; return "$TEST_UCI_GET_RC" ;;
				set:*) return "$TEST_UCI_SET_RC" ;;
				commit:*) return "$TEST_UCI_COMMIT_RC" ;;
			esac
			return 2
		}
		ucode() { printf '%s' "$TEST_OD_VALUE"; return 0; }
		logger() { printf 'logger %s\n' "$*" >> "$PROCD_LOG"; }
		. "$DEFAULTS"
	)
}

run_defaults defaults-generate 1 '' 65535 0 0; rc=$?
expect "uci-defaults creates randomized minute" 0 "$rc"
contains "$T/defaults-generate.log" 'uci set aetherproxy.update.data_minute=15' \
	&& contains "$T/defaults-generate.log" 'uci commit aetherproxy' \
	&& ok "uci-defaults writes and commits minute" || bad "uci-defaults writes and commits minute"
run_defaults defaults-idempotent 0 22 100 0 0; rc=$?
expect "uci-defaults preserves existing minute" 0 "$rc"
! contains "$T/defaults-idempotent.log" 'uci set' && ok "existing minute is not overwritten" || bad "existing minute is not overwritten"
run_defaults defaults-get-fail 4 '' 100 0 0; rc=$?
expect "uci get error fails closed" 1 "$rc"
contains "$T/defaults-get-fail.log" 'uci -q get aetherproxy.update.data_minute failed (rc=4)' \
	&& ok "uci get failure is logged" || bad "uci get failure is logged"

echo "procd stubs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
