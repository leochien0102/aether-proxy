#!/usr/bin/env bash
# T16.55: default regression; signed ordinary controls and legal compatibility terminals.
for manager in opkg apk; do
	if [ "$manager" = apk ]; then
		cp "$ROOT/tests/stubs/update-bin/apk" "$T/bin/apk"
		chmod +x "$T/bin/apk"
	fi
	for mode in ordinary compatibility; do
		while IFS='|' read -r scenario package; do
			policy_reset
			case "$scenario" in
				backend|app|download-fails|install-fails)
					printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy"
					rm "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
				both-backend|both-app|backend-newer)
					printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy"
					printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
				only-language-backend|only-language-app|language|language-download-fails|language-install-fails)
					printf '0.1.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
				language-newer) printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
				language-missing) rm "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
				missing-pages) rm "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy" "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
				newer-pages)
					printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-app-aether-proxy"
					printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/luci-i18n-aether-proxy-zh-cn" ;;
			esac
			if [ "$scenario" = backend-newer ]; then
				printf '0.3.0-r1\n' > "$UPDATE_PACKAGE_STATE_DIR/aether-proxy"
			fi
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
			case "$scenario" in
				download-fails|language-download-fails)
					failed_package=luci-app-aether-proxy
					[ "$scenario" != language-download-fails ] || failed_package=luci-i18n-aether-proxy-zh-cn
					for channel in ch1 ch2; do
						rm "$T/$channel/${failed_package}_0.2.0-r1_aarch64_generic.ipk" "$T/$channel/${failed_package}-0.2.0-r1_aarch64_generic.apk"
					done ;;
				install-fails) export UPDATE_INSTALL_FAIL_PACKAGE=luci-app-aether-proxy ;;
				language-install-fails) export UPDATE_INSTALL_FAIL_PACKAGE=luci-i18n-aether-proxy-zh-cn ;;
			esac
			if [ "$scenario" = query-fails ]; then
				# Inject only into the disposable copied stub; repository stubs stay untouched.
				mv "$T/bin/$manager" "$T/bin/$manager-terminal-real"
				cat > "$T/bin/$manager" <<'QUERY'
#!/bin/sh
if { [ "$1" = status ] && [ "$2" = luci-app-aether-proxy ]; } ||
   { [ "$1" = list ] && [ "$2" = -I ] && [ "$3" = luci-app-aether-proxy ]; }; then
	printf 'fixture query failure: luci-app-aether-proxy\n' >&2
	exit 7
fi
exec "$0-terminal-real" "$@"
QUERY
				chmod +x "$T/bin/$manager"
			fi
			# Keep independent before-state evidence; no expectations are derived from the reply.
			cp -r "$T/package-inventory" "$T/terminal-before"
			start1=$(wc -l < "$T/http1"); start2=$(wc -l < "$T/http2")
			out=$(policy_run "$package"); rc=$?
			if python3 "$ROOT/tests/update/terminal-evidence.py" "$T" "$manager" "$mode" "$scenario" "$package" "$rc" "$out" "$start1" "$start2"; then
				ok "T16.55 $manager $mode $scenario exact terminal contract"
			else
				bad "T16.55 $manager $mode $scenario exact terminal contract"
			fi
			if [ "$scenario" = query-fails ]; then
				mv "$T/bin/$manager-terminal-real" "$T/bin/$manager"
			fi
			rm -rf "$T/terminal-before"
			unset UPDATE_INSTALL_FAIL_PACKAGE
		done <<'TERMINAL_CASES'
backend|aether-proxy
app|luci-app-aether-proxy
both-backend|aether-proxy
both-app|luci-app-aether-proxy
only-language-backend|aether-proxy
only-language-app|luci-app-aether-proxy
language|luci-i18n-aether-proxy-zh-cn
all-current|aether-proxy
all-current-app|luci-app-aether-proxy
language-current|luci-i18n-aether-proxy-zh-cn
language-newer|luci-i18n-aether-proxy-zh-cn
language-missing|luci-i18n-aether-proxy-zh-cn
missing-pages|aether-proxy
newer-pages|luci-app-aether-proxy
backend-newer|luci-app-aether-proxy
download-fails|aether-proxy
install-fails|luci-app-aether-proxy
language-download-fails|luci-i18n-aether-proxy-zh-cn
language-install-fails|luci-i18n-aether-proxy-zh-cn
query-fails|aether-proxy
TERMINAL_CASES
	done
	if [ "$manager" = apk ]; then rm "$T/bin/apk"; fi
done
unset UPDATE_PACKAGE_STATE_DIR UPDATE_PACKAGE_QUERY_CALLS
make_manifest
