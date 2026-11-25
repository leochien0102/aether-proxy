#!/usr/bin/env bash
# Subscription atomic updates and effective download settings (docs/06, docs/05).
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
	cp "$STUBS/curl" "$T/bin/curl-body"
	cp "$ROOT/tests/sub/curl-record.sh" "$T/bin/curl"
	cp "$STUBS/xray" "$T/bin/xray"
	chmod +x "$T/bin/curl" "$T/bin/curl-body" "$T/bin/xray"
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
if ! has_line "$R/etc/config/aetherproxy" 'failover_nodes'; then
	ok 'T16.21 first subscription import without a previous selection does not join roster'
else
	bad 'T16.21 first subscription import without a previous selection does not join roster'
fi
if cmp -s "$R/etc/config/aetherproxy" "$R/etc/aether-proxy/config.backup" &&
	[ "$(stat -c %a "$R/etc/aether-proxy/config.backup")" = 600 ]; then
	ok 'T10.70 subscription success updates private validated backup'
else
	bad 'T10.70 subscription success updates private validated backup'
fi
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

# libuci always reads the real /tmp/.uci, whatever savedir is set (06 step 3), so the LuCI
# case can only be shown there. Runs only when no such delta exists; the file is removed after.
if [ -e /tmp/.uci/aetherproxy ]; then
	echo 'SKIP real /tmp/.uci/aetherproxy delta case (a delta already exists on this host)'
else
	make_root "$T/root-luci"; write_config; BODY="$FIX/one-node.txt"
	made_dir=0; [ -d /tmp/.uci ] || { mkdir -p /tmp/.uci && made_dir=1; }
	printf "aetherproxy.main.mode='global'\n" > /tmp/.uci/aetherproxy
	ap s_00000001 >/dev/null 2>"$T/luci.err"; rc=$?
	luci_mode=$(sed -n "s/^[[:space:]]*option mode '\(.*\)'/\1/p" "$R/etc/config/aetherproxy")
	luci_delta=$(cat /tmp/.uci/aetherproxy)
	rm -f /tmp/.uci/aetherproxy; [ "$made_dir" = 1 ] && rmdir /tmp/.uci
	expect "real LuCI delta scenario exits successfully" 0 "$rc"
	expect "real LuCI delta is not committed" gfw "$luci_mode"
	expect "real LuCI delta stays pending" "aetherproxy.main.mode='global'" "$luci_delta"
fi

# A corrupt sub.json is only a status record: logged, replaced, and the update proceeds.
make_root "$T/root-corrupt"; write_config; BODY="$FIX/one-node.txt"
printf '{broken' > "$R/etc/aether-proxy/state/sub.json"
ap s_00000001 >/dev/null 2>"$T/corrupt.err"; rc=$?
expect "corrupt sub.json does not block the update" 0 "$rc"
"$UCODE" -l fs -e "let v = json(fs.readfile('$R/etc/aether-proxy/state/sub.json')); exit(type(v) == 'object' && v.s_00000001 ? 0 : 1);" 2>>"$T/corrupt.err" \
	&& ok "corrupt sub.json is rewritten as a valid record" || bad "corrupt sub.json is rewritten as a valid record" "$(cat "$T/corrupt.err")"

# Disabled subscriptions: skipped and left out of the result; named explicitly -> disabled, no download.
make_root "$T/root-disabled"; write_config; BODY="$FIX/one-node.txt"
sed -i "/config subscription 's_00000002'/,/^$/ s/option enabled '1'/option enabled '0'/" "$R/etc/config/aetherproxy"
out=$(ap --json 2>/dev/null); rc=$?
echo "$out" | grep -q '"s_00000002"' && bad "disabled subscription is left out of the result" "$out" || ok "disabled subscription is left out of the result"
: > "$R/calls.log"
out=$(ap s_00000002 --json 2>/dev/null); rc=$?
expect "named disabled subscription exits successfully" 0 "$rc"
echo "$out" | grep -q '"disabled": true' && ok "named disabled subscription is reported as disabled" || bad "named disabled subscription is reported as disabled" "$out"
! grep -q '^curl ' "$R/calls.log" && ok "named disabled subscription is not downloaded" || bad "named disabled subscription is not downloaded"

# T9.14: normalized bools and URI UCI strings must compare equal on repeat updates.
make_root "$T/root-grpc-multi"
write_config
BODY="$FIX/grpc-multi.txt"
out=$(ap --json s_00000001 2>"$T/grpc-multi-first.err"); rc=$?
expect "grpc multi initial subscription import exits successfully" 0 "$rc"
has_line "$R/etc/config/aetherproxy" "option grpc_multi_mode '1'" \
	&& ok "grpc multi subscription writes UCI bool" || bad "grpc multi subscription writes UCI bool"
has_line "$R/etc/config/aetherproxy" "option ech_config_list 'opaque-ech'" \
	&& ok "grpc multi subscription writes ECH" || bad "grpc multi subscription writes ECH"
cp "$R/etc/config/aetherproxy" "$T/grpc-multi.before"
out=$(ap --json s_00000001 2>"$T/grpc-multi-repeat.err"); rc=$?
expect "grpc multi repeat subscription exits successfully" 0 "$rc"
expect "grpc multi repeat subscription reports zero updated nodes" 0 \
	"$(printf '%s\n' "$out" | jget subs.s_00000001.updated)"
cmp -s "$T/grpc-multi.before" "$R/etc/config/aetherproxy" \
	&& ok "grpc multi repeat subscription preserves exact UCI bytes" \
	|| bad "grpc multi repeat subscription preserves exact UCI bytes"

