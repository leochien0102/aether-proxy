#!/bin/sh
# Execute the packaged init; only config, commands and procd RPC boundaries are stubs.
# No errexit: rc.common must continue after a failing hook or kill.
. "$INIT"
. "$FIXTURE"
AETHER_PROXY="$CASE_DIR/aether-proxy"
initscript=/etc/init.d/aether-proxy
trace() { printf '%s\n' "$*" >> "$CASE_DIR/trace"; }
config_load() { :; }
config_get_bool() { enabled="$TEST_ENABLED"; }
logger() { trace "logger $*"; }
procd_lock() { trace lock; }
procd_running() { [ "$RUNNING" = 1 ]; }
procd_open_service() { trace open-service; }
procd_close_service() { service_triggers; trace close-service; }
procd_add_reload_trigger() { trace "trigger $*"; }
rm() {
	case "$*" in
		"-f $_AETHER_PROXY_RESTART_INTENT")
			if [ "$FAULT" = intent ]; then trace fail-intent-remove; return 13; fi ;;
		"-f $_AETHER_PROXY_STOP_MARK")
			if [ "$FAULT" = mark-remove ]; then trace fail-mark-remove; return 14; fi ;;
	esac
	command rm "$@"
}
phase() {
	# Python owns this exact child PID; ready/ack gates replace timing-window sleeps.
	printf 'ready %s %s\n' "$1" "$$"
	read -r ack || exit 90
	[ "$ack" = continue ] || exit 91
	trace "resumed $1"
}
procd_kill() {
	trace kill
	if [ "$SIGNALS" = 1 ]; then phase stop; fi
	return 19
}
start() {
	trace start
	if [ "$SIGNALS" = 1 ]; then phase start; fi
	return "$START_RC"
}
case "$MODE" in
	stop|reload_service|restart|service_stopped)
		"$MODE"; result=$?
		trace "result $result"
		if [ "$SIGNALS" = 1 ]; then phase returned; fi
		exit "$result" ;;
	reset)
		stop; trace "first $?"
		service_stopped; trace "after-failure-callback $?"
		FAULT=none
		command rm -rf "$_AETHER_PROXY_STOP_MARK"
		stop; trace "second $?"
		service_stopped; trace "independent $?" ;;
	esac
