#!/usr/bin/env bash
# T16.78 (M11): verify streaming decompressed plaintext size limit on real `update data`
# with local real gzip assets: normal, exact limit (8 MiB), limit+1 byte, large repetitive
# harmless text, invalid gzip, and downstream check preservation + zero residue.

RULE_SIZE_LIMIT=$("$UCODE" -e "import * as C from 'aetherproxy.const'; print(C.UPDATE_DATA_MAX_BYTES);")
expect 'T16.78 UPDATE_DATA_MAX_BYTES is 8 MiB' 8388608 "$RULE_SIZE_LIMIT"

RS_DATA_DIR="$T/root/etc/aether-proxy/data"
RS_SNAP="$T/rule-size-snap"
mkdir -p "$RS_DATA_DIR" "$RS_SNAP"

rs_make_manifest() {
	local mode=$1
	python3 - "$T" "$mode" "$RULE_SIZE_LIMIT" <<'PY'
import gzip, hashlib, json, os, sys

t, mode, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])

def build_exact_cidr_text(target_bytes):
    # Harmless valid CIDR list padded with fixed-width comment lines so
    # line_count() and parse_cidrs() see valid rules and exact byte length.
    tail = b'10.10.0.0/16\n192.168.10.0/24\n'
    need = target_bytes - len(tail)
    assert need >= 0
    chunk = b'#' + b'a' * 4094 + b'\n'  # 4096 bytes per comment line
    full, rem = divmod(need, len(chunk))
    parts = [chunk] * full
    if rem == 1:
        parts.append(b'\n')
    elif rem >= 2:
        parts.append(b'#' + b'b' * (rem - 2) + b'\n')
    parts.append(tail)
    data = b''.join(parts)
    assert len(data) == target_bytes, (len(data), target_bytes)
    return data

if mode == 'normal':
    plain = b'10.1.0.0/16\n192.168.1.0/24\n'
    compressed = gzip.compress(plain, mtime=0)
    content_hash = hashlib.sha256(plain).hexdigest()
    lines = 2
elif mode == 'exact':
    plain = build_exact_cidr_text(limit)
    compressed = gzip.compress(plain, mtime=0)
    content_hash = hashlib.sha256(plain).hexdigest()
    lines = 2
elif mode == 'over1':
    plain = build_exact_cidr_text(limit + 1)
    compressed = gzip.compress(plain, mtime=0)
    content_hash = hashlib.sha256(plain).hexdigest()
    lines = 2
elif mode == 'large':
    # 32 MiB of harmless comment lines + valid CIDR; compresses small (~35 KiB)
    # to exercise early streaming abort and gunzip termination/reaping.
    plain = build_exact_cidr_text(limit * 4)
    compressed = gzip.compress(plain, mtime=0)
    content_hash = hashlib.sha256(plain).hexdigest()
    lines = 2
elif mode == 'exact_bad_hash':
    plain = build_exact_cidr_text(limit)
    compressed = gzip.compress(plain, mtime=0)
    content_hash = 'e' * 64
    lines = 2
elif mode == 'invalid_gz':
    # Not a valid gzip stream; manifest sha256/size match the raw bytes so
    # download_asset() passes and real gunzip rejects the stream.
    compressed = b'not-a-valid-gzip-stream-payload\n'
    content_hash = 'd' * 64
    lines = 2
else:
    raise SystemExit(f'unknown mode: {mode}')

fn = f'chnroute4-{mode}.txt.gz'
for d in ('ch1', 'ch2'):
    with open(os.path.join(t, d, fn), 'wb') as fh:
        fh.write(compressed)

manifest = {
    'schema': 2,
    'generated': '2026-11-24T00:00:00Z',
    'packages': {},
    'data': {
        'chnroute4': {
            'version': content_hash[:12],
            'url': fn,
            'sha256': hashlib.sha256(compressed).hexdigest(),
            'size': len(compressed),
            'content_sha256': content_hash,
            'lines': lines,
        }
    },
}
for d in ('ch1', 'ch2'):
    with open(os.path.join(t, d, 'manifest.json'), 'w', encoding='utf-8') as fh:
        json.dump(manifest, fh)
PY
	"$USIGN" -S -m "$T/ch1/manifest.json" -s "$T/sec" >/dev/null 2>&1
	"$USIGN" -S -m "$T/ch2/manifest.json" -s "$T/sec" >/dev/null 2>&1
}

rs_check_no_temp_residue() {
	local label=$1
	local dl_left data_left
	dl_left=$(find "$DL_ROOT" -maxdepth 1 -name 'data-chnroute4*' | wc -l)
	data_left=$(find "$RS_DATA_DIR" -maxdepth 1 -name 'chnroute4*.tmp*' | wc -l)
	expect "T16.78 $label leaves no download temp files" 0 "$dl_left"
	expect "T16.78 $label leaves no data staging temp files" 0 "$data_left"
}