# T9.14: removal must survive the real staging/commit path, not only the pure plan.
make_root "$T/root-node-fields"
init_current_config
cat >> "$R/etc/config/aetherproxy" <<'EOF'
	option ech_config_list 'opaque-ech'
	option reality_pqv 'opaque-pqv'
	option grpc_multi_mode '1'
	option ws_heartbeat '30'
	option xhttp_extra '{}'
	option mux '1'
	option mux_concurrency '8'
	option mux_xudp_concurrency '16'
	option mux_xudp_udp443 'allow'
	option tcp_fast_open '1'
	option tcp_mptcp '1'
EOF
BODY="$FIX/one-node.txt"
out=$(ap --json s_00000001 2>"$T/node-fields.err"); rc=$?
expect "node extensions removal update exits successfully" 0 "$rc"
expect "node extensions removal counts an updated node" 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.updated)"
"$UCODE" -e '
import * as uci from "uci";
let c = uci.cursor(ARGV[0], ARGV[0] + "/../uci-save");
let names = [];
c.foreach("aetherproxy", "node", n => { push(names, n[".name"]); });
let id = "n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
let fields = [ "ech_config_list", "reality_pqv", "grpc_multi_mode", "ws_heartbeat", "xhttp_extra",
    "mux", "mux_concurrency", "mux_xudp_concurrency", "mux_xudp_udp443", "tcp_fast_open", "tcp_mptcp" ];
let old = c.get_all("aetherproxy", id);
exit(length(names) == 1 && names[0] == id && old != null
    && !length(filter(fields, k => old[k] != null)) ? 0 : 1);
' -- "$R/etc/config" 2>>"$T/node-fields.err" \
	&& ok "subscription deletes all absent extensions including ECH and keeps node ID" \
	|| bad "subscription deletes all absent extensions including ECH and keeps node ID"

# State and structured events have the documented per-subscription shape.
R="$T/root1"
state="$R/etc/aether-proxy/state/sub.json"
[ -s "$state" ] && ok "sub.json is written" || bad "sub.json is written"
expect "sub.json stores last_attempt" true "$("$UCODE" -e "import * as fs from 'fs'; let o=json(fs.readfile(ARGV[0])); print(type(o.s_00000001.last_attempt)=='int');" "$state")"
expect "sub.json stores last_ok" true "$("$UCODE" -e "import * as fs from 'fs'; let o=json(fs.readfile(ARGV[0])); print(type(o.s_00000001.last_ok)=='int');" "$state")"
expect "sub.json stores node count" 1 "$(jget s_00000001.nodes < "$state")"
has_line "$R/var/run/aether-proxy/events.jsonl" '"code": "SUB_UPDATED"' \
	&& ok "successful update emits SUB_UPDATED" || bad "successful update emits SUB_UPDATED"

# T9.17: check exact curl argv from the committed-package read path, not just normalization.
assert_fetch_args() {
	local label="$1" ua="$2" proxies="$3" calls="$4" i ua_count=0 proxy_count=0 valid=1
	local -a args=()
	if [ ! -f "$R/curl-argv.log" ]; then bad "$label" 'no curl argv recorded'; return; fi
	mapfile -t args < "$R/curl-argv.log"
	for ((i=0; i<${#args[@]}; i++)); do
		case "${args[i]}" in
		-A)
			ua_count=$((ua_count + 1))
			[ "${args[i+1]:-}" = "$ua" ] || valid=0 ;;
		-x)
			proxy_count=$((proxy_count + 1))
			[ "${args[i+1]:-}" = 'http://127.0.0.1:31081' ] || valid=0 ;;
		esac
	done
	if [ "$valid" = 1 ] && [ "$ua_count" = "$calls" ] && [ "$proxy_count" = "$proxies" ]; then
		ok "$label"
	else
		bad "$label" "UA count=$ua_count proxy count=$proxy_count valid=$valid"
	fi
}

for mode in direct proxy auto; do
	make_root "$T/root-defaults-$mode"
	cp "$ROOT/tests/fixtures/t917-sub-defaults/aetherproxy" "$R/etc/config/aetherproxy"
	# The listener is available even in the direct case, so absence of -x is meaningful.
	printf '{"state":"running"}\n' > "$R/var/run/aether-proxy/state.json"
	printf '0: 0100007F:7969 00000000:0000 0A\n' >> "$R/proc/net/tcp"
	"$UCODE" -e 'import * as uci from "uci";
		let c = uci.cursor(ARGV[0], ARGV[0] + "/../uci-save");
		if (!c.set("aetherproxy", "sub", "fetch_via", ARGV[1]) || !c.commit("aetherproxy"))
			die(c.error() ?? "cannot set common fetch mode");' -- "$R/etc/config" "$mode"
	BODY="$FIX/one-node.txt"
	if [ "$mode" = auto ]; then export STUB_CURL_DIRECT_RC=22; fi
	out=$(ap s_00000001 --json 2>"$T/defaults-$mode.stderr"); rc=$?
	unset STUB_CURL_DIRECT_RC
	expect "T9.17 inherited $mode download succeeds" 0 "$rc"
	case "$mode" in
	direct) assert_fetch_args 'T9.17 inherited direct uses common UA without proxy' x 0 1 ;;
	proxy) assert_fetch_args 'T9.17 inherited proxy uses common UA and current-node proxy' x 1 1 ;;
	auto) assert_fetch_args 'T9.17 inherited auto retries with common UA through proxy' x 1 2 ;;
	esac
	if [ "$mode" = proxy ]; then
		: > "$R/curl-argv.log"
		# s_00000003 explicitly retained auto/UA/24 before this feature. They must win.
		out=$(ap s_00000003 --json 2>"$T/defaults-override.stderr"); rc=$?
		expect 'T9.17 explicit download override succeeds' 0 "$rc"
		assert_fetch_args 'T9.17 explicit UA and auto override common proxy' 'legacy UA' 0 1
	fi
