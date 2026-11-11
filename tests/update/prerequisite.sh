#!/usr/bin/env bash
# M4-03b: signed transactions exercise real discovery and mutable package metadata.
prereq_prepare() {
	policy_reset
	python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" target
	export UPDATE_ENGINE_PROBES="$T/engine-probes"
	: > "$UPDATE_ENGINE_PROBES"
	export UPDATE_ENGINE_BIN_DIR="$T/bin"
	rm -f "$T/bin/aether-dns" "$T/bin/chinadns-ng"
	printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
	# Existing pages are already current; only the backend needs an install.
	for package in luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
}
prereq_binary() {
	printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$UPDATE_ENGINE_PROBES"\necho "%s %s"\n' "$1" "$2" > "$T/bin/$1"
	chmod +x "$T/bin/$1"
}
prereq_sign() {
	for channel in ch1 ch2; do
		"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
	done
}
prereq_assert() {
	if python3 "$ROOT/tests/update/prerequisite-assert.py" "$T" "$1" "$out"; then
		ok "M4-03b $1 prerequisite transaction"
	else
		bad "M4-03b $1 prerequisite transaction"
	fi
}
"$UCODE" "$ROOT/tests/update/prerequisite-unit.uc"
expect 'M4-03b pure prerequisite decisions exit' 0 "$?"
for scenario in T1 T2 T3 T4-download T4-hash T5 T6 T7 T8 T9 T10 T12 T14 T14-bridge; do
	prereq_prepare
	case "$scenario" in
		T1|T9)
			printf '1.0.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-dns"
			printf 'dns-engine\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-dns.provides"
			prereq_binary aether-dns 1.0.0 ;;
		T3) prereq_binary chinadns-ng 2025.08.09 ;;
		T6|T7)
			printf '2026.11.04-r2\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-dns"
			prereq_binary aether-dns 2026.11.04 ;;
		T8)
			prereq_binary custom-engine 0.1.0
			printf "config main 'main'\n option chinadns_bin '%s'\n" "$T/bin/custom-engine" >> "$T/conf/aetherproxy" ;;
		T10|T14|T14-bridge)
			python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" "$scenario"
			if [ "$scenario" != T10 ]; then
				printf '0.7.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
			fi ;;
	esac
	if [ "$scenario" = T9 ]; then printf '1.0.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"; fi
	if [ "$scenario" = T6 ]; then
		python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" recovery
	fi
	if [ "$scenario" = T4-download ] || [ "$scenario" = T4-hash ] || [ "$scenario" = T12 ]; then
		python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" "$scenario"
	fi
	prereq_sign
	if [ "$scenario" = T12 ]; then
		out=$(run_check)
		expect 'M4-03b T12 unknown package check exit' 0 "$?"
		expect 'M4-03b T12 check retains backend target' 1.0.0-r1 "$(get "$out" packages.aether-proxy.available)"
	fi
	case "$scenario" in T5|T6) export UPDATE_INSTALL_FAIL_PACKAGE=aether-proxy ;; esac
	out=$(policy_run aether-proxy)
	rc=$?
	case "$scenario" in T4-*|T5|T6|T7|T14-bridge) expected=1 ;; *) expected=0 ;; esac
	expect "M4-03b $scenario exit" "$expected" "$rc"
	prereq_assert "$scenario"
	if [ "$scenario" = T8 ]; then
		"$UCODE" -e "import * as check from 'aetherproxy.cmd.check';
			print(check.find_component('chinadns-ng', '$T/bin/custom-engine', { bin_dir: '$T/bin' }).path);" \
			> "$T/selected-custom-engine"
		expect 'M4-03b T8 selected custom engine is unchanged' "$T/bin/custom-engine" "$(< "$T/selected-custom-engine")"
	fi
	if [ "$scenario" = T1 ]; then
		expect 'M4-03b T1 one runtime version probe' 1 "$(wc -l < "$UPDATE_ENGINE_PROBES" | tr -d ' ')"
	fi
	unset UPDATE_INSTALL_FAIL_PACKAGE
	if [ "$scenario" = T5 ]; then
		: > "$UPDATE_PACKAGE_CALLS"
		: > "$T/run/events.jsonl"
		out=$(policy_run aether-proxy)
		expect 'M4-03b T11 retry exit' 0 "$?"
		prereq_assert T11
		: > "$UPDATE_PACKAGE_CALLS"
		: > "$UPDATE_INIT_CALLS"
		: > "$T/run/events.jsonl"
		out=$(policy_run aether-proxy)
		prereq_assert T11-idempotent
	fi
	if [ "$scenario" = T8 ]; then
		python3 - "$T/conf/aetherproxy" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().split("config main 'main'")[0])
PY
	fi
done
# M4-05: a date version is numerically newer; both managers must still install
# the exact local 1.0.0 asset, and restore the exact date asset on backend failure.
for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for outcome in success rollback; do
		prereq_prepare
		printf '2026.11.04-r2\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-dns"
		prereq_binary aether-dns 2026.11.04
		python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" recovery
		prereq_sign
		if [ "$outcome" = rollback ]; then export UPDATE_INSTALL_FAIL_PACKAGE=aether-proxy; fi
		out=$(policy_run aether-proxy)
		rc=$?
		if [ "$outcome" = success ]; then expected=0; else expected=1; fi
		expect "M4-05 $manager date downgrade $outcome exit" "$expected" "$rc"
		if python3 "$ROOT/tests/update/downgrade-assert.py" "$T" "$manager" "$outcome" "$out"; then
			ok "M4-05 $manager date downgrade $outcome exact arguments and inventory"
		else
			bad "M4-05 $manager date downgrade $outcome exact arguments and inventory"
		fi
		if [ "$manager" = opkg ] && [ "$outcome" = success ]; then
			components=$(ap components --json --confdir "$T/conf" --bin-dir "$T/bin")
			expect 'M4-05 migrated components inventory exit' 0 "$?"
			expect 'M4-05 migrated components.dns.version' 1.0.0 "$(get "$components" components.dns.version)"
			expect 'M4-05 migrated components.dns.engine' aether-dns "$(get "$components" components.dns.engine)"
		fi
		unset UPDATE_INSTALL_FAIL_PACKAGE
	done
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
rm -f "$T/bin/aether-dns" "$T/bin/chinadns-ng" "$T/bin/custom-engine"
unset UPDATE_ENGINE_BIN_DIR UPDATE_ENGINE_PROBES
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
