#!/usr/bin/env bash
# CLI scenario tests for `log`, `node import` and `custom` (docs/tasks/m8.md T8.2,
# scenarios 1-9 of the card; scenario 10 lives in tests/rpcd/run.sh).
# Also covers T8.18's colored Zig/C log sources (docs/10 log classification).
# Runs the real entry point on the host through the test-only options of docs/10, with
# stubs for `logread` (via PATH), the init script (via --sys-root) and the import race
# hook (via AETHER_PROXY_TEST_NODE_IMPORT_RACE), so nothing outside a mktemp directory
# is touched. Needs tests/host/bootstrap.sh to have run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
ENTRY="$ROOT/aether-proxy/src/aether-proxy"
JGET="$ROOT/tests/cli/jget.uc"

T="$(mktemp -d "$ROOT/tests/node/tmp.XXXXXX")"
pass=0
fail=0
R=''

cleanup() {
	if [ -n "$T" ] && [ -d "$T" ]; then
		if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept node-test temp: $T"; else rm -rf "$T"; fi
	fi
}
trap cleanup EXIT INT TERM

ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
jget() { "$UCODE" "$JGET" -- "$1"; }
ap() { "$UCODE" -S "$ENTRY" -- "$@"; }
# Length of a top-level JSON array, e.g. `alen "$out" lines`.
alen() {
echo "$1" | "$UCODE" -e 'import * as fs from "fs"; let v = json(fs.stdin.read("all")); print(length(v[ARGV[0]] ?? []));' -- "$2"
}
# inode + mtime of a file, to prove it was not rewritten.
stamp() { stat -c '%i %y' "$1"; }
has_line() { grep -Fq -- "$2" "$1"; }
matches() { grep -Eq -- "$2" "$1"; }

# ===========================================================================
# 1-2: log
# ===========================================================================
mkdir -p "$T/bin"
cat > "$T/bin/logread" <<'SH'
#!/bin/sh
# Test double for busybox logread (docs/tasks/m8.md T8.2): prints the fixture
# named by LOGREAD_FIXTURE and exits with LOGREAD_RC (default 0).
if [ -n "${LOGREAD_FIXTURE:-}" ]; then cat "$LOGREAD_FIXTURE"; fi
exit "${LOGREAD_RC:-0}"
SH
chmod +x "$T/bin/logread"

cat > "$T/logd.txt" <<'EOF'
Thu Oct 16 12:00:00 2026 daemon.notice aether-proxy[1234]: SERVICE_STARTED proxy started [mode=gfw node=n_a]
Thu Oct 16 12:00:01 2026 daemon.warn aether-proxy[1234]: 2026/10/16 12:00:01.123456 [Warning] transport: failed to dial upstream
Thu Oct 16 12:00:02 2026 daemon.info aether-proxy[1234]: 2026/10/16 12:00:02.000000 [Info] app: listener ready
Thu Oct 16 12:00:03 2026 daemon.notice aether-proxy[1234]: [main.zig:123] trust upstream switched
Thu Oct 16 12:00:04 2026 daemon.notice dnsmasq[999]: reading /tmp/resolv.conf
Thu Oct 16 12:00:05 2026 daemon.err aether-proxy[1235]: CMD_FAILED external command failed [cmd="nft -f x" rc=1 stderr="err"]
Thu Oct 16 12:00:06 2026 daemon.info aether-proxy[1234]: [resolver.zig:44] cached 10 entries
EOF
export LOGREAD_FIXTURE="$T/logd.txt"