rs_run_in_session() {
	local out_file=$1 rc_file=$2 sid_file=$3
	setsid -w bash -c '
		printf "%s\n" "$$" > "$3"
		LD_LIBRARY_PATH="'"$ROOT"'/tests/host/prefix/lib" \
			"'"$ROOT"'/tests/host/prefix/bin/ucode" \
			-L "'"$ROOT"'/tests/host/modules/*.uc" \
			-L "'"$ROOT"'/tests/host/modules/*/*.uc" \
			-S "'"$ENTRY"'" -- update data --json \
			--confdir "'"$T"'/conf" --run-dir "'"$T"'/run" \
			--sys-root "'"$T"'/root" --bin-dir "'"$T"'/bin" \
			> "$1" 2>"'"$T"'/stderr"
		printf "%s\n" "$?" > "$2"
	' _ "$out_file" "$rc_file" "$sid_file"
}

rs_check_no_child_residue() {
	local label=$1 sid=$2
	local left
	left=$(ps -o pid=,sid=,comm= | awk -v s="$sid" '$2 == s && ($3 == "gunzip" || $3 == "gzip" || $3 == "head") { print $1 }' | wc -l)
	expect "T16.78 $label leaves no gunzip/head child processes" 0 "$left"
}

rs_seed_old_rule() {
	printf '10.0.0.0/8\n172.16.0.0/12\n' > "$RS_DATA_DIR/chnroute4.txt"
	sha256sum "$RS_DATA_DIR/chnroute4.txt" | awk '{print $1}' > "$RS_DATA_DIR/chnroute4.sha256"
	cp "$RS_DATA_DIR/chnroute4.txt" "$RS_SNAP/old.txt"
	cp "$RS_DATA_DIR/chnroute4.sha256" "$RS_SNAP/old.sha256"
}

rs_check_old_unchanged() {
	local label=$1
	cmp -s "$RS_SNAP/old.txt" "$RS_DATA_DIR/chnroute4.txt" \
		&& ok "T16.78 $label preserves old rule bytes" \
		|| bad "T16.78 $label preserves old rule bytes"
	cmp -s "$RS_SNAP/old.sha256" "$RS_DATA_DIR/chnroute4.sha256" \
		&& ok "T16.78 $label preserves old hash bytes" \
		|| bad "T16.78 $label preserves old hash bytes"
}

rs_saved_state=''
[ -f "$T/run/state.json" ] && rs_saved_state=$(cat "$T/run/state.json")
printf '{"state":"running"}\n' > "$T/run/state.json"

# 1. Normal real-gzip rule data updates cleanly
rs_seed_old_rule
rs_make_manifest normal
: > "$UPDATE_INIT_CALLS"
rs_run_in_session "$RS_SNAP/normal.out" "$RS_SNAP/normal.rc" "$RS_SNAP/normal.sid"
expect 'T16.78 normal gzip update exits 0' 0 "$(cat "$RS_SNAP/normal.rc")"
expect 'T16.78 normal gzip item updated' chnroute4 "$(get "$(cat "$RS_SNAP/normal.out")" updated.0)"
expect 'T16.78 normal gzip triggers reload' reload "$(cat "$UPDATE_INIT_CALLS")"
rs_check_no_temp_residue 'normal gzip'
rs_check_no_child_residue 'normal gzip' "$(cat "$RS_SNAP/normal.sid")"

# 2. Exact limit (8,388,608 bytes) valid gzip updates cleanly
rs_seed_old_rule
rs_make_manifest exact
: > "$UPDATE_INIT_CALLS"
rs_run_in_session "$RS_SNAP/exact.out" "$RS_SNAP/exact.rc" "$RS_SNAP/exact.sid"
expect 'T16.78 exact-limit gzip update exits 0' 0 "$(cat "$RS_SNAP/exact.rc")"
expect 'T16.78 exact-limit gzip item updated' chnroute4 "$(get "$(cat "$RS_SNAP/exact.out")" updated.0)"
expect 'T16.78 exact-limit written byte count matches limit' "$RULE_SIZE_LIMIT" "$(stat -c %s "$RS_DATA_DIR/chnroute4.txt")"
expect 'T16.78 exact-limit hash file matches written content' \
	"$(sha256sum "$RS_DATA_DIR/chnroute4.txt" | awk '{print $1}')" \
	"$(tr -d '\n' < "$RS_DATA_DIR/chnroute4.sha256")"
expect 'T16.78 exact-limit triggers reload' reload "$(cat "$UPDATE_INIT_CALLS")"
rs_check_no_temp_residue 'exact-limit gzip'
rs_check_no_child_residue 'exact-limit gzip' "$(cat "$RS_SNAP/exact.sid")"

