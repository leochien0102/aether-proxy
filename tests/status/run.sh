#!/usr/bin/env bash
# Scenario tests for the `status` notices and the overview data (docs/tasks/m8.md T8.4).
# Every run gets its own confdir / run-dir / sys-root / bin-dir under a mktemp directory,
# so nothing outside it is touched and no network access happens. Needs
# tests/host/bootstrap.sh to have run.
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

ap() { PATH="$1" "$UCODE" -S "$ENTRY" -- "${@:2}"; }
jget() { "$UCODE" "$JGET" -- "$1"; }

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }

# expect <name> <expected> <actual>
expect() {
	if [ "$2" == "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# Component stubs. The full pair lives in $T/bin; $T/bin-nochinadns only has xray, so the
# chinadns-ng lookup falls through to a PATH (kept free of chinadns-ng) and fails.
mkdir -p "$T/bin" "$T/bin-nochinadns"
for name in xray chinadns-ng; do
	printf '#!/bin/sh\nexit 0\n' > "$T/bin/$name"
done
cp "$T/bin/xray" "$T/bin-nochinadns/xray"
chmod +x "$T/bin/"* "$T/bin-nochinadns/"*

PATH_BOTH="$T/bin:/usr/bin:/bin"
PATH_NOCHINADNS="$T/bin-nochinadns:/usr/bin:/bin"

# make_root <dir>: dnsmasq instance (LAN br-lan, conf-dir /tmp/dnsmasq.d) with only our own
# fragment, plus an if_inet6 whose br-lan address is link-local only.
make_root() {
	local root="$1"
	mkdir -p "$root/proc/net" "$root/var/etc" "$root/tmp/dnsmasq.d"
	{
		echo "interface=br-lan"
		echo "conf-dir=/tmp/dnsmasq.d"
	} > "$root/var/etc/dnsmasq.conf.cfg01411c"
	printf 'server=127.0.0.1#31053\n' > "$root/tmp/dnsmasq.d/aether-proxy.conf"
	printf 'fe800000000000000000000000000001 04 40 20 80 br-lan\n' > "$root/proc/net/if_inet6"
}

# ------------------------------------------------------------------
# Shared component lookup: the notices must use exactly the lookup rules of
# docs/01 「组件二进制的查找顺序」 as `check` does (the exported find_component).
# ------------------------------------------------------------------
cat > "$T/findcomp.uc" <<EOF
'use strict';
import * as fs from 'fs';
import * as check from 'aetherproxy.cmd.check';

let bin = '$T/bin-nochinadns';
fs.mkdir('$T/uci-bin');
fs.writefile('$T/uci-bin/chinadns-ng', '#!/bin/sh\n');
fs.chmod('$T/uci-bin/chinadns-ng', 493);	// executable -> found from UCI
fs.mkdir('$T/uci-noexec');
fs.writefile('$T/uci-noexec/chinadns-ng', 'x');
fs.chmod('$T/uci-noexec/chinadns-ng', 420);	// 0644: present but not executable

function j(v) { return v == null ? 'null' : v.source + ':' + v.path; }
let out = [
	j(check.find_component('xray', null, { bin_dir: bin })),
	j(check.find_component('chinadns-ng', null, { bin_dir: bin })),
	j(check.find_component('chinadns-ng', '$T/uci-bin/chinadns-ng', { bin_dir: bin })),
	j(check.find_component('chinadns-ng', '$T/uci-noexec/chinadns-ng', { bin_dir: bin })),
	j(check.find_component('chinadns-ng', '$T/uci-noexec/chinadns-ng', null))
];
print(join('\n', out) + '\n');
EOF
out="$(PATH="$PATH_NOCHINADNS" "$UCODE" "$T/findcomp.uc" 2>"$T/findcomp.stderr")"; rc=$?
expect "find_component: module loads" 0 "$rc"
expect "find_component: bin-dir wins" "bin-dir:$T/bin-nochinadns/xray" "$(echo "$out" | sed -n 1p)"
expect "find_component: missing when nowhere" "null" "$(echo "$out" | sed -n 2p)"
expect "find_component: uci path when executable" "uci:$T/uci-bin/chinadns-ng" "$(echo "$out" | sed -n 3p)"
expect "find_component: non-executable uci path missing" "null" "$(echo "$out" | sed -n 4p)"
expect "find_component: falls back to PATH" "null" "$(echo "$out" | sed -n 5p)"

# ------------------------------------------------------------------
# Scenario 1: nothing pending -> notices is []
# ------------------------------------------------------------------
R="$T/s1"; SR="$T/s1-root"
make_root "$SR"
mkdir -p "$R"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/s1.stderr")"; rc=$?
expect "s1: exit code 0" 0 "$rc"
expect "s1: stderr empty" "" "$(cat "$T/s1.stderr")"
expect "s1: notices empty" "<missing>" "$(echo "$out" | jget notices.0.code)"
expect "s1: state still reported" "stopped" "$(echo "$out" | jget state)"

# ------------------------------------------------------------------
# Scenario 2: COMPONENT_MISSING
# ------------------------------------------------------------------
R="$T/s2"; SR="$T/s2-root"
make_root "$SR"
mkdir -p "$R"
out="$(ap "$PATH_NOCHINADNS" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin-nochinadns" 2>"$T/s2.stderr")"; rc=$?
expect "s2: exit code 0" 0 "$rc"
expect "s2: exactly one notice" "<missing>" "$(echo "$out" | jget notices.1.code)"
expect "s2: code" "COMPONENT_MISSING" "$(echo "$out" | jget notices.0.code)"
expect "s2: component is chinadns-ng" "chinadns-ng" "$(echo "$out" | jget notices.0.args.component)"

# A configured chinadns_bin that is not executable counts as missing, like in check.
mkdir -p "$T/conf-noexec" "$T/noexec"
sed "s#option password 'secret'#option password 'secret'\\n\\toption chinadns_bin '$T/noexec/chinadns-ng'#" \
	"$FIX/sample/aetherproxy" > "$T/conf-noexec/aetherproxy"
printf 'not executable\n' > "$T/noexec/chinadns-ng"
chmod 644 "$T/noexec/chinadns-ng"
out="$(ap "$PATH_NOCHINADNS" status --json --confdir "$T/conf-noexec" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin-nochinadns" 2>"$T/s2b.stderr")"; rc=$?
expect "s2b: exit code 0" 0 "$rc"
expect "s2b: exactly one notice" "<missing>" "$(echo "$out" | jget notices.1.code)"
expect "s2b: code" "COMPONENT_MISSING" "$(echo "$out" | jget notices.0.code)"
expect "s2b: component is chinadns-ng" "chinadns-ng" "$(echo "$out" | jget notices.0.args.component)"