done

make_root "$T/root-defaults-packaged"
cp "$ROOT/aether-proxy/files/aether-proxy.config" "$R/etc/config/aetherproxy"
if "$UCODE" -e 'import * as uci from "uci";
	import * as config from "aetherproxy.config";
	import * as C from "aetherproxy.const";
	let c = uci.cursor(ARGV[0], ARGV[0] + "/../uci-save");
	let raw = config.read_raw(c, C.UCI_PACKAGE);
	let r = config.load(c);
	let s = r.snapshot?.sub;
	exit(raw.sub != null && r.ok && s.user_agent == C.PROG + "/" + C.VERSION
		&& s.fetch_via == "auto" && s.interval_hours == 24 ? 0 : 1);' -- "$R/etc/config"; then
	ok 'T9.17 packaged sub defaults include the running version UA'
else
	bad 'T9.17 packaged sub defaults include the running version UA'
fi

for field in interval_hours fetch_via; do
	make_root "$T/root-defaults-invalid-$field"
	cp "$ROOT/tests/fixtures/t917-sub-defaults/aetherproxy" "$R/etc/config/aetherproxy"
	if [ "$field" = interval_hours ]; then value=-1; else value=foo; fi
	"$UCODE" -e 'import * as uci from "uci";
		let c = uci.cursor(ARGV[0], ARGV[0] + "/../uci-save");
		if (!c.set("aetherproxy", "sub", ARGV[1], ARGV[2]) || !c.commit("aetherproxy"))
			die(c.error() ?? "cannot set invalid common value");' -- "$R/etc/config" "$field" "$value"
	out=$(ap s_00000001 --json 2>"$T/defaults-invalid.stderr"); rc=$?
	expect "T9.17 invalid sub.$field exits CONFIG_INVALID" 2 "$rc"
	expect "T9.17 invalid sub.$field reports CONFIG_INVALID" CONFIG_INVALID "$(printf '%s\n' "$out" | jget code)"
	grep -Fq -- "\"field\": \"sub.$field\"" "$R/var/run/aether-proxy/events.jsonl" \
		&& ok "T9.17 invalid sub.$field event has correct field" \
		|| bad "T9.17 invalid sub.$field event has correct field"
	[ ! -f "$R/curl-argv.log" ] && ok "T9.17 invalid sub.$field prevents download" \
		|| bad "T9.17 invalid sub.$field prevents download"
done

# T9.18: exercise CLI rejection and a mixed subscription through the atomic write path.
python3 "$ROOT/tests/sub/flow.py" "$ROOT" "$T/flow-cli" \
	&& ok 'T9.18 flow CLI scenarios' || bad 'T9.18 flow CLI scenarios'
make_root "$T/root-flow"
write_config
BODY="$FIX/flow.txt"
out=$(ap --json s_00000001 2>"$T/flow.stderr"); rc=$?
expect 'T9.18 mixed flow subscription succeeds' 0 "$rc"
expect 'T9.18 mixed flow subscription adds exactly three valid nodes' 3 \
	"$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
expect 'T9.18 mixed flow subscription counts two invalid_value skips' 2 \
	"$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.invalid_value)"
"$UCODE" -e '
import * as uci from "uci";
let c = uci.cursor(ARGV[0], ARGV[0] + "/../uci-save");
let nodes = [];
c.foreach("aetherproxy", "node", n => { push(nodes, n); });
let actual = sort(map(nodes, n => n.address + ":" + (n.flow ?? "")));
let expected = [ "empty.example:", "udp443.example:xtls-rprx-vision-udp443",
	"vision.example:xtls-rprx-vision" ];
exit(sprintf("%.J", actual) == sprintf("%.J", expected) ? 0 : 1);
' -- "$R/etc/config" 2>>"$T/flow.stderr" \
	&& ok 'T9.18 subscription commits only valid flows unchanged' \
	|| bad 'T9.18 subscription commits only valid flows unchanged'
expect 'T9.18 sub.json stores three valid nodes' 3 \
	"$(jget s_00000001.nodes < "$R/etc/aether-proxy/state/sub.json")"
expect 'T9.18 sub.json stores two invalid_value skips' 2 \
	"$(jget s_00000001.skipped.invalid_value < "$R/etc/aether-proxy/state/sub.json")"

# T9.42 (security F1): a line that decodes as Base64 but not as a JSON object is
# one skip reason. It must not end the update: the remaining lines, the other
# enabled subscription and the sub.json status record are still processed.
make_root "$T/root-badvmess"
write_config
BODY="$FIX/bad-vmess.txt"
export STUB_CURL_BODY_ALT="$FIX/one-node.txt"
out=$(ap --json 2>"$T/badvmess.stderr"); rc=$?
unset STUB_CURL_BODY_ALT
expect 'T9.42 non-JSON vmess line exits successfully' 0 "$rc"
expect 'T9.42 the mixed subscription is applied' true "$(printf '%s\n' "$out" | jget subs.s_00000001.ok)"
expect 'T9.42 the valid line after the bad one is imported' 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
expect 'T9.42 the bad line is counted as malformed' 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.malformed)"
expect 'T9.42 the second subscription is still processed' true "$(printf '%s\n' "$out" | jget subs.s_00000002.ok)"
expect 'T9.42 both subscriptions were downloaded' 2 "$(grep -c '^curl ' "$R/calls.log" 2>/dev/null || echo 0)"
has_line "$R/etc/config/aetherproxy" "option address 'mixed.example.com'" \
	&& ok 'T9.42 the surviving node is committed' || bad 'T9.42 the surviving node is committed'
[ -s "$R/etc/aether-proxy/state/sub.json" ] && ok 'T9.42 sub.json is written' || bad 'T9.42 sub.json is written'
expect 'T9.42 sub.json records the malformed skip' 1 \
	"$(jget s_00000001.skipped.malformed < "$R/etc/aether-proxy/state/sub.json")"
