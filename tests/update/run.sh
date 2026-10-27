#!/usr/bin/env bash
# Signed update discovery/install regressions (docs/08 "检查" and "软件包安装").
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"; ENTRY="$ROOT/aether-proxy/src/aether-proxy"; USIGN="$ROOT/tests/host/prefix/bin/usign"
T=$(mktemp -d "$ROOT/tests/update/tmp.XXXXXX"); PIDS=(); pass=0; fail=0
export PATH="$ROOT/tests/stubs/update-bin:$PATH"
PORT1=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || :; wait "$p" 2>/dev/null || :; done; if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept $T"; else rm -rf "$T"; fi; }
trap cleanup EXIT INT TERM
ok() { pass=$((pass+1)); echo "PASS  $1"; }; bad() { fail=$((fail+1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
get() { python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[int(k)] if isinstance(v,list) else v[k]
print("<null>" if v is None else str(v).lower() if isinstance(v,bool) else v)' "$2" <<<"$1"; }
ap() { "$UCODE" -S "$ENTRY" -- "$@"; }
mkdir -p "$T/root/etc/aether-proxy/keys" "$T/root/etc/aether-proxy/data" "$T/root/tmp" "$T/run" "$T/conf" "$T/bin" "$T/ch1" "$T/ch2" "$T/root/etc/init.d" "$T/root/var/run/aether-proxy"
mkdir -p "$T/root/usr/share/aether-proxy/data" "$T/root/etc/init.d"
cat > "$T/root/etc/init.d/aether-proxy" <<'INIT'
#!/bin/sh
printf '%s\n' "$*" >> "$UPDATE_INIT_CALLS"
INIT
chmod +x "$T/root/etc/init.d/aether-proxy"
export UPDATE_INIT_CALLS="$T/init-calls"
"$USIGN" -G -p "$T/pub" -s "$T/sec" >/dev/null 2>&1
fp=$("$USIGN" -F -p "$T/pub"); cp "$T/pub" "$T/root/etc/aether-proxy/keys/$fp"
cp "$ROOT/tests/stubs/update-bin/opkg" "$T/bin/opkg"; cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"; chmod +x "$T/bin"/*
cp "$USIGN" "$T/bin/usign"
printf "DISTRIB_ARCH='aarch64_generic'\n" > "$T/root/etc/openwrt_release"
cat > "$T/conf/aetherproxy" <<UCI
config update 'update'
 list channel_urls 'http://127.0.0.1:$PORT1/'
 list channel_urls 'http://127.0.0.1:$PORT2/'
UCI
python3 -m http.server "$PORT1" --bind 127.0.0.1 --directory "$T/ch1" >"$T/http1" 2>&1 & PIDS+=("$!")
python3 -m http.server "$PORT2" --bind 127.0.0.1 --directory "$T/ch2" >"$T/http2" 2>&1 & PIDS+=("$!")
# Like GitHub releases: every path answers 302 to the real file on the first server.
PORT3=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 - "$PORT3" "$PORT1" >"$T/http3" 2>&1 <<'PY' & PIDS+=("$!")
import http.server, sys
port, target = int(sys.argv[1]), sys.argv[2]
class Redirect(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", f"http://127.0.0.1:{target}{self.path}")
        self.send_header("Content-Length", "0")
        self.end_headers()
http.server.HTTPServer(("127.0.0.1", port), Redirect).serve_forever()
PY
for _ in {1..100}; do curl -fsS "http://127.0.0.1:$PORT1/" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$PORT2/" >/dev/null 2>&1 && break; sleep .05; done
make_manifest() {
 python3 - "$T" <<'PY'
import hashlib,json,os,sys
t=sys.argv[1]; content=b'local package fixture\n'; m={'schema':2,'generated':'2026-10-15T00:00:00Z','packages':{},'data':{'chnroute4':{'version':'v1','url':'data.gz','sha256':'a'*64,'size':1,'content_sha256':'b'*64,'lines':1}}}
for name,version,old in [('xray-core','26.10.10-r1','26.7.28-r1'),('aether-proxy','0.2.0-r1','0.1.0-r1'),('luci-app-aether-proxy','0.2.0-r1','0.1.0-r1'),('luci-i18n-aether-proxy-zh-cn','0.2.0-r1','0.1.0-r1')]:
  releases=[]
  for ver in (version,old):
   a={}
   for arch in ('aarch64_generic','all'):
    a[arch]={}
    for ext in ('ipk','apk'):
     fn=f'{name}_{ver}_{arch}.{ext}' if ext=='ipk' else f'{name}-{ver}_{arch}.apk'
     for d in ('ch1','ch2'): open(os.path.join(t,d,fn),'wb').write(content)
     a[arch][ext]={'url':fn,'sha256':hashlib.sha256(content).hexdigest(),'size':len(content)}
   releases.append({'version':ver,'assets':a})
  m['packages'][name]={'current':releases[0],'previous':releases[1]}
for d in ('ch1','ch2'): json.dump(m,open(os.path.join(t,d,'manifest.json'),'w'))
PY
 "$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
 "$USIGN" -S -m "$T/ch2/manifest.json" -s "$T/sec" >/dev/null 2>&1
}
make_manifest
cat > "$T/bin/aether-proxy" <<WRAPPER
#!/bin/sh
exec "$UCODE" -S "$ENTRY" -- "\$@"
WRAPPER
chmod +x "$T/bin/aether-proxy"
run_check() { ap update check --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr"; }
export UPDATE_INSTALLED_MODE=normal UPDATE_INSTALLED_VERSION=26.9.30-r5
# 1 opkg check, versions/newer/architecture/pm/asset and status linkage
rm "$T/bin/apk"
out=$(run_check); expect 'signed opkg check succeeds' 0 "$?"; expect 'opkg stderr empty' '' "$(cat "$T/stderr")"
expect 'architecture is stored' aarch64_generic "$(get "$out" arch)"; expect 'opkg selected' opkg "$(get "$out" pm)"
expect 'installed package version' 26.9.30-r5 "$(get "$out" packages.xray-core.installed)"; expect 'available package version' 26.10.10-r1 "$(get "$out" packages.xray-core.available)"
expect 'newer version detected' true "$(get "$out" packages.xray-core.newer)"; expect 'opkg asset key' xray-core_26.10.10-r1_aarch64_generic.ipk "$(get "$out" packages.xray-core.asset)"
status=$(ap status --json --run-dir "$T/run"); expect 'status reads updates.json' true "$(python3 -c 'import json,sys;print(str(json.load(sys.stdin)["updates_available"]==json.load(open(sys.argv[1]))).lower())' "$T/run/updates.json" <<<"$status")"
# T8.9b: sign each variant so asset selection, not signature rejection, is tested.
expect 'T8.9b previous opkg asset yields version' 26.7.28-r1 "$(get "$out" packages.xray-core.previous)"
for variant in null arch ipk-only; do
	make_manifest
	python3 - "$T" "$variant" <<'PY'
import json, os, sys
for channel in ('ch1', 'ch2'):
    path = os.path.join(sys.argv[1], channel, 'manifest.json')
    manifest = json.load(open(path))
    previous = manifest['packages']['xray-core']['previous']
    if sys.argv[2] == 'null':
        manifest['packages']['xray-core']['previous'] = None
    elif sys.argv[2] == 'arch':
        previous['assets'] = {'other_arch': previous['assets']['aarch64_generic']}
    else:
        for assets in previous['assets'].values():
            del assets['apk']
    json.dump(manifest, open(path, 'w'))
PY
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
	if [ "$variant" = ipk-only ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	out=$(run_check)
	expect "T8.9b previous $variant returns null" '<null>' "$(get "$out" packages.xray-core.previous)"
	if [ "$variant" = ipk-only ]; then
		rm "$T/bin/apk"
	fi
done
make_manifest
# T8.8 scenario 1: baseline equality must work without a downloaded hash.
printf '192.0.2.0/24\n' > "$T/root/usr/share/aether-proxy/data/chnroute4.txt"
base_hash=$(sha256sum "$T/root/usr/share/aether-proxy/data/chnroute4.txt" | cut -d' ' -f1)
python3 - "$T/ch1/manifest.json" "$base_hash" <<'PY'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
m['data']['chnroute4']['content_sha256']=sys.argv[2]
json.dump(m,open(p,'w'))
PY
"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
out=$(run_check)
expect 'T8.8 baseline equal without sha256 is unchanged' false "$(get "$out" data.chnroute4.changed)"
printf '198.51.100.0/24\n' > "$T/root/usr/share/aether-proxy/data/chnroute4.txt"
out=$(run_check)
expect 'T8.8 baseline different without sha256 is changed' true "$(get "$out" data.chnroute4.changed)"
printf '%s\n' "$base_hash" > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(run_check)
expect 'T8.8 downloaded sha256 overrides different baseline' false "$(get "$out" data.chnroute4.changed)"
printf '%064d\n' 0 > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(run_check)
expect 'T8.8 different downloaded sha256 reports changed' true "$(get "$out" data.chnroute4.changed)"
rm "$T/root/etc/aether-proxy/data/chnroute4.sha256"
make_manifest
# 2 apk precedence and apk version/asset parsing
cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"; chmod +x "$T/bin/apk"
export UPDATE_APK_VERSION=26.9.30-r5; out=$(run_check); expect 'apk check succeeds' 0 "$?"; expect 'apk preferred' apk "$(get "$out" pm)"
expect 'apk installed version' 26.9.30-r5 "$(get "$out" packages.xray-core.installed)"; expect 'apk asset key' xray-core-26.10.10-r1_aarch64_generic.apk "$(get "$out" packages.xray-core.asset)"; rm "$T/bin/apk"
expect 'T8.9b previous apk asset yields version' 26.7.28-r1 "$(get "$out" packages.xray-core.previous)"
# 3 tampered first address falls through
printf ' ' >> "$T/ch1/manifest.json"; out=$(run_check); expect 'tampered first address falls through' 0 "$?"
expect 'second channel selected' "http://127.0.0.1:$PORT2/" "$(get "$out" url)"; grep -q '"code": "MANIFEST_BAD_SIGNATURE"' "$T/run/events.jsonl" && ok 'bad signature event logged' || bad 'bad signature event logged'; make_manifest
# 4 all bad signatures fail rc 4 without replacing updates.json
cp "$T/run/updates.json" "$T/old"; printf x >> "$T/ch1/manifest.json"; printf x >> "$T/ch2/manifest.json"; out=$(run_check); expect 'all bad signatures exit 4' 4 "$?"
expect 'failure code is signature' MANIFEST_BAD_SIGNATURE "$(get "$out" code)"; cmp -s "$T/old" "$T/run/updates.json" && ok 'failed check preserves updates.json' || bad 'failed check preserves updates.json'; make_manifest
# 5 unknown key is not trusted
"$USIGN" -G -p "$T/otherpub" -s "$T/othersec" >/dev/null 2>&1; "$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/othersec" >/dev/null 2>&1
out=$(run_check); expect 'unknown signer falls back' "http://127.0.0.1:$PORT2/" "$(get "$out" url)"; make_manifest
# 6 invalid JSON and schema=1 use next address
printf '{broken' > "$T/ch1/manifest.json"; printf bad > "$T/ch1/manifest.json.sig"; out=$(run_check); expect 'non-JSON manifest fallback' "http://127.0.0.1:$PORT2/" "$(get "$out" url)"
python3 -c 'import json,sys;json.dump({"schema":1},open(sys.argv[1],"w"))' "$T/ch1/manifest.json"; "$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
out=$(run_check); expect 'schema 1 manifest fallback' "http://127.0.0.1:$PORT2/" "$(get "$out" url)"; make_manifest
# 7 architecture missing is nonfatal and event logged
python3 - "$T/ch1/manifest.json" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p))
for v in m['packages'].values():v['current']['assets'].pop('aarch64_generic');v['current']['assets'].pop('all')
json.dump(m,open(p,'w'))
PY
"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1; cp "$T/ch1/manifest.json" "$T/ch2/manifest.json"; cp "$T/ch1/manifest.json.sig" "$T/ch2/manifest.json.sig"
out=$(run_check); expect 'unsupported architecture check succeeds' 0 "$?"; expect 'unsupported arch package not newer' false "$(get "$out" packages.xray-core.newer)"
grep -q '"code": "ARCH_UNSUPPORTED"' "$T/run/events.jsonl" && ok 'ARCH_UNSUPPORTED logged' || bad 'ARCH_UNSUPPORTED logged'; make_manifest
# 8 uninstalled package and both numeric/revision comparisons
export UPDATE_INSTALLED_MODE=missing; out=$(run_check); expect 'missing package check succeeds' 0 "$?"; expect 'missing version is null' '<null>' "$(get "$out" packages.xray-core.installed)"; expect 'missing package is not newer' false "$(get "$out" packages.xray-core.newer)"
export UPDATE_INSTALLED_MODE=versions UPDATE_INSTALLED_VERSION=26.9.30-r5; out=$(run_check); expect '26.10.10-r1 > 26.9.30-r5' true "$(get "$out" packages.xray-core.newer)"
export UPDATE_INSTALLED_VERSION=26.10.10-r0; out=$(run_check); expect 'r1 > r0' true "$(get "$out" packages.xray-core.newer)"
python3 - "$T" <<'PY'
import json,os,sys
t=sys.argv[1]; p=os.path.join(t,'ch1','manifest.json'); m=json.load(open(p)); pkg=m['packages']['xray-core']['current']; pkg['version']='26.9.30-r6'
for arch,types in pkg['assets'].items():
 for pm,asset in types.items():
  old=asset['url']; new=old.replace('26.10.10-r1','26.9.30-r6'); asset['url']=new
  for d in ('ch1','ch2'): open(os.path.join(t,d,new),'wb').write(open(os.path.join(t,d,old),'rb').read())
json.dump(m,open(p,'w'))
PY
"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
export UPDATE_INSTALLED_VERSION=26.9.30-r5; out=$(run_check)
expect '26.9.30-r6 > 26.9.30-r5' true "$(get "$out" packages.xray-core.newer)"; make_manifest
# T8.21: use signed, usable assets and fresh run directories so cached results cannot
# suppress a spurious UPDATE_AVAILABLE event. Keep private comparison helpers private.
version_case=0
while IFS='|' read -r package installed available newer label; do
	version_case=$((version_case + 1))
	version_run="$T/version-$version_case"
	mkdir -p "$version_run"
	make_manifest
	python3 - "$T" "$package" "$available" <<'PY'
import json, os, sys
root, package, available = sys.argv[1:]
for channel in ('ch1', 'ch2'):
    path = os.path.join(root, channel, 'manifest.json')
    with open(path) as source:
        manifest = json.load(source)
    entry = manifest['packages'][package]
    entry['current']['version'] = available
    # Discovery only needs a usable asset; leave its existing filename and hash intact.
    manifest['packages'] = {package: entry}
    with open(path, 'w') as target:
        json.dump(manifest, target)
PY
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
	export UPDATE_INSTALLED_VERSION="$installed"
	out=$(ap update check --json --confdir "$T/conf" --run-dir "$version_run" \
		--sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr")
	expect "T8.21 $label check succeeds" 0 "$?"
	expect "T8.21 $label installed version" "$installed" "$(get "$out" "packages.$package.installed")"
	expect "T8.21 $label channel version" "$available" "$(get "$out" "packages.$package.available")"
	asset=$(get "$out" "packages.$package.asset")
	if [ -n "$asset" ] && [ "$asset" != '<null>' ]; then
		ok "T8.21 $label has usable asset"
	else
		bad "T8.21 $label has usable asset"
	fi
	expect "T8.21 $label newer=$newer" "$newer" "$(get "$out" "packages.$package.newer")"
	events=$(python3 - "$version_run/events.jsonl" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
print(sum(event['code'] == 'UPDATE_AVAILABLE' for event in events))
PY
	)
	if [ "$newer" = true ]; then
		expected_events=1
	else
		expected_events=0
	fi
	expect "T8.21 $label UPDATE_AVAILABLE count" "$expected_events" "$events"
done <<'CASES'
xray-core|26.9.30-5|26.9.30-r1|false|plain release 5 beats r1
xray-core|26.9.30-5|26.10.10-r1|true|upstream beats plain release 5
xray-core|26.9.30-r5|26.9.30-6|true|plain release 6 beats r5
xray-core|26.9.30-r5|26.10.10-r1|true|legacy upstream ordering
xray-core|26.9.30|26.9.30-r1|true|missing release is zero before r1
xray-core|26.9.30-r1|26.9.30|false|missing release is zero after r1
xray-core|26.9.30|26.9.30-1|true|missing release is zero before plain 1
xray-core|26.9.30-1|26.9.30|false|missing release is zero after plain 1
xray-core|26.9.30-5|26.9.30-r5|false|equal plain and r releases
xray-core|26.9.30-r5|26.9.30-5|false|equal r and plain releases
luci-i18n-aether-proxy-zh-cn|26.290.04520~640694b|26.290.04520~fffffff|false|i18n hash ignored
luci-i18n-aether-proxy-zh-cn|26.290.04520~640694b|26.291.00001~0000000|true|i18n higher numeric segment
luci-i18n-aether-proxy-zh-cn|26.290.04520~640694b|26.289.99999~fffffff|false|i18n lower numeric segment
CASES
make_manifest
export UPDATE_INSTALLED_VERSION=26.9.30-r5
# 9 asset helper checksum failure cleanup and test-only low-space hook
cat > "$T/asset.uc" <<'UCODE'
'use strict';
import * as update from 'aetherproxy.update';
print(sprintf('%.J', update.download_asset({sys_root:ARGV[0],bin_dir:ARGV[1]},ARGV[2],{url:ARGV[3],size:+ARGV[4],sha256:ARGV[5]},'asset-test')),'\n');
UCODE
asset=xray-core_26.10.10-r1_aarch64_generic.ipk; size=$(wc -c < "$T/ch1/$asset" | tr -d ' '); hash=$(sha256sum "$T/ch1/$asset"|cut -d' ' -f1)
export AETHER_PROXY_TEST_TMP_FREE=99999999; result=$("$UCODE" "$T/asset.uc" -- "$T/root" "$T/bin" "http://127.0.0.1:$PORT1" "$asset" "$size" 0000000000000000000000000000000000000000000000000000000000000000)
expect 'asset checksum mismatch rejected' UPDATE_VERIFY_FAILED "$(get "$result" code)"; [ ! -e "$T/root/tmp/aether-proxy-dl/asset-test" ] && ok 'bad asset removed' || bad 'bad asset removed'
export AETHER_PROXY_TEST_TMP_FREE=1; result=$("$UCODE" "$T/asset.uc" -- "$T/root" "$T/bin" "http://127.0.0.1:$PORT1" "$asset" "$size" "$hash"); expect 'low space returns NO_SPACE' NO_SPACE "$(get "$result" code)"; unset AETHER_PROXY_TEST_TMP_FREE
# A bad first mirror is discarded and the following address may supply the checked asset.
python3 - "$T/ch1/$asset" "$size" <<'PY'
import sys
open(sys.argv[1],'wb').write(b'X'*int(sys.argv[2]))
PY
cat > "$T/asset-fallback.uc" <<'UCODE'
'use strict';
import * as update from 'aetherproxy.update';
print(sprintf('%.J', update.download_asset({sys_root:ARGV[0],bin_dir:ARGV[1]},[ARGV[2],ARGV[3]],
	{url:ARGV[4],size:+ARGV[5],sha256:ARGV[6]},'asset-fallback')),'\n');
UCODE
result=$("$UCODE" "$T/asset-fallback.uc" -- "$T/root" "$T/bin" "http://127.0.0.1:$PORT1" "http://127.0.0.1:$PORT2" "$asset" "$size" "$hash")
expect 'bad first asset mirror falls back' true "$(get "$result" ok)"
# Unknown residue from the pre-package update design remains ignored by config validation.
mkdir -p "$T/legacy-conf" "$T/legacy-data" "$T/legacy-base" "$T/legacy-custom"
cat > "$T/legacy-conf/aetherproxy" <<'UCI'
config update 'update'
	option chinadns_auto 'off'
UCI
for f in gfwlist chnlist apple chnroute4 gfw_static4; do : > "$T/legacy-base/$f.txt"; done
out=$(ap check --json --no-precheck --confdir "$T/legacy-conf" --data-dir "$T/legacy-data" --baseline-dir "$T/legacy-base" --custom-dir "$T/legacy-custom" --run-dir "$T/legacy-run")
expect 'legacy chinadns_auto does not fail check' 0 "$?"
expect 'legacy chinadns_auto check returns ok' true "$(get "$out" ok)"
# T7.4 package installation uses only signed local assets and package-manager substitutes.
cat > "$T/root/etc/init.d/aether-proxy" <<'INIT'
#!/bin/sh
printf '%s\n' "$*" >> "$UPDATE_INIT_CALLS"
if [ "$1" = restart ]; then
	case "${UPDATE_INIT_FAIL:-none}" in
		always) exit 7 ;;
		first)
			if [ "$(wc -l < "$UPDATE_INIT_CALLS")" -eq 1 ]; then exit 7; fi
			;;
	esac
	printf '{"state":"running"}\n' > "$UPDATE_INIT_STATE_FILE"
fi
exit 0
INIT
cat > "$T/bin/ubus" <<'UBUS'
#!/bin/sh
# JSON may be formatted across lines; keep one record per invocation, not per line.
python3 - "$@" >> "$UPDATE_SIGNAL_CALLS" <<'PY'
import json, sys
assert sys.argv[1:4] == ['call', 'service', 'signal'] and len(sys.argv) == 5
print('call service signal ' + json.dumps(json.loads(sys.argv[4])))
PY
rc=$?
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
if [ "${UPDATE_SIGNAL_EXIT:-0}" != 0 ]; then exit "$UPDATE_SIGNAL_EXIT"; fi
if [ "${UPDATE_SIGNAL_NO_PROBE:-0}" != 1 ]; then
 python3 - "$UPDATE_STATE_FILE" <<'PY'
import json,sys,time
# Strictly later than any probe already recorded, even within the same second.
p=sys.argv[1]; x=json.load(open(p)); last=(x.get('last_probe') or {}).get('at') or 0
x['last_probe']={'ok':True,'at':max(int(time.time()),last)+1}; json.dump(x,open(p,'w'))
PY
fi
exit 0
UBUS
chmod +x "$T/root/etc/init.d/aether-proxy" "$T/bin/ubus"
export PATH="$T/bin:$PATH"
export UPDATE_PACKAGE_CALLS="$T/package-calls" UPDATE_SIGNAL_CALLS="$T/signals" UPDATE_INIT_CALLS="$T/init-calls"
export UPDATE_PACKAGE_STATE_FILE="$T/installed-version" UPDATE_STATE_FILE="$T/run/state.json" UPDATE_INIT_STATE_FILE="$T/run/state.json"
export AETHER_PROXY_TEST_TMP_FREE=999999999
printf '%s\n' 26.7.28-r1 > "$UPDATE_PACKAGE_STATE_FILE"
printf '{"state":"running","last_probe":{"ok":true,"at":1},"components":{"xray":{"path":"xray"}}}\n' > "$UPDATE_STATE_FILE"
out=$(ap update package xray-core --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin")
expect 'opkg xray package install succeeds' 0 "$?"
expect 'installed xray package version is reported' 26.10.10-r1 "$(get "$out" to)"
expect 'opkg selected package asset' xray-core_26.10.10-r1_aarch64_generic.ipk "$(awk '{print $NF}' "$UPDATE_PACKAGE_CALLS" | tail -1 | sed 's@.*/@@')"
# procd's `service signal` policy (service/service.c): name string, signal int32 (SIGUSR2 = 12);
# an `instance` that does not exist makes procd answer NOT_FOUND, so none is sent.
python3 - "$UPDATE_SIGNAL_CALLS" <<'PY' && ok 'xray install sends SIGUSR2 via procd' || bad 'xray install sends SIGUSR2 via procd'
import json,sys
t=open(sys.argv[1]).read(); assert t.startswith('call service signal '), t
r=json.loads(t[len('call service signal '):]); assert r=={'name':'aether-proxy','signal':12}, r
PY
grep -q 'UPDATE_INSTALLED' "$T/run/events.jsonl" && ok 'successful package logs UPDATE_INSTALLED' || bad 'successful package logs UPDATE_INSTALLED'
# T9.38: grouped requests need independent versions; one shared state file would
# make the page appear installed as soon as the backend is installed.
legacy_group_inventory() {
	export UPDATE_PACKAGE_STATE_DIR="$T/legacy-group-inventory"
	mkdir -p "$UPDATE_PACKAGE_STATE_DIR"
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
}
# apk command line and installed version handling
legacy_group_inventory
cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"; chmod +x "$T/bin/apk"; : > "$UPDATE_PACKAGE_CALLS"
printf '%s\n' 0.1.0-r1 > "$UPDATE_PACKAGE_STATE_FILE"
out=$(ap update package luci-app-aether-proxy --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin")
expect 'apk package install succeeds' 0 "$?"
grep -q 'add --allow-untrusted .*luci-app-aether-proxy-0.2.0-r1_aarch64_generic.apk' "$UPDATE_PACKAGE_CALLS" && ok 'apk uses --allow-untrusted and selected asset' || bad 'apk uses --allow-untrusted and selected asset'
rm "$T/bin/apk"
unset UPDATE_PACKAGE_STATE_DIR
# T9.6: real signed installs refresh installed versions after the stub touches the
# package database. A later external package install invalidates only the presentation.
for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
		database="$T/root/lib/apk/db/installed"
	else
		database="$T/root/usr/lib/opkg/status"
	fi
	mkdir -p "$(dirname "$database")"
	touch -d @1760400000 "$database"
	export UPDATE_PACKAGE_DB_FILE="$database"
	legacy_group_inventory
	printf '%s\n' 0.1.0-r1 > "$UPDATE_PACKAGE_STATE_FILE"
	out=$(ap update package luci-app-aether-proxy --json --confdir "$T/conf" \
		--run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin")
	expect "T9.6 $manager signed install succeeds" 0 "$?"
	status=$(ap status --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" --bin-dir "$T/bin")
	expect "T9.6 $manager post-install status succeeds" 0 "$?"
	expect "T9.6 $manager post-install cache remains fresh" "$manager" "$(get "$status" updates_available.pm)"
	expect "T9.6 $manager post-install installed version refreshed" 0.2.0-r1 \
		"$(get "$status" updates_available.packages.luci-app-aether-proxy.installed)"
	if python3 - "$database" "$T/run/updates.json" <<'PY'
import json, os, sys
mtime = int(os.stat(sys.argv[1]).st_mtime)
checked = json.load(open(sys.argv[2]))['checked']
assert 1760400000 < mtime <= checked, (mtime, checked)
PY
	then
		ok "T9.6 $manager install touched database before checked"
	else
		bad "T9.6 $manager install touched database before checked"
	fi
	cp "$T/run/updates.json" "$T/post-install-cache"
	# Simulate another opkg/apk install: no new check, only database mtime changes.
	checked=$(get "$status" updates_available.checked)
	touch -d "@$((checked + 10))" "$database"
	status=$(ap status --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" --bin-dir "$T/bin")
	expect "T9.6 $manager external install status succeeds" 0 "$?"
	expect "T9.6 $manager external install hides cache" '<null>' "$(get "$status" updates_available)"
	if python3 - "$status" <<'PY'
import json, sys
assert all(n['code'] != 'UPDATE_AVAILABLE' for n in json.loads(sys.argv[1])['notices'])
PY
	then
		ok "T9.6 $manager external install hides update notices"
	else
		bad "T9.6 $manager external install hides update notices"
	fi
	cmp -s "$T/post-install-cache" "$T/run/updates.json" \
		&& ok "T9.6 $manager external install preserves cache bytes" \
		|| bad "T9.6 $manager external install preserves cache bytes"
	unset UPDATE_PACKAGE_DB_FILE UPDATE_PACKAGE_STATE_DIR
	rm "$database"
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done

# T9.29 reuses the signed manifests, package-manager stubs and restart fixture above.
source "$ROOT/tests/update/package-policy.sh"
source "$ROOT/tests/update/update-together.sh"

# Invalid hashes and unsupported architectures never reach the package manager.
: > "$UPDATE_PACKAGE_CALLS"
python3 - "$T/ch1/manifest.json" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['packages']['xray-core']['current']['assets']['aarch64_generic']['ipk']['sha256']='0'*64;json.dump(m,open(p,'w'))
PY
"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1; cp "$T/ch1/manifest.json" "$T/ch2/manifest.json"; cp "$T/ch1/manifest.json.sig" "$T/ch2/manifest.json.sig"
out=$(ap update package xray-core --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect 'bad package hash fails' UPDATE_VERIFY_FAILED "$(get "$out" code)"
[ ! -s "$UPDATE_PACKAGE_CALLS" ] && ok 'bad hash never invokes package manager' || bad 'bad hash never invokes package manager'
make_manifest
# Snapshot requests before removing both architecture keys.
asset_requests_before=$(grep -h 'GET /xray-core_26.10.10-r1_aarch64_generic.ipk' "$T/http1" "$T/http2" | wc -l | tr -d ' ')
python3 - "$T/ch1/manifest.json" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['packages']['xray-core']['current']['assets'].pop('aarch64_generic');m['packages']['xray-core']['current']['assets'].pop('all');json.dump(m,open(p,'w'))
PY
"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1; cp "$T/ch1/manifest.json" "$T/ch2/manifest.json"; cp "$T/ch1/manifest.json.sig" "$T/ch2/manifest.json.sig"
: > "$UPDATE_PACKAGE_CALLS"; out=$(ap update package xray-core --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect 'unsupported package architecture reports ARCH_UNSUPPORTED' ARCH_UNSUPPORTED "$(get "$out" code)"
[ ! -s "$UPDATE_PACKAGE_CALLS" ] && ok 'unsupported architecture skips package manager' || bad 'unsupported architecture skips package manager'
asset_requests_after=$(grep -h 'GET /xray-core_26.10.10-r1_aarch64_generic.ipk' "$T/http1" "$T/http2" | wc -l | tr -d ' ')
expect 'unsupported architecture does not download an asset' "$asset_requests_before" "$asset_requests_after"
make_manifest
# Verification failure rolls back to previous; null previous never triggers a speculative install.
: > "$UPDATE_PACKAGE_CALLS"; export UPDATE_SIGNAL_NO_PROBE=1 AETHER_PROXY_TEST_UPDATE_WAIT_SECS=0
printf '%s\n' 26.7.28-r1 > "$UPDATE_PACKAGE_STATE_FILE"
out=$(ap update package xray-core --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect 'failed health check returns verification failure' UPDATE_VERIFY_FAILED "$(get "$out" code)"
expect 'failed health check reports rollback' true "$(get "$out" rolled_back)"
grep -q -- '--force-downgrade .*26.7.28-r1' "$UPDATE_PACKAGE_CALLS" && ok 'opkg rollback forces downgrade to previous' || bad 'opkg rollback forces downgrade to previous'
grep -q 'UPDATE_ROLLED_BACK' "$T/run/events.jsonl" && ok 'rollback logs UPDATE_ROLLED_BACK' || bad 'rollback logs UPDATE_ROLLED_BACK'
python3 - "$T/ch1/manifest.json" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['packages']['xray-core']['previous']=None;json.dump(m,open(p,'w'))
PY
"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1; cp "$T/ch1/manifest.json" "$T/ch2/manifest.json"; cp "$T/ch1/manifest.json.sig" "$T/ch2/manifest.json.sig"
: > "$UPDATE_PACKAGE_CALLS"; out=$(ap update package xray-core --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect 'null previous does not roll back' false "$(get "$out" rolled_back)"
expect 'null previous reports no rollback version' '无可回滚的版本' "$(get "$out" detail)"
expect 'null previous performs only one install' 1 "$(wc -l < "$UPDATE_PACKAGE_CALLS" | tr -d ' ')"
make_manifest; unset UPDATE_SIGNAL_NO_PROBE AETHER_PROXY_TEST_UPDATE_WAIT_SECS
# Explicit previous and aether-proxy service restart.
: > "$UPDATE_PACKAGE_CALLS"; printf '%s\n' 26.10.10-r1 > "$UPDATE_PACKAGE_STATE_FILE"
out=$(ap update package xray-core --previous --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect '--previous install succeeds' 0 "$?"
grep -q -- '--force-downgrade .*26.7.28-r1' "$UPDATE_PACKAGE_CALLS" && ok '--previous installs previous with force-downgrade' || bad '--previous installs previous with force-downgrade'
printf '{"state":"running"}\n' > "$UPDATE_STATE_FILE"; : > "$UPDATE_INIT_CALLS"
printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_FILE"
out=$(ap update package aether-proxy --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect 'aether-proxy package update succeeds' 0 "$?"
grep -q '^restart$' "$UPDATE_INIT_CALLS" && ok 'aether-proxy update invokes init restart' || bad 'aether-proxy update invokes init restart'
out=$(ap update package unknown --json); expect 'unknown package is USAGE' USAGE "$(get "$out" code)"

# T8.23: verification must really fail after installation; then count activation calls
# against the pre-update state, even if restart changes state.json during verification.
cat > "$T/bin/xray" <<'XRAY'
#!/bin/sh
printf 'Xray wrong-version\n'
XRAY
chmod +x "$T/bin/xray"
rollback_case() {
	local label=$1 package=$2 state=$3 previous=$4 init_failure=$5 restarts=$6 signals=$7
	local args=() rc
	if [ "$previous" = yes ]; then args+=(--previous); fi
	: > "$UPDATE_PACKAGE_CALLS"
	: > "$UPDATE_INIT_CALLS"
	: > "$UPDATE_SIGNAL_CALLS"
	: > "$T/run/events.jsonl"
	printf '%s\n' 0.1.0-r1 > "$UPDATE_PACKAGE_STATE_FILE"
	if [ "$state" = missing ]; then
		rm -f "$UPDATE_STATE_FILE"
	else
		printf '{"state":"%s","last_probe":{"ok":true,"at":1}}\n' "$state" > "$UPDATE_STATE_FILE"
	fi
	export UPDATE_INIT_FAIL="$init_failure" UPDATE_SIGNAL_NO_PROBE=1 AETHER_PROXY_TEST_UPDATE_WAIT_SECS=0
	out=$(ap update package "$package" "${args[@]}" --json --confdir "$T/conf" \
		--run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr")
	rc=$?
	expect "T8.23 $label exit 1" 1 "$rc"
	expect "T8.23 $label remains UPDATE_VERIFY_FAILED" UPDATE_VERIFY_FAILED "$(get "$out" code)"
	expect "T8.23 $label rolled_back true" true "$(get "$out" rolled_back)"
	expect "T8.23 $label restart count" "$restarts" "$(wc -l < "$UPDATE_INIT_CALLS" | tr -d ' ')"
	expect "T8.23 $label SIGUSR2 count" "$signals" "$(wc -l < "$UPDATE_SIGNAL_CALLS" | tr -d ' ')"
	expect "T8.23 $label installs exactly twice" 2 "$(wc -l < "$UPDATE_PACKAGE_CALLS" | tr -d ' ')"
	python3 - "$T/run/events.jsonl" "$UPDATE_SIGNAL_CALLS" "$UPDATE_PACKAGE_CALLS" \
		"$UPDATE_PACKAGE_STATE_FILE" "$package" "$previous" "$init_failure" "$UPDATE_INIT_CALLS" <<'PY'
import json, pathlib, sys
(events_file, signals_file, packages_file, installed_file, package, previous, init_failure, init_file) = sys.argv[1:]
events = [json.loads(line) for line in pathlib.Path(events_file).read_text().splitlines()]
update_events = [event['code'] for event in events
                 if event['code'] in ('UPDATE_VERIFY_FAILED', 'UPDATE_ROLLED_BACK', 'UPDATE_INSTALLED')]
assert update_events == ['UPDATE_VERIFY_FAILED', 'UPDATE_ROLLED_BACK'], update_events
for line in pathlib.Path(signals_file).read_text().splitlines():
    assert line.startswith('call service signal '), line
    request = json.loads(line[len('call service signal '):])
    assert request == {'name': 'aether-proxy', 'signal': 12}, request
    assert type(request['signal']) is int
current, old = ('26.10.10-r1', '26.7.28-r1') if package == 'xray-core' else ('0.2.0-r1', '0.1.0-r1')
expected = current if previous == 'yes' else old
assert pathlib.Path(installed_file).read_text().strip() == expected
calls = pathlib.Path(packages_file).read_text().splitlines()
assert (old if previous == 'yes' else current) in calls[0], calls
assert expected in calls[1] and '--force-downgrade' in calls[1], calls
if init_failure == 'always' and len(pathlib.Path(init_file).read_text().splitlines()) == 2:
    rollback_at = next(i for i, event in enumerate(events) if event['code'] == 'UPDATE_ROLLED_BACK')
    assert any(event['code'] == 'CMD_FAILED' and event['args']['rc'] == 7
               and 'restart' in event['args']['cmd'] for event in events[rollback_at + 1:])
PY
	if [ "$?" -eq 0 ]; then
		ok "T8.23 $label ordered events, restored asset and activation payload"
	else
		bad "T8.23 $label ordered events, restored asset and activation payload"
	fi
	unset UPDATE_INIT_FAIL UPDATE_SIGNAL_NO_PROBE AETHER_PROXY_TEST_UPDATE_WAIT_SECS
}
while IFS='|' read -r label package state previous init_failure restarts signals; do
	rollback_case "$label" "$package" "$state" "$previous" "$init_failure" "$restarts" "$signals"
done <<'ROLLBACK_CASES'
running rollback|aether-proxy|running|no|first|2|0
stopped rollback|aether-proxy|stopped|no|first|1|0
rollback restart fails|aether-proxy|running|no|always|2|0
starting rollback|aether-proxy|starting|no|first|2|0
degraded rollback|aether-proxy|degraded|no|first|2|0
error rollback|aether-proxy|error|no|first|1|0
missing state rollback|aether-proxy|missing|no|first|1|0
failsafe rollback|aether-proxy|failsafe|no|first|1|0
xray running rollback|xray-core|running|no|none|0|2
xray stopped rollback|xray-core|stopped|no|none|0|0
xray previous restores current|xray-core|running|yes|none|0|2
xray starting rollback|xray-core|starting|no|none|0|1
xray degraded rollback|xray-core|degraded|no|none|0|1
ROLLBACK_CASES
# A failed rollback signal is also best effort; there is no second verification pass.
export UPDATE_SIGNAL_EXIT=9
rollback_case 'xray rollback signal fails' xray-core running no none 0 2
python3 - "$T/run/events.jsonl" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
rollback_at = next(i for i, event in enumerate(events) if event['code'] == 'UPDATE_ROLLED_BACK')
assert any(event['code'] == 'CMD_FAILED' and event['args']['rc'] == 9 for event in events[rollback_at + 1:])
PY
if [ "$?" -eq 0 ]; then
	ok 'T8.23 rollback signal failure logs CMD_FAILED'
else
	bad 'T8.23 rollback signal failure logs CMD_FAILED'
fi
unset UPDATE_SIGNAL_EXIT
# T9.38: app requests now check the backend, so its mismatch recovers with restart.
# Standalone i18n still rolls back without activating the service.
export UPDATE_STATUS_VERSION=0.0.0-r0
rollback_case 'luci app group backend mismatch activates recovery' luci-app-aether-proxy running no none 2 0
rollback_case 'luci i18n rollback has no activation' luci-i18n-aether-proxy-zh-cn running no none 0 0
unset UPDATE_STATUS_VERSION
rm "$T/bin/xray"
# Inspect the shared helper's actual sys.run options without sleeping for 90 seconds.
cat > "$T/restart-timeout.uc" <<'UCODE'
'use strict';
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
let source = fs.readfile(ARGV[0]);
let start = index(source, 'function restart_service(');
let end = index(source, '\nfunction activate_rollback(');
let factory = loadstring('(function(sys, C, system_path) { ' + substr(source, start, end - start) +
	' return restart_service({ root: "/fixture" }); })')();
let called = null;
let ok = factory({ run: (argv, opts) => { called = { argv, opts }; return { code: 0 }; } },
	C, (root, path) => root + path);
print(sprintf('%.J', { ok, called, constant: C.UPDATE_RESTART_TIMEOUT_SECS }));
UCODE
out=$("$UCODE" "$T/restart-timeout.uc" -- "$ROOT/aether-proxy/src/lib/update.uc")
expect 'T8.23 restart timeout constant is 90' 90 "$(get "$out" constant)"
expect 'T8.23 shared restart helper passes 90 seconds to sys.run' 90 "$(get "$out" called.opts.timeout)"
expect 'T8.23 shared restart helper invokes init restart' restart "$(get "$out" called.argv.1)"

# 10 real update_check background job
export UPDATE_INSTALLED_MODE=normal UPDATE_INSTALLED_VERSION=26.9.30-r5
out=$(ap job start update check --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_check job starts' 0 "$?"; id=$(get "$out" job)
for _ in {1..200}; do js=$(ap job status "$id" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'update_check job completes' ok "$(get "$js" state)"; expect 'job result matches updates.json' true "$(python3 -c 'import json,sys;print(str(json.load(sys.stdin)["result"]==json.load(open(sys.argv[1]))).lower())' "$T/run/updates.json" <<<"$js")"
# update_package is a job kind and shares its busy lock with update_check.
out=$(ap job start update package luci-i18n-aether-proxy-zh-cn --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_package job starts' 0 "$?"; package_job=$(get "$out" job)
for _ in {1..300}; do js=$(ap job status "$package_job" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'update_package job completes' ok "$(get "$js" state)"
UPDATE_INSTALLED_SLEEP=2 out=$(ap job start update check --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'second update_check job starts' 0 "$?"; check_job=$(get "$out" job)
# BUSY needs the worker to have exec'd (job.uc matches its cmdline); wait for that, not a fixed sleep.
check_pid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$T/run/jobs/$check_job.json")
for _ in {1..100}; do tr '\0' ' ' < "/proc/$check_pid/cmdline" 2>/dev/null | grep -q "job run $check_job" && break; sleep .05; done
out=$(ap job start update package xray-core --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_package is excluded by shared update lock' 3 "$?"
unset UPDATE_INSTALLED_SLEEP
# Let the slow check finish: later scenarios run `update check` directly and need the lock.
for _ in {1..200}; do js=$(ap job status "$check_job" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'second update_check job completes' ok "$state"
# 11 data change is judged by content_sha256 (the local .sha256 holds the plain list's hash)
printf '%s\n' "$(printf 'b%.0s' $(seq 64))" > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(run_check); expect 'same content hash means unchanged data' false "$(get "$out" data.chnroute4.changed)"
printf '%s\n' "$(printf 'a%.0s' $(seq 64))" > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(run_check); expect 'the .gz hash is not mistaken for the content hash' true "$(get "$out" data.chnroute4.changed)"
rm -f "$T/root/etc/aether-proxy/data/chnroute4.sha256"

# T7.5 data assets are generated as gzip during the test; the signed manifest and all HTTP
# requests stay on the loopback fixture servers.
make_data_manifest() {
 python3 - "$T" "${1:-normal}" <<'PY'
import gzip,hashlib,json,os,sys
t,mode=sys.argv[1:]
contents={
 'chnroute4':b'10.0.0.0/8\n192.168.0.0/16\n',
 'gfwlist':b'example.com\nexample.net\n',
}
if mode in ('illegal','partial'):
 contents['chnroute4']=b'1.2.3.4/33\n'
if mode in ('hash','partial'):
 bad='f'*64
else: bad=None
entries={}
for name,plain in contents.items():
 fn=name+'-fixture.txt.gz'; compressed=gzip.compress(plain,mtime=0)
 for d in ('ch1','ch2'): open(os.path.join(t,d,fn),'wb').write(compressed)
 content_hash=hashlib.sha256(plain).hexdigest()
 if name=='chnroute4' and mode=='low': lines=10
 else: lines=len([x for x in plain.splitlines() if x and not x.startswith(b'#')])
 entries[name]={'version':content_hash[:12],'url':fn,'sha256':hashlib.sha256(compressed).hexdigest(),
                'size':len(compressed),'content_sha256':bad if name=='chnroute4' and bad else content_hash,'lines':lines}
m={'schema':2,'generated':'2026-10-15T00:00:00Z','packages':{},'data':entries}
for d in ('ch1','ch2'): json.dump(m,open(os.path.join(t,d,'manifest.json'),'w'))
if mode=='future':
 entries['chnroute6']=dict(entries['chnroute4'])
if mode in ('single','future'):
 for d in ('ch1','ch2'):
  m2=dict(m);m2['data']={k:v for k,v in entries.items() if k in ('chnroute4','chnroute6')};json.dump(m2,open(os.path.join(t,d,'manifest.json'),'w'))
PY
 "$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
 "$USIGN" -S -m "$T/ch2/manifest.json" -s "$T/sec" >/dev/null 2>&1
}
data_update() { ap update data --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr"; }
make_data_manifest single
base_content=$'10.0.0.0/8\n192.168.0.0/16\n'
printf '10.0.0.0/8\n' > "$T/root/usr/share/aether-proxy/data/chnroute4.txt"
printf 'baseline.example\n' > "$T/root/usr/share/aether-proxy/data/gfwlist.txt"
printf '%s\n' 'running' > "$T/state"
python3 - "$T/run/state.json" <<'PY'
import json,sys
json.dump({'state':'running'},open(sys.argv[1],'w'))
PY
# T9.11: use all five files so data status can inspect the complete inventory.
for name in chnlist apple gfw_static4; do
	: > "$T/root/usr/share/aether-proxy/data/$name.txt"
done
data_status() { ap data status --json --run-dir "$T/run" --sys-root "$T/root" 2>"$T/stderr"; }
manifest_hash=$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1]))["data"]["chnroute4"]["content_sha256"])' "$T/ch1/manifest.json")
out=$(run_check)
expect 'T9.11 check succeeds before data update' 0 "$?"
expect 'T9.11 check reports changed before data update' true "$(get "$out" data.chnroute4.changed)"
expect 'T9.11 check saves manifest content hash' "$manifest_hash" "$(get "$out" data.chnroute4.sha256)"
expect 'T9.11 updates.json saves manifest content hash' "$manifest_hash" \
	"$(get "$(< "$T/run/updates.json")" data.chnroute4.sha256)"
cp "$T/run/updates.json" "$T/live-cache-before"
status=$(data_status)
expect 'T9.11 pre-update data status succeeds' 0 "$?"
expect 'T9.11 pre-update data status changed true' true "$(get "$status" items.chnroute4.changed)"
# 12 one changed item writes validated text/hash, requests one reload, and emits DATA_UPDATED.
: > "$UPDATE_INIT_CALLS"; out=$(data_update); expect 'changed rule data update succeeds' 0 "$?"
expect 'changed item appears in updated list' chnroute4 "$(get "$out" updated.0)"
expect 'updated text is exact' "$(printf '10.0.0.0/8\n192.168.0.0/16')" "$(cat "$T/root/etc/aether-proxy/data/chnroute4.txt")"
expect 'content hash file is exact' "$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$T/root/etc/aether-proxy/data/chnroute4.txt")" "$(tr -d '\n' < "$T/root/etc/aether-proxy/data/chnroute4.sha256")"
expect 'running service reloaded once' reload "$(cat "$UPDATE_INIT_CALLS")"
grep -q '"code": "DATA_UPDATED"' "$T/run/events.jsonl" && ok 'DATA_UPDATED event logged' || bad 'DATA_UPDATED event logged'
# Do not check again: the cached boolean must still be true while live status is false.
cp "$T/run/events.jsonl" "$T/live-events-before"
status=$(data_status)
expect 'T9.11 post-update data status succeeds' 0 "$?"
expect 'T9.11 post-update data status immediately changed false' false "$(get "$status" items.chnroute4.changed)"
expect 'T9.11 data status stderr empty' '' "$(< "$T/stderr")"
expect 'T9.11 cached changed remains true without another check' true \
	"$(get "$(< "$T/run/updates.json")" data.chnroute4.changed)"
cmp -s "$T/live-cache-before" "$T/run/updates.json" \
	&& ok 'T9.11 update and status preserve check cache bytes' \
	|| bad 'T9.11 update and status preserve check cache bytes'
cmp -s "$T/live-events-before" "$T/run/events.jsonl" \
	&& ok 'T9.11 data status adds no events' \
	|| bad 'T9.11 data status adds no events'
# 13 no change preserves file mtimes and does not reload.
text_mtime=$(stat -c %y "$T/root/etc/aether-proxy/data/chnroute4.txt"); hash_mtime=$(stat -c %y "$T/root/etc/aether-proxy/data/chnroute4.sha256")
: > "$UPDATE_INIT_CALLS"; sleep 1; out=$(data_update); expect 'unchanged data update succeeds' 0 "$?"
expect 'unchanged item is reported' chnroute4 "$(get "$out" unchanged.0)"
expect 'unchanged text mtime preserved' "$text_mtime" "$(stat -c %y "$T/root/etc/aether-proxy/data/chnroute4.txt")"
expect 'unchanged hash mtime preserved' "$hash_mtime" "$(stat -c %y "$T/root/etc/aether-proxy/data/chnroute4.sha256")"
[ ! -s "$UPDATE_INIT_CALLS" ] && ok 'unchanged data did not reload' || bad 'unchanged data did not reload'
# 14 without .sha256 the packaged baseline is authoritative.
rm "$T/root/etc/aether-proxy/data/chnroute4.sha256"; printf '%s' "$base_content" > "$T/root/usr/share/aether-proxy/data/chnroute4.txt"; cp "$T/root/usr/share/aether-proxy/data/chnroute4.txt" "$T/root/etc/aether-proxy/data/chnroute4.txt"
out=$(data_update); expect 'matching packaged baseline skips download' chnroute4 "$(get "$out" unchanged.0)"
[ ! -e "$T/root/etc/aether-proxy/data/chnroute4.sha256" ] && ok 'baseline comparison did not write hash' || bad 'baseline comparison did not write hash'
# 15 wrong decompressed hash, invalid CIDR, and <90% rows each reject the item and preserve old data.
make_data_manifest hash; printf 'old-rule\n' > "$T/root/etc/aether-proxy/data/chnroute4.txt"; printf '%s\n' "$(printf 'c%.0s' $(seq 64))" > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
before=$(sha256sum "$T/root/etc/aether-proxy/data/chnroute4.txt" | cut -d' ' -f1); out=$(data_update); expect 'decompressed hash mismatch exits 1' 1 "$?"
expect 'decompressed hash mismatch is reported' 'decompressed content sha256 mismatch' "$(get "$out" failed.chnroute4)"
expect 'hash mismatch preserves old text' "$before" "$(sha256sum "$T/root/etc/aether-proxy/data/chnroute4.txt" | cut -d' ' -f1)"
grep -q '"code": "UPDATE_VERIFY_FAILED"' "$T/run/events.jsonl" && ok 'UPDATE_VERIFY_FAILED logged' || bad 'UPDATE_VERIFY_FAILED logged'
make_data_manifest illegal; out=$(data_update); expect 'invalid CIDR rejects data' 1 "$?"
expect 'invalid CIDR preserves old text' "$before" "$(sha256sum "$T/root/etc/aether-proxy/data/chnroute4.txt" | cut -d' ' -f1)"
make_data_manifest low; out=$(data_update); expect 'under-90-percent line count rejected' 1 "$?"
expect 'low line count preserves old text' "$before" "$(sha256sum "$T/root/etc/aether-proxy/data/chnroute4.txt" | cut -d' ' -f1)"
# 16 one bad and one valid item: the valid one commits and reloads, command still exits 1.
make_data_manifest partial; rm -f "$T/root/etc/aether-proxy/data/gfwlist.txt" "$T/root/etc/aether-proxy/data/gfwlist.sha256"; : > "$UPDATE_INIT_CALLS"; out=$(data_update); expect 'partial data update exits 1' 1 "$?"
expect 'partial valid item updated' gfwlist "$(get "$out" updated.0)"
expect 'partial bad item reported' 'decompressed content sha256 mismatch' "$(get "$out" failed.chnroute4)"
expect 'partial valid item content written' "$(printf 'example.com\nexample.net')" "$(cat "$T/root/etc/aether-proxy/data/gfwlist.txt")"
expect 'partial update reloads once' reload "$(cat "$UPDATE_INIT_CALLS")"
# 17 stopped service updates files without reload.
make_data_manifest single; rm -f "$T/root/etc/aether-proxy/data/chnroute4.sha256"; rm -f "$T/root/etc/aether-proxy/data/chnroute4.txt"
python3 - "$T/run/state.json" <<'PY'
import json,sys
json.dump({'state':'stopped'},open(sys.argv[1],'w'))
PY
: > "$UPDATE_INIT_CALLS"; out=$(data_update); expect 'stopped service data update succeeds' 0 "$?"
[ ! -s "$UPDATE_INIT_CALLS" ] && ok 'stopped service did not reload' || bad 'stopped service did not reload'
# 18 update_data job completes and shares the update lock with a running update_package job.
python3 - "$T/run/state.json" <<'PY'
import json,sys
json.dump({'state':'stopped'},open(sys.argv[1],'w'))
PY
out=$(ap job start update data --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_data job starts' 0 "$?"; data_id=$(get "$out" job)
for _ in {1..200}; do js=$(ap job status "$data_id" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'update_data job completes' ok "$(get "$js" state)"
cat > "$T/fake-worker" <<'SH'
#!/bin/sh
sleep 8
SH
chmod +x "$T/fake-worker"; "$T/fake-worker" job run fake & fake_pid=$!; PIDS+=("$fake_pid")
python3 - "$T/run/jobs/fake.json" "$fake_pid" <<'PY'
import json,sys
json.dump({'id':'fake','kind':'update_package','state':'running','pid':int(sys.argv[2]),'started':1,'finished':None},open(sys.argv[1],'w'))
PY
out=$(ap job start update data --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_data job conflicts with update_package lock' BUSY "$(get "$out" code)"
kill "$fake_pid"; wait "$fake_pid" 2>/dev/null || :
# 12 no address answers at all: exit 1 and UPDATE_FETCH_FAILED, not a signature failure
mkdir -p "$T/conf-down"
cat > "$T/conf-down/aetherproxy" <<'UCI'
config update 'update'
 list channel_urls 'http://127.0.0.1:1/'
 list channel_urls 'http://127.0.0.1:2/'
UCI
out=$(ap update check --json --confdir "$T/conf-down" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null); rc=$?
expect 'unreachable channels exit 1' 1 "$rc"; expect 'unreachable channels report UPDATE_FETCH_FAILED' UPDATE_FETCH_FAILED "$(get "$out" code)"
grep -q '"code": "UPDATE_FETCH_FAILED"' "$T/run/events.jsonl" && ok 'UPDATE_FETCH_FAILED event logged' || bad 'UPDATE_FETCH_FAILED event logged'
# manifest-level failures keep the `update check` codes; unknown future items are ignored
out=$(ap update data --json --confdir "$T/conf-down" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null); rc=$?
expect 'data: unreachable channels exit 1' 1 "$rc"; expect 'data: unreachable reports UPDATE_FETCH_FAILED' UPDATE_FETCH_FAILED "$(get "$out" code)"
make_data_manifest single
for d in ch1 ch2; do printf ' ' >> "$T/$d/manifest.json"; done
out=$(data_update); rc=$?
expect 'data: bad signature exits 4' 4 "$rc"; expect 'data: bad signature code' MANIFEST_BAD_SIGNATURE "$(get "$out" code)"
make_data_manifest future; out=$(data_update); rc=$?
expect 'data: unknown future item is not a failure' 0 "$rc"
expect 'data: unknown future item not reported' '{}' "$(get "$out" failed)"
[ ! -e "$T/root/etc/aether-proxy/data/chnroute6.sha256" ] && ok 'data: unknown future item not written' || bad 'data: unknown future item not written'
# update check with the same manifest: the unknown item is reported changed without
# hashing a nonexistent baseline (no CMD_FAILED for it)
: >| "$T/run/events.jsonl"
out=$(run_check); expect 'check: unknown future item reported changed' true "$(get "$out" data.chnroute6.changed)"
expect 'T9.11 unknown future item retains manifest content hash' "$manifest_hash" \
	"$(get "$out" data.chnroute6.sha256)"
grep -q 'sha256sum' "$T/run/events.jsonl" && bad 'check: unknown future item hashes nothing' || ok 'check: unknown future item hashes nothing'
# a .sha256 with garbage content: update data refuses the item, update check reports changed
make_data_manifest single
printf 'not-a-hash\n' >| "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(data_update); expect 'data: garbage .sha256 fails the item' 'invalid local content hash' "$(get "$out" failed.chnroute4)"
out=$(run_check); expect 'check: garbage .sha256 reports changed' true "$(get "$out" data.chnroute4.changed)"
rm -f "$T/root/etc/aether-proxy/data/chnroute4.sha256"
# release hosts redirect (GitHub: 302 to a storage host): manifest and assets follow it
mkdir -p "$T/conf-redirect"
printf "config update 'update'\n list channel_urls 'http://127.0.0.1:%s/'\n" "$PORT3" > "$T/conf-redirect/aetherproxy"
out=$(ap update check --json --confdir "$T/conf-redirect" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null); rc=$?
expect 'redirected channel: check succeeds' 0 "$rc"
make_data_manifest single; printf "%064d\n" 0 > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(ap update data --json --confdir "$T/conf-redirect" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null); rc=$?
expect 'redirected channel: data asset downloads' 0 "$rc"; expect 'redirected channel: item updated' chnroute4 "$(get "$out" updated.0)"
# T8.16: isolate PATH so neither the repository stubs nor a host package manager can leak in.
make_manifest
mkdir -p "$T/path-tools" "$T/path-first" "$T/path-later" "$T/path-apk" "$T/path-empty"
for tool in sh mktemp sleep rm cat curl sha256sum sed; do
	ln -s "$(command -v "$tool")" "$T/path-tools/$tool"
done
ln -s "$USIGN" "$T/path-tools/usign"
export UPDATE_PM_PATH_CALLS="$T/pm-path-calls"
make_path_pm() {
	local name=$1 dir=$2
	cat > "$dir/$name" <<PM
#!/bin/sh
printf '%s %s\\n' "\$0" "\$*" >> "\$UPDATE_PM_PATH_CALLS"
exec "$ROOT/tests/stubs/update-bin/$name" "\$@"
PM
	chmod +x "$dir/$name"
}
# Launch the real host binary directly: the host bash wrapper itself needs PATH utilities.
path_ap() {
	local search=$1
	shift
	PATH="$search" LD_LIBRARY_PATH="$ROOT/tests/host/prefix/lib" \
		"$ROOT/tests/host/prefix/bin/ucode" -L "$ROOT/tests/host/modules/*.uc" \
		-L "$ROOT/tests/host/modules/*/*.uc" -S "$ENTRY" -- "$@" 2>"$T/path-stderr"
}
path_check() {
	local search=$1
	shift
	path_ap "$search" update check --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" "$@"
}
make_path_pm opkg "$T/path-later"
search="$T/path-tools:$T/path-first:$T/path-later"
export UPDATE_INSTALLED_VERSION=26.9.30-r5
unset UPDATE_PACKAGE_STATE_FILE
out=$(path_check "$search")
expect 'T8.16 PATH opkg check succeeds without bin-dir' 0 "$?"
expect 'T8.16 PATH later directory selects opkg' opkg "$(get "$out" pm)"
expect 'T8.16 PATH opkg supplies installed version' 26.9.30-r5 "$(get "$out" packages.xray-core.installed)"
expect 'T8.16 opkg called by absolute path' "$T/path-later/opkg status xray-core" \
	"$(awk 'NR == 1 {print; exit}' "$UPDATE_PM_PATH_CALLS")"
# apk wins even when opkg appears earlier in PATH.
make_path_pm apk "$T/path-apk"
export UPDATE_APK_VERSION=26.8.8-r2
out=$(path_check "$search:$T/path-apk")
expect 'T8.16 PATH apk check succeeds' 0 "$?"
expect 'T8.16 PATH apk outranks earlier opkg' apk "$(get "$out" pm)"
expect 'T8.16 PATH apk supplies installed version' 26.8.8-r2 "$(get "$out" packages.xray-core.installed)"
# An executable directory is not an executable file; non-executable files must not mask later tools.
printf '#!/bin/sh\nexit 99\n' > "$T/path-first/opkg"
chmod 644 "$T/path-first/opkg"
mkdir "$T/path-first/apk"
out=$(path_check "$search")
expect 'T8.16 non-executable and directory candidates are skipped' 0 "$?"
expect 'T8.16 later executable still supplies installed version' 26.9.30-r5 \
	"$(get "$out" packages.xray-core.installed)"
out=$(path_check "$T/path-tools:$T/path-first")
expect 'T8.16 no executable manager exits 1' 1 "$?"
expect 'T8.16 no executable manager code' CMD_FAILED "$(get "$out" code)"
expect 'T8.16 no executable manager preserves error' 'neither apk nor opkg is available' "$(get "$out" detail)"
: > "$UPDATE_PM_PATH_CALLS"
ln -s "$USIGN" "$T/path-empty/usign"
out=$(path_check "$search" --bin-dir "$T/path-empty")
expect 'T8.16 bin-dir excludes PATH managers' 1 "$?"
expect 'T8.16 bin-dir missing manager error' 'neither apk nor opkg is available' "$(get "$out" detail)"
expect 'T8.16 bin-dir never calls PATH managers' '' "$(< "$UPDATE_PM_PATH_CALLS")"
# Relative and empty PATH entries must still produce absolute invocation paths.
relative_dir=${T#"$ROOT/"}/path-later
out=$(cd "$ROOT" && path_check "$T/path-tools:$relative_dir")
expect 'T8.16 relative PATH entry works' 0 "$?"
expect 'T8.16 relative PATH command is called absolutely' "$T/path-later/opkg status xray-core" \
	"$(awk 'NR == 1 {print; exit}' "$UPDATE_PM_PATH_CALLS")"
: > "$UPDATE_PM_PATH_CALLS"
out=$(cd "$T/path-later" && path_check "$T/path-tools:")
expect 'T8.16 empty PATH entry searches current directory' 0 "$?"
expect 'T8.16 empty PATH entry command is called absolutely' "$T/path-later/opkg status xray-core" \
	"$(awk 'NR == 1 {print; exit}' "$UPDATE_PM_PATH_CALLS")"
# Exercise the private lookup with a fake fs: no host /bin/opkg or permissions are required.
# Keep the production helper intact instead of exporting an implementation detail for tests.
cat > "$T/default-path.uc" <<'UCODE'
'use strict';
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
let source = fs.readfile(ARGV[0]);
let start = index(source, 'function package_manager(');
let end = index(source, '\nfunction installed_version(');
let factory = loadstring('(function(fs, C) { ' + substr(source, start, end - start) +
	' return package_manager(null); })')();
let probed = [];
let manager = factory({
	access: (path, mode) => {
		push(probed, path);
		return path == '/bin/opkg' && mode == 'x';
	},
	stat: path => ({ type: 'file' }),
	realpath: path => path
}, C);
print(sprintf('%.J', { manager, probed }), '\n');
UCODE
for mode in empty unset; do
	if [ "$mode" = empty ]; then
		path_env=(PATH=)
	else
		path_env=(-u PATH)
	fi
	out=$(/usr/bin/env "${path_env[@]}" LD_LIBRARY_PATH="$ROOT/tests/host/prefix/lib" \
		"$ROOT/tests/host/prefix/bin/ucode" -L "$ROOT/tests/host/modules/*.uc" \
		-L "$ROOT/tests/host/modules/*/*.uc" "$T/default-path.uc" -- "$ROOT/aether-proxy/src/lib/update.uc")
	expect "T8.16 $mode PATH default lookup succeeds" 0 "$?"
	expect "T8.16 $mode PATH default finds bin opkg" /bin/opkg "$(get "$out" manager.path)"
	expect "T8.16 $mode PATH default searches usr sbin first" /usr/sbin/apk "$(get "$out" probed.0)"
done
# Shared callers must reuse discovery for installation too, not rebuild a bare command name.
: > "$UPDATE_PM_PATH_CALLS"
export UPDATE_PACKAGE_STATE_FILE="$T/path-installed-version"
printf '%s\n' 0.1.0-r1 > "$UPDATE_PACKAGE_STATE_FILE"
# T9.38: the page entry now verifies the backend; keep this PATH-only fixture
# running so verification polls state, rather than needing a CLI binary in PATH.
printf '{"state":"running"}\n' > "$UPDATE_STATE_FILE"
out=$(cd "$ROOT" && path_ap "$T/path-tools:$relative_dir" update package luci-app-aether-proxy \
	--json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root")
expect 'T8.16 PATH package install succeeds' 0 "$?"
expect 'T8.16 PATH package install verifies new version' 0.2.0-r1 "$(get "$out" to)"
if grep -q "^$T/path-later/opkg install " "$UPDATE_PM_PATH_CALLS"; then
	ok 'T8.16 package install calls discovered absolute path'
else
	bad 'T8.16 package install calls discovered absolute path'
fi

# T9.42 (security F2, rework R1): published asset names only use
# [A-Za-z0-9._-] and must be a single file name, not '.' or '..' (docs/08,
# decision 6.1). A failed size/sha256 check also must not delete or overwrite
# whatever already sits at the target path.
cat > "$T/dl.uc" <<'UCODE'
'use strict';
import * as update from 'aetherproxy.update';

function name_arg(value) {
	return value == 'MISSING' || value == 'NULL' ? null : value;
}
function size_arg(value) {
	if (value == 'MISSING' || value == 'NULL')
		return null;
	if (substr(value, 0, 4) == 'STR:')
		return substr(value, 4);
	if (substr(value, 0, 6) == 'FLOAT:')
		return +substr(value, 6);
	return +value;
}
function sha_arg(value) {
	return value == 'MISSING' || value == 'NULL' ? null : value;
}

let asset = {};
if (ARGV[2] != 'MISSING')
	asset.url = name_arg(ARGV[2]);
if (ARGV[3] != 'MISSING')
	asset.size = size_arg(ARGV[3]);
if (ARGV[4] != 'MISSING')
	asset.sha256 = sha_arg(ARGV[4]);
let bases = split(ARGV[1], ',');
let result = update.download_asset({ sys_root: ARGV[0] },
	length(bases) == 1 ? bases[0] : bases, asset, name_arg(ARGV[5]));
print(sprintf('%.J', result), '\n');
UCODE
download_asset() {
	# `--` stops ucode's own option parsing: a negative size value starts with '-'.
	AETHER_PROXY_TEST_TMP_FREE=99999999 "$UCODE" "$T/dl.uc" -- "$T/root" "$1" "$2" "$3" "$4" "$5"
}
pkg_update() {
	ap update package "$1" --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" --bin-dir "$T/bin"
}
DL_ROOT="$T/root/tmp/aether-proxy-dl"
BASE="http://127.0.0.1:$PORT1/"
BASE2="http://127.0.0.1:$PORT2/"
mkdir -p "$DL_ROOT"
printf 'PAYLOAD-FROM-CHANNEL\n' > "$T/ch1/asset.bin"
printf 'PAYLOAD-FROM-CHANNEL\n' > "$T/ch1/victim.txt"
# Names inside the published charset: dots in the middle and a leading dot are
# still plain components, so the validator must accept them.
printf 'DOTTED\n' > "$T/ch1/a..b.ipk"
printf 'HIDDEN\n' > "$T/ch1/.hidden.ipk"
asset_sha=$(sha256sum "$T/ch1/asset.bin" | cut -d' ' -f1)
asset_size=$(stat -c %s "$T/ch1/asset.bin")
part_count() { find "$DL_ROOT" -name '*.part*' | wc -l; }
sentinel() { printf 'SENTINEL:%s\n' "$1" > "$DL_ROOT/keep.bin"; }
name_detail='asset name is not a plain file name'
type_detail='asset size or sha256 in the manifest is invalid'

# -- 1. the remote URL name and the local target name are checked separately --
printf 'OUTSIDE-FILE\n' > "$T/root/tmp/victim.txt"
out=$(download_asset "$BASE" '../victim.txt' "$asset_size" "$asset_sha" 'ok.bin'); rc=$?
expect 'T9.42 remote traversal name is rejected' 0 "$rc"
expect 'T9.42 remote traversal is a name failure' "$name_detail" "$(get "$out" detail)"
expect 'T9.42 remote traversal never writes outside the download directory' OUTSIDE-FILE \
	"$(cat "$T/root/tmp/victim.txt")"
[ ! -e "$DL_ROOT/ok.bin" ] && ok 'T9.42 rejected remote name downloads nothing' \
	|| bad 'T9.42 rejected remote name downloads nothing'
out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$asset_sha" '../victim.txt'); rc=$?
expect 'T9.42 target traversal name is rejected' 0 "$rc"
expect 'T9.42 target traversal is a name failure' "$name_detail" "$(get "$out" detail)"
expect 'T9.42 target traversal never touches the outside file' OUTSIDE-FILE "$(cat "$T/root/tmp/victim.txt")"
for bad in '' '.' '..' 'a/b' 'a\b' 'a b.ipk' 'pkg~r.ipk' 'café.ipk'; do
	out=$(download_asset "$BASE" "$bad" "$asset_size" "$asset_sha" 'ok.bin'); rc=$?
	expect "T9.42 remote name <$bad> is rejected" 0 "$rc"
	expect "T9.42 remote name <$bad> reports a name failure" "$name_detail" "$(get "$out" detail)"
	out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$asset_sha" "$bad"); rc=$?
	expect "T9.42 target name <$bad> is rejected" 0 "$rc"
	expect "T9.42 target name <$bad> reports a name failure" "$name_detail" "$(get "$out" detail)"
done
for spec in 'MISSING' 'NULL'; do
	out=$(download_asset "$BASE" "$spec" "$asset_size" "$asset_sha" 'ok.bin'); rc=$?
	expect "T9.42 remote name $spec is rejected" "$name_detail" "$(get "$out" detail)"
	out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$asset_sha" "$spec"); rc=$?
	expect "T9.42 target name $spec is rejected" "$name_detail" "$(get "$out" detail)"
done
for good in 'a..b.ipk' '.hidden.ipk'; do
	good_sha=$(sha256sum "$T/ch1/$good" | cut -d' ' -f1)
	good_size=$(stat -c %s "$T/ch1/$good")
	out=$(download_asset "$BASE" "$good" "$good_size" "$good_sha" "$good"); rc=$?
	expect "T9.42 charset-legal name <$good> is accepted" 0 "$rc"
	expect "T9.42 charset-legal name <$good> downloads" "$DL_ROOT/$good" "$(get "$out" path)"
done
expect 'T9.42 name checks leave no temporary file' 0 "$(part_count)"

# -- 2. size/sha256 types from the manifest (decision 6.4) -------------------
for spec in 'STR:21' 'FLOAT:3.5' 'NULL' 'MISSING' '-1'; do
	out=$(download_asset "$BASE" 'asset.bin' "$spec" "$asset_sha" 'keep.bin'); rc=$?
	expect "T9.42 size $spec is rejected" 0 "$rc"
	expect "T9.42 size $spec is a type failure" "$type_detail" "$(get "$out" detail)"
done
bad_shas=$(printf 'f%.0s' $(seq 1 64))
short=$(printf 'a%.0s' $(seq 1 63))
long=$(printf 'a%.0s' $(seq 1 65))
nonhex=$(printf 'z%.0s' $(seq 1 64))
for spec in 'NULL' 'MISSING' 'deadbeef' "$short" "$long" "$nonhex"; do
	out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$spec" 'keep.bin'); rc=$?
	expect "T9.42 sha256 ${spec:0:12}… is rejected" 0 "$rc"
	expect "T9.42 sha256 ${spec:0:12}… is a type failure" "$type_detail" "$(get "$out" detail)"
done
upper_sha=$(printf '%s' "$asset_sha" | tr 'a-f' 'A-F')
out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$upper_sha" 'upper.bin'); rc=$?
expect 'T9.42 uppercase hex sha256 is accepted' 0 "$rc"

# -- 3. verification failure keeps the existing final file ------------------
check_sentinel() {
	[ "$(cat "$DL_ROOT/keep.bin" 2>&1)" = "SENTINEL:$1" ] \
		&& ok "T9.42 $1 keeps the existing final file" \
		|| bad "T9.42 $1 keeps the existing final file" "$(cat "$DL_ROOT/keep.bin" 2>&1)"
}
sentinel 'size'; out=$(download_asset "$BASE" 'asset.bin' 3 "$asset_sha" 'keep.bin'); rc=$?
expect 'T9.42 size mismatch exits cleanly' 0 "$rc"
expect 'T9.42 size mismatch reports verification failure' UPDATE_VERIFY_FAILED "$(get "$out" code)"
check_sentinel 'size'
sentinel 'sha'; out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$bad_shas" 'keep.bin'); rc=$?
expect 'T9.42 sha256 mismatch reports verification failure' UPDATE_VERIFY_FAILED "$(get "$out" code)"
check_sentinel 'sha'
sentinel 'missing-asset'
out=$(download_asset "$BASE" 'never-on-the-channel.bin' "$asset_size" "$asset_sha" 'keep.bin'); rc=$?
expect 'T9.42 a missing asset reports verification failure' UPDATE_VERIFY_FAILED "$(get "$out" code)"
check_sentinel 'missing-asset'
sentinel 'int-zero'; out=$(download_asset "$BASE" 'asset.bin' 0 "$asset_sha" 'keep.bin'); rc=$?
expect 'T9.42 int size 0 is a verification failure, not a type failure' UPDATE_VERIFY_FAILED "$(get "$out" code)"
expect 'T9.42 int size 0 is checked against the real file' \
	'asset size or sha256 mismatch, or download failed' "$(get "$out" detail)"
check_sentinel 'int-zero'
# The first channel serves the wrong bytes, the second one the real asset.
printf 'CH1-PAYLOAD\n' > "$T/ch1/mirror.bin"
printf 'CH2-PAYLOAD\n' > "$T/ch2/mirror.bin"
mirror_sha=$(sha256sum "$T/ch2/mirror.bin" | cut -d' ' -f1)
mirror_size=$(stat -c %s "$T/ch2/mirror.bin")
sentinel 'mirror-fallback'
out=$(download_asset "$BASE,$BASE2" 'mirror.bin' "$mirror_size" "$mirror_sha" 'keep.bin'); rc=$?
expect 'T9.42 mirror fallback succeeds' 0 "$rc"
expect 'T9.42 mirror fallback keeps the second channel data' CH2-PAYLOAD "$(cat "$DL_ROOT/keep.bin")"
expect 'T9.42 mirror fallback leaves no temporary file' 0 "$(part_count)"
sentinel 'all-channels-fail'
out=$(download_asset "$BASE,$BASE2" 'asset.bin' "$asset_size" "$bad_shas" 'keep.bin'); rc=$?
expect 'T9.42 both channels failing reports verification failure' UPDATE_VERIFY_FAILED "$(get "$out" code)"
check_sentinel 'all-channels-fail'
expect 'T9.42 failed downloads leave no temporary file' 0 "$(part_count)"
sentinel 'success'
out=$(download_asset "$BASE" 'asset.bin' "$asset_size" "$asset_sha" 'keep.bin'); rc=$?
expect 'T9.42 verified download reports the final path' "$DL_ROOT/keep.bin" "$(get "$out" path)"
expect 'T9.42 verified download replaces the target' PAYLOAD-FROM-CHANNEL "$(cat "$DL_ROOT/keep.bin")"
expect 'T9.42 successful download leaves no temporary file' 0 "$(part_count)"

# -- 4. the same contract applies when `update check` reads the manifest -----
python3 - "$T" <<'PY'
import json, os, sys
for channel in ('ch1', 'ch2'):
    path = os.path.join(sys.argv[1], channel, 'manifest.json')
    manifest = json.load(open(path))
    def ipk(name):
        return manifest['packages'][name]['current']['assets']['aarch64_generic']['ipk']
    ipk('xray-core')['url'] = '../evil.ipk'
    ipk('aether-proxy')['size'] = '19'
    ipk('luci-i18n-aether-proxy-zh-cn')['sha256'] = 'deadbeef'
    json.dump(manifest, open(path, 'w'))
PY
for channel in ch1 ch2; do
	"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec" >/dev/null 2>&1
done
out=$(run_check)
expect 'T9.42 check rejects a traversal asset name' '<null>' "$(get "$out" packages.xray-core.asset)"
expect 'T9.42 check does not call a bad name newer' false "$(get "$out" packages.xray-core.newer)"
expect 'T9.42 check rejects a string size' '<null>' "$(get "$out" packages.aether-proxy.asset)"
expect 'T9.42 check rejects a short sha256' '<null>' "$(get "$out" packages.luci-i18n-aether-proxy-zh-cn.asset)"
expect 'T9.42 check still offers the untouched asset' luci-app-aether-proxy_0.2.0-r1_aarch64_generic.ipk \
	"$(get "$out" packages.luci-app-aether-proxy.asset)"
# The install path must refuse the same entries, without invoking a package manager.
: > "$UPDATE_PACKAGE_CALLS"
out=$(pkg_update xray-core); rc=$?
expect 'T9.42 install refuses a traversal asset name' 1 "$rc"
expect 'T9.42 install reports ARCH_UNSUPPORTED for a bad name' ARCH_UNSUPPORTED "$(get "$out" code)"
out=$(pkg_update luci-i18n-aether-proxy-zh-cn); rc=$?
expect 'T9.42 install refuses a short sha256' 1 "$rc"
expect 'T9.42 install reports ARCH_UNSUPPORTED for a bad sha256' ARCH_UNSUPPORTED "$(get "$out" code)"
out=$(pkg_update aether-proxy); rc=$?
expect 'T9.42 grouped install refuses a string size' 1 "$rc"
expect 'T9.42 grouped install reports ARCH_UNSUPPORTED for a bad size' ARCH_UNSUPPORTED "$(get "$out" code)"
[ ! -s "$UPDATE_PACKAGE_CALLS" ] && ok 'T9.42 rejected assets never reach the package manager' \
	|| bad 'T9.42 rejected assets never reach the package manager' "$(cat "$UPDATE_PACKAGE_CALLS")"

echo "update: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
