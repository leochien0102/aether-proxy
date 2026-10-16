#!/usr/bin/env bash
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
    for pm,ext in [('opkg','ipk'),('apk','apk')]:
     fn=f'{name}_{ver}_{arch}.{ext}' if ext=='ipk' else f'{name}-{ver}_{arch}.apk'
     for d in ('ch1','ch2'): open(os.path.join(t,d,fn),'wb').write(content)
     a[arch][pm]={'url':fn,'sha256':hashlib.sha256(content).hexdigest(),'size':len(content)}
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
# 2 apk precedence and apk version/asset parsing
cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"; chmod +x "$T/bin/apk"
export UPDATE_APK_VERSION=26.9.30-r5; out=$(run_check); expect 'apk check succeeds' 0 "$?"; expect 'apk preferred' apk "$(get "$out" pm)"
expect 'apk installed version' 26.9.30-r5 "$(get "$out" packages.xray-core.installed)"; expect 'apk asset key' xray-core-26.10.10-r1_aarch64_generic.apk "$(get "$out" packages.xray-core.asset)"; rm "$T/bin/apk"
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
if [ "$1" = restart ]; then printf '{"state":"running"}\n' > "$UPDATE_INIT_STATE_FILE"; fi
exit 0
INIT
cat > "$T/bin/killall" <<'KILLALL'
#!/bin/sh
printf '%s\n' "$*" >> "$UPDATE_SIGNAL_CALLS"
if [ "${UPDATE_SIGNAL_NO_PROBE:-0}" != 1 ]; then
 python3 - "$UPDATE_STATE_FILE" <<'PY'
import json,sys,time
p=sys.argv[1]; x=json.load(open(p)); x['last_probe']={'ok':True,'at':int(time.time())+2}; json.dump(x,open(p,'w'))
PY
fi
exit 0
KILLALL
chmod +x "$T/root/etc/init.d/aether-proxy" "$T/bin/killall"
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
grep -q 'USR2' "$UPDATE_SIGNAL_CALLS" && ok 'xray install sends SIGUSR2' || bad 'xray install sends SIGUSR2'
grep -q 'UPDATE_INSTALLED' "$T/run/events.jsonl" && ok 'successful package logs UPDATE_INSTALLED' || bad 'successful package logs UPDATE_INSTALLED'
# apk command line and installed version handling
cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"; chmod +x "$T/bin/apk"; : > "$UPDATE_PACKAGE_CALLS"
printf '%s\n' 0.1.0-r1 > "$UPDATE_PACKAGE_STATE_FILE"
out=$(ap update package luci-app-aether-proxy --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin")
expect 'apk package install succeeds' 0 "$?"
grep -q 'add --allow-untrusted .*luci-app-aether-proxy-0.2.0-r1_aarch64_generic.apk' "$UPDATE_PACKAGE_CALLS" && ok 'apk uses --allow-untrusted and selected asset' || bad 'apk uses --allow-untrusted and selected asset'
rm "$T/bin/apk"
# Invalid hashes and unsupported architectures never reach the package manager.
: > "$UPDATE_PACKAGE_CALLS"
python3 - "$T/ch1/manifest.json" <<'PY'
import json,sys
p=sys.argv[1];m=json.load(open(p));m['packages']['xray-core']['current']['assets']['aarch64_generic']['opkg']['sha256']='0'*64;json.dump(m,open(p,'w'))
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
out=$(ap update package aether-proxy --json --confdir "$T/conf" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin"); expect 'aether-proxy package update succeeds' 0 "$?"
grep -q '^restart$' "$UPDATE_INIT_CALLS" && ok 'aether-proxy update invokes init restart' || bad 'aether-proxy update invokes init restart'
out=$(ap update package unknown --json); expect 'unknown package is USAGE' USAGE "$(get "$out" code)"
out=$(ap update data --json); expect 'data update remains USAGE' USAGE "$(get "$out" code)"
# 10 real update_check background job
export UPDATE_INSTALLED_MODE=normal UPDATE_INSTALLED_VERSION=26.9.30-r5
out=$(ap job start update check --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_check job starts' 0 "$?"; id=$(get "$out" job)
for _ in {1..200}; do js=$(ap job status "$id" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'update_check job completes' ok "$(get "$js" state)"; expect 'job result matches updates.json' true "$(python3 -c 'import json,sys;print(str(json.load(sys.stdin)["result"]==json.load(open(sys.argv[1]))).lower())' "$T/run/updates.json" <<<"$js")"
# update_package is a job kind and shares its busy lock with update_check.
out=$(ap job start update package luci-i18n-aether-proxy-zh-cn --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_package job starts' 0 "$?"; package_job=$(get "$out" job)
for _ in {1..300}; do js=$(ap job status "$package_job" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'update_package job completes' ok "$(get "$js" state)"
UPDATE_INSTALLED_SLEEP=2 out=$(ap job start update check --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'second update_check job starts' 0 "$?"
sleep .1
out=$(ap job start update package xray-core --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_package is excluded by shared update lock' 3 "$?"
unset UPDATE_INSTALLED_SLEEP
# 11 data change is judged by content_sha256 (the local .sha256 holds the plain list's hash)
printf '%s\n' "$(printf 'b%.0s' $(seq 64))" > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(run_check); expect 'same content hash means unchanged data' false "$(get "$out" data.chnroute4.changed)"
printf '%s\n' "$(printf 'a%.0s' $(seq 64))" > "$T/root/etc/aether-proxy/data/chnroute4.sha256"
out=$(run_check); expect 'the .gz hash is not mistaken for the content hash' true "$(get "$out" data.chnroute4.changed)"
rm -f "$T/root/etc/aether-proxy/data/chnroute4.sha256"
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
echo "update: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