[ ! -s "$T/badvmess.stderr" ] && ok 'T9.42 no exception escapes to stderr' \
	|| bad 'T9.42 no exception escapes to stderr' "$(cat "$T/badvmess.stderr")"

# A corrupt state.json is not an update failure: proxy_running() only needs
# "not running", and an exception here used to abort the whole update (T9.42).
make_root "$T/root-corrupt-state"
write_config
# auto reads proxy_running(); direct would never touch state.json.
sed -i "s/fetch_via 'direct'/fetch_via 'auto'/" "$R/etc/config/aetherproxy"
printf '{broken' > "$R/var/run/aether-proxy/state.json"
BODY="$FIX/one-node.txt"
out=$(ap --json s_00000001 2>"$T/corrupt-state.stderr"); rc=$?
expect 'T9.42 corrupt state.json does not abort the update' 0 "$rc"
expect 'T9.42 corrupt state.json still imports the node' 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
[ ! -s "$T/corrupt-state.stderr" ] && ok 'T9.42 corrupt state.json leaves no exception' \
	|| bad 'T9.42 corrupt state.json leaves no exception' "$(cat "$T/corrupt-state.stderr")"

# T11.11: new protocols must survive the full atomic subscription write path.
make_root "$T/root-new-uri"
write_config
BODY="$FIX/new-protocols.txt"
out=$(ap --json s_00000001 2>"$T/new-uri.stderr"); rc=$?
expect 'T11.11 mixed new protocol subscription succeeds' 0 "$rc"
expect 'T11.11 imports all seven new protocol nodes' 7 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
for reason in missing_field invalid_value malformed; do
	want=1; [ "$reason" = malformed ] && want=2
	expect "T11.11 counts $reason" "$want" "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.$reason)"
done
"$UCODE" -e 'import * as uci from "uci";
let c = uci.cursor(ARGV[0]); let nodes = [];
c.foreach("aetherproxy", "node", n => { push(nodes, n); });
let wg = filter(nodes, n => n.protocol == "wireguard")[0];
let hy = filter(nodes, n => n.label == "HY")[0];
let socks = filter(nodes, n => n.label == "SOCKS")[0];
let noauth = filter(nodes, n => n.label == "HTTP-noauth")[0];
exit(length(nodes) == 7 && wg?.keepalive == "0" && length(wg?.local_address) == 2
	&& wg?.preshared_key == "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
	&& hy?.hysteria_auth == "HY_SECRET+token" && hy?.sni == "sni.example"
	&& socks?.username == "User" && socks?.password == "SOCKS_SECRET"
	&& noauth?.username == null && noauth?.password == null ? 0 : 1);' -- "$R/etc/config" \
	&& ok 'T11.11 persists all protocol fields and no-auth omission' \
	|| bad 'T11.11 persists all protocol fields and no-auth omission'
expect 'T11.11 sub status records seven nodes' 7 "$(jget s_00000001.nodes < "$R/etc/aether-proxy/state/sub.json")"
has_line "$R/var/run/aether-proxy/events.jsonl" NODE_INSECURE_IGNORED \
	&& ok 'T11.11 insecure flag emits warning event' || bad 'T11.11 insecure flag emits warning event'
if printf '%s\n' "$out" | grep -Eq 'SECRET|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE' \
	|| grep -ERq 'SECRET|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE' \
		"$R/var/run/aether-proxy/events.jsonl" "$T/new-uri.stderr" "$R/calls.log"; then
	bad 'T11.11 credentials absent from output logs events and errors'
else
	ok 'T11.11 credentials absent from output logs events and errors'
fi
out=$(ap --json s_00000001 2>"$T/new-uri-repeat.stderr"); rc=$?
expect 'T11.11 identical second update succeeds' 0 "$rc"
expect 'T11.11 identical second update adds nothing' 0 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
expect 'T11.11 identical second update changes nothing' 0 "$(printf '%s\n' "$out" | jget subs.s_00000001.updated)"

# T16.21 uses the real host UCI CLI and preserves exports with KEEP_TMP=1.
u() {
	LD_LIBRARY_PATH="$ROOT/tests/host/prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$ROOT/tests/host/prefix/bin/uci" -q -c "$R/etc/config" -C "$R/tmp/uci-override" -P "$R/tmp/uci-delta" "$@"
}
export_case() { u export aetherproxy > "$T/failover-$1.uci"; }
roster() { u get aetherproxy.main.failover_nodes; }
write_uci() {
	local body="$1"; shift
	"$UCODE" -e "
import { cursor } from 'uci';
let c = cursor(shift(ARGV), shift(ARGV));
let p = 'aetherproxy';
$body
if (!c.commit(p)) die(c.error());" -- "$R/etc/config" "$R/tmp/uci-delta" "$@"
}
set_roster() {
	write_uci 'if (!c.set(p, "main", "failover_nodes", ARGV)) die(c.error());' "$@"
}
find_id() {
	u show aetherproxy | awk -F '[.=]' -v host="'$1'" '$3 == "address" && substr($0, index($0, "=") + 1) == host { print $2 }'
}

