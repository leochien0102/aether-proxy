#!/usr/bin/env bash
# CLI scenario tests for `aether-proxy check` and `render` (docs/tasks/m1 T1.7).
# Runs the real entry point on the host through the test-only options of docs/10, so nothing
# outside a mktemp directory is touched. Needs tests/host/bootstrap.sh to have run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"
FIX="$ROOT/tests/fixtures"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0

ap() { "$UCODE" -S "$ENTRY" -- "$@"; }
jget() { "$UCODE" "$JGET" -- "$1"; }

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }

# expect <name> <expected> <actual>
expect() {
	if [ "$2" == "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# Rule data: baseline holds everything, data dir starts empty.
mkdir -p "$T/data" "$T/base" "$T/custom"
for f in gfwlist chnlist apple; do printf 'example.com\n' > "$T/base/$f.txt"; done
printf '1.0.0.0/8\n' > "$T/base/chnroute4.txt"
printf '91.108.4.0/22\n' > "$T/base/gfw_static4.txt"

# opts <confdir> <rundir>
opts() {
	echo --confdir "$1" --data-dir "$T/data" --baseline-dir "$T/base" --custom-dir "$T/custom" --run-dir "$2"
}

# --- 1. enabled=1 without a node: configuration error, exit 2, nothing staged
out="$(ap check --json --no-precheck $(opts "$FIX/t11-err-enabled-no-node" "$T/run1") 2>/dev/null)"; rc=$?
expect "no node: exit code 2" 2 "$rc"
expect "no node: ok false" false "$(echo "$out" | jget ok)"
expect "no node: code" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "no node: error field" main.node "$(echo "$out" | jget errors.0.field)"
expect "no node: error code" required "$(echo "$out" | jget errors.0.code)"
[ ! -e "$T/run1" ] && ok "no node: run dir untouched" || bad "no node: run dir untouched"

# --- 2. valid config: exit 0, staging files equal render output byte for byte
out="$(ap check --json --no-precheck $(opts "$FIX/sample" "$T/run2") 2>/dev/null)"; rc=$?
expect "valid: exit code 0" 0 "$rc"
expect "valid: ok true" true "$(echo "$out" | jget ok)"
expect "valid: staging path" "$T/run2/staging" "$(echo "$out" | jget staging)"

declare -A FILES=( [nft]=aether-proxy.nft [chinadns]=chinadns.conf [dnsmasq]=dnsmasq.conf [xray]=xray.json )
for name in nft chinadns dnsmasq xray; do
	ap render "$name" $(opts "$FIX/sample" "$T/run2") > "$T/render-$name" 2>/dev/null; rc=$?
	expect "render $name: exit code 0" 0 "$rc"
	if cmp -s "$T/render-$name" "$T/run2/staging/${FILES[$name]}" && [ -s "$T/render-$name" ]; then
		ok "render $name: identical to staged ${FILES[$name]}"
	else
		bad "render $name: identical to staged ${FILES[$name]}"
	fi
done
[ "$(ls "$T/run2" | tr '\n' ' ')" == "staging " ] && ok "valid: only staging created in run dir" || bad "valid: only staging created in run dir"
[ ! -e "$T/run2/boot.txt" ] && ok "valid: boot.txt not written" || bad "valid: boot.txt not written"

# render writes no files
ap render nft $(opts "$FIX/sample" "$T/run2b") >/dev/null 2>&1
[ ! -e "$T/run2b" ] && ok "render: writes nothing" || bad "render: writes nothing"

# chinadns config carries all six paths (the sample config uses the default mode)
cd_conf="$T/render-chinadns"
for needle in "$T/custom/proxy_domain.txt" "$T/custom/direct_domain.txt" "$T/run2/boot.txt"; do
	grep -qF "$needle" "$cd_conf" && ok "chinadns: references $needle" || bad "chinadns: references $needle"
done

# render --json wraps the same bytes
out="$(ap render nft --json $(opts "$FIX/sample" "$T/run2") 2>/dev/null)"
expect "render --json: ok" true "$(echo "$out" | jget ok)"
expect "render --json: file" aether-proxy.nft "$(echo "$out" | jget file)"

# --- 3. rule data missing in both places: error, exit 2
rm "$T/base/chnlist.txt"
out="$(ap check --json --no-precheck $(opts "$FIX/sample" "$T/run3") 2>/dev/null)"; rc=$?
expect "missing data: exit code 2" 2 "$rc"
expect "missing data: ok false" false "$(echo "$out" | jget ok)"
expect "missing data: error code" missing_data "$(echo "$out" | jget errors.0.code)"
ap render chinadns $(opts "$FIX/sample" "$T/run3") >/dev/null 2>&1; rc=$?
expect "missing data: render exit code 2" 2 "$rc"

# the data directory takes priority over the baseline
printf 'example.org\n' > "$T/data/chnlist.txt"
mkdir -p "$T/conf_cn"
sed "s/option mode 'gfw'/option mode 'bypass_cn'/" "$FIX/sample/aetherproxy" > "$T/conf_cn/aetherproxy"
ap check --json --no-precheck $(opts "$T/conf_cn" "$T/run3") >/dev/null 2>&1; rc=$?
expect "data dir overrides baseline: exit code 0" 0 "$rc"
grep -F "chnlist-file" "$T/run3/staging/chinadns.conf" | grep -qF "$T/data/chnlist.txt" \
	&& ok "data dir overrides baseline: chnlist from data dir" || bad "data dir overrides baseline: chnlist from data dir"
grep -F "chnlist-file" "$T/run3/staging/chinadns.conf" | grep -qF "$T/base/apple.txt" \
	&& ok "data dir overrides baseline: apple from baseline" || bad "data dir overrides baseline: apple from baseline"

# --- 4. usage errors
ap render nosuch $(opts "$FIX/sample" "$T/run4") >/dev/null 2>&1; rc=$?
expect "render unknown name: exit code 2" 2 "$rc"
ap render $(opts "$FIX/sample" "$T/run4") >/dev/null 2>&1; rc=$?
expect "render without name: exit code 2" 2 "$rc"
out="$(ap render nosuch --json $(opts "$FIX/sample" "$T/run4") 2>/dev/null)"
expect "render unknown name --json: ok false" false "$(echo "$out" | jget ok)"
ap check --bogus >/dev/null 2>&1; rc=$?
expect "check unknown option: exit code 2" 2 "$rc"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
