#!/usr/bin/env bash
# Start the real chinadns-ng on every tests/fixtures/*/expected/chinadns.conf for 2 seconds.
# Exit code 124 (killed by timeout) means it started and stayed up = pass; anything else = fail.
# Needs root (nft sets, ports), the sets the config references are created first.
#
# Binary: zfl9/chinadns-ng release $CHINADNS_MIN_VERSION, wolfssl x86_64 static build (same
# asset the OpenWrt helloworld feed packages). The release publishes no checksums, so the
# SHA256 is pinned below, taken from helloworld's chinadns-ng Makefile PKG_HASH. When
# CHINADNS_MIN_VERSION changes, update the pin (the script refuses an unpinned version).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

declare -A PINNED_SHA256=(
	[2025.08.09]=842ea4e9816efd91d39bc76ead5c4a42e79011757e37c521b4270b675cfcb30c
)

ver=$(const_value CHINADNS_MIN_VERSION) || exit 2
want=${PINNED_SHA256[$ver]:-}
if [ -z "$want" ]; then
	echo "error: no pinned SHA256 for chinadns-ng $ver; add it to PINNED_SHA256 in $0" >&2
	echo "       (helloworld/chinadns-ng/Makefile, x86_64 branch, PKG_HASH)" >&2
	exit 2
fi

dir="$TOOLS_DIR/chinadns-ng-$ver"
bin="$dir/chinadns-ng"
if [ ! -x "$bin" ]; then
	mkdir -p "$dir" || exit 2
	asset='chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto'
	download "https://github.com/zfl9/chinadns-ng/releases/download/$ver/$asset" "$bin" || exit 2
	got=$(sha256sum "$bin" | cut -d' ' -f1)
	if [ "$got" != "$want" ]; then
		echo "error: chinadns-ng SHA256 mismatch: want $want, got $got" >&2
		rm -f "$bin"
		exit 2
	fi
	chmod +x "$bin"
	echo "chinadns-ng $ver: SHA256 verified ($got)"
fi
"$bin" -V

if [ "${CHINADNS_VERSION_ONLY:-0}" = 1 ]; then
	exit 0
fi

command -v nft >/dev/null || { echo "error: nft not installed" >&2; exit 2; }
SUDO=sudo
[ "$(id -u)" -eq 0 ] && SUDO=

# The configs reference fixed files. Create them empty at their real paths (instead of rewriting
# the configs) so the exact bytes of the golden file are what chinadns-ng reads.
files=()
while IFS= read -r f; do
	[ -n "$f" ] || continue
	files+=("$f")
done < <(fixtures chinadns.conf | xargs -r grep -hEo '(/etc/aether-proxy|/var/run/aether-proxy)/[A-Za-z0-9_./-]+\.txt' | sort -u)
for f in "${files[@]}"; do
	$SUDO mkdir -p "$(dirname "$f")" && $SUDO touch "$f" || { echo "error: cannot create $f" >&2; exit 2; }
done

cleanup() {
	local f
	for f in "${files[@]}"; do $SUDO rm -f "$f"; done
}
trap cleanup EXIT

fail=0 n=0
while IFS= read -r conf; do
	[ -n "$conf" ] || continue
	name=$(fixture_name "$conf")
	n=$((n + 1))

	# Sets referenced as inet@<table>@<set> ("null" is a placeholder, not a set).
	ruleset=$(grep -Eo 'inet@[A-Za-z0-9_]+@[A-Za-z0-9_]+' "$conf" | sort -u | awk -F@ '
		{ if (!($2 in seen)) { seen[$2] = 1; order[++k] = $2 } sets[$2] = sets[$2] "\tset " $3 " { type ipv4_addr; }\n" }
		END { for (i = 1; i <= k; i++) printf "table inet %s {\n%s}\n", order[i], sets[order[i]] }')
	tables=$(printf '%s\n' "$ruleset" | sed -n 's/^table inet \([A-Za-z0-9_]*\) {$/\1/p')
	setup=$(mktemp)
	printf '%s\n' "$ruleset" >"$setup"
	if ! out=$($SUDO nft -f "$setup" 2>&1); then
		echo "FAIL $name: cannot create referenced nft sets: $out"
		cat "$setup" | sed 's/^/     /'
		fail=$((fail + 1)); rm -f "$setup"; continue
	fi
	rm -f "$setup"

	out=$($SUDO timeout 2 "$bin" -C "$conf" 2>&1)
	rc=$?
	if [ "$rc" -eq 124 ]; then
		echo "ok   $name"
	else
		echo "FAIL $name (chinadns-ng exit $rc, expected 124 after timeout): $conf"
		printf '%s\n' "$out" | sed 's/^/     /'
		fail=$((fail + 1))
	fi
	for t in $tables; do $SUDO nft delete table inet "$t" || echo "warn: could not delete table $t" >&2; done
done < <(fixtures chinadns.conf)

echo "chinadns-ng: $n checked, $fail failed"
[ "$n" -gt 0 ] || { echo "error: no chinadns.conf fixtures found" >&2; exit 2; }
[ "$fail" -eq 0 ]