make_root "$T/root-failover"
init_current_config
old=n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
missing=n_ffffffffffffffffffffffffffffffff
base_uri="$(<"$FIX/one-node.txt")"
extra_uri='vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@extra.example.com:443?security=tls#Extra'
third_uri='vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@third.example.com:443?security=tls#Third'
printf '%s\n%s\n' "$base_uri" "$extra_uri" > "$T/failover-two.txt"
printf '%s\n%s\n%s\n' "$base_uri" "$extra_uri" "$third_uri" > "$T/failover-three.txt"
printf '%s\n%s\n' "$base_uri" "$third_uri" > "$T/failover-replacement.txt"
set_roster "$old" "$missing" "$old"
BODY="$T/failover-two.txt"
export_case add-before
out=$(ap --json s_00000001 2>"$T/failover-add.stderr"); rc=$?
expect 'T16.21 full selection refresh succeeds with global switch off' 0 "$rc"
extra=$(find_id extra.example.com)
[ -n "$extra" ] && ok 'T16.21 refresh creates extra node' || bad 'T16.21 refresh creates extra node'
expect 'T16.21 full selection prunes unknown and duplicate IDs then appends new ID' "$old $extra" "$(roster)"
export_case add-after

cp "$R/etc/config/aetherproxy" "$T/failover-unchanged.conf"
stamp_before=$(stat -c '%i %y' "$R/etc/config/aetherproxy")
out=$(ap --json s_00000001 2>"$T/failover-unchanged.stderr"); rc=$?
expect 'T16.21 no-op roster refresh succeeds' 0 "$rc"
expect 'T16.21 no-op refresh does not replace live UCI file' "$stamp_before" "$(stat -c '%i %y' "$R/etc/config/aetherproxy")"
cmp -s "$T/failover-unchanged.conf" "$R/etc/config/aetherproxy" \
	&& ok 'T16.21 no-op refresh preserves UCI bytes' || bad 'T16.21 no-op refresh preserves UCI bytes'

set_roster "$old"
BODY="$T/failover-three.txt"
out=$(ap --json s_00000001 2>"$T/failover-partial.stderr"); rc=$?
expect 'T16.21 partial selection refresh succeeds' 0 "$rc"
third=$(find_id third.example.com)
[ -n "$third" ] && ok 'T16.21 partial selection still adds node' || bad 'T16.21 partial selection still adds node'
expect 'T16.21 partial selection does not extend' "$old" "$(roster)"

set_roster "$extra" "$old" "$third"
BODY="$T/failover-two.txt"
export_case remove-before
out=$(ap --json s_00000001 2>"$T/failover-remove.stderr"); rc=$?
expect 'T16.21 pure reduction refresh succeeds' 0 "$rc"
expect 'T16.21 pure reduction deletes node' '' "$(find_id third.example.com)"
expect 'T16.21 pure reduction retains survivor order' "$extra $old" "$(roster)"
export_case remove-after

BODY="$T/failover-replacement.txt"
out=$(ap --json s_00000001 2>"$T/failover-replacement.stderr"); rc=$?
expect 'T16.21 replacement refresh succeeds' 0 "$rc"
expect 'T16.21 replacement removes old node' '' "$(find_id extra.example.com)"
third=$(find_id third.example.com)
[ -n "$third" ] && ok 'T16.21 replacement adds node' || bad 'T16.21 replacement adds node'
expect 'T16.21 replacement appends new ID after removing old ID' "$old $third" "$(roster)"

printf '%s\n%s\n' "${base_uri//edge.example.com/edge-moved.example.com}" "$third_uri" > "$T/failover-moved.txt"
BODY="$T/failover-moved.txt"
out=$(ap --json s_00000001 2>"$T/failover-moved.stderr"); rc=$?
expect 'T16.21 address change refresh succeeds' 0 "$rc"
expect 'T16.21 address change matches original ID' "$old" "$(find_id edge-moved.example.com)"
expect 'T16.21 address change preserves roster' "$old $third" "$(roster)"

BODY="$FIX/one-node.txt"
cp "$R/etc/config/aetherproxy" "$T/failover-rejected.conf"
out=$(STUB_XRAY_TEST_RC=1 ap --json s_00000001 2>"$T/failover-rejected.stderr"); rc=$?
expect 'T16.21 invalid rendered update fails' 1 "$rc"
cmp -s "$T/failover-rejected.conf" "$R/etc/config/aetherproxy" \
	&& ok 'T16.21 rejected staged update publishes neither node nor roster changes' \
	|| bad 'T16.21 rejected staged update publishes neither node nor roster changes'

# Delete the last subscription through UCI; leave one owned node to exercise orphan cleanup.
export_case delete-sub-baseline
write_uci '
if (!c.set(p, "main", "enabled", "0") || !c.delete(p, "main", "node") ||
    !c.delete(p, ARGV[0]) || !c.delete(p, "s_00000001")) die(c.error());' "$third"
export_case delete-sub-before
out=$(ap --json 2>"$T/failover-delete-sub.stderr"); rc=$?
expect 'T16.21 update-all after last subscription deletion succeeds' 0 "$rc"
expect 'T16.21 last subscription removal clears missing and orphaned IDs' '' "$(roster)"
export_case delete-sub-after

make_root "$T/root-failover-import"
write_config
import_uri() {
	"$UCODE" -S "$ENTRY" -- node import "$1" --json \
		--sys-root "$R" --confdir "$R/etc/config" --run-dir "$R/var/run/aether-proxy"
}
out=$(import_uri "$base_uri" 2>"$T/failover-import-off.stderr"); rc=$?
expect 'T16.21 manual import with global switch off succeeds' 0 "$rc"
expect 'T16.21 manual import with global switch off leaves roster absent' '' "$(roster)"
write_uci 'if (!c.set(p, "sub", "sub") || !c.set(p, "sub", "failover", "1")) die(c.error());'
out=$(import_uri "$extra_uri" 2>"$T/failover-import-on.stderr"); rc=$?
expect 'T16.21 manual import with global switch on succeeds' 0 "$rc"
manual=$(printf '%s\n' "$out" | jget node)
expect 'T16.21 manual import with global switch on joins roster' "$manual" "$(roster)"
out=$(import_uri "$extra_uri" 2>"$T/failover-import-duplicate.stderr"); rc=$?
expect 'T16.21 duplicate import succeeds' 0 "$rc"
expect 'T16.21 duplicate import is recognized' true "$(printf '%s\n' "$out" | jget duplicate)"
expect 'T16.21 duplicate import does not repeat entry' "$manual" "$(roster)"

