#!/usr/bin/env bash
# T16.77: verify update.uc curl protocol whitelist and `--` URL separation
# on both direct and proxied-first/fallback paths, plus real curl over local HTTP 302 redirect.

"$UCODE" "$ROOT/tests/update/protocol-policy.uc" -- "$ROOT/aether-proxy/src/lib/update.uc" "$T"
expect 'T16.77 unit argv policy (direct + proxy-fallback)' 0 "$?"

PROTO_BIN="$T/proto-bin"
PROTO_LOG="$T/proto-curl-argv.jsonl"
REAL_CURL="$(command -v curl)"
mkdir -p "$PROTO_BIN" "$T/root/proc/net"
cat > "$PROTO_BIN/curl" <<'SHIM'
#!/usr/bin/env python3
import json, os, sys

argv = ['curl'] + sys.argv[1:]
with open(os.environ['PROTO_CURL_LOG'], 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(argv) + '\n')

if '-x' in sys.argv[1:]:
    sys.stderr.write('curl: (7) proxy connect refused (injected by T16.77 test shim)\n')
    sys.exit(7)

env = {
    k: v for k, v in os.environ.items()
    if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
}
os.execve(os.environ['PROTO_REAL_CURL'], argv, env)
SHIM
chmod +x "$PROTO_BIN/curl"

make_manifest
printf 'T16.77-REDIRECT-PAYLOAD\n' > "$T/ch1/proto-asset.bin"
proto_sha=$(sha256sum "$T/ch1/proto-asset.bin" | cut -d' ' -f1)
proto_size=$(stat -c %s "$T/ch1/proto-asset.bin")
proto_base="http://127.0.0.1:$PORT3/"

verify_proto_log() {
	python3 - "$PROTO_LOG" "$1" "$proto_base" <<'PY'
import json, sys

log_path, mode, base = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(line) for line in open(log_path, encoding='utf-8') if line.strip()]

def has_pair(argv, flag, value):
    for i in range(len(argv) - 1):
        if argv[i] == flag and argv[i + 1] == value:
            return i
    return -1

def check_row(argv, expected_url, expect_proxy):
    assert argv[0] == 'curl', f'bad bin: {argv}'
    for flag in ('--fail', '--silent', '--show-error', '--location'):
        assert flag in argv, f'missing {flag}: {argv}'
    assert has_pair(argv, '--max-redirs', '5') >= 0, f'missing --max-redirs 5: {argv}'
    assert has_pair(argv, '--proto', '=http,https') >= 0, f'missing --proto =http,https: {argv}'
    assert has_pair(argv, '--proto-redir', '=http,https') >= 0, f'missing --proto-redir =http,https: {argv}'
    proxy_idx = has_pair(argv, '-x', 'http://127.0.0.1:31081')
    if expect_proxy:
        assert proxy_idx >= 0, f'expected proxy -x: {argv}'
        assert proxy_idx < len(argv) - 4, f'-x must precede -o <path> -- <url>: {argv}'
    else:
        assert '-x' not in argv, f'unexpected -x on direct route: {argv}'
    assert len(argv) >= 4 and argv[-4] == '-o' and argv[-2] == '--' and argv[-1] == expected_url, (
        f'bad trailing argv for {expected_url}: {argv[-4:]}'
    )

urls = [f'{base}manifest.json', f'{base}manifest.json.sig', f'{base}proto-asset.bin']
if mode == 'direct':
    expected = [(u, False) for u in urls]
elif mode == 'proxy-fallback':
    expected = []
    for u in urls:
        expected.append((u, True))
        expected.append((u, False))
else:
    raise SystemExit(f'unknown mode: {mode}')

assert len(rows) == len(expected), f'{mode}: expected {len(expected)} curl calls, got {len(rows)}: {rows}'
for argv, (url, expect_proxy) in zip(rows, expected):
    check_row(argv, url, expect_proxy)
PY
}

# 1. Direct route over local HTTP 302 redirect (PORT3 -> PORT1)
rm -f "$T/root/proc/net/tcp" "$T/root/proc/net/tcp6"
: > "$PROTO_LOG"
out=$(PATH="$PROTO_BIN:$PATH" PROTO_CURL_LOG="$PROTO_LOG" PROTO_REAL_CURL="$REAL_CURL" \
	ap update check --json --confdir "$T/conf-redirect" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null)
expect 'T16.77 direct HTTP redirect check succeeds' 0 "$?"
out=$(PATH="$PROTO_BIN:$PATH" PROTO_CURL_LOG="$PROTO_LOG" PROTO_REAL_CURL="$REAL_CURL" \
	download_asset "$proto_base" 'proto-asset.bin' "$proto_size" "$proto_sha" 'proto-direct.bin')
expect 'T16.77 direct HTTP redirect asset download exits 0' 0 "$?"
expect 'T16.77 direct HTTP redirect asset download ok' true "$(get "$out" ok)"
expect 'T16.77 direct HTTP redirect asset payload matches' 'T16.77-REDIRECT-PAYLOAD' "$(cat "$DL_ROOT/proto-direct.bin")"
if verify_proto_log direct; then
	ok 'T16.77 direct real curl argv verified'
else
	bad 'T16.77 direct real curl argv verified'
fi

# 2. Proxied-first with direct fallback over local HTTP 302 redirect
saved_state=''
[ -f "$T/run/state.json" ] && saved_state=$(cat "$T/run/state.json")
saved_root_state=''
[ -f "$T/root/var/run/aether-proxy/state.json" ] && saved_root_state=$(cat "$T/root/var/run/aether-proxy/state.json")
printf '{"state":"running"}\n' > "$T/run/state.json"
printf '{"state":"running"}\n' > "$T/root/var/run/aether-proxy/state.json"
printf '  sl  local_address rem_address   st\n   0: 0100007F:7969 00000000:0000 0A\n' > "$T/root/proc/net/tcp"
: > "$PROTO_LOG"
out=$(PATH="$PROTO_BIN:$PATH" PROTO_CURL_LOG="$PROTO_LOG" PROTO_REAL_CURL="$REAL_CURL" \
	ap update check --json --confdir "$T/conf-redirect" --run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>/dev/null)
expect 'T16.77 proxy-fallback HTTP redirect check succeeds' 0 "$?"
out=$(PATH="$PROTO_BIN:$PATH" PROTO_CURL_LOG="$PROTO_LOG" PROTO_REAL_CURL="$REAL_CURL" \
	download_asset "$proto_base" 'proto-asset.bin' "$proto_size" "$proto_sha" 'proto-fallback.bin')
expect 'T16.77 proxy-fallback HTTP redirect asset download exits 0' 0 "$?"
expect 'T16.77 proxy-fallback HTTP redirect asset download ok' true "$(get "$out" ok)"
expect 'T16.77 proxy-fallback HTTP redirect asset payload matches' 'T16.77-REDIRECT-PAYLOAD' "$(cat "$DL_ROOT/proto-fallback.bin")"
if verify_proto_log proxy-fallback; then
	ok 'T16.77 proxy-fallback real curl argv verified'
else
	bad 'T16.77 proxy-fallback real curl argv verified'
fi

rm -f "$T/root/proc/net/tcp" "$T/root/proc/net/tcp6"
if [ -n "$saved_state" ]; then
	printf '%s\n' "$saved_state" > "$T/run/state.json"
else
	rm -f "$T/run/state.json"
fi
if [ -n "$saved_root_state" ]; then
	printf '%s\n' "$saved_root_state" > "$T/root/var/run/aether-proxy/state.json"
else
	rm -f "$T/root/var/run/aether-proxy/state.json"
fi
