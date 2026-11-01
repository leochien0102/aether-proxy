#!/usr/bin/env bash
# T11.14: sourced by run.sh; signed CLI installs advance exactly one backend step.
bridge_prepare() {
	local scenario=$1 installed=$2 channel package
	policy_reset
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '0.6.3-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
	printf '%s\n' "$installed" > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
	python3 "$ROOT/tests/update/bridge-manifest.py" "$T" "$scenario"
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
}
bridge_assert() {
	local label=$1 mode=$2 installed=$3 target=$4
	if python3 "$ROOT/tests/update/bridge-assert.py" "$T" "$manager" "$mode" "$installed" "$target" "$out"; then
		ok "T11.14 $manager $label transactions and inventory"
	else
		bad "T11.14 $manager $label transactions and inventory"
	fi
}
for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		bridge_prepare valid 0.6.3-r1
		installed=0.6.3-r1
		for target in 0.6.4-r1 0.6.6-r1 0.6.8-r1; do
			: > "$UPDATE_PACKAGE_CALLS"
			out=$(run_check)
			expect "T11.14 $manager $package check $target exit" 0 "$?"
			bridge_assert "$package check $target" check "$installed" "$target"
			out=$(policy_run "$package")
			expect "T11.14 $manager $package chain $installed -> $target exit" 0 "$?"
			bridge_assert "$package chain $installed -> $target" installed "$installed" "$target"
			installed=$target
		done
	done
	for scenario in null-chain empty-chain missing reordered rejoined wrong-version wrong-terminal no-reason blank-reason later-platform-missing bad-metadata bad-hash bad-bytes download-missing exact-revision exact-release-alias; do
		installed=0.6.3-r1
		if [ "$scenario" = exact-revision ]; then installed=0.6.3-r2; fi
		if [ "$scenario" = exact-release-alias ]; then installed=0.6.3-1; fi
		bridge_prepare "$scenario" "$installed"
		out=$(policy_run aether-proxy)
		expect "T11.14 $manager $scenario exit" 1 "$?"
		bridge_assert "$scenario" blocked "$installed" 0.6.4-r1
	done
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		bridge_prepare valid 0.6.4-r1
		out=$(policy_run "$package" --previous)
		expect "T11.14 $manager $package --previous exit" 2 "$?"
		bridge_assert "$package --previous guard" guard 0.6.4-r1 0.6.6-r1
	done
	while IFS='|' read -r scenario installed target mode; do
		bridge_prepare "$scenario" "$installed"
		export UPDATE_INIT_FAIL=first AETHER_PROXY_TEST_UPDATE_WAIT_SECS=0
		# This case must fail installed-version verification, not the restart.
		if [ "$mode" = mismatch-rollback ]; then unset UPDATE_INIT_FAIL; fi
		out=$(policy_run aether-proxy)
		expect "T11.14 $manager $scenario $installed rollback exit" 1 "$?"
		bridge_assert "$scenario $installed rollback" "$mode" "$installed" "$target"
		unset UPDATE_INIT_FAIL AETHER_PROXY_TEST_UPDATE_WAIT_SECS
	done <<'BRIDGE_ROLLBACK_CASES'
installed-version-mismatch|0.6.3-r1|0.6.4-r1|mismatch-rollback
valid|0.6.3-r1|0.6.4-r1|rollback
valid|0.6.4-r1|0.6.6-r1|rollback
valid|0.6.6-r1|0.6.8-r1|rollback
rollback-unmatched|0.6.3-r1|0.6.4-r1|no-rollback
rollback-previous-target|0.6.3-r1|0.6.4-r1|no-rollback
BRIDGE_ROLLBACK_CASES
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
