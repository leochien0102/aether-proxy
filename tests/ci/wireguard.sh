#!/usr/bin/env bash
# T11.3: real Xray golden preflight plus secret-free CLI/error/event rejection paths.
# Invoke once per target Xray binary, with its path as $1.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BIN=${1:-aether-xray}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export XRAY_LOCATION_ASSET="$T/assets"
mkdir -p "$XRAY_LOCATION_ASSET"
"$BIN" version
for kind in basic psk zero; do
	"$BIN" run -test -c "$ROOT/tests/fixtures/t113-wireguard-$kind/expected/xray.json"
	echo "PASS  WireGuard $kind golden"
done
for fixture in "$ROOT"/tests/fixtures/t113-wireguard-{missing,bad}-*; do
	name=${fixture##*/}
	run="$T/$name"
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
    text = path.read_text()
    assert 'credential-sentinel' not in text
    assert 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=' not in text
assert not stderr.read_text()
PY
	echo "PASS  WireGuard $name CONFIG_INVALID and credential-free errors/events"
done