# T16.85: subscription candidate limit (1024 allowed, 1025 fails without touching UCI).
make_root "$T/root-t1685"
cat > "$R/etc/config/aetherproxy" <<'EOF'
config global 'main'
	option enabled '1'
	option mode 'gfw'
	option node 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	list failover_nodes 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	list failover_nodes 'n_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

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

config node 'n_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
	option label 'Edge Two'
	option source 's_00000001'
	option protocol 'vless'
	option address 'edge2.example.com'
	option port '443'
	option uuid '22222222-2222-4333-8444-555555555555'
	option transport 'ws'
	option security 'tls'
	option encryption 'none'
	option sni 'edge2.example.com'
	option path '/ws'
	option host 'cdn2.example.com'
EOF
printf '{"s_00000001":{"last_attempt":1000,"last_ok":1000,"nodes":2,"skipped":{},"error":null}}\n' > "$R/etc/aether-proxy/state/sub.json"
printf '{"state":"running"}\n' > "$R/var/run/aether-proxy/state.json"

python3 - "$T/t1685-1025-plain.txt" "$T/t1685-1025-b64.txt" "$T/t1685-1024-valid.txt" <<'PY'
import base64, sys
plain_1025, b64_1025, valid_1024 = sys.argv[1:4]
lines = [
    f"trojan://secret-pass-t1685-{i}@limit-{i}.example:443#secret-label-t1685-{i}"
    for i in range(1, 1026)
]
body_1025 = "\n".join(lines) + "\n"
with open(plain_1025, "w", encoding="utf-8") as f:
    f.write(body_1025)
with open(b64_1025, "w", encoding="utf-8") as f:
    f.write(base64.b64encode(body_1025.encode("utf-8")).decode("ascii") + "\n")
valid_lines = [
    "vless://11111111-2222-4333-8444-555555555555@edge.example.com:443?type=ws&security=tls&sni=edge.example.com&path=%2Fws&host=cdn.example.com#Edge%20One",
    "vless://33333333-2222-4333-8444-555555555555@edge3.example.com:443?type=ws&security=tls&sni=edge3.example.com&path=%2Fws&host=cdn3.example.com#Edge%20Three",
]
valid_lines.extend([valid_lines[1]] * 1022)
with open(valid_1024, "w", encoding="utf-8") as f:
    f.write("\n".join(valid_lines) + "\n")
PY

cp "$R/etc/config/aetherproxy" "$T/t1685.before"
BODY="$T/t1685-1025-plain.txt"
out_human=$(ap s_00000001 2>&1); rc=$?
expect 'T16.85 1025-node plaintext update exits nonzero' 1 "$rc"
printf '%s\n' "$out_human" | grep -Fq 'SUB_TOO_MANY_NODES' \
	&& ok 'T16.85 human output reports SUB_TOO_MANY_NODES' \
	|| bad 'T16.85 human output reports SUB_TOO_MANY_NODES' "$out_human"
! printf '%s\n' "$out_human" | grep -Eq 'secret-pass-t1685|secret-label-t1685|limit-[0-9]+\.example' \
	&& ok 'T16.85 human output does not echo raw URI or credentials' \
	|| bad 'T16.85 human output does not echo raw URI or credentials' "$out_human"
cmp -s "$T/t1685.before" "$R/etc/config/aetherproxy" \
	&& ok 'T16.85 1025-node plaintext preserves UCI bytes' \
	|| bad 'T16.85 1025-node plaintext preserves UCI bytes'

out=$(ap --json s_00000001 2>"$T/t1685-json.stderr"); rc=$?
expect 'T16.85 1025-node JSON update exits nonzero' 1 "$rc"
expect 'T16.85 1025-node JSON reports SUB_TOO_MANY_NODES' SUB_TOO_MANY_NODES "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
expect 'T16.85 1025-node JSON adds zero nodes' 0 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
expect 'T16.85 status record records SUB_TOO_MANY_NODES' SUB_TOO_MANY_NODES "$(jget s_00000001.error < "$R/etc/aether-proxy/state/sub.json")"
expect 'T16.85 status record preserves prior last_ok' 1000 "$(jget s_00000001.last_ok < "$R/etc/aether-proxy/state/sub.json")"
expect 'T16.85 status record preserves existing node count' 2 "$(jget s_00000001.nodes < "$R/etc/aether-proxy/state/sub.json")"
has_line "$R/var/run/aether-proxy/events.jsonl" '"code": "SUB_TOO_MANY_NODES"' \
	&& ok 'T16.85 events log records SUB_TOO_MANY_NODES' \
	|| bad 'T16.85 events log records SUB_TOO_MANY_NODES'
! grep -Eq 'secret-pass-t1685|secret-label-t1685|limit-[0-9]+\.example' "$R/var/run/aether-proxy/events.jsonl" "$R/etc/aether-proxy/state/sub.json" \
	&& ok 'T16.85 events and status files never echo raw URI or credentials' \
	|| bad 'T16.85 events and status files never echo raw URI or credentials'
! grep -q '^init reload$' "$R/calls.log" \
	&& ok 'T16.85 rejected over-limit update does not reload daemon' \
	|| bad 'T16.85 rejected over-limit update does not reload daemon'
cmp -s "$T/t1685.before" "$R/etc/config/aetherproxy" \
	&& ok 'T16.85 1025-node JSON preserves UCI bytes, current node, and failover roster' \
	|| bad 'T16.85 1025-node JSON preserves UCI bytes, current node, and failover roster'