# --- 1: --source all keeps exactly the three tagged sources; other programs never appear
out="$(PATH="$T/bin:$PATH" ap log --json --source all 2>"$T/log-all.stderr")"; rc=$?
expect "log all: exit code 0" 0 "$rc"
expect "log all: stderr empty" "" "$(cat "$T/log-all.stderr")"
expect "log all: ok true" true "$(echo "$out" | jget ok)"
expect "log all: echoes source" all "$(echo "$out" | jget source)"
expect "log all: keeps the six tagged lines" 6 "$(alen "$out" lines)"
expect "log all: line 1 source" aether-proxy "$(echo "$out" | jget lines.0.source)"
expect "log all: line 2 source" xray "$(echo "$out" | jget lines.1.source)"
expect "log all: line 3 source" xray "$(echo "$out" | jget lines.2.source)"
expect "log all: line 4 source" dns "$(echo "$out" | jget lines.3.source)"
expect "log all: line 5 source" aether-proxy "$(echo "$out" | jget lines.4.source)"
expect "log all: line 6 source" dns "$(echo "$out" | jget lines.5.source)"
echo "$out" | grep -q 'dnsmasq\[999\]' && bad "log all: foreign lines are not returned" || ok "log all: foreign lines are not returned"
expect "log all: text is the original whole line" \
	"$(sed -n '2p' "$T/logd.txt")" "$(echo "$out" | jget lines.1.text)"

for src in xray dns aether-proxy; do
	out="$(PATH="$T/bin:$PATH" ap log --json --source "$src" 2>/dev/null)"
	expect "log --source $src: only its own lines" 2 "$(alen "$out" lines)"
	expect "log --source $src: first line classified" "$src" "$(echo "$out" | jget lines.0.source)"
	expect "log --source $src: second line classified" "$src" "$(echo "$out" | jget lines.1.source)"
done

# --- 2: --lines takes the filtered tail in order; bad values are USAGE; logread failure is CMD_FAILED
out="$(PATH="$T/bin:$PATH" ap log --json --source all --lines 2 2>/dev/null)"
expect "log --lines 2: keeps the last two lines" 2 "$(alen "$out" lines)"
expect "log --lines 2: last-but-one line kept" aether-proxy "$(echo "$out" | jget lines.0.source)"
expect "log --lines 2: last line kept" dns "$(echo "$out" | jget lines.1.source)"
expect "log --lines 2: original order preserved" \
	"$(sed -n '6p' "$T/logd.txt")" "$(echo "$out" | jget lines.0.text)"
out="$(PATH="$T/bin:$PATH" ap log --json --source xray --lines 1 2>/dev/null)"
expect "log --lines 1 applies after filtering: newest xray line" \
	"$(sed -n '3p' "$T/logd.txt")" "$(echo "$out" | jget lines.0.text)"

for bad_lines in 0 2001 abc -1; do
	out="$(PATH="$T/bin:$PATH" ap log --json --lines "$bad_lines" 2>/dev/null)"; rc=$?
	expect "log --lines $bad_lines: exit code 2" 2 "$rc"
	expect "log --lines $bad_lines: code USAGE" USAGE "$(echo "$out" | jget code)"
done
out="$(PATH="$T/bin:$PATH" ap log --json --source bogus 2>/dev/null)"; rc=$?
expect "log --source bogus: exit code 2" 2 "$rc"
expect "log --source bogus: code USAGE" USAGE "$(echo "$out" | jget code)"

# No logread at all -> CMD_FAILED, exit 1. /usr/bin:/bin has no logread on the host.
out="$(PATH=/usr/bin:/bin ap log --json 2>"$T/log-missing.stderr")"; rc=$?
expect "log without logread: exit code 1" 1 "$rc"
expect "log without logread: code CMD_FAILED" CMD_FAILED "$(echo "$out" | jget code)"
# A failing logread is the same documented case.
export LOGREAD_RC=5
out="$(PATH="$T/bin:$PATH" ap log --json 2>/dev/null)"; rc=$?
expect "logread exits 5: exit code 1" 1 "$rc"
expect "logread exits 5: code CMD_FAILED" CMD_FAILED "$(echo "$out" | jget code)"
unset LOGREAD_RC

