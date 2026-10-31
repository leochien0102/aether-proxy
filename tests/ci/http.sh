#!/usr/bin/env bash
# T11.2: real aether-xray golden validation and CLI/event credential-safety checks.
# Pass the host aether-xray path as $1, or install it in PATH (no mock binary).
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BIN=${1:-aether-xray}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export XRAY_LOCATION_ASSET="$T/assets"
mkdir -p "$XRAY_LOCATION_ASSET"
"$BIN" version
for kind in no-auth auth; do
	"$BIN" run -test -c "$ROOT/tests/fixtures/t112-http-$kind/expected/xray.json"
	echo "PASS  HTTP $kind aether-xray golden"
done
for missing in username password; do
	run="$T/$missing"
	mkdir -p "$run"
	rc=0
	"$ROOT/tests/host/ucode" -S "$ROOT/aether-proxy/src/aether-proxy" -- check --json --no-precheck \
		--confdir "$ROOT/tests/fixtures/t112-http-missing-$missing" --run-dir "$run" \
		> "$T/reply.json" 2> "$T/stderr" || rc=$?
	[ "$rc" -eq 2 ]
	python3 - "$T/reply.json" "$run/events.jsonl" "$T/stderr" "$missing" <<'PY'
import json
import pathlib
import sys
reply, events, stderr, missing = sys.argv[1:]
r = json.loads(pathlib.Path(reply).read_text())
assert r['ok'] is False and r['code'] == 'CONFIG_INVALID'
assert r['errors'][0]['field'] == 'node.n_' + 'a' * 32 + '.' + missing
assert r['errors'][0]['code'] == 'required'
log = pathlib.Path(events).read_text()
assert json.loads(log.splitlines()[0])['code'] == 'CONFIG_INVALID'
for filename in [reply, events, stderr]:
    assert 'test-secret' not in pathlib.Path(filename).read_text()
PY
	echo "PASS  HTTP missing $missing CONFIG_INVALID field and secret-free events"
done