BODY="$T/t1685-1025-b64.txt"
out=$(ap --json s_00000001 2>"$T/t1685-b64.stderr"); rc=$?
expect 'T16.85 1025-node Base64 update exits nonzero' 1 "$rc"
expect 'T16.85 1025-node Base64 reports SUB_TOO_MANY_NODES' SUB_TOO_MANY_NODES "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
cmp -s "$T/t1685.before" "$R/etc/config/aetherproxy" \
	&& ok 'T16.85 1025-node Base64 preserves UCI bytes' \
	|| bad 'T16.85 1025-node Base64 preserves UCI bytes'

# Neighboring valid subscription still publishes while s_00000001 fails with SUB_TOO_MANY_NODES.
BODY="$T/t1685-1025-plain.txt"
STUB_CURL_BODY_ALT="$FIX/one-node.txt"
out=$(ap --json 2>"$T/t1685-multi.stderr"); rc=$?
unset STUB_CURL_BODY_ALT
expect 'T16.85 multi-sub with one over-limit exits nonzero' 1 "$rc"
expect 'T16.85 over-limit subscription fails cleanly' SUB_TOO_MANY_NODES "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
expect 'T16.85 neighboring valid subscription succeeds' true "$(printf '%s\n' "$out" | jget subs.s_00000002.ok)"
expect 'T16.85 neighboring valid subscription adds its node' 1 "$(printf '%s\n' "$out" | jget subs.s_00000002.added)"
has_line "$R/etc/config/aetherproxy" "option source 's_00000002'" \
	&& ok 'T16.85 neighboring valid subscription publishes to UCI' \
	|| bad 'T16.85 neighboring valid subscription publishes to UCI'
has_line "$R/etc/config/aetherproxy" "option node 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'" \
	&& expect 'T16.85 existing failover roster stays intact after over-limit failure' 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa n_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$(roster)" \
	|| bad 'T16.85 current node stays intact after over-limit failure'

# Subsequent valid 1024-candidate update on s_00000001 succeeds and publishes.
BODY="$T/t1685-1024-valid.txt"
out=$(ap --json s_00000001 2>"$T/t1685-1024.stderr"); rc=$?
expect 'T16.85 valid 1024-candidate update succeeds' 0 "$rc"
expect 'T16.85 valid 1024-candidate update adds deduplicated new node' 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
expect 'T16.85 valid 1024-candidate update deduplicates repeated candidates' 1022 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.duplicate)"
expect 'T16.85 valid update clears error in status record' '<missing>' "$(jget s_00000001.error < "$R/etc/aether-proxy/state/sub.json")"
has_line "$R/etc/config/aetherproxy" "option address 'edge3.example.com'" \
	&& ok 'T16.85 valid 1024-candidate update publishes new node to UCI' \
	|| bad 'T16.85 valid 1024-candidate update publishes new node to UCI'

# ---- T16.86: control-character rejection in subscription import ----
python3 - "$T/t1686-mixed-crlf.txt" "$T/t1686-mixed-b64.txt" "$T/t1686-all-bad.txt" <<'PY'
import base64, sys
mixed_crlf, mixed_b64, all_bad = sys.argv[1:4]
uuid = "11111111-2222-4333-8444-555555555555"
vmess_bad = "vmess://" + base64.b64encode(
    ('{"ps":"t1686-secret-vm\\u0000evil","add":"t1686-bad-vm.example","port":"443",'
     f'"id":"{uuid}","aid":0,"scy":"auto","net":"tcp","tls":"tls"}}').encode()
).decode()
good_line = f"vless://{uuid}@t1686-good.example:443?security=tls#%E4%B8%AD%E6%96%87%20%E8%AE%A2%E9%98%85"
bad_lines = [
    f"vless://{uuid}@t1686-bad-nul.example:443?security=tls#t1686-secret-nul\x00tail",
    "trojan://t1686-secret-pw%0d%0a@t1686-bad-crlf.example:443?security=tls#bad",
    f"vless://{uuid}@t1686-bad-del.example:443?security=tls#del%7ftag",
    vmess_bad,
]
mixed_bytes = ("\r\n".join(bad_lines + [good_line]) + "\r\n").encode("utf-8")
with open(mixed_crlf, "wb") as f:
    f.write(mixed_bytes)
encoded = base64.b64encode(mixed_bytes).decode("ascii")
wrapped = "\r\n".join(encoded[i:i + 64] for i in range(0, len(encoded), 64)) + "\r\n"
with open(mixed_b64, "wb") as f:
    f.write(wrapped.encode("ascii"))
with open(all_bad, "wb") as f:
    f.write(("\r\n".join(bad_lines) + "\r\n").encode("utf-8"))
PY

BODY="$T/t1686-mixed-crlf.txt"
out=$(ap --json s_00000001 2>"$T/t1686-mixed-crlf.stderr"); rc=$?
expect 'T16.86 mixed CRLF subscription succeeds' 0 "$rc"
expect 'T16.86 mixed CRLF skips all 4 control-char lines' 4 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.malformed)"
expect 'T16.86 mixed CRLF publishes adjacent valid node' 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.added)"
has_line "$R/etc/config/aetherproxy" "option address 't1686-good.example'" \
	&& ok 'T16.86 mixed CRLF writes adjacent valid node address' \
	|| bad 'T16.86 mixed CRLF writes adjacent valid node address'
has_line "$R/etc/config/aetherproxy" "option label '中文 订阅'" \
	&& ok 'T16.86 mixed CRLF preserves Chinese+space label' \
	|| bad 'T16.86 mixed CRLF preserves Chinese+space label'