# T8.18: preserve the task's on-device location text; envelopes and SGR sequences
# are synthetic because the repository does not contain the full device capture.
export LOGREAD_FIXTURE="$ROOT/tests/node/fixtures/logd-chinadns.txt"
mapfile -t device_lines < "$LOGREAD_FIXTURE"
expected_sources=(aether-proxy xray xray dns dns)
out="$(PATH="$T/bin:$PATH" ap log --json 2>"$T/device-all.stderr")"; rc=$?
expect "log device all: exit code 0" 0 "$rc"
expect "log device all: stderr empty" '' "$(<"$T/device-all.stderr")"
expect "log device all: five tagged lines" 5 "$(alen "$out" lines)"
for i in "${!expected_sources[@]}"; do
	expect "log device all: line $((i + 1)) source" "${expected_sources[$i]}" \
		"$(printf '%s' "$out" | jget "lines.$i.source")"
	expect "log device all: line $((i + 1)) text byte-identical" "${device_lines[$i]}" \
		"$(printf '%s' "$out" | jget "lines.$i.text")"
done

out="$(PATH="$T/bin:$PATH" ap log --json --source dns 2>"$T/device-dns.stderr")"; rc=$?
expect "log device --source dns: exit code 0" 0 "$rc"
expect "log device --source dns: stderr empty" '' "$(<"$T/device-dns.stderr")"
expect "log device --source dns: exactly two lines" 2 "$(alen "$out" lines)"
for i in 0 1; do
	expect "log device --source dns: line $((i + 1)) source dns" dns \
		"$(printf '%s' "$out" | jget "lines.$i.source")"
	expect "log device --source dns: line $((i + 1)) text byte-identical" "${device_lines[$((i + 3))]}" \
		"$(printf '%s' "$out" | jget "lines.$i.text")"
done

PATH="$T/bin:$PATH" ap log --source dns >"$T/device-human.txt" 2>"$T/device-human.stderr"; rc=$?
expect "log device human dns: exit code 0" 0 "$rc"
expect "log device human dns: stderr empty" '' "$(<"$T/device-human.stderr")"
printf '%s\n' "${device_lines[3]}" "${device_lines[4]}" > "$T/device-expected.txt"
if cmp -s "$T/device-expected.txt" "$T/device-human.txt"; then
	ok "log device human dns: output byte-identical including ANSI and newlines"
else
	bad "log device human dns: output byte-identical including ANSI and newlines"
fi
export LOGREAD_FIXTURE="$T/logd.txt"

# ===========================================================================
# 3-6: node import
# ===========================================================================
make_root() {
	R="$1"
	mkdir -p "$R/etc/config" "$R/var/run/aether-proxy"
}

write_base_config() {
	# Leading blank line and blank separators: the exact shape libuci commit produces,
	# so a later import round-trips these bytes unchanged (verified against libuci).
	cat > "$R/etc/config/aetherproxy" <<'EOF'

config global 'main'
	option enabled '0'
	option mode 'gfw'

config subscription 's_00000001'
	option enabled '1'
	option name 'first'
	option url 'https://sub.example/list'
EOF
}

import_opts() { echo --confdir "$R/etc/config" --run-dir "$R/var/run/aether-proxy"; }

node_sections() { grep -c "^config node 'n_" "$R/etc/config/aetherproxy"; }

make_root "$T/imp1"
write_base_config
VLESS_URI='vless://11111111-2222-4333-8444-555555555555@example.com:443?security=tls&sni=example.com&type=ws&path=%2Fws&host=cdn.example.com#Edge%20One'
VMESS_URI="vmess://$(printf '%s' '{"ps":"VM Node","add":"vm.example.com","port":"8443","id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","scy":"auto","net":"tcp","tls":"tls"}' | base64 -w0)"
TROJAN_URI='trojan://pass%40word@t.example.com:443?sni=t.example.com#Troj'
SS_URI="ss://$(printf '%s' 'aes-256-gcm:password' | base64 -w0)@ss.example.com:8388#SSNode"

