#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"; ENTRY="$ROOT/aether-proxy/src/aether-proxy"; USIGN="$ROOT/tests/host/prefix/bin/usign"
T=$(mktemp -d "$ROOT/tests/update/tmp.XXXXXX"); PIDS=(); pass=0; fail=0
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || :; wait "$p" 2>/dev/null || :; done; if [ "${KEEP_TMP:-0}" = 1 ]; then echo "kept $T"; else rm -rf "$T"; fi; }
trap cleanup EXIT INT TERM
ok() { pass=$((pass+1)); echo "PASS  $1"; }; bad() { fail=$((fail+1)); echo "FAIL  $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }
get() { python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v[int(k)] if isinstance(v,list) else v[k]
print("<null>" if v is None else str(v).lower() if isinstance(v,bool) else v)' "$2" <<<"$1"; }
ap() { "$UCODE" -S "$ENTRY" -- "$@"; }
mkdir -p "$T/root/etc/aether-proxy/keys" "$T/root/etc/aether-proxy/data" "$T/root/tmp" "$T/run" "$T/conf" "$T/bin" "$T/ch1" "$T/ch2"
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
cat > "$T/conf/aetherproxy" <<'UCI'
config update 'update'
 list channel_urls 'http://127.0.0.1:18080/'
 list channel_urls 'http://127.0.0.1:18081/'
UCI
for i in 1 2; do python3 -m http.server $((18079+i)) --bind 127.0.0.1 --directory "$T/ch$i" >"$T/http$i" 2>&1 & PIDS+=("$!"); done
for _ in {1..100}; do curl -fsS http://127.0.0.1:18080/ >/dev/null 2>&1 && curl -fsS http://127.0.0.1:18081/ >/dev/null 2>&1 && break; sleep .05; done
make_manifest() {
 python3 - "$T" <<'PY'
import hashlib,json,os,sys
t=sys.argv[1]; content=b'local package fixture\n'; m={'schema':2,'generated':'2026-10-15T00:00:00Z','packages':{},'data':{'chnroute4':{'version':'v1','url':'data.gz','sha256':'a'*64,'size':1,'content_sha256':'b'*64,'lines':1}}}
for name,version in [('xray-core','26.10.10-r1'),('aether-proxy','0.2.0-r1'),('luci-app-aether-proxy','0.2.0-r1')]:
 a={}
 for arch in ('aarch64_generic','all'):
  a[arch]={}
  for pm,ext in [('opkg','ipk'),('apk','apk')]:
   fn=f'{name}_{version}_{arch}.{ext}' if ext=='ipk' else f'{name}-{version}_{arch}.apk'
   for d in ('ch1','ch2'): open(os.path.join(t,d,fn),'wb').write(content)
   a[arch][pm]={'url':fn,'sha256':hashlib.sha256(content).hexdigest(),'size':len(content)}
 m['packages'][name]={'current':{'version':version,'assets':a},'previous':None}
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
expect 'second channel selected' http://127.0.0.1:18081/ "$(get "$out" url)"; grep -q '"code": "MANIFEST_BAD_SIGNATURE"' "$T/run/events.jsonl" && ok 'bad signature event logged' || bad 'bad signature event logged'; make_manifest
# 4 all bad signatures fail rc 4 without replacing updates.json
cp "$T/run/updates.json" "$T/old"; printf x >> "$T/ch1/manifest.json"; printf x >> "$T/ch2/manifest.json"; out=$(run_check); expect 'all bad signatures exit 4' 4 "$?"
expect 'failure code is signature' MANIFEST_BAD_SIGNATURE "$(get "$out" code)"; cmp -s "$T/old" "$T/run/updates.json" && ok 'failed check preserves updates.json' || bad 'failed check preserves updates.json'; make_manifest
# 5 unknown key is not trusted
"$USIGN" -G -p "$T/otherpub" -s "$T/othersec" >/dev/null 2>&1; "$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/othersec" >/dev/null 2>&1
out=$(run_check); expect 'unknown signer falls back' http://127.0.0.1:18081/ "$(get "$out" url)"; make_manifest
# 6 invalid JSON and schema=1 use next address
printf '{broken' > "$T/ch1/manifest.json"; printf bad > "$T/ch1/manifest.json.sig"; out=$(run_check); expect 'non-JSON manifest fallback' http://127.0.0.1:18081/ "$(get "$out" url)"
python3 -c 'import json,sys;json.dump({"schema":1},open(sys.argv[1],"w"))' "$T/ch1/manifest.json"; "$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
out=$(run_check); expect 'schema 1 manifest fallback' http://127.0.0.1:18081/ "$(get "$out" url)"; make_manifest
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
export AETHER_PROXY_TEST_TMP_FREE=99999999; result=$("$UCODE" "$T/asset.uc" -- "$T/root" "$T/bin" http://127.0.0.1:18080 "$asset" "$size" 0000000000000000000000000000000000000000000000000000000000000000)
expect 'asset checksum mismatch rejected' UPDATE_VERIFY_FAILED "$(get "$result" code)"; [ ! -e "$T/root/tmp/aether-proxy-dl/asset-test" ] && ok 'bad asset removed' || bad 'bad asset removed'
export AETHER_PROXY_TEST_TMP_FREE=1; result=$("$UCODE" "$T/asset.uc" -- "$T/root" "$T/bin" http://127.0.0.1:18080 "$asset" "$size" "$hash"); expect 'low space returns NO_SPACE' NO_SPACE "$(get "$result" code)"; unset AETHER_PROXY_TEST_TMP_FREE
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
result=$("$UCODE" "$T/asset-fallback.uc" -- "$T/root" "$T/bin" http://127.0.0.1:18080 http://127.0.0.1:18081 "$asset" "$size" "$hash")
expect 'bad first asset mirror falls back' true "$(get "$result" ok)"
# T7.4 is a parallel card and is not in this branch; its CLI remains unavailable here.
out=$(ap update package xray-core --json); expect 'package update remains USAGE' USAGE "$(get "$out" code)"
out=$(ap job start update package xray-core); expect 'unimplemented package update is not a job' USAGE "$(get "$out" code)"
# 10 real update_check background job
export UPDATE_INSTALLED_MODE=normal UPDATE_INSTALLED_VERSION=26.9.30-r5
out=$(ap job start update check --json --confdir "$T/conf" --sys-root "$T/root" --run-dir "$T/run" --bin-dir "$T/bin"); expect 'update_check job starts' 0 "$?"; id=$(get "$out" job)
for _ in {1..200}; do js=$(ap job status "$id" --json --sys-root "$T/root" --run-dir "$T/run"); state=$(get "$js" state); [ "$state" = ok ] || [ "$state" = failed ] && break; sleep .05; done
expect 'update_check job completes' ok "$(get "$js" state)"; expect 'job result matches updates.json' true "$(python3 -c 'import json,sys;print(str(json.load(sys.stdin)["result"]==json.load(open(sys.argv[1]))).lower())' "$T/run/updates.json" <<<"$js")"
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
if mode=='single':
 for d in ('ch1','ch2'):
  m2=dict(m);m2['data']={'chnroute4':entries['chnroute4']};json.dump(m2,open(os.path.join(t,d,'manifest.json'),'w'))
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
# 12 one changed item writes validated text/hash, requests one reload, and emits DATA_UPDATED.
out=$(data_update); expect 'changed rule data update succeeds' 0 "$?"
expect 'changed item appears in updated list' chnroute4 "$(get "$out" updated.0)"
expect 'updated text is exact' "$(printf '10.0.0.0/8\n192.168.0.0/16')" "$(cat "$T/root/etc/aether-proxy/data/chnroute4.txt")"
expect 'content hash file is exact' "$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$T/root/etc/aether-proxy/data/chnroute4.txt")" "$(tr -d '\n' < "$T/root/etc/aether-proxy/data/chnroute4.sha256")"
expect 'running service reloaded once' reload "$(cat "$UPDATE_INIT_CALLS")"
grep -q '"code": "DATA_UPDATED"' "$T/run/events.jsonl" && ok 'DATA_UPDATED event logged' || bad 'DATA_UPDATED event logged'
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
 list channel_urls 'http://127.0.0.1:18097/'
 list channel_urls 'http://127.0.0.1:18098/'
UCI
out=$(ap update check --json --confdir "$T/conf-down" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null); rc=$?
expect 'unreachable channels exit 1' 1 "$rc"; expect 'unreachable channels report UPDATE_FETCH_FAILED' UPDATE_FETCH_FAILED "$(get "$out" code)"
grep -q '"code": "UPDATE_FETCH_FAILED"' "$T/run/events.jsonl" && ok 'UPDATE_FETCH_FAILED event logged' || bad 'UPDATE_FETCH_FAILED event logged'
echo "update: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
