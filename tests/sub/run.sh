#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"
FIX="$ROOT/tests/sub/fixtures"
STUBS="$ROOT/tests/stubs/sub-bin"
T="$(mktemp -d "$ROOT/tests/sub/tmp.XXXXXX")"
pass=0
fail=0
R=''
BODY=''

cleanup() {
	if [ -n "$T" ] && [ -d "$T" ]; then
		if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept sub-test temp: $T"; else rm -rf "$T"; fi
	fi
}
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
has_line() { grep -Fq -- "$2" "$1"; }
count_line() { awk -v needle="$2" '$0 == needle { n++ } END { print n+0 }' "$1"; }
jget() { "$UCODE" "$JGET" -- "$1"; }
ap() {
	env SYSROOT="$R" STUB_LOG="$R/calls.log" STUB_CURL_BODY="$BODY" \
		STUB_CURL_BODY_ALT="${STUB_CURL_BODY_ALT:-}" \
		STUB_CURL_DIRECT_RC="${STUB_CURL_DIRECT_RC:-0}" STUB_CURL_PROXY_RC="${STUB_CURL_PROXY_RC:-0}" \
		STUB_CURL_URL_RC="${STUB_CURL_URL_RC:-22}" STUB_CURL_FAIL_URL="${STUB_CURL_FAIL_URL:-}" \
		STUB_CURL_EMPTY="${STUB_CURL_EMPTY:-0}" STUB_CURL_EMPTY_URL="${STUB_CURL_EMPTY_URL:-}" \
		STUB_CURL_REPLACE_CONFIG="${STUB_CURL_REPLACE_CONFIG:-}" \
		STUB_XRAY_TEST_RC="${STUB_XRAY_TEST_RC:-0}" \
		"$UCODE" -S "$ENTRY" -- sub update "$@" \
		--sys-root "$R" --confdir "$R/etc/config" --run-dir "$R/var/run/aether-proxy" --bin-dir "$T/bin"
}
options_for() { echo --sys-root "$R" --confdir "$R/etc/config" --run-dir "$R/var/run/aether-proxy" --bin-dir "$T/bin"; }

setup_tools() {
	mkdir -p "$T/bin"
	cp "$STUBS/curl" "$T/bin/curl"
	cp "$STUBS/xray" "$T/bin/xray"
	chmod +x "$T/bin/curl" "$T/bin/xray"
}

make_root() {
	R="$1"
	mkdir -p "$R/etc/config" "$R/etc/init.d" "$R/etc/aether-proxy/state" \
		"$R/var/lock" "$R/var/run/aether-proxy" "$R/tmp" "$R/proc/net" \
		"$R/usr/share/aether-proxy" "$R/etc/aether-proxy/custom"
	ln -s "$ROOT/aether-proxy/files/data" "$R/usr/share/aether-proxy/data"
	cp "$STUBS/aether-proxy.init" "$R/etc/init.d/aether-proxy"
	chmod +x "$R/etc/init.d/aether-proxy"
	printf 'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$R/proc/net/tcp"
	printf 'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n' > "$R/proc/net/tcp6"
	: > "$R/calls.log"
}

write_config() {
	cat > "$R/etc/config/aetherproxy" <<'EOF'
config global 'main'
	option enabled '0'
	option mode 'gfw'

config subscription 's_00000001'
	option enabled '1'
	option name 'first'
	option url 'https://sub-a.example/list'
	option fetch_via 'direct'

config subscription 's_00000002'
	option enabled '1'
	option name 'second'
	option url 'https://sub-b.example/list'
	option fetch_via 'direct'
EOF
}

init_current_config() {
	cat > "$R/etc/config/aetherproxy" <<'EOF'
config global 'main'
	option enabled '1'
	option mode 'gfw'
	option node 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

config subscription 's_00000001'
	option enabled '1'
	option url 'https://sub-a.example/list'
	option fetch_via 'direct'

config node 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	option label 'Edge One'
	option source 's_00000001'
	option protocol 'vless'
	option address 'edge.example.com'
	option port '443'
	option uuid '11111111-2222-4333-8444-555555555555'
	option transport 'ws'
	option security 'tls'
	option encryption 'none'
	option sni 'edge.example.com'
	option path '/ws'
	option host 'cdn.example.com'
EOF
}

setup_tools