# --- 3: one import per scheme writes exactly one new manual section
before="$(cat "$R/etc/config/aetherproxy")"
out="$(ap node import "$VLESS_URI" --json $(import_opts) 2>"$T/imp1a.stderr")"; rc=$?
expect "import vless: exit code 0" 0 "$rc"
expect "import vless: stderr empty" "" "$(cat "$T/imp1a.stderr")"
expect "import vless: ok true" true "$(echo "$out" | jget ok)"
expect "import vless: duplicate false" false "$(echo "$out" | jget duplicate)"
new_id="$(echo "$out" | jget node)"
[[ "$new_id" =~ ^n_[0-9a-f]{32}$ ]] && ok "import vless: section name is n_<32 hex>" || bad "import vless: section name is n_<32 hex>" "$new_id"
for kv in \
	"option label 'Edge One'" "option source 'manual'" "option protocol 'vless'" \
	"option address 'example.com'" "option port '443'" \
	"option uuid '11111111-2222-4333-8444-555555555555'" "option transport 'ws'" \
	"option security 'tls'" "option sni 'example.com'" "option path '/ws'" \
	"option host 'cdn.example.com'" "option encryption 'none'"; do
	matches "$R/etc/config/aetherproxy" "^[[:space:]]*${kv//./\\.}$" \
		&& ok "import vless: writes ${kv%% *}" || bad "import vless: writes ${kv%% *}" "missing line: $kv"
done
has_line "$R/etc/config/aetherproxy" "option match_strong 'vless|example.com|443|ws|/ws|cdn.example.com||tls|example.com|11111111-2222-4333-8444-555555555555'" \
	&& ok "import vless: writes the computed strong key" || bad "import vless: writes the computed strong key" \
	"$(grep match_strong "$R/etc/config/aetherproxy")"
has_line "$R/etc/config/aetherproxy" "option match_weak 'vless|example.com|443|ws|/ws|cdn.example.com|'" \
	&& ok "import vless: writes the weak key" || bad "import vless: writes the weak key"
# Everything that existed before is kept byte for byte; exactly one section is appended.
after="$(cat "$R/etc/config/aetherproxy")"
[ "${after#"$before"}" != "$after" ] \
	&& ok "import vless: original content kept as prefix" \
	|| bad "import vless: original content kept as prefix" "$(diff <(printf '%s' "$before") <(printf '%s' "$after") | head -5)"
tail_block="$(printf '%s\n' "$after" | tail -n +$(( $(printf '%s\n' "$before" | wc -l) + 1 )) | sed '/^$/d')"
[ "$(printf '%s\n' "$tail_block" | head -n 1)" = "config node '$new_id'" ] \
	&& ok "import vless: the new section is appended last" || bad "import vless: the new section is appended last" "$tail_block"
[ -z "$(printf '%s\n' "$tail_block" | tail -n +2 | grep -v '^	option ' | grep -v '^$')" ] \
	&& ok "import vless: the appended block holds only the new node's options" \
	|| bad "import vless: the appended block holds only the new node's options" "$tail_block"

out="$(ap node import "$VMESS_URI" --json $(import_opts) 2>"$T/imp1b.stderr")"; rc=$?
expect "import vmess: exit code 0" 0 "$rc"
for kv in \
	"option label 'VM Node'" "option protocol 'vmess'" "option address 'vm.example.com'" \
	"option port '8443'" "option uuid 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'" \
	"option method 'auto'" "option transport 'raw'" "option security 'tls'"; do
	matches "$R/etc/config/aetherproxy" "^[[:space:]]*${kv//./\\.}$" \
		&& ok "import vmess: writes ${kv%% *}" || bad "import vmess: writes ${kv%% *}" "missing line: $kv"
done

out="$(ap node import "$TROJAN_URI" --json $(import_opts) 2>"$T/imp1c.stderr")"; rc=$?
expect "import trojan: exit code 0" 0 "$rc"
has_line "$R/etc/config/aetherproxy" "option password 'pass@word'" \
	&& ok "import trojan: password URL-decoded" || bad "import trojan: password URL-decoded"
matches "$R/etc/config/aetherproxy" "option security 'tls'" \
	&& ok "import trojan: security defaults to tls" || bad "import trojan: security defaults to tls"