# ------------------------------------------------------------------
# Scenario 3: UPDATE_AVAILABLE
# ------------------------------------------------------------------
R="$T/s3"; SR="$T/s3-root"
make_root "$SR"
mkdir -p "$R"
cat > "$R/updates.json" <<'EOF'
{"checked":1760400000,"url":"https://channel.example/","arch":"x86_64","pm":"apk",
 "packages":{
   "xray-core":{"installed":"26.9.30-r1","available":"26.10.1","newer":true,"asset":"https://channel.example/xray.apk"},
   "aether-proxy":{"installed":"0.1.0-r2","available":"0.2.0","newer":true,"asset":"https://channel.example/ap.apk"},
   "luci-app-aether-proxy":{"installed":"0.1.0-r2","available":"0.1.0-r2","newer":false}
 },
 "data":{}}
EOF
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/s3.stderr")"; rc=$?
expect "s3: exit code 0" 0 "$rc"
expect "s3: exactly two update notices" "<missing>" "$(echo "$out" | jget notices.2.code)"
expect "s3: first package (UPDATE_PACKAGES order)" "xray-core" "$(echo "$out" | jget notices.0.args.package)"
expect "s3: first available" "26.10.1" "$(echo "$out" | jget notices.0.args.available)"
expect "s3: second package" "aether-proxy" "$(echo "$out" | jget notices.1.args.package)"
expect "s3: second available" "0.2.0" "$(echo "$out" | jget notices.1.args.available)"
expect "s3: codes" "UPDATE_AVAILABLE" "$(echo "$out" | jget notices.0.code)"

# update.xray_auto == 'off' mutes only the xray-core notice.
mkdir -p "$T/conf-xrayoff"
cat "$FIX/sample/aetherproxy" > "$T/conf-xrayoff/aetherproxy"
cat >> "$T/conf-xrayoff/aetherproxy" <<'EOF'

config update 'update'
	option xray_auto 'off'