# First import writes a correctly named node and subscription identity metadata.
make_root "$T/root1"
write_config
BODY="$FIX/one-node.txt"
out=$(ap --json s_00000001 2>"$T/stderr1"); rc=$?
expect "initial import exits successfully" 0 "$rc"
expect "initial import reports one added node" 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
node_id=$(sed -n "s/^config node '\(n_[0-9a-f]*\)'$/\1/p" "$R/etc/config/aetherproxy" | head -n 1)
[[ "$node_id" =~ ^n_[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}$ ]] \
	&& ok "new section name is UUID v4 format" || bad "new section name is UUID v4 format" "$node_id"
has_line "$R/etc/config/aetherproxy" "option source 's_00000001'" && ok "new node records source" || bad "new node records source"
grep -q "option match_strong 'vless|edge.example.com|443|ws|/ws|cdn.example.com||tls|edge.example.com|11111111-2222-4333-8444-555555555555'" "$R/etc/config/aetherproxy" \
	&& ok "new node stores direct strong identity key" || bad "new node stores direct strong identity key"
[ -f "$R/var/run/aether-proxy/sub-work/aetherproxy_sub" ] \
	&& ok "staging uses the synthetic package name" || bad "staging uses the synthetic package name"
[ ! -e "$R/var/run/aether-proxy/sub-work/aetherproxy" ] \
	&& ok "staging never commits under the live package name" || bad "staging never commits under the live package name"
[ ! -s "$T/stderr1" ] && ok "JSON mode leaves stderr empty" || bad "JSON mode leaves stderr empty" "$(cat "$T/stderr1")"

# Unchanged rendered nodes leave the configuration bytes intact and do not reload.
cp "$R/etc/config/aetherproxy" "$T/unchanged.before"
out=$(ap --json s_00000001 2>"$T/stderr2"); rc=$?
[ "$rc" -eq 0 ] && ok "unchanged subscription exits successfully" || bad "unchanged subscription exits successfully" "rc=$rc out=$out stderr=$(cat "$T/stderr2")"
cmp -s "$T/unchanged.before" "$R/etc/config/aetherproxy" \
	&& ok "unchanged subscription preserves exact UCI bytes" || bad "unchanged subscription preserves exact UCI bytes"
! grep -q '^init reload$' "$R/calls.log" && ok "unchanged subscription does not reload" || bad "unchanged subscription does not reload"

# A current-node credential change is validated against rendered Xray and reloads only when active.
make_root "$T/root2"
init_current_config
BODY="$FIX/one-node-rotated.txt"
printf '{"state":"running"}\n' > "$R/var/run/aether-proxy/state.json"
out=$(ap --json s_00000001 2>"$T/stderr3"); rc=$?
expect "current-node update exits successfully" 0 "$rc"
has_line "$R/calls.log" 'xray run -test -c' && ok "current-node update runs xray validation" || bad "current-node update runs xray validation"
expect "active current-node update reloads exactly once" 1 "$(count_line "$R/calls.log" 'init reload')"
has_line "$R/etc/config/aetherproxy" "option uuid 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'" \
	&& ok "current node credential is replaced" || bad "current node credential is replaced"
expect "current-node update reports one updated node" 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.updated)"

# Without an active daemon the same current-node change is committed without init reload.
make_root "$T/root3"
init_current_config
: > "$R/calls.log"
out=$(ap --json s_00000001 2>"$T/stderr4"); rc=$?
expect "stopped current-node update exits successfully" 0 "$rc"
! grep -q '^init reload$' "$R/calls.log" && ok "stopped service is not reloaded" || bad "stopped service is not reloaded"

# Xray validation failure rejects the staged configuration and preserves the original file.
make_root "$T/root4"
init_current_config
cp "$R/etc/config/aetherproxy" "$T/xray-fail.before"
export STUB_XRAY_TEST_RC=1
out=$(ap --json s_00000001 2>"$T/stderr5"); rc=$?
unset STUB_XRAY_TEST_RC
expect "xray rejection exits nonzero" 1 "$rc"
expect "xray rejection reports SUB_APPLY_INVALID" SUB_APPLY_INVALID "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
cmp -s "$T/xray-fail.before" "$R/etc/config/aetherproxy" \
	&& ok "xray rejection preserves original config" || bad "xray rejection preserves original config"

# Fetch errors, empty bodies, and all-invalid bodies preserve the old UCI file.
make_root "$T/root5"
write_config
cp "$R/etc/config/aetherproxy" "$T/fetch-fail.before"
export STUB_CURL_DIRECT_RC=22
out=$(ap --json s_00000001 2>"$T/stderr6"); rc=$?
unset STUB_CURL_DIRECT_RC
expect "curl failure exits nonzero" 1 "$rc"
expect "curl failure reports SUB_FETCH_FAILED" SUB_FETCH_FAILED "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
cmp -s "$T/fetch-fail.before" "$R/etc/config/aetherproxy" \
	&& ok "curl failure preserves UCI file" || bad "curl failure preserves UCI file"