out="$(ap node import "$SS_URI" --json $(import_opts) 2>"$T/imp1d.stderr")"; rc=$?
expect "import ss: exit code 0" 0 "$rc"
has_line "$R/etc/config/aetherproxy" "option method 'aes-256-gcm'" \
	&& ok "import ss: method from base64 userinfo" || bad "import ss: method from base64 userinfo"
has_line "$R/etc/config/aetherproxy" "option password 'password'" \
	&& ok "import ss: password decoded" || bad "import ss: password decoded"
expect "import: four node sections in total" 4 "$(node_sections)"
has_line "$R/etc/config/aetherproxy" "option url 'https://sub.example/list'" \
	&& ok "import: subscription section untouched" || bad "import: subscription section untouched"

# --- 4: duplicates are recognized and nothing is written
dup_before="$(stamp "$R/etc/config/aetherproxy")"
out="$(ap node import "$VLESS_URI" --json $(import_opts) 2>"$T/imp4.stderr")"; rc=$?
expect "import duplicate: exit code 0" 0 "$rc"
expect "import duplicate: duplicate true" true "$(echo "$out" | jget duplicate)"
expect "import duplicate: returns the existing section" "$new_id" "$(echo "$out" | jget node)"
expect "import duplicate: config unchanged (inode+mtime)" "$dup_before" "$(stamp "$R/etc/config/aetherproxy")"
expect "import duplicate: still four sections" 4 "$(node_sections)"

# A hand-written node without match_strong is still recognized by the fresh strong key.
make_root "$T/imp4b"
cat > "$R/etc/config/aetherproxy" <<'EOF'
config global 'main'
	option enabled '0'
config node 'n_00000000000000000000000000000abc'
	option label 'Handmade'
	option source 'manual'
	option protocol 'vless'
	option address 'hand.example.com'
	option port '443'
	option uuid '99999999-8888-4777-8666-555555555555'
	option security 'tls'
EOF
out="$(ap node import 'vless://99999999-8888-4777-8666-555555555555@hand.example.com:443?security=tls' --json $(import_opts) 2>"$T/imp4b.stderr")"; rc=$?
expect "import vs hand-written node: exit code 0" 0 "$rc"
expect "import vs hand-written node: duplicate true" true "$(echo "$out" | jget duplicate)"
expect "import vs hand-written node: returns its section name" n_00000000000000000000000000000abc "$(echo "$out" | jget node)"
expect "import vs hand-written node: config unchanged" 1 "$(node_sections)"

# --- 5: invalid URIs are CONFIG_INVALID, exit 2, and write nothing
make_root "$T/imp5"
write_base_config
before="$(cat "$R/etc/config/aetherproxy")"
for uri in foo http://x vless://; do
	out="$(ap node import "$uri" --json $(import_opts) 2>"$T/imp5.stderr")"; rc=$?
	expect "import invalid '$uri': exit code 2" 2 "$rc"
	expect "import invalid '$uri': code CONFIG_INVALID" CONFIG_INVALID "$(echo "$out" | jget code)"
	[ "$(echo "$out" | jget detail)" != '<missing>' ] \
		&& ok "import invalid '$uri': detail names the reason" \
		|| bad "import invalid '$uri': detail names the reason" "empty detail"
done
expect "import invalid: config file unchanged" "$before" "$(cat "$R/etc/config/aetherproxy")"
expect "import invalid: no node sections" 0 "$(node_sections)"

# --- 6: a concurrent modification between staging and replace aborts the import
make_root "$T/imp6"
write_base_config
cp "$R/etc/config/aetherproxy" "$T/imp6.before"
cat > "$T/race.sh" <<RACE
#!/bin/sh
# The hook run by node import right before the replace (test-only): simulates
# another writer committing to the configuration in that window.
printf '# concurrent edit\n' >> "$R/etc/config/aetherproxy"
RACE
chmod +x "$T/race.sh"
out="$(AETHER_PROXY_TEST_NODE_IMPORT_RACE="$T/race.sh" ap node import "$VLESS_URI" --json $(import_opts) 2>"$T/imp6.stderr")"; rc=$?
expect "import concurrent edit: exit code 2" 2 "$rc"
expect "import concurrent edit: code CONFIG_INVALID" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "import concurrent edit: config holds only the concurrent edit" \
	"$(cat "$T/imp6.before")
