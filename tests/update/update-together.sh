#!/usr/bin/env bash
# T9.38, sourced by run.sh: signed current assets, real updater and per-package
# opkg/apk inventories prove docs/08 "更新一起更新" without system writes.

group_prepare() {
	local scenario=$1 package
	policy_reset
	for package in aether-proxy luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
	printf '26.7.28-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-xray"
	case "$scenario" in
		pages-only|all-current|app-current|i18n-current)
			printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy" ;;
		backend-newer)
			printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy" ;;
	esac
	case "$scenario" in
		missing-i18n) rm "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
		missing-app) rm "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy" ;;
		all-current)
			printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy"
			printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
		app-current) printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy" ;;
		i18n-current) printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
		app-install-fails|first-failure) export UPDATE_INSTALL_FAIL_PACKAGE=luci-app-aether-proxy ;;
		backend-install-fails) export UPDATE_INSTALL_FAIL_PACKAGE=aether-proxy ;;
		backend-recovers|app-entry-recovers) export UPDATE_INIT_FAIL=first ;;
	esac
	python3 "$ROOT/tests/update/group-manifest.py" "$T" "$scenario"
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
}

for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	while IFS='|' read -r scenario package expected_exit; do
		group_prepare "$scenario"
		cp "$T/run/updates.json" "$T/group-cache-before"
		out=$(policy_run "$package")
		expect "T9.38 $manager $scenario exit $expected_exit" "$expected_exit" "$?"
		if python3 "$ROOT/tests/update/group-assert.py" "$T" "$manager" "$scenario" "$package" "$out"; then
			ok "T9.38 $manager $scenario ordered transactions and result"
		else
			bad "T9.38 $manager $scenario ordered transactions and result"
		fi
		unset UPDATE_INSTALL_FAIL_PACKAGE UPDATE_INIT_FAIL
	done <<'GROUP_CASES'
all-new|aether-proxy|0
app-entry|luci-app-aether-proxy|0
pages-only|aether-proxy|0
backend-newer|luci-app-aether-proxy|0
backend-recovers|aether-proxy|1
app-entry-recovers|luci-app-aether-proxy|1
missing-i18n|aether-proxy|0
missing-app|aether-proxy|0
app-no-current|aether-proxy|0
i18n-no-asset|aether-proxy|0
app-all-asset|aether-proxy|0
app-current|aether-proxy|0
i18n-current|aether-proxy|0
all-current|luci-app-aether-proxy|0
app-install-fails|aether-proxy|1
app-download-fails|aether-proxy|1
i18n-hash-fails|luci-app-aether-proxy|1
first-failure|aether-proxy|1
backend-install-fails|luci-app-aether-proxy|1
backend-hash-fails|aether-proxy|1
backend-no-asset|luci-app-aether-proxy|1
single-i18n|luci-i18n-aether-proxy-zh-cn|0
single-xray|aether-xray|0
GROUP_CASES
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