! grep -Eq 't1686-secret|t1686-bad-' "$R/etc/config/aetherproxy" "$R/var/run/aether-proxy/events.jsonl" "$R/etc/aether-proxy/state/sub.json" \
	&& ok 'T16.86 mixed CRLF never writes or leaks bad-node credentials' \
	|| bad 'T16.86 mixed CRLF never writes or leaks bad-node credentials'

BODY="$T/t1686-mixed-b64.txt"
out=$(ap --json s_00000001 2>"$T/t1686-mixed-b64.stderr"); rc=$?
expect 'T16.86 wrapped Base64 mixed subscription succeeds' 0 "$rc"
expect 'T16.86 wrapped Base64 skips all 4 control-char lines' 4 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.malformed)"

cp "$R/etc/config/aetherproxy" "$T/t1686-allbad.before"
: > "$R/calls.log"
BODY="$T/t1686-all-bad.txt"
out=$(ap --json s_00000001 2>"$T/t1686-allbad.stderr"); rc=$?
expect 'T16.86 all-control-char subscription exits nonzero' 1 "$rc"
expect 'T16.86 all-control-char subscription reports SUB_NO_VALID_NODES' SUB_NO_VALID_NODES "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
expect 'T16.86 all-control-char subscription counts all malformed skips' 4 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.malformed)"
cmp -s "$T/t1686-allbad.before" "$R/etc/config/aetherproxy" \
	&& ok 'T16.86 all-control-char subscription preserves UCI bytes' \
	|| bad 'T16.86 all-control-char subscription preserves UCI bytes'
! grep -q '^init reload$' "$R/calls.log" \
	&& ok 'T16.86 all-control-char subscription does not reload daemon' \
	|| bad 'T16.86 all-control-char subscription does not reload daemon'
! printf '%s\n' "$out" | grep -Eq 't1686-secret|t1686-bad-' \
	&& ok 'T16.86 all-control-char output never echoes credentials' \
	|| bad 'T16.86 all-control-char output never echoes credentials'

# T16.86 rework: bare CR at EOF without LF is rejected as node content (not stripped)
# in both plaintext and Base64 subscriptions, while valid preceding lines still publish.
python3 - "$T/t1686-eofcr-only-plain.txt" "$T/t1686-eofcr-only-b64.txt" \
	"$T/t1686-eofcr-mixed-plain.txt" "$T/t1686-eofcr-mixed-b64.txt" <<'PY'
import base64, sys
only_plain, only_b64, mixed_plain, mixed_b64 = sys.argv[1:5]
uuid = "11111111-2222-4333-8444-555555555555"
good = f"vless://{uuid}@t1686-eofcr-good.example:443?security=tls#%E4%B8%AD%E6%96%87%20%E6%AD%A3%E5%B8%B8"
bad_eof_cr = f"vless://{uuid}@t1686-bad-eofcr.example:443?security=tls#t1686-secret-eofcr\r"
only_bytes = bad_eof_cr.encode("utf-8")
mixed_bytes = (good + "\r\n" + bad_eof_cr).encode("utf-8")
for path, data in [
    (only_plain, only_bytes),
    (only_b64, base64.b64encode(only_bytes)),
    (mixed_plain, mixed_bytes),
    (mixed_b64, base64.b64encode(mixed_bytes)),
]:
    with open(path, "wb") as f:
        f.write(data)
PY

cp "$R/etc/config/aetherproxy" "$T/t1686-eofcr.before"
: > "$R/calls.log"
for kind in plain b64; do
	BODY="$T/t1686-eofcr-only-$kind.txt"
	out=$(ap --json s_00000001 2>"$T/t1686-eofcr-only-$kind.stderr"); rc=$?
	expect "T16.86 sole EOF bare CR ($kind) exits nonzero" 1 "$rc"
	expect "T16.86 sole EOF bare CR ($kind) reports SUB_NO_VALID_NODES" SUB_NO_VALID_NODES "$(printf '%s\n' "$out" | jget subs.s_00000001.code)"
	expect "T16.86 sole EOF bare CR ($kind) skips malformed=1" 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.malformed)"
	cmp -s "$T/t1686-eofcr.before" "$R/etc/config/aetherproxy" \
		&& ok "T16.86 sole EOF bare CR ($kind) preserves UCI bytes" \
		|| bad "T16.86 sole EOF bare CR ($kind) preserves UCI bytes"
	! grep -q '^init reload$' "$R/calls.log" \
		&& ok "T16.86 sole EOF bare CR ($kind) does not reload daemon" \
		|| bad "T16.86 sole EOF bare CR ($kind) does not reload daemon"
done

for kind in plain b64; do
	BODY="$T/t1686-eofcr-mixed-$kind.txt"
	out=$(ap --json s_00000001 2>"$T/t1686-eofcr-mixed-$kind.stderr"); rc=$?
	expect "T16.86 valid + EOF bare CR last line ($kind) succeeds" 0 "$rc"
	expect "T16.86 valid + EOF bare CR last line ($kind) skips malformed=1" 1 "$(printf '%s\n' "$out" | jget subs.s_00000001.skipped.malformed)"
	has_line "$R/etc/config/aetherproxy" "option address 't1686-eofcr-good.example'" \
		&& ok "T16.86 valid + EOF bare CR last line ($kind) publishes valid first node" \
		|| bad "T16.86 valid + EOF bare CR last line ($kind) publishes valid first node"
	! grep -Eq 't1686-bad-eofcr|t1686-secret-eofcr' "$R/etc/config/aetherproxy" "$R/var/run/aether-proxy/events.jsonl" "$R/etc/aether-proxy/state/sub.json" \
		&& ok "T16.86 valid + EOF bare CR last line ($kind) never writes or leaks bad last line" \
		|| bad "T16.86 valid + EOF bare CR last line ($kind) never writes or leaks bad last line"
done

echo "sub: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