# concurrent edit" "$(cat "$R/etc/config/aetherproxy")"
expect "import concurrent edit: no node section was added" 0 "$(node_sections)"

# ===========================================================================
# 7-9: custom get / set
# ===========================================================================
make_root "$T/cust"
mkdir -p "$R/etc/aether-proxy/custom" "$R/etc/init.d" "$R/var/run/aether-proxy"
cat > "$R/etc/init.d/aether-proxy" <<SH
#!/bin/sh
# Test double for /etc/init.d/aether-proxy (same approach as tests/sub and
# tests/update): records each invocation, exits with STUB_INIT_RC.
printf 'init %s\n' "\$*" >> "$R/init-calls.log"
exit "\${STUB_INIT_RC:-0}"
SH
chmod +x "$R/etc/init.d/aether-proxy"
: > "$R/init-calls.log"
cust_opts() { echo --custom-dir "$R/etc/aether-proxy/custom" --run-dir "$R/var/run/aether-proxy" --sys-root "$R"; }
reload_calls() { grep -c '^init reload$' "$R/init-calls.log"; }

# --- 7: get returns the file content; a missing file is an empty string
printf 'example.com\n# comment kept\nexample.org\n' > "$R/etc/aether-proxy/custom/direct_domain.txt"
out="$(ap custom get direct_domain --json $(cust_opts) 2>"$T/cust7.stderr")"; rc=$?
expect "custom get: exit code 0" 0 "$rc"
expect "custom get: stderr empty" "" "$(cat "$T/cust7.stderr")"
expect "custom get: ok true" true "$(echo "$out" | jget ok)"
expect "custom get: echoes name" direct_domain "$(echo "$out" | jget name)"
expect "custom get: content verbatim" "example.com
# comment kept
example.org" "$(echo "$out" | jget content)"
out="$(ap custom get proxy_ip --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom get missing file: exit code 0" 0 "$rc"
expect "custom get missing file: content empty string" '' "$(echo "$out" | jget content)"

# --- 8: set writes (with a trailing newline), is idempotent, reloads only while running
out="$(ap custom set direct_domain --content $'example.com\nexample.org' --json $(cust_opts) 2>"$T/cust8.stderr")"; rc=$?
expect "custom set: exit code 0" 0 "$rc"
expect "custom set: stderr empty" "" "$(cat "$T/cust8.stderr")"
expect "custom set: changed true" true "$(echo "$out" | jget changed)"
expect "custom set: reload false while stopped" false "$(echo "$out" | jget reload)"
expect "custom set: file written with trailing newline" "example.com
example.org" "$(cat "$R/etc/aether-proxy/custom/direct_domain.txt")"
expect "custom set: no reload call while stopped" 0 "$(reload_calls)"

set_stamp="$(stamp "$R/etc/aether-proxy/custom/direct_domain.txt")"
out="$(ap custom set direct_domain --content $'example.com\nexample.org' --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set same content: exit code 0" 0 "$rc"
expect "custom set same content: changed false" false "$(echo "$out" | jget changed)"
expect "custom set same content: file not rewritten" "$set_stamp" "$(stamp "$R/etc/aether-proxy/custom/direct_domain.txt")"

printf '{"state":"running"}\n' > "$R/var/run/aether-proxy/state.json"
out="$(ap custom set direct_domain --content $'example.com\nexample.net' --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set while running: exit code 0" 0 "$rc"
expect "custom set while running: changed true" true "$(echo "$out" | jget changed)"
expect "custom set while running: reload true" true "$(echo "$out" | jget reload)"
expect "custom set while running: init recorded exactly one reload" 1 "$(reload_calls)"

