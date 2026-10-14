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
mkdir -p "$T/run1"
out="$(ap check --json --no-precheck $(opts "$FIX/t11-err-enabled-no-node" "$T/run1") 2>"$T/check-fail.stderr")"; rc=$?
expect "no node: exit code 2" 2 "$rc"
expect "check --json failure: stderr empty" "" "$(cat "$T/check-fail.stderr")"
expect "no node: ok false" false "$(echo "$out" | jget ok)"
expect "no node: code" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "no node: error field" main.node "$(echo "$out" | jget errors.0.field)"
expect "no node: error code" required "$(echo "$out" | jget errors.0.code)"
[ ! -e "$T/run1/staging" ] && ok "no node: no staging written" || bad "no node: no staging written"
[ -s "$T/run1/events.jsonl" ] && ok "no node: structured failure event appended" || bad "no node: structured failure event appended"
expect "no node: event is one JSONL object" CONFIG_INVALID "$(head -n 1 "$T/run1/events.jsonl" | jget code)"
expect "no node: event severity" error "$(head -n 1 "$T/run1/events.jsonl" | jget level)"
[ -n "$(head -n 1 "$T/run1/events.jsonl" | jget ts)" ] \
	&& ok "no node: event timestamp present" || bad "no node: event timestamp present"

# --- 2. valid config: exit 0, staging files equal render output byte for byte
out="$(ap check --json --no-precheck $(opts "$FIX/sample" "$T/run2") 2>"$T/check-ok.stderr")"; rc=$?
expect "valid: exit code 0" 0 "$rc"
expect "check --json success: stderr empty" "" "$(cat "$T/check-ok.stderr")"
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
out="$(ap render nft --json $(opts "$FIX/sample" "$T/run2") 2>"$T/render-json.stderr")"
expect "render --json: stderr empty" "" "$(cat "$T/render-json.stderr")"
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
out="$(ap version --json 2>"$T/version-json.stderr")"; rc=$?
expect "version --json: exit code 0" 0 "$rc"
expect "version --json: stderr empty" "" "$(cat "$T/version-json.stderr")"
expect "version --json: parses as object" true "$(echo "$out" | jget ok)"
version="$(echo "$out" | jget version)"
[ -n "$version" ] && [ "$version" != '<missing>' ] \
	&& ok "version --json: version present" || bad "version --json: version present"
ap check --bogus >/dev/null 2>&1; rc=$?
expect "check unknown option: exit code 2" 2 "$rc"

# --- 5. runtime status/events are isolated to the test run directory
mkdir -p "$T/status-empty"
out="$(ap status --json --run-dir "$T/status-empty" 2>"$T/status-empty.stderr")"; rc=$?
expect "status missing file: exit code 0" 0 "$rc"
expect "status missing file: stderr empty" "" "$(cat "$T/status-empty.stderr")"
expect "status missing file: stopped default" stopped "$(echo "$out" | jget state)"

mkdir -p "$T/status-populated"
printf '{"state":"running","dns_tier":"T1","future_field":{"kept":true}}\n' > "$T/status-populated/state.json"
out="$(ap status --json --run-dir "$T/status-populated" 2>"$T/status-populated.stderr")"; rc=$?
expect "status existing file: exit code 0" 0 "$rc"
expect "status existing file: stderr empty" "" "$(cat "$T/status-populated.stderr")"
expect "status existing file: state" running "$(echo "$out" | jget state)"
expect "status existing file: unknown field preserved" true "$(echo "$out" | jget future_field.kept)"

mkdir -p "$T/events"
cat > "$T/events/events.jsonl" <<'EVENTS'
{"ts":100,"level":"notice","code":"SERVICE_STARTED","args":{"mode":"gfw"}}
{"ts":200,"level":"warn","code":"DNS_TIER_CHANGED","args":{"from":"T1","to":"T2"}}
{"ts":300,"level":"error","code":"XRAY_DOWN","args":{}}
EVENTS
out="$(ap events --json --run-dir "$T/events" 2>"$T/events-all.stderr")"; rc=$?
expect "events: exit code 0" 0 "$rc"
expect "events: stderr empty" "" "$(cat "$T/events-all.stderr")"
expect "events: first row" SERVICE_STARTED "$(echo "$out" | jget events.0.code)"
expect "events: third row" XRAY_DOWN "$(echo "$out" | jget events.2.code)"

out="$(ap events --json --since 200 --run-dir "$T/events" 2>"$T/events-since.stderr")"; rc=$?
expect "events since: exit code 0" 0 "$rc"
expect "events since: stderr empty" "" "$(cat "$T/events-since.stderr")"
expect "events since: inclusive boundary" 200 "$(echo "$out" | jget events.0.ts)"
expect "events since: later event retained" 300 "$(echo "$out" | jget events.1.ts)"
expect "events since: earlier event removed" '<missing>' "$(echo "$out" | jget events.2.ts)"

out="$(ap events --json --level warn --run-dir "$T/events" 2>"$T/events-level.stderr")"; rc=$?
expect "events level: exit code 0" 0 "$rc"
expect "events level: stderr empty" "" "$(cat "$T/events-level.stderr")"
expect "events level: exact level selected" DNS_TIER_CHANGED "$(echo "$out" | jget events.0.code)"
expect "events level: other levels removed" '<missing>' "$(echo "$out" | jget events.1.ts)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