EOF
out="$(ap "$PATH_BOTH" status --json --confdir "$T/conf-xrayoff" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/s3b.stderr")"; rc=$?
expect "s3b (xray_auto off): exit code 0" 0 "$rc"
expect "s3b: only aether-proxy remains" "aether-proxy" "$(echo "$out" | jget notices.0.args.package)"
expect "s3b: xray-core suppressed" "<missing>" "$(echo "$out" | jget notices.1.code)"

# newer=false and a missing updates.json never produce a notice.
cat > "$R/updates.json" <<'EOF'
{"checked":1760400000,"packages":{
   "xray-core":{"installed":"26.10.1","available":"26.10.1","newer":false},
   "aether-proxy":{"installed":"0.2.0","available":"0.2.0","newer":false}}}
EOF
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>/dev/null)"
expect "s3c (newer=false): notices empty" "<missing>" "$(echo "$out" | jget notices.0.code)"
rm "$R/updates.json"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>/dev/null)"
expect "s3d (no updates.json): notices empty" "<missing>" "$(echo "$out" | jget notices.0.code)"
expect "s3d: updates_available stays null" "<missing>" "$(echo "$out" | jget updates_available)"

# ------------------------------------------------------------------
# Scenario 4: IPV6_PRESENT (sys-root /proc/net/if_inet6 fixture)
# ------------------------------------------------------------------
R="$T/s4"; SR="$T/s4-root"
make_root "$SR"
mkdir -p "$R"
cat > "$SR/proc/net/if_inet6" <<'EOF'
20010db8000000000000000000000001 04 40 00 00 br-lan
fe800000000000000000000000000001 04 40 20 80 br-lan
20010db8000000000000000000000002 05 40 00 00 eth9
EOF
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/s4.stderr")"; rc=$?
expect "s4a: exit code 0" 0 "$rc"
expect "s4a: exactly one notice" "<missing>" "$(echo "$out" | jget notices.1.code)"
expect "s4a: code" "IPV6_PRESENT" "$(echo "$out" | jget notices.0.code)"
expect "s4a: iface is br-lan" "br-lan" "$(echo "$out" | jget notices.0.args.iface)"

# Only a link-local (scope 20) address: no notice.
printf 'fe800000000000000000000000000001 04 40 20 80 br-lan\n' > "$SR/proc/net/if_inet6"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>/dev/null)"
expect "s4b (link-local only): notices empty" "<missing>" "$(echo "$out" | jget notices.0.code)"

# A global address on an interface outside lan_ifaces: no notice.
printf '20010db8000000000000000000000002 05 40 00 00 eth9\n' > "$SR/proc/net/if_inet6"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>/dev/null)"
expect "s4c (non-LAN iface): notices empty" "<missing>" "$(echo "$out" | jget notices.0.code)"

# ------------------------------------------------------------------
# Scenario 5: DNSMASQ_EXTRA_SERVERS, and status stays read-only
# ------------------------------------------------------------------
R="$T/s5"; SR="$T/s5-root"
make_root "$SR"
mkdir -p "$R"
printf 'server=8.8.8.8\nserver=9.9.9.9\n' > "$SR/tmp/dnsmasq.d/other.conf"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/s5.stderr")"; rc=$?
expect "s5a: exit code 0" 0 "$rc"
expect "s5a: exactly one notice" "<missing>" "$(echo "$out" | jget notices.1.code)"
expect "s5a: code" "DNSMASQ_EXTRA_SERVERS" "$(echo "$out" | jget notices.0.code)"
expect "s5a: first foreign line" "server=8.8.8.8" "$(echo "$out" | jget notices.0.args.servers.0)"
expect "s5a: second foreign line" "server=9.9.9.9" "$(echo "$out" | jget notices.0.args.servers.1)"
expect "s5a: no third line" "<missing>" "$(echo "$out" | jget notices.0.args.servers.2)"
[ ! -e "$R/events.jsonl" ] && ok "s5a: no events.jsonl created (read-only)" \
	|| bad "s5a: no events.jsonl created (read-only)" "$(cat "$R/events.jsonl")"

# Only our own fragment has server= lines: no notice, still no events.
rm "$SR/tmp/dnsmasq.d/other.conf"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/s5b.stderr")"; rc=$?
expect "s5b (own fragment only): exit code 0" 0 "$rc"
expect "s5b: notices empty" "<missing>" "$(echo "$out" | jget notices.0.code)"
[ ! -e "$R/events.jsonl" ] && ok "s5b: no events.jsonl created (read-only)" \
	|| bad "s5b: no events.jsonl created (read-only)" "$(cat "$R/events.jsonl")"

