#!/usr/bin/env bash
# T11.8: invoke once per real Xray binary (26.3.27 and 26.10.29).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BIN=${1:-aether-xray}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export XRAY_LOCATION_ASSET="$T/assets"
mkdir -p "$XRAY_LOCATION_ASSET"
"$BIN" version
for kind in minimal sni; do
	fixture="$ROOT/tests/fixtures/t118-hysteria-$kind"
	"$ROOT/tests/host/ucode" -S "$ROOT/aether-proxy/src/aether-proxy" -- render xray \
		--confdir "$fixture" --baseline-dir "$ROOT/aether-proxy/files/data" \
		--data-dir "$T/data" --custom-dir "$T/custom" > "$T/xray.json"
	cmp "$T/xray.json" "$fixture/expected/xray.json"
	"$BIN" run -test -c "$T/xray.json"
	echo "PASS  Hysteria2 $kind rendered golden"
done
for kind in missing-auth bad-transport bad-security; do
	fixture="$ROOT/tests/fixtures/t118-hysteria-$kind"
	run="$T/$kind"
	mkdir -p "$run"
	rc=0
	"$ROOT/tests/host/ucode" -S "$ROOT/aether-proxy/src/aether-proxy" -- check --json --no-precheck \
		--confdir "$fixture" --run-dir "$run" > "$T/reply.json" 2> "$T/stderr" || rc=$?
	[ "$rc" -eq 2 ]
	python3 - "$T/reply.json" "$run/events.jsonl" "$T/stderr" "$fixture/expected/error.json" <<'PY'
import json
import pathlib
import sys
reply, events, stderr, expected = map(pathlib.Path, sys.argv[1:])
r = json.loads(reply.read_text())
assert r['ok'] is False and r['code'] == 'CONFIG_INVALID'
assert r['errors'] == json.loads(expected.read_text())['errors']
assert json.loads(events.read_text().splitlines()[0])['code'] == 'CONFIG_INVALID'
for path in [reply, events, stderr]:
    assert 'credential-sentinel' not in path.read_text()
assert not stderr.read_text()
PY
	echo "PASS  Hysteria2 $kind CONFIG_INVALID and auth-free errors/events"
done
