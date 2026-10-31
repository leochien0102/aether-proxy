#!/usr/bin/env bash
# B24 migration scenarios share the signed local channel and package stubs in run.sh.
# Keep a real installed legacy package throughout: absence alone cannot prove non-interference.

b24_manifest() {
	make_manifest
	python3 - "$T" "$1" "${2:-26.10.21-r1}" <<'PY'
import copy
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for channel in ('ch1', 'ch2'):
    path = root / channel / 'manifest.json'
    manifest = json.loads(path.read_text())
    owned = manifest['packages']['aether-xray']
    owned['current']['version'] = sys.argv[3]
    for formats in owned['current']['assets'].values():
        for asset in formats.values():
            original = root / channel / asset['url']
            asset['url'] = asset['url'].replace('26.10.10-r1', sys.argv[3])
            (root / channel / asset['url']).write_bytes(original.read_bytes())
    if sys.argv[2] != 'owned-only':
        legacy = copy.deepcopy(owned)
        legacy['current']['version'] = '99.1.1-r99'
        manifest['packages']['xray-core'] = legacy
    if sys.argv[2] == 'legacy-only':
        del manifest['packages']['aether-xray']
    path.write_text(json.dumps(manifest))
PY
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
}

b24_update() {
	ap update package "$@" --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr"
}

cp "$UPDATE_STATE_FILE" "$T/b24-state-before"
export UPDATE_PACKAGE_STATE_DIR="$T/b24-installed" UPDATE_PACKAGE_QUERY_CALLS="$T/b24-queries"
mkdir -p "$UPDATE_PACKAGE_STATE_DIR"
printf '99.1.1-ssrplus\n' > "$UPDATE_PACKAGE_STATE_DIR/xray-core"
cp "$UPDATE_PACKAGE_STATE_DIR/xray-core" "$T/b24-legacy-before"
cat > "$T/bin/aether-xray" <<'OWNED'
#!/bin/sh
printf '%s\n' owned >> "$UPDATE_BINARY_CALLS"
if [ "${UPDATE_OWNED_WRONG:-0}" = 1 ]; then
	printf 'Xray wrong-version\n'
else
	version=$(cat "$UPDATE_PACKAGE_STATE_DIR/aether-xray") || exit 1
	printf 'Xray %s\n' "${version%-*}"
fi
OWNED
cat > "$T/bin/xray" <<'FALLBACK'
#!/bin/sh
printf '%s\n' fallback >> "$UPDATE_BINARY_CALLS"
printf 'Xray 26.10.21\n'
FALLBACK
chmod +x "$T/bin/aether-xray" "$T/bin/xray"
export UPDATE_BINARY_CALLS="$T/b24-binary-calls"
cp "$T/conf/aetherproxy" "$T/b24-config-before"
printf "\nconfig main 'main'\n option xray_bin '%s'\n" "$T/bin/xray" >> "$T/conf/aetherproxy"

for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		# This fixture also exercises firmware packages with a plain -N release suffix.
		python3 - "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('-r[0-9]+', '-r?[0-9]+'))
PY
		chmod +x "$T/bin/apk"
	fi
	# Observe every invocation, including unsupported remove/del requests, not just installs.
	mv "$T/bin/$manager" "$T/bin/$manager.b24"
	cat > "$T/bin/$manager" <<'MANAGER'
#!/bin/sh
printf '%s\n' "$*" >> "$B24_PM_CALLS"
exec "$0.b24" "$@"
MANAGER
	chmod +x "$T/bin/$manager"
	export B24_PM_CALLS="$T/b24-pm-calls"
	for variant in owned-only both legacy-only; do
		b24_manifest "$variant"
		printf '26.9.30-r9\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-xray"
		: > "$B24_PM_CALLS"
		: > "$UPDATE_PACKAGE_QUERY_CALLS"
		: > "$UPDATE_PACKAGE_CALLS"
		: > "$UPDATE_BINARY_CALLS"
		printf '{"state":"stopped"}\n' > "$UPDATE_STATE_FILE"
		out=$(run_check)
		expect "T10.73 $manager $variant signed check succeeds" 0 "$?"
		python3 - "$T/run/updates.json" "$variant" <<'PY'
import json
import sys

packages = json.load(open(sys.argv[1]))['packages']
assert 'xray-core' not in packages, packages
if sys.argv[2] == 'legacy-only':
    assert 'aether-xray' not in packages, packages
else:
    owned = packages['aether-xray']
    assert owned['installed'] == '26.9.30-r9', owned
    assert owned['available'] == '26.10.21-r1' and owned['newer'] is True, owned
PY
		expect "T10.73 $manager $variant cache only manages owned package" 0 "$?"
		if [ "$variant" != legacy-only ]; then
			out=$(b24_update aether-xray)
			expect "T10.73 $manager $variant install verifies owned base version" 0 "$?"
			expect "T10.73 $manager $variant installed target" 26.10.21-r1 "$(get "$out" to)"
			out=$(b24_update aether-xray --previous)
			expect "T10.73 $manager $variant previous succeeds" 0 "$?"
			expect "T10.73 $manager $variant previous target" 26.7.28-r1 "$(get "$out" to)"
			# A matching fallback must not conceal a broken/missing owned installation.
			export UPDATE_OWNED_WRONG=1
			out=$(b24_update aether-xray)
			expect "T10.73 $manager $variant wrong owned version fails" UPDATE_VERIFY_FAILED "$(get "$out" code)"
			expect "T10.73 $manager $variant wrong owned version rolls back" true "$(get "$out" rolled_back)"
			unset UPDATE_OWNED_WRONG
			mv "$T/bin/aether-xray" "$T/bin/aether-xray.saved"
			out=$(b24_update aether-xray)
			expect "T10.73 $manager $variant missing owned binary never verifies fallback" UPDATE_VERIFY_FAILED "$(get "$out" code)"
			mv "$T/bin/aether-xray.saved" "$T/bin/aether-xray"
		fi
		for previous in '' --previous; do
			out=$(b24_update xray-core $previous)
			expect "T10.73 $manager $variant legacy $previous rejected" 2 "$?"
		done
		python3 - "$UPDATE_PACKAGE_QUERY_CALLS" "$UPDATE_PACKAGE_CALLS" "$UPDATE_BINARY_CALLS" "$B24_PM_CALLS" <<'PY'
from pathlib import Path
import sys

for filename in sys.argv[1:3]:
    assert 'xray-core' not in Path(filename).read_text(), Path(filename).read_text()
assert 'fallback' not in Path(sys.argv[3]).read_text()
assert 'xray-core' not in Path(sys.argv[4]).read_text(), Path(sys.argv[4]).read_text()
PY
		expect "T10.73 $manager $variant no legacy query install remove or fallback verification" 0 "$?"
		cmp -s "$T/b24-legacy-before" "$UPDATE_PACKAGE_STATE_DIR/xray-core"
		expect "T10.73 $manager $variant installed legacy package preserved" 0 "$?"
	done
	b24_manifest owned-only 26.10.21-1
	out=$(b24_update aether-xray)
	expect "T10.73 $manager plain release verifies 26.10.21 base version" 0 "$?"
	expect "T10.73 $manager plain release target" 26.10.21-1 "$(get "$out" to)"
	mv "$T/bin/$manager.b24" "$T/bin/$manager"
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
rm "$T/bin/aether-xray" "$T/bin/xray"
cp "$T/b24-config-before" "$T/conf/aetherproxy"
cp "$T/b24-state-before" "$UPDATE_STATE_FILE"
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS UPDATE_BINARY_CALLS B24_PM_CALLS
make_manifest