export STUB_CURL_EMPTY=1
out=$(ap --json s_00000001 2>"$T/stderr7"); rc=$?
unset STUB_CURL_EMPTY
expect "empty response exits nonzero" 1 "$rc"
expect "empty response reports SUB_FETCH_FAILED" SUB_FETCH_FAILED "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
BODY="$FIX/invalid.txt"
out=$(ap --json s_00000001 2>"$T/stderr8"); rc=$?
expect "all-invalid response exits nonzero" 1 "$rc"
expect "all-invalid response reports SUB_NO_VALID_NODES" SUB_NO_VALID_NODES "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
cmp -s "$T/fetch-fail.before" "$R/etc/config/aetherproxy" \
	&& ok "invalid responses preserve UCI file" || bad "invalid responses preserve UCI file"

# Explicit proxy mode requires a running listener; auto retries a failed direct fetch via proxy.
make_root "$T/root6"
write_config
sed -i "s/fetch_via 'direct'/fetch_via 'proxy'/" "$R/etc/config/aetherproxy"
out=$(ap --json s_00000001 2>"$T/stderr9"); rc=$?
expect "proxy-only unavailable exits nonzero" 1 "$rc"
expect "proxy-only unavailable reports SUB_PROXY_UNAVAILABLE" SUB_PROXY_UNAVAILABLE "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
! grep -q '^curl ' "$R/calls.log" && ok "unavailable proxy does not invoke curl" || bad "unavailable proxy does not invoke curl"
make_root "$T/root7"
write_config
sed -i "s/fetch_via 'direct'/fetch_via 'auto'/" "$R/etc/config/aetherproxy"
BODY="$FIX/one-node.txt"
printf '{"state":"running"}\n' > "$R/var/run/aether-proxy/state.json"
printf '  0: 0100007F:7969 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n' >> "$R/proc/net/tcp"
export STUB_CURL_DIRECT_RC=7
out=$(ap --json s_00000001 2>"$T/stderr10"); rc=$?
unset STUB_CURL_DIRECT_RC
[ "$rc" -eq 0 ] && ok "auto proxy fallback succeeds" || bad "auto proxy fallback succeeds" "rc=$rc out=$out stderr=$(cat "$T/stderr10")"
grep -q '^curl proxy=0 ' "$R/calls.log" && grep -q '^curl proxy=1 ' "$R/calls.log" \
	&& ok "auto fallback retries with proxy argument" || bad "auto fallback retries with proxy argument"

# A subscription shrinking from four nodes to one is still applied and warned.
make_root "$T/root8"
write_config
for n in 1 2 3 4; do
	printf "\nconfig node 'n_%032x'\n\toption source 's_00000001'\n\toption label 'old-%d'\n\toption protocol 'vless'\n\toption address 'old-%d.example.com'\n\toption port '443'\n\toption uuid '11111111-2222-4333-8444-55555555555%d'\n\toption transport 'ws'\n\toption security 'tls'\n" "$n" "$n" "$n" "$n" "$n" >> "$R/etc/config/aetherproxy"
done
BODY="$FIX/one-node.txt"
out=$(ap --json s_00000001 2>"$T/stderr11"); rc=$?
expect "shrunk subscription is applied" 0 "$rc"
has_line "$R/var/run/aether-proxy/events.jsonl" '"code": "SUB_SHRANK"' \
	&& ok "shrunk subscription emits SUB_SHRANK" || bad "shrunk subscription emits SUB_SHRANK"

# Per-subscription isolation keeps one successful update when the next subscription fails.
make_root "$T/root9"
write_config
export STUB_CURL_FAIL_URL=sub-b
out=$(ap --json 2>"$T/stderr12"); rc=$?
unset STUB_CURL_FAIL_URL
expect "partial multi-subscription update exits nonzero" 1 "$rc"
expect "first subscription succeeds independently" true "$(printf '%s\n' "$out" | jget subs.s_00000001.ok)"
expect "second subscription failure is isolated" SUB_FETCH_FAILED "$(printf '%s\n' "$out" | jget subs.s_00000002.code)"
grep -q "option source 's_00000001'" "$R/etc/config/aetherproxy" \
	&& ! grep -q "option source 's_00000002'" "$R/etc/config/aetherproxy" \
	&& ok "successful subscription persists despite peer failure" || bad "successful subscription persists despite peer failure"