# 3. Exact limit with wrong content_sha256 still rejected by downstream hash check
rs_seed_old_rule
rs_make_manifest exact_bad_hash
: > "$UPDATE_INIT_CALLS"
rs_run_in_session "$RS_SNAP/exact-bad.out" "$RS_SNAP/exact-bad.rc" "$RS_SNAP/exact-bad.sid"
expect 'T16.78 exact-limit bad hash exits 1' 1 "$(cat "$RS_SNAP/exact-bad.rc")"
expect 'T16.78 exact-limit bad hash reports hash mismatch' \
	'decompressed content sha256 mismatch' "$(get "$(cat "$RS_SNAP/exact-bad.out")" failed.chnroute4)"
rs_check_old_unchanged 'exact-limit bad hash'
[ ! -s "$UPDATE_INIT_CALLS" ] && ok 'T16.78 exact-limit bad hash does not reload' || bad 'T16.78 exact-limit bad hash does not reload'
rs_check_no_temp_residue 'exact-limit bad hash'
rs_check_no_child_residue 'exact-limit bad hash' "$(cat "$RS_SNAP/exact-bad.sid")"

# 4. Limit + 1 byte (8,388,609 bytes) rejected with clear error; old rule and hash unchanged
rs_seed_old_rule
rs_make_manifest over1
: > "$UPDATE_INIT_CALLS"
: > "$T/run/events.jsonl"
rs_run_in_session "$RS_SNAP/over1.out" "$RS_SNAP/over1.rc" "$RS_SNAP/over1.sid"
expect 'T16.78 over-limit+1 exits 1' 1 "$(cat "$RS_SNAP/over1.rc")"
expect 'T16.78 over-limit+1 reports size limit failure' \
	"decompressed size exceeds ${RULE_SIZE_LIMIT} bytes" "$(get "$(cat "$RS_SNAP/over1.out")" failed.chnroute4)"
grep -q '"code": "UPDATE_VERIFY_FAILED"' "$T/run/events.jsonl" \
	&& ok 'T16.78 over-limit+1 logs UPDATE_VERIFY_FAILED' \
	|| bad 'T16.78 over-limit+1 logs UPDATE_VERIFY_FAILED'
rs_check_old_unchanged 'over-limit+1'
[ ! -s "$UPDATE_INIT_CALLS" ] && ok 'T16.78 over-limit+1 does not reload' || bad 'T16.78 over-limit+1 does not reload'
rs_check_no_temp_residue 'over-limit+1'
rs_check_no_child_residue 'over-limit+1' "$(cat "$RS_SNAP/over1.sid")"

# 5. Multi-limit harmless repetitive text (32 MiB) aborts early and leaves no residue
rs_seed_old_rule
rs_make_manifest large
: > "$UPDATE_INIT_CALLS"
rs_run_in_session "$RS_SNAP/large.out" "$RS_SNAP/large.rc" "$RS_SNAP/large.sid"
expect 'T16.78 large repetitive gzip exits 1' 1 "$(cat "$RS_SNAP/large.rc")"
expect 'T16.78 large repetitive gzip reports size limit failure' \
	"decompressed size exceeds ${RULE_SIZE_LIMIT} bytes" "$(get "$(cat "$RS_SNAP/large.out")" failed.chnroute4)"
rs_check_old_unchanged 'large repetitive gzip'
[ ! -s "$UPDATE_INIT_CALLS" ] && ok 'T16.78 large repetitive gzip does not reload' || bad 'T16.78 large repetitive gzip does not reload'
rs_check_no_temp_residue 'large repetitive gzip'
rs_check_no_child_residue 'large repetitive gzip' "$(cat "$RS_SNAP/large.sid")"

# 6. Invalid gzip stream fails cleanly without publishing or leaving residue
rs_seed_old_rule
rs_make_manifest invalid_gz
: > "$UPDATE_INIT_CALLS"
rs_run_in_session "$RS_SNAP/badgz.out" "$RS_SNAP/badgz.rc" "$RS_SNAP/badgz.sid"
expect 'T16.78 invalid gzip exits 1' 1 "$(cat "$RS_SNAP/badgz.rc")"
case "$(get "$(cat "$RS_SNAP/badgz.out")" failed.chnroute4)" in
	gunzip\ exited\ *) ok 'T16.78 invalid gzip reports gunzip failure' ;;
	*) bad 'T16.78 invalid gzip reports gunzip failure' "$(get "$(cat "$RS_SNAP/badgz.out")" failed.chnroute4)" ;;
esac
rs_check_old_unchanged 'invalid gzip'
[ ! -s "$UPDATE_INIT_CALLS" ] && ok 'T16.78 invalid gzip does not reload' || bad 'T16.78 invalid gzip does not reload'
rs_check_no_temp_residue 'invalid gzip'
rs_check_no_child_residue 'invalid gzip' "$(cat "$RS_SNAP/badgz.sid")"

if [ -n "$rs_saved_state" ]; then
	printf '%s\n' "$rs_saved_state" > "$T/run/state.json"
else
	rm -f "$T/run/state.json"
fi