# A failing reload is reported in the reload field; the file stays saved (no rollback).
: > "$R/init-calls.log"
export STUB_INIT_RC=1
out="$(ap custom set direct_domain --content $'example.com' --json $(cust_opts) 2>/dev/null)"; rc=$?
unset STUB_INIT_RC
expect "custom set with failing reload: exit code 0" 0 "$rc"
expect "custom set with failing reload: ok true" true "$(echo "$out" | jget ok)"
expect "custom set with failing reload: changed true" true "$(echo "$out" | jget changed)"
expect "custom set with failing reload: reload failed" failed "$(echo "$out" | jget reload)"
expect "custom set with failing reload: content saved" "example.com" "$(cat "$R/etc/aether-proxy/custom/direct_domain.txt")"

# degraded counts as running; stopped (and no state at all) does not reload.
: > "$R/init-calls.log"
printf '{"state":"degraded"}\n' > "$R/var/run/aether-proxy/state.json"
out="$(ap custom set proxy_ip --content '10.0.0.0/8' --json $(cust_opts) 2>/dev/null)"
expect "custom set while degraded: reload true" true "$(echo "$out" | jget reload)"
: > "$R/init-calls.log"
printf '{"state":"stopped"}\n' > "$R/var/run/aether-proxy/state.json"
out="$(ap custom set proxy_ip --content $'10.0.0.0/8\n192.168.0.0/16' --json $(cust_opts) 2>/dev/null)"
expect "custom set while stopped: reload false" false "$(echo "$out" | jget reload)"
expect "custom set while stopped: init not called" 0 "$(reload_calls)"
: > "$R/init-calls.log"
rm -f "$R/var/run/aether-proxy/state.json"
out="$(ap custom set proxy_ip --content $'10.0.0.0/8\n192.168.0.0/24' --json $(cust_opts) 2>/dev/null)"
expect "custom set without state.json: reload false" false "$(echo "$out" | jget reload)"
expect "custom set without state.json: init not called" 0 "$(reload_calls)"

# --- 9: invalid lines are rejected with line numbers; size and name are USAGE
printf 'example.com\n' > "$R/etc/aether-proxy/custom/proxy_domain.txt"
out="$(ap custom set proxy_domain --content $'good.example\nexa mple.com\nalso.example\nbad domain again' --json $(cust_opts) 2>"$T/cust9.stderr")"; rc=$?
expect "custom set invalid domain line: exit code 2" 2 "$rc"
expect "custom set invalid domain line: code CONFIG_INVALID" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "custom set invalid domain line: first error line number" 2 "$(echo "$out" | jget errors.0.line)"
expect "custom set invalid domain line: first error text" 'exa mple.com' "$(echo "$out" | jget errors.0.text)"
expect "custom set invalid domain line: second error line number" 4 "$(echo "$out" | jget errors.1.line)"
expect "custom set invalid domain line: second error text" 'bad domain again' "$(echo "$out" | jget errors.1.text)"
expect "custom set invalid domain line: file unchanged" 'example.com' "$(cat "$R/etc/aether-proxy/custom/proxy_domain.txt")"

out="$(ap custom set direct_ip --content $'10.0.0.0/8\n1.2.3.4/33\n192.168.1.0/24' --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set invalid cidr: exit code 2" 2 "$rc"
expect "custom set invalid cidr: code CONFIG_INVALID" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "custom set invalid cidr: reports the right line" 2 "$(echo "$out" | jget errors.0.line)"
expect "custom set invalid cidr: reports the original text" '1.2.3.4/33' "$(echo "$out" | jget errors.0.text)"
[ ! -e "$R/etc/aether-proxy/custom/direct_ip.txt" ] \
	&& ok "custom set invalid cidr: no file written" || bad "custom set invalid cidr: no file written"

many=''
i=1
while [ "$i" -le 25 ]; do many="${many}bad line ${i}
"; i=$((i + 1)); done
out="$(ap custom set direct_domain --content "$many" --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set 25 invalid lines: exit code 2" 2 "$rc"
expect "custom set 25 invalid lines: at most 20 errors reported" 20 "$(alen "$out" errors)"

