#!/usr/bin/env bash
# T16.55 diagnostic: sourced by run.sh; record old behavior without relaxing gates.
for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for mode in ordinary compatibility; do
		for scenario in backend app language all-current language-newer; do
			policy_reset
			printf '0.2.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
			package=aether-proxy
			case "$scenario" in
				backend|app)
					printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy"
					rm "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn"
					[ "$scenario" != app ] || package=luci-app-aether-proxy ;;
				language)
					printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn"
					package=luci-i18n-aether-proxy-zh-cn ;;
				language-newer)
					printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn"
					package=luci-i18n-aether-proxy-zh-cn ;;
			esac
			if [ "$mode" = compatibility ]; then
				python3 - "$T" <<'PY'
import json, sys
from pathlib import Path
for channel in ('ch1', 'ch2'):
    path = Path(sys.argv[1]) / channel / 'manifest.json'
    manifest = json.loads(path.read_text())
    step = dict(manifest['packages']['aether-proxy']['current'])
    step.update(min_from='0.1.0-r1', reason='offline terminal regression')
    manifest['compatibility'] = {'aether-proxy': {
        'from': '0.1.0-r1', 'required_steps': ['0.2.0-r1'], 'steps': [step]}}
    path.write_text(json.dumps(manifest))
PY
				for channel in ch1 ch2; do
					"$USIGN" -S -m "$T/$channel/manifest.json" -s "$T/sec"
				done
			fi
			# Flush server logs by using offsets and retaining only this invocation's requests.
			start1=$(wc -l < "$T/http1"); start2=$(wc -l < "$T/http2")
			out=$(policy_run "$package"); rc=$?
			python3 "$ROOT/tests/update/terminal-evidence.py" "$T" "$manager" "$mode" "$scenario" "$rc" "$out" "$start1" "$start2"
		done
	done
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
