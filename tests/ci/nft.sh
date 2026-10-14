#!/usr/bin/env bash
# Validate every tests/fixtures/*/expected/aether-proxy.nft with `sudo nft -c -f`.
# Exit codes: 0 ok, 1 a fixture has a rule error, 2 environment problem (no nft, kernel module
# missing). A missing kernel module is reported separately and never as a fixture failure.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

command -v nft >/dev/null || { echo "error: nft not installed" >&2; exit 2; }
SUDO=sudo
[ "$(id -u)" -eq 0 ] && SUDO=

# 1. Try to load the modules the ruleset needs. Failure is not fatal here (may be built in);
#    the probes below decide.
for m in nft_tproxy nft_socket nft_fib_inet; do
	if ! out=$($SUDO modprobe "$m" 2>&1); then
		echo "note: modprobe $m failed: $out"
	fi
done

# 2. Probe each feature with a minimal ruleset, so "kernel lacks X" is told apart from
#    "the rendered rules are wrong".
probe() { # name, rule
	local f out
	f=$(mktemp) || return 2
	printf 'table inet ci_probe {\n\tchain c {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n\t\t%s\n\t}\n}\n' "$2" >"$f"
	if out=$($SUDO nft -c -f "$f" 2>&1); then
		rm -f "$f"
		echo "probe ok: $1"
		return 0
	fi
	rm -f "$f"
	echo "MODULE MISSING or unsupported: $1 (probe rule: $2)" >&2
	printf '%s\n' "$out" | sed 's/^/     /' >&2
	return 1
}
missing=0
probe tproxy 'meta l4proto tcp tproxy ip to :31080 accept' || missing=1
probe socket 'meta l4proto tcp socket transparent 1 accept' || missing=1
probe fib 'fib daddr type local accept' || missing=1
probe ether 'ether saddr 00:11:22:33:44:55 accept' || missing=1
if [ "$missing" -ne 0 ]; then
	echo "error: this runner's kernel cannot check the ruleset; fixtures were NOT checked" >&2
	exit 2
fi

# 3. The real check. Any failure here, with the probes passing, is a rule error.
fail=0 n=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	name=$(fixture_name "$f")
	n=$((n + 1))
	if out=$($SUDO nft -c -f "$f" 2>&1); then
		echo "ok   $name"
	else
		rc=$?
		echo "FAIL $name (nft exit $rc, rule error): $f"
		printf '%s\n' "$out" | sed 's/^/     /'
		fail=$((fail + 1))
	fi
done < <(fixtures aether-proxy.nft)

echo "nft: $n checked, $fail failed"
[ "$n" -gt 0 ] || { echo "error: no aether-proxy.nft fixtures found" >&2; exit 2; }
[ "$fail" -eq 0 ]