big="$(printf 'a%.0s' $(seq 1 65537))"
out="$(ap custom set direct_domain --content "$big" --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set over 65536 bytes: exit code 2" 2 "$rc"
expect "custom set over 65536 bytes: code USAGE" USAGE "$(echo "$out" | jget code)"
out="$(ap custom set nope --content 'x' --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set unknown name: exit code 2" 2 "$rc"
expect "custom set unknown name: code USAGE" USAGE "$(echo "$out" | jget code)"
out="$(ap custom get nope --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom get unknown name: exit code 2" 2 "$rc"
expect "custom get unknown name: code USAGE" USAGE "$(echo "$out" | jget code)"
out="$(ap custom set direct_domain --json $(cust_opts) 2>/dev/null)"; rc=$?
expect "custom set without --content: exit code 2" 2 "$rc"
expect "custom set without --content: code USAGE" USAGE "$(echo "$out" | jget code)"

echo
# T9.10 uses real libuci plus an isolated init script/session savedir.
python3 "$ROOT/tests/node/use.py" "$ROOT" "$T/use" \
	&& ok 'node use committed selection scenarios' || bad 'node use committed selection scenarios'

# T9.20 checks shared node/mode transactions with a private libuci savedir.
python3 "$ROOT/tests/node/mode.py" "$ROOT" "$T/mode" \
	&& ok 'node and mode shared selection scenarios' || bad 'node and mode shared selection scenarios'

# T9.41 rejects bad input through CLI parse/import and a cold config read.
python3 "$ROOT/tests/node/invalid-input.py" "$ROOT" "$T/invalid-input" \
	&& ok 'T9.41 invalid input boundary scenarios' || bad 'T9.41 invalid input boundary scenarios'

# T9.41 verifies the target configuration before any selection commit.
python3 "$ROOT/tests/node/preflight.py" "$ROOT" "$T/preflight" \
	&& ok 'T9.41 transactional Xray preflight scenarios' || bad 'T9.41 transactional Xray preflight scenarios'
python3 "$ROOT/tests/node/xray-values.py" "$ROOT" "$T/xray-values" \
	&& ok 'T9.41 real Xray value oracle' || bad 'T9.41 real Xray value oracle'

# T9.13 reuses protocol fixtures and real libuci for parse/import parity.
python3 "$ROOT/tests/node/parse.py" "$ROOT" "$T/parse" \
	&& ok 'node parse read-only sharing scenarios' || bad 'node parse read-only sharing scenarios'

# T9.42 (security F1): `vmess://<valid Base64, not a JSON object>` is a parse
# error. It used to escape as an exception (exit 254, stack on stderr), which
# rpcd then reported as CMD_FAILED instead of the documented CONFIG_INVALID.
out="$(ap node parse 'vmess://bm90IGpzb24=' --json 2>"$T/badvmess.stderr")"; rc=$?
expect "T9.42 non-JSON vmess: exit code 2" 2 "$rc"
expect "T9.42 non-JSON vmess: code CONFIG_INVALID" CONFIG_INVALID "$(echo "$out" | jget code)"
expect "T9.42 non-JSON vmess: detail malformed" malformed "$(echo "$out" | jget detail)"
[ ! -s "$T/badvmess.stderr" ] && ok "T9.42 non-JSON vmess: no exception on stderr" \
	|| bad "T9.42 non-JSON vmess: no exception on stderr" "$(cat "$T/badvmess.stderr")"
out="$(ap node parse 'vmess://'$(printf '%s' '{"a":1' | base64 -w0) --json 2>"$T/badjson.stderr")"; rc=$?
expect "T9.42 truncated vmess JSON: exit code 2" 2 "$rc"
expect "T9.42 truncated vmess JSON: code CONFIG_INVALID" CONFIG_INVALID "$(echo "$out" | jget code)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
