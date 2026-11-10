#!/usr/bin/env bash
# M4-04: sourced after prerequisite.sh; wrappers only touch this run's isolated stubs.
export UPDATE_EVENT_ROOT="$T"
for spec in 'package opkg' 'init ../root/etc/init.d/aether-proxy'; do
	read -r kind stub <<< "$spec"
	path="$T/bin/$stub"
	mv "$path" "$path.events-original"
	printf '#!/bin/sh\nexec python3 "%s" "%s" "%s" "$@"\n' \
		"$ROOT/tests/update/events-observer.py" "$kind" "$path.events-original" > "$path"
	chmod +x "$path"
done
for scenario in V1 V2 V3-download V3-hash V4 V5; do
	package=aether-proxy
	case "$scenario" in
		V1) group_prepare all-new ;;
		V2)
			group_prepare single-xray
			printf '{"state":"stopped"}\n' > "$UPDATE_STATE_FILE"
			printf '#!/bin/sh\necho "Xray 26.10.10"\n' > "$T/bin/aether-xray"
			chmod +x "$T/bin/aether-xray"
			package=aether-xray ;;
		V3-download) group_prepare backend-hash-fails
			# A signed asset that is unavailable at every mirror.
			rm "$T/ch1/aether-proxy_0.2.0-r1_aarch64_generic.ipk" \
				"$T/ch2/aether-proxy_0.2.0-r1_aarch64_generic.ipk" ;;
		V3-hash) group_prepare backend-hash-fails ;;
		V4) group_prepare backend-recovers ;;
		V5) prereq_prepare; prereq_sign; package=aether-proxy ;;
	esac
	out=$(policy_run "$package")
	rc=$?
	case "$scenario" in V3-*|V4) expected=1 ;; *) expected=0 ;; esac
	expect "M4-04 $scenario exit" "$expected" "$rc"
	if python3 "$ROOT/tests/update/events-assert.py" "$T" "$scenario" "$out"; then
		ok "M4-04 $scenario event contract"
	else
		bad "M4-04 $scenario event contract"
	fi
	unset UPDATE_INIT_FAIL
done
for stub in opkg ../root/etc/init.d/aether-proxy; do
	mv "$T/bin/$stub.events-original" "$T/bin/$stub"
done
rm "$T/bin/aether-xray"
unset UPDATE_EVENT_ROOT UPDATE_ENGINE_BIN_DIR UPDATE_ENGINE_PROBES UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
