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
rm -f "$fifo"
mkfifo -m 0600 "$fifo"
reader= writer=
cleanup() {
	trap '' TERM INT
	[ -z "$reader" ] || kill "$reader" 2>/dev/null || :
	[ -z "$writer" ] || kill "$writer" 2>/dev/null || :
	[ -z "$reader" ] || wait "$reader" 2>/dev/null || :
	[ -z "$writer" ] || wait "$writer" 2>/dev/null || :
	rm -f "$fifo"
}
trap cleanup EXIT
trap 'exit 0' TERM INT
# -f without -l asks OpenWrt logd for lines=0: new records only.
"${2:-logread}" -f -e aether-proxy > "$fifo" &
reader=$!
awk -v bytes="$(wc -c < raw.log)" -v lines="$(wc -l < raw.log)" '
function rotate() {
	close("raw.log")
	if (system("mv -f raw.log raw.log.1") != 0) exit 1
	printf "%s", "" > "raw.log"
	close("raw.log")
	bytes = lines = 0
}
# Only a real application tag, not a quoted tag in another program message.
/^[^\n]* [a-z0-9]+\.[a-z]+ aether-proxy\[[0-9]+\]: / {
	n = length($0) + 1
	# Preserve whole records: a single oversized record cannot fit a segment.
	if (n > 1048576) next
	if (bytes + n > 1048576 || lines >= 2000) rotate()
	print $0 >> "raw.log"
	if (fflush("raw.log") != 0) exit 1
	bytes += n
	lines++
	if (bytes >= 1048576 || lines >= 2000) rotate()
}
' < "$fifo" &
writer=$!
# EOF from logread also ends awk. Reap both on normal exit and TERM.
wait "$writer"
exit 1
