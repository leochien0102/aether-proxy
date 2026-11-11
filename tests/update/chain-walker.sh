#!/usr/bin/env bash
# M4-07: sourced after prerequisite.sh; real CLI + signatures, simulated package inventory.
walker_prepare() {
	prereq_prepare
	printf '0.6.3-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
	for package in luci-app-aether-proxy luci-i18n-aether-proxy-zh-cn; do
		printf '1.0.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/$package"
	done
	python3 "$ROOT/tests/update/walker-fixture.py" "$T" valid
	prereq_sign
	: > "$T/handoffs"
	rm -f "$T/legacy-done"
	cp "$T/bin/aether-proxy" "$T/original-cli"
	cat > "$T/new-cli" <<'WRAPPER'
#!/bin/sh
if [ "$1" = update ]; then
	printf '%s %s %s\n' "$AETHER_PROXY_CHAIN_DEADLINE" \
		"$AETHER_PROXY_CHAIN_LEFT" "$AETHER_PROXY_CHAIN_FROM" >> "$WALKER_T/handoffs"
	case "$WALKER_MODE" in
		legacy-no-progress)
			printf '{"ok":true,"code":"BRIDGE_INSTALLED","steps_remaining":0}\n'
			exit 0 ;;
		legacy)
			if [ ! -f "$WALKER_T/legacy-done" ]; then
				printf '0.8.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
				touch "$WALKER_T/legacy-done"
				printf '{"ok":true,"code":"BRIDGE_INSTALLED","to":"0.8.0-r1","steps_remaining":1}\n'
				exit 0
			fi ;;
		fail) export UPDATE_INSTALL_FAIL_PACKAGE=aether-proxy ;;
		timeout)
			# Model budget consumed before the successor admits its next transaction.
			AETHER_PROXY_CHAIN_DEADLINE=$(python3 -c 'import time; print(time.monotonic()+179)') || exit 1
			export AETHER_PROXY_CHAIN_DEADLINE ;;
		extend)
			python3 "$WALKER_ROOT/tests/update/walker-fixture.py" "$WALKER_T" extend || exit 1
			for channel in ch1 ch2; do
				"$WALKER_USIGN" -S -m "$WALKER_T/$channel/manifest.json" -s "$WALKER_T/sec" || exit 1
			done ;;
		bad-signature) printf ' ' >> "$WALKER_T/ch1/manifest.json"; printf ' ' >> "$WALKER_T/ch2/manifest.json" ;;
		no-progress) printf '0.6.3-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy" ;;
	esac
fi
exec "$WALKER_UCODE" -S "$WALKER_ENTRY" -- "$@"
WRAPPER
	chmod +x "$T/new-cli"
	cp "$T/root/etc/init.d/aether-proxy" "$T/original-init"
	cat > "$T/root/etc/init.d/aether-proxy" <<'INIT'
#!/bin/sh
printf '%s\n' "$*" >> "$UPDATE_INIT_CALLS"
# Simulate the on-disk CLI replacement becoming visible after this hop's restart.
cp "$WALKER_T/new-cli" "$WALKER_T/bin/aether-proxy"
INIT
	chmod +x "$T/root/etc/init.d/aether-proxy"
	export WALKER_T="$T" WALKER_ROOT="$ROOT" WALKER_USIGN="$USIGN"
	export WALKER_UCODE="$UCODE" WALKER_ENTRY="$ENTRY" WALKER_MODE=normal
}
walker_restore() {
	cp "$T/original-cli" "$T/bin/aether-proxy"
	cp "$T/original-init" "$T/root/etc/init.d/aether-proxy"
}
walker_assert() {
	if python3 "$ROOT/tests/update/walker-assert.py" "$T" "$1" "$out"; then
		ok "M4-07 $1 inventory, handoff, events and result"
	else
		bad "M4-07 $1 inventory, handoff, events and result"
	fi
}
"$UCODE" "$ROOT/tests/update/walker-budget.uc" -- "$ROOT/aether-proxy/src/lib/update.uc"
expect 'M4-07 fractional budget arithmetic exit' 0 "$?"
for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for scenario in W1 W2 W3 W4 W5 W5-low W6 W6-newer W7-cap W7-progress fresh-signature legacy legacy-no-progress; do
		walker_prepare
		case "$scenario" in
			W2) printf '0.7.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy" ;;
			W3) python3 "$ROOT/tests/update/walker-fixture.py" "$T" broken; prereq_sign ;;
			W4) export WALKER_MODE=fail ;;
			W5)
				export WALKER_MODE=timeout
				export AETHER_PROXY_CHAIN_DEADLINE
				AETHER_PROXY_CHAIN_DEADLINE=$(python3 -c 'import time; print(time.monotonic()+300)')
				printf '%s\n' "$AETHER_PROXY_CHAIN_DEADLINE" > "$T/start-deadline" ;;
			W5-low)
				export AETHER_PROXY_CHAIN_DEADLINE
				AETHER_PROXY_CHAIN_DEADLINE=$(python3 -c 'import time; print(time.monotonic()+179)') ;;
			legacy-no-progress) export WALKER_MODE=legacy-no-progress ;;
			legacy)
				export WALKER_MODE=legacy
				python3 "$ROOT/tests/update/walker-fixture.py" "$T" extend; prereq_sign ;;
			W6-newer) printf '1.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy" ;;
			W6)
				printf '1.0.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
				printf '1.0.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-dns"
				printf 'dns-engine\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-dns.provides"
				prereq_binary aether-dns 1.0.0 ;;
			W7-cap) export WALKER_MODE=extend ;;
			W7-progress) export WALKER_MODE=no-progress ;;
			fresh-signature) export WALKER_MODE=bad-signature ;;
		esac
		out=$(policy_run aether-proxy)
		rc=$?
		case "$scenario" in W1|W2|W6|W6-newer|legacy) expected=0 ;; fresh-signature) expected=4 ;; *) expected=1 ;; esac
		expect "M4-07 $manager $scenario exit" "$expected" "$rc"
		walker_assert "$scenario"
		unset AETHER_PROXY_CHAIN_DEADLINE
		if [ "$scenario" = W4 ] || [ "$scenario" = W5 ] || [ "$scenario" = W5-low ]; then
			export WALKER_MODE=normal
			: > "$UPDATE_PACKAGE_CALLS"; : > "$UPDATE_INIT_CALLS"; : > "$T/run/events.jsonl"; : > "$T/handoffs"
			out=$(policy_run aether-proxy)
			expect "M4-07 $manager $scenario retry exit" 0 "$?"
			if [ "$scenario" = W5-low ]; then walker_assert W1; else walker_assert W2; fi
		fi
		walker_restore
	done
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
rm -f "$T/bin/aether-dns" "$T/bin/chinadns-ng"
unset WALKER_T WALKER_ROOT WALKER_USIGN WALKER_UCODE WALKER_ENTRY WALKER_MODE
unset UPDATE_ENGINE_BIN_DIR UPDATE_ENGINE_PROBES UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