# ------------------------------------------------------------------
# Usage errors and an invalid configuration (documented decision: status
# fails with CONFIG_INVALID instead of reporting notices).
# ------------------------------------------------------------------
out="$(ap "$PATH_BOTH" status --json --bogus 2>"$T/s6.stderr")"; rc=$?
expect "unknown option: exit code 2" 2 "$rc"
expect "unknown option: code" "USAGE" "$(echo "$out" | jget code)"
out="$(ap "$PATH_BOTH" status --json --confdir "$FIX/t11-err-enabled-no-node" --run-dir "$T/s6" 2>/dev/null)"; rc=$?
expect "invalid configuration: exit code 2" 2 "$rc"
expect "invalid configuration: code" "CONFIG_INVALID" "$(echo "$out" | jget code)"
expect "invalid configuration: error field" "main.node" "$(echo "$out" | jget errors.0.field)"

# T9.6: compare the entire status response with the original usable-cache response,
# not just its notice count. Database times are fixed, independent of the wall clock.
R="$T/cache"; SR="$T/cache-root"
make_root "$SR"
mkdir -p "$R" "$SR/usr/lib/opkg" "$SR/lib/apk/db"
cache_status() {
	ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" \
		--sys-root "$SR/" --bin-dir "$T/bin" 2>"$T/cache.stderr"
}
cache='{"checked":1760400000,"pm":"opkg",
 "packages":{"xray-core":{"newer":true,"available":"26.10-r1","asset":"xray.ipk"}},"data":{}}'
printf '%s\n' "$cache" > "$R/updates.json"
reference=$(cache_status)
expect 'T9.6 reference has UPDATE_AVAILABLE' UPDATE_AVAILABLE "$(echo "$reference" | jget notices.0.code)"

cache_case() {
	local label=$1 pm=$2 checked=$3 opkg_time=$4 apk_time=$5 stale=$6 output expected actual before after
	python3 - "$R/updates.json" "$cache" "$pm" "$checked" <<'PY'
import json, sys
path, source, pm, checked = sys.argv[1:]
value = json.loads(source)
for key, raw in [('pm', pm), ('checked', checked)]:
    if raw == 'missing':
        del value[key]
    else:
        value[key] = json.loads(raw)
with open(path, 'w') as dest:
    json.dump(value, dest)
PY
	rm -f "$SR/usr/lib/opkg/status" "$SR/lib/apk/db/installed"
	python3 - "$SR" "$opkg_time" "$apk_time" <<'PY'
import os, pathlib, sys
root, opkg, apk = sys.argv[1:]
for path, stamp in [('usr/lib/opkg/status', opkg), ('lib/apk/db/installed', apk)]:
    target = pathlib.Path(root) / path
    if stamp == 'missing':
        continue
    if stamp == 'stat-fail':
        target.symlink_to(target.name)  # ELOOP: an existing entry that stat cannot follow.
    else:
        target.write_text('package database fixture\n')
        os.utime(target, (int(stamp), int(stamp)))
PY
	before=$(stat -c '%y' "$R/updates.json")
	cp "$R/updates.json" "$T/cache-before"
	output=$(cache_status)
	expect "T9.6 $label exit 0" 0 "$?"
	expected=$(python3 - "$reference" "$R/updates.json" "$stale" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
value['updates_available'] = None if sys.argv[3] == 'yes' else json.load(open(sys.argv[2]))
if sys.argv[3] == 'yes':
    value['notices'] = []
print(json.dumps(value, sort_keys=True))
PY
	)
	actual=$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True))' <<< "$output")
	expect "T9.6 $label full status and notices" "$expected" "$actual"
	cmp -s "$T/cache-before" "$R/updates.json" \
		&& ok "T9.6 $label cache bytes unchanged" || bad "T9.6 $label cache bytes unchanged"
	after=$(stat -c '%y' "$R/updates.json")
	expect "T9.6 $label cache mtime unchanged" "$before" "$after"
	[ ! -e "$R/events.jsonl" ] && ok "T9.6 $label no events" || bad "T9.6 $label no events"
}
while IFS='|' read -r label pm checked opkg_time apk_time stale; do
	cache_case "$label" "$pm" "$checked" "$opkg_time" "$apk_time" "$stale"