out=$(ap --json s_ffffffff 2>"$T/stderr13"); rc=$?
expect "unknown subscription exits with usage status" 2 "$rc"
expect "unknown subscription reports USAGE" USAGE "$(printf '%s\n' "$out" | jget code)"

# A held subscription lock returns BUSY without invoking curl.
make_root "$T/root10"
write_config
if command -v flock >/dev/null 2>&1; then
	flock "$R/var/lock/aether-proxy-sub.lock" sleep 3 >/dev/null 2>&1 & lock_pid=$!
	sleep 0.1
	out=$(ap --json s_00000001 2>"$T/stderr14"); rc=$?
	expect "held lock exits with busy status" 3 "$rc"
	expect "held lock reports BUSY" BUSY "$(printf '%s\n' "$out" | jget code)"
	! grep -q '^curl ' "$R/calls.log" && ok "busy lock prevents download" || bad "busy lock prevents download"
	if wait "$lock_pid"; then ok "lock holder exits cleanly"; else bad "lock holder exits cleanly"; fi
else
	echo 'SKIP lock contention (flock is unavailable on this host)'
fi

# A LuCI-style delta in the isolated UCI savedir must not be merged into the live config.
make_root "$T/root12"
write_config
delta="$R/var/run/aether-proxy/sub-work/.delta"
mkdir -p "$delta"
tests/host/ucode -e 'import * as uci from "uci"; let c=uci.cursor(ARGV[0], ARGV[1]); if (!c.set("aetherproxy", "main", "mode", "global") || !c.save("aetherproxy")) die(c.error() ?? "cannot save test delta");' -- "$R/etc/config" "$delta"
[ -s "$delta/aetherproxy" ] && ok "uncommitted package delta is staged in isolated savedir" || bad "uncommitted package delta is staged in isolated savedir"
out=$(ap --json s_00000001 2>"$T/stderr16"); rc=$?
expect "isolated delta scenario exits successfully" 0 "$rc"
has_line "$R/etc/config/aetherproxy" "option mode 'gfw'" \
	&& ok "live package delta is not committed" || bad "live package delta is not committed"
[ -s "$delta/aetherproxy" ] && ok "uncommitted delta remains available" || bad "uncommitted delta remains available"

# The curl replacement simulates a concurrent writer between snapshot and atomic replace.
make_root "$T/root11"
write_config
cp "$R/etc/config/aetherproxy" "$T/concurrent.config"
printf '# concurrent committed edit\n' >> "$T/concurrent.config"
export STUB_CURL_REPLACE_CONFIG="$T/concurrent.config"
out=$(ap --json s_00000001 2>"$T/stderr15"); rc=$?
unset STUB_CURL_REPLACE_CONFIG
expect "concurrent config edit exits nonzero" 1 "$rc"
expect "concurrent config edit reports SUB_APPLY_INVALID" SUB_APPLY_INVALID "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
cmp -s "$T/concurrent.config" "$R/etc/config/aetherproxy" \
	&& ok "concurrent writer content is preserved" || bad "concurrent writer content is preserved"

# Do not touch the host's /tmp/.uci: the hermetic package-delta equivalent above uses the
# temporary sysroot; the real global-delta case is skipped by the worktree-only policy.
echo 'SKIP real /tmp/.uci/aetherproxy delta case (global UCI state is outside this worktree)'

# State and structured events have the documented per-subscription shape.
R="$T/root1"
state="$R/etc/aether-proxy/state/sub.json"
[ -s "$state" ] && ok "sub.json is written" || bad "sub.json is written"
expect "sub.json stores last_attempt" true "$("$UCODE" -e "import * as fs from 'fs'; let o=json(fs.readfile(ARGV[0])); print(type(o.s_00000001.last_attempt)=='int');" "$state")"
expect "sub.json stores last_ok" true "$("$UCODE" -e "import * as fs from 'fs'; let o=json(fs.readfile(ARGV[0])); print(type(o.s_00000001.last_ok)=='int');" "$state")"
expect "sub.json stores node count" 1 "$(jget s_00000001.nodes < "$state")"
has_line "$R/var/run/aether-proxy/events.jsonl" '"code": "SUB_UPDATED"' \
	&& ok "successful update emits SUB_UPDATED" || bad "successful update emits SUB_UPDATED"

echo "sub: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
