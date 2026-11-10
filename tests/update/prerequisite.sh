#!/usr/bin/env bash
# M4-03b: signed transactions exercise real discovery and mutable package metadata.
prereq_prepare() {
	policy_reset
	unset UPDATE_DNS_BASELINE
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
for scenario in T1 T2 T3 T4-download T4-hash T5 T6 T7 T8 T9 T10 T12; do
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
		T10)
			python3 "$ROOT/tests/update/bridge-manifest.py" "$T" valid
			printf '0.6.3-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy" ;;
	esac
	if [ "$scenario" = T9 ]; then printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"; fi
	if [ "$scenario" = T6 ]; then
		python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" recovery
	fi
	if [ "$scenario" = T4-download ] || [ "$scenario" = T4-hash ] || [ "$scenario" = T12 ]; then
		python3 "$ROOT/tests/update/prerequisite-manifest.py" "$T" "$scenario"
	fi
	prereq_sign
	case "$scenario" in T5|T6) export UPDATE_INSTALL_FAIL_PACKAGE=aether-proxy ;; esac
	out=$(policy_run aether-proxy)
	rc=$?
	case "$scenario" in T4-*|T5|T6|T7) expected=1 ;; *) expected=0 ;; esac
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
		out=$(policy_run aether-proxy)
		expect 'M4-03b T11 retry exit' 0 "$?"
		prereq_assert T11
		: > "$UPDATE_PACKAGE_CALLS"
		: > "$UPDATE_INIT_CALLS"
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
unset UPDATE_ENGINE_BIN_DIR UPDATE_ENGINE_PROBES
export UPDATE_DNS_BASELINE=1
prereq_binary aether-dns 1.0.0
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