done <<'CACHE_CASES'
opkg T+10|"opkg"|1760400000|1760400010|missing|yes
opkg T-10|"opkg"|1760400000|1760399990|missing|no
opkg T exact|"opkg"|1760400000|1760400000|missing|no
opkg ignores newer apk|"opkg"|1760400000|1760399990|1760400010|no
apk T+10|"apk"|1760400000|1760399990|1760400010|yes
apk ignores newer opkg|"apk"|1760400000|1760400010|1760399990|no
apk T exact|"apk"|1760400000|1760400010|1760400000|no
missing database|"opkg"|1760400000|missing|missing|no
stat failure|"opkg"|1760400000|stat-fail|missing|no
missing pm|missing|1760400000|1760400010|1760400010|no
unknown pm|"other"|1760400000|1760400010|1760400010|no
null pm|null|1760400000|1760400010|1760400010|no
missing checked|"opkg"|missing|1760400010|missing|no
string checked|"opkg"|"1760400000"|1760400010|missing|no
null checked|"opkg"|null|1760400010|missing|no
boolean checked|"opkg"|true|1760400010|missing|no
object checked|"opkg"|{}|1760400010|missing|no
double checked fresh|"opkg"|1760400000.5|1760400000|missing|no
double checked stale|"opkg"|1760400000.5|1760400010|missing|yes
CACHE_CASES

# Package freshness must not hide rule-data discovery results (docs/08).
printf '%s\n' "$cache" > "$R/updates.json"
rm -f "$SR/usr/lib/opkg/status"
mkdir -p "$SR/usr/share/aether-proxy/data"
for name in gfwlist chnlist apple; do
	printf 'example.com\n' > "$SR/usr/share/aether-proxy/data/$name.txt"
done
for name in chnroute4 gfw_static4; do
	printf '192.0.2.0/24\n' > "$SR/usr/share/aether-proxy/data/$name.txt"
done
python3 - "$R/updates.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value['data'] = {'gfwlist': {'changed': True}, 'chnroute4': {'changed': False}}
json.dump(value, open(path, 'w'))
PY
data_before=$(ap "$PATH_BOTH" data status --json --run-dir "$R" --sys-root "$SR")
expect 'T9.6 fresh data status exit 0' 0 "$?"
expect 'T9.6 fresh data status changed true' true "$(echo "$data_before" | jget items.gfwlist.changed)"
expect 'T9.6 fresh data status changed false' false "$(echo "$data_before" | jget items.chnroute4.changed)"
touch -d @1760400010 "$SR/usr/lib/opkg/status"
out=$(cache_status)
expect 'T9.6 data test package cache is stale' '<missing>' "$(echo "$out" | jget updates_available)"
data_after=$(ap "$PATH_BOTH" data status --json --run-dir "$R" --sys-root "$SR")
expect 'T9.6 stale data status exit 0' 0 "$?"
expect 'T9.6 stale data status unchanged byte for byte' "$data_before" "$data_after"
expect 'T9.6 stale data status keeps checked' 1760400000 "$(echo "$data_after" | jget checked)"
[ ! -e "$R/events.jsonl" ] && ok 'T9.6 data status no events' || bad 'T9.6 data status no events'

# Broken JSON and non-object JSON retain the old FS_FAILED parse semantics.
for broken in '{broken' '[]' 'null'; do
	printf '%s\n' "$broken" > "$R/updates.json"
	rm -f "$R/events.jsonl"
	out=$(cache_status)
	expect "T9.6 corrupt $broken exit 0" 0 "$?"
	expect "T9.6 corrupt $broken cache null" '<missing>' "$(echo "$out" | jget updates_available)"
	expect "T9.6 corrupt $broken no update notice" '<missing>' "$(echo "$out" | jget notices.0.code)"
	expect "T9.6 corrupt $broken FS_FAILED" FS_FAILED "$(jget code < "$R/events.jsonl")"
	expect "T9.6 corrupt $broken parse operation" parse "$(jget args.op < "$R/events.jsonl")"
done
rm "$R/updates.json" "$R/events.jsonl"
out=$(cache_status)
expect 'T9.6 absent cache exit 0' 0 "$?"
expect 'T9.6 absent cache null' '<missing>' "$(echo "$out" | jget updates_available)"
expect 'T9.6 absent cache no notice' '<missing>' "$(echo "$out" | jget notices.0.code)"
[ ! -e "$R/events.jsonl" ] && ok 'T9.6 absent cache no events' || bad 'T9.6 absent cache no events'

