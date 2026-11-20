#!/bin/sh
# Private tmpfs copy of new logd records; never change logd or its configuration.
set -eu
export LC_ALL=C
umask 077
mkdir -p "$1"
cd "$1"
: >> raw.log
chmod 0600 raw.log
[ ! -e raw.log.1 ] || chmod 0600 raw.log.1
fifo=raw-log.pipe
ready=raw-log.ready
rm -f "$fifo" "$ready"
reader= writer= sleeper= prober=
probe_follow() {
	# The -p pidfile precedes the logd subscription. Round-trip a live record instead.
	pause=
	trap '[ -z "$pause" ] || { kill "$pause" || :; wait "$pause" || :; }; exit 0' TERM INT
	i=0
	while [ ! -f "$ready" ] && [ "$i" -lt 20 ]; do
		"$2" -p daemon.info -t aether-proxy-rawlog "$1" &
		pause=$!
		wait "$pause" || :
		i=$((i + 1))
		sleep 0.1 &
		pause=$!
		wait "$pause" || :
		pause=
	done
}
stop_pair() {
	# A worker may already have exited; still wait to reap its status.
	[ -z "$prober" ] || kill "$prober" || :
	[ -z "$reader" ] || kill "$reader" || :
	[ -z "$writer" ] || kill "$writer" || :
	[ -z "$prober" ] || wait "$prober" || :
	[ -z "$reader" ] || wait "$reader" || :
	[ -z "$writer" ] || wait "$writer" || :
	reader= writer= prober=
	rm -f "$fifo" "$ready"
}
cleanup() {
	trap '' TERM INT
	[ -z "$sleeper" ] || kill "$sleeper" || :
	[ -z "$sleeper" ] || wait "$sleeper" || :
	stop_pair
}
trap cleanup EXIT
trap 'exit 0' TERM INT
delay=1
attempt=0
while :; do
	rm -f "$ready"
	attempt=$((attempt + 1))
	probe="ready:$$:$attempt"
	mkfifo -m 0600 "$fifo"
	started=$(date +%s)
	# -f without -l asks OpenWrt logd for lines=0: new records only.
	"${2:-logread}" -f -e aether-proxy > "$fifo" &
	reader=$!
	awk -v bytes="$(wc -c < raw.log)" -v lines="$(wc -l < raw.log)" \
		-v ready="$ready" -v probe=" daemon.info aether-proxy-rawlog: $probe" '
function mark_ready() {
	if (!attached) {
		printf "%s", "" > ready
		close(ready)
		attached = 1
	}
}
substr($0, length($0) - length(probe) + 1) == probe {
	mark_ready()
	next
}
function rotate() {
	close("raw.log")
	if (system("mv -f raw.log raw.log.1") != 0) exit 1
	printf "%s", "" > "raw.log"
	close("raw.log")
	bytes = lines = 0
}
function append(record, n) {
	n = length(record) + 1
	if (bytes + n > 1048576 || lines >= 2000) rotate()
	print record >> "raw.log"
	# BusyBox awk flushes but does not define a return value for fflush().
	fflush("raw.log")
	bytes += n
	lines++
	if (bytes >= 1048576 || lines >= 2000) rotate()
}
function flush_suppressed() {
	if (!suppressed) return
	append("aether-proxy: chinadns-ng startup: " suppressed " info lines suppressed")
	suppressed = 0
}
function startup_noise(msg) {
	return msg ~ /^I \[(main|dnl|groups)\.(zig|c):[0-9]+ / &&
	       msg !~ /local listen addr|failed|^[WE] \[|\[(Warning|Error)\]/ &&
	       msg !~ /^I \[dnl\.c:[0-9]+ dnl_init\] tag: /
}
{ gsub(/\033\[[0-9;]*m/, "") }
# Split at the first application prefix, not at a tag quoted in its payload.
match($0, / [a-z0-9]+\.[a-z]+ aether-proxy\[[0-9]+\]: /) {
	# A genuine live application record also proves the subscription is active.
	mark_ready()
	end = RSTART + RLENGTH - 1
	msg = substr($0, end + 1)
	sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [[:space:]]*/, "", msg)
	if (startup_noise(msg)) {
		suppressed++
		next
	}
	record = substr($0, 1, end) msg
	# Preserve whole records: a single oversized record cannot fit a segment.
	if (length(record) + 1 > 1048576) next
	flush_suppressed()
	append(record)
}
END { flush_suppressed() }
	' < "$fifo" &
	writer=$!
	probe_follow "$probe" "${3:-logger}" &
	prober=$!
	# Reader EOF ends awk; an awk failure must also stop the old reader before retry.
	# A nonzero wait is expected here and must not trigger set -e / collector exit.
	wait "$writer" || :
	writer=
	stop_pair
	# Reset after a stable session; repeated short sessions back off 1,2,3,4,5 seconds.
	[ "$(( $(date +%s) - started ))" -lt 30 ] || delay=1
	# Background + wait lets TERM/INT interrupt even the capped retry delay.
	sleep "$delay" &
	sleeper=$!
	wait "$sleeper" || :
	sleeper=
	[ "$delay" -ge 5 ] || delay=$((delay + 1))
done
