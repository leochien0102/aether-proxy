#!/usr/bin/env bash
# T9.29: sourced by run.sh; docs/08 "取消三包手动回滚".
# Keep real signed channels available: USAGE must precede all network/package activity.

policy_reset() {
	local package
	make_manifest
	rm -rf "$T/package-inventory"
	mkdir -p "$T/package-inventory"
	export UPDATE_PACKAGE_STATE_DIR="$T/package-inventory"
	export UPDATE_PACKAGE_QUERY_CALLS="$T/package-queries"
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
	printf '26.10.10-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-xray"
	printf '{"state":"running","last_probe":{"ok":true,"at":1}}\n' > "$UPDATE_STATE_FILE"
	: > "$UPDATE_PACKAGE_CALLS"
	: > "$UPDATE_PACKAGE_QUERY_CALLS"
	: > "$UPDATE_INIT_CALLS"
	: > "$UPDATE_SIGNAL_CALLS"
	: > "$T/run/events.jsonl"
}

policy_run() {
	ap update package "$@" --json --confdir "$T/conf" --run-dir "$T/run" \
		--sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr"
}

policy_assert() {
	local label=$1 mode=$2
	if python3 "$ROOT/tests/update/package-assert.py" "$T" "$manager" "$mode" "$out"; then
		ok "T9.29 $manager $label"
	else
		bad "T9.29 $manager $label"
	fi
}

# Exercise the updater API too, so removing just its guard cannot hide behind CLI validation.
cat > "$T/package-api.uc" <<'UCODE'
'use strict';
import * as update from 'aetherproxy.update';
let root = ARGV[0];
let result = update.package_update({ confdir: root + '/conf', run_dir: root + '/run',
	sys_root: root + '/root', bin_dir: root + '/bin' }, ARGV[1], true);
printf('%.J\n', result.value ?? result);
exit(result.exit);
UCODE

for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		for entry in cli api; do
			policy_reset
			out=$(run_check)
			expect "T9.29 $manager $package $entry valid channel before rejection" 0 "$?"
			cp "$T/run/updates.json" "$T/policy-cache"
			cp "$T/http1" "$T/policy-http1"
			cp "$T/http2" "$T/policy-http2"
			: > "$UPDATE_PACKAGE_QUERY_CALLS"
			if [ "$entry" = cli ]; then
				out=$(policy_run "$package" --previous)
			else
				out=$("$UCODE" "$T/package-api.uc" -- "$T" "$package")
			fi
			expect "T9.29 $manager $package $entry previous exit 2" 2 "$?"
			expect "T9.29 $manager $package $entry previous USAGE" USAGE "$(get "$out" code)"
			policy_assert "$package $entry rejected without downloads or installs" "reject:$package"
		done
		# Human-readable output must reject the same request, regardless of flag position.
		policy_reset
		out=$(ap update package --previous "$package" --confdir "$T/conf" \
			--run-dir "$T/run" --sys-root "$T/root" --bin-dir "$T/bin" 2>"$T/stderr")
		expect "T9.29 $manager $package text previous exit 2" 2 "$?"
		grep -q 'only supported for aether-xray' "$T/stderr" \
			&& ok "T9.29 $manager $package text previous explains restriction" \
			|| bad "T9.29 $manager $package text previous explains restriction"
		grep -q '^Usage: aether-proxy update check' "$T/stderr" \
			&& ok "T9.29 $manager $package text previous prints usage" \
			|| bad "T9.29 $manager $package text previous prints usage"
	done

	policy_reset
	printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
	export UPDATE_INIT_FAIL=first
	out=$(policy_run aether-proxy)
	expect "T9.29 $manager backend automatic recovery exit 1" 1 "$?"
	unset UPDATE_INIT_FAIL
	policy_assert 'backend automatic recovery leaves companions skipped' automatic

	# T9.38 groups backend/app forward requests; keep standalone and manual rollback coverage.
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn aether-xray; do
		policy_reset
		out=$(policy_run "$package")
		expect "T9.29 $manager $package forward exit" 0 "$?"
		policy_assert "$package forward respects group policy" "forward:$package"
	done
	policy_reset
	out=$(policy_run aether-xray --previous)
	expect "T9.29 $manager aether-xray independent previous exit" 0 "$?"
	policy_assert 'aether-xray previous unchanged' previous:aether-xray
	if [ "$manager" = apk ]; then
		rm "$T/bin/apk"
	fi
done
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