# T9.26: a saved mode is applied state, even while UCI requests another mode.
# Keep the existing status behavior for old state files which have no mode field.
R="$T/applied-mode"; SR="$T/applied-mode-root"
make_root "$SR"
mkdir -p "$R"
for mode in gfw bypass_cn global; do
	printf '{"state":"running","node_id":"n_00000000000000000000000000000001","mode":"%s"}\n' \
		"$mode" > "$R/state.json"
	cp "$R/state.json" "$T/applied-mode-before"
	human=$(ap "$PATH_BOTH" status --run-dir "$R" --confdir "$FIX/sample" --sys-root "$SR" --bin-dir "$T/bin")
	expect "T9.27 human status $mode succeeds" 0 "$?"
	printf '%s\n' "$human" | grep -Fxq "mode: \"$mode\"" \
		&& ok "T9.27 human status contains applied mode: $mode" \
		|| bad "T9.27 human status contains applied mode: $mode"
	printf '%s\n' "$human" | awk '/^node_id:/ { getline; if ($0 ~ /^mode:/) found=1 } END { exit !found }' \
		&& ok "T9.27 human mode is adjacent to node_id: $mode" \
		|| bad "T9.27 human mode is adjacent to node_id: $mode"
	out=$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" \
		--sys-root "$SR" --bin-dir "$T/bin" 2>"$T/applied-mode.stderr")
	expect "T9.26 status $mode exits successfully" 0 "$?"
	expect "T9.26 status preserves applied $mode despite configured gfw" "$mode" \
		"$(printf '%s\n' "$out" | jget mode)"
	cmp -s "$T/applied-mode-before" "$R/state.json" \
		&& ok "T9.26 status $mode leaves state bytes unchanged" \
		|| bad "T9.26 status $mode leaves state bytes unchanged"
done
printf '{"state":"running"}\n' > "$R/state.json"
out=$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" \
	--sys-root "$SR" --bin-dir "$T/bin" 2>"$T/applied-mode.stderr")
expect 'T9.26 legacy status exits successfully' 0 "$?"
expect 'T9.26 legacy status does not infer mode from UCI' '<missing>' "$(printf '%s\n' "$out" | jget mode)"

# T9.32 scenario 5: `stopping` is a known state which is not "running".
R="$T/stopping"; SR="$T/stopping-root"
make_root "$SR"
mkdir -p "$R"
printf '{"state":"stopping","since":1700000000,"node_id":"n_00000000000000000000000000000001","mode":"gfw","dns_tier":"T2"}\n' > "$R/state.json"
cp "$R/state.json" "$T/stopping-before"
out=$(ap "$PATH_BOTH" status --json --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/stopping.stderr"); rc=$?
expect 'T9.32 status --json under stopping exits 0' 0 "$rc"
expect 'T9.32 status --json under stopping keeps state' stopping "$(printf '%s\n' "$out" | jget state)"
expect 'T9.32 status --json under stopping keeps node_id' n_00000000000000000000000000000001 "$(printf '%s\n' "$out" | jget node_id)"
expect 'T9.32 status --json under stopping has empty stderr' '' "$(cat "$T/stopping.stderr")"
human=$(ap "$PATH_BOTH" status --confdir "$FIX/sample" --run-dir "$R" --sys-root "$SR" --bin-dir "$T/bin" 2>&1); rc=$?
expect 'T9.32 human status under stopping exits 0' 0 "$rc"
printf '%s\n' "$human" | grep -Fxq 'state: stopping' \
	&& ok 'T9.32 human status under stopping shows the state' || bad 'T9.32 human status under stopping shows the state' "$human"
out=$(ap "$PATH_BOTH" probe now --json --run-dir "$R" --confdir "$FIX/sample" --sys-root "$SR" --bin-dir "$T/bin" 2>"$T/stopping-probe.stderr"); rc=$?
expect 'T9.32 probe now under stopping exits 1' 1 "$rc"
expect 'T9.32 probe now under stopping is NOT_RUNNING' NOT_RUNNING "$(printf '%s\n' "$out" | jget code)"
cmp -s "$T/stopping-before" "$R/state.json" \
	&& ok 'T9.32 stopping state bytes unchanged by status and probe now' \
	|| bad 'T9.32 stopping state bytes unchanged by status and probe now'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
