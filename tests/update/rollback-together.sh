#!/usr/bin/env bash
# T9.16: sourced by run.sh to reuse its signed channels and isolated package/init fixtures.
# docs/08 "回滚一起回滚": backend health gates all companion installations.

rollback_reset() {
	local package
	make_manifest
	rm -rf "$T/package-inventory"
	mkdir -p "$T/package-inventory"
	export UPDATE_PACKAGE_STATE_DIR="$T/package-inventory"
	export UPDATE_PACKAGE_QUERY_CALLS="$T/package-queries"
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
	printf '26.10.10-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/xray-core"
	printf '{"state":"running","last_probe":{"ok":true,"at":1}}\n' > "$UPDATE_STATE_FILE"
	: > "$UPDATE_PACKAGE_CALLS"
	: > "$UPDATE_PACKAGE_QUERY_CALLS"
	: > "$UPDATE_INIT_CALLS"
	: > "$UPDATE_SIGNAL_CALLS"
	: > "$T/run/events.jsonl"
}

rollback_run() {
	ap update package "$@" --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr"
}

rollback_manifest_variant() {
	python3 - "$T" "$1" <<'PY'
import json, pathlib, sys
root, variant = pathlib.Path(sys.argv[1]), sys.argv[2]
for channel in ('ch1', 'ch2'):
    path = root / channel / 'manifest.json'
    manifest = json.loads(path.read_text())
    package = manifest['packages']['luci-app-aether-proxy']
    if variant == 'none':
        package['previous'] = None
    elif variant == 'arch':
        package['previous']['assets'] = {'other': package['previous']['assets']['all']}
    elif variant == 'format':
        for assets in package['previous']['assets'].values():
            assets.clear()
    elif variant == 'hash':
        for assets in package['previous']['assets'].values():
            for asset in assets.values():
                asset['sha256'] = '0' * 64
    elif variant == 'all':
        del package['previous']['assets']['aarch64_generic']
    path.write_text(json.dumps(manifest))
PY
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
}

# Check the complete transaction, not just the JSON status: package-manager order,
# actual per-package versions, restart gate, events and the final discovery snapshot.
rollback_assert() {
	local label=$1 mode=$2
	if python3 "$ROOT/tests/update/rollback-assert.py" "$T" "$manager" "$mode" "$out"; then
		ok "T9.16 $manager $label"
	else
		bad "T9.16 $manager $label"
	fi
}

for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for entry in aether-proxy luci-app-aether-proxy; do
		rollback_reset
		out=$(rollback_run "$entry" --previous)
		expect "T9.16 $manager $entry grouped exit" 0 "$?"
		rollback_assert "$entry backend first and both companions rolled_back" success
	done

	rollback_reset
	export UPDATE_INIT_FAIL=first
	out=$(rollback_run luci-app-aether-proxy --previous)
	expect "T9.16 $manager backend check failure exit" 1 "$?"
	unset UPDATE_INIT_FAIL
	rollback_assert 'backend restored without touching companions' backend

	rollback_reset
	export UPDATE_INSTALL_FAIL_PACKAGE=aether-proxy
	out=$(rollback_run aether-proxy --previous)
	expect "T9.16 $manager backend install failure exit" 1 "$?"
	unset UPDATE_INSTALL_FAIL_PACKAGE
	rollback_assert 'backend install failure preserves original error fields' backend-install

	for variant in none arch format; do
		rollback_reset
		rm "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn"
		rollback_manifest_variant "$variant"
		out=$(rollback_run luci-app-aether-proxy --previous)
		expect "T9.16 $manager $variant missing companions exit" 0 "$?"
		rollback_assert "$variant unavailable app and uninstalled i18n skipped" skipped
	done

	rollback_reset
	rollback_manifest_variant all
	out=$(rollback_run aether-proxy --previous)
	expect "T9.16 $manager all-architecture fallback exit" 0 "$?"
	rollback_assert 'all-architecture companion fallback' all

	for package in luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		rollback_reset
		export UPDATE_INSTALL_FAIL_PACKAGE="$package"
		out=$(rollback_run aether-proxy --previous)
		expect "T9.16 $manager $package failure exit" 1 "$?"
		unset UPDATE_INSTALL_FAIL_PACKAGE
		rollback_assert "$package failed without restoring backend" "$package"
	done

	rollback_reset
	rollback_manifest_variant hash
	out=$(rollback_run aether-proxy --previous)
	expect "T9.16 $manager companion bad hash exit" 1 "$?"
	rollback_assert 'bad hash never installs app and still rolls back i18n' hash

	# All forward installs and the two independent downgrade entry points retain their
	# original result shape and touch exactly one package (including health activation).
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn xray-core; do
		rollback_reset
		out=$(rollback_run "$package")
		expect "T9.16 $manager $package forward exit" 0 "$?"
		rollback_assert "$package forward unchanged" "forward:$package"
	done
	for package in xray-core luci-i18n-aether-proxy-zh-cn; do
		rollback_reset
		out=$(rollback_run "$package" --previous)
		expect "T9.16 $manager $package independent previous exit" 0 "$?"
		rollback_assert "$package previous unchanged" "previous:$package"
	done
	if [ "$manager" = apk ]; then
		rm "$T/bin/apk"
	fi
done
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
