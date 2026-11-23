#!/usr/bin/env bash
# rpcd plugin scenario tests for luci-app-aether-proxy (docs/tasks/m8.md T8.1 and T8.2;
# scenario 11 was rewritten by T8.3 now that overview.js uses the shared module).
# Loads the plugin file the way rpcd does and calls its methods directly; the
# aether-proxy CLI and the init script are replaced by the stubs in this
# directory, so nothing outside a mktemp directory is touched.
# Needs tests/host/bootstrap.sh to have run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UCODE="$ROOT/tests/host/ucode"
VIEW="$ROOT/luci-app-aether-proxy/htdocs/luci-static/resources/view/aether-proxy/overview.js"

T="$(mktemp -d)"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }

export RPCD_TEST_CTRL="$T/ctrl"
export RPCD_TEST_CLI_LOG="$T/cli.log"
export RPCD_TEST_INIT_LOG="$T/init.log"
# The init stub sleeps long enough to prove that the plugin backgrounds the
# service action instead of waiting for it (docs/10 "service").
export RPCD_TEST_INIT_SLEEP=5
export AETHER_PROXY_TEST_RPCD_CLI="$ROOT/tests/rpcd/stub-cli.sh"
export AETHER_PROXY_TEST_RPCD_INIT="$ROOT/tests/rpcd/stub-init.sh"

# --- scenarios 1-13 ------------------------------------------------------------
out="$("$UCODE" "$ROOT/tests/rpcd/test.uc" 2>&1)"; rc=$?
printf '%s\n' "$out"
pass=$((pass + "$(printf '%s\n' "$out" | grep -c '^PASS  ')"))
fail=$((fail + "$(printf '%s\n' "$out" | grep -c '^FAIL  ')"))
[ "$rc" -eq 0 ] || bad "rpcd scenarios exited with code $rc"

# --- 11. overview.js: syntax and shared-module usage (T8.3) --------------------
if node --check "$VIEW" 2>"$T/node.err"; then
	ok "11. node --check passes on overview.js"
else
	bad "11. node --check passes on overview.js" "$(cat "$T/node.err")"
fi

# T8.3 (docs/10 "公共模块与菜单"): the version comes from the shared module,
# pages never declare rpc themselves.
if grep -q "require aether-proxy\.common as ap" "$VIEW" && grep -q "ap\.call('version')" "$VIEW"; then
	ok "11. overview.js gets the version via ap.call('version')"
else
	bad "11. overview.js gets the version via ap.call('version')" "no 'require aether-proxy.common as ap' / ap.call('version') in overview.js"
fi

if grep -q "rpc\.declare" "$VIEW"; then
	bad "11. overview.js does not declare rpc itself" "rpc.declare still present in overview.js"
else
	ok "11. overview.js does not declare rpc itself"
fi

# T16.11 / T16.61: inspect the shipped hooks, then run them in an isolated root.
# Replacing absolute /etc/init.d/rpcd and /tmp/ paths keeps these tests away from
# host services and real /tmp caches.
LUCI_MAKEFILE="${AETHER_PROXY_TEST_LUCI_MAKEFILE:-$ROOT/luci-app-aether-proxy/Makefile}"
for hook in postinst postrm; do
	body="$(awk -v hook="$hook" '
		$0 == "define Package/luci-app-aether-proxy/" hook { inside = 1; next }
		inside && /^endef$/ { exit }
		inside { print }
	' "$LUCI_MAKEFILE")"
	if [[ "$body" == *'[ -n "$${IPKG_INSTROOT}" ] && exit 0'* ]] &&
		[[ "$body" == *'/etc/init.d/rpcd reload'* ]] &&
		[[ "$body" != *restart* ]]; then
		ok "T16.11 $hook guards IPKG_INSTROOT, calls rpcd reload, and contains no restart"
	else
		bad "T16.11 $hook guards IPKG_INSTROOT, calls rpcd reload, and contains no restart"
	fi
	# OpenWrt make expands doubled dollars before installing the shell script.
	body="${body//\$\$/\$}"
	hook_root="$T/root-$hook"
	hook_rpcd="$hook_root/etc/init.d/rpcd"
	hook_tmp="$hook_root/tmp"
	mkdir -p "$hook_root/etc/init.d" "$hook_tmp"
	isolated="${body//\/tmp\//$hook_tmp\/}"
	isolated="${isolated//\/etc\/init.d\/rpcd/$hook_rpcd}"
	stripped="${isolated//"$hook_root"/__ISOLATED_ROOT__}"
	if printf '%s\n' "$stripped" | grep -qE '(^|[[:space:]"'"'"'])/(tmp|etc)/'; then
		bad "T16.61 $hook isolated script contains no unrewritten host /tmp or /etc paths"
	else
		ok "T16.61 $hook isolated script contains no unrewritten host /tmp or /etc paths"
	fi
	printf '%s\n' "$isolated" >"$T/$hook"
	printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexit 7\n' "$T/reload.log" >"$hook_rpcd"
	chmod +x "$hook_rpcd"
	rm -f "$T/reload.log"
	if IPKG_INSTROOT="$T/image" sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
		[ ! -e "$T/reload.log" ] && [ ! -s "$T/hook.out" ] && [ ! -s "$T/hook.err" ]; then
		ok "T16.11 $hook skips rpcd silently during image builds"
	else
		bad "T16.11 $hook skips rpcd silently during image builds"
	fi
	rm -f "$T/reload.log"
	if IPKG_INSTROOT= sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
		[ -f "$T/reload.log" ] && [ "$(wc -l <"$T/reload.log")" -eq 1 ] &&
		[ "$(<"$T/reload.log")" = reload ] && [ ! -s "$T/hook.out" ] &&
		[ "$(<"$T/hook.err")" = 'luci-app-aether-proxy: rpcd reload failed (rc=7)' ]; then
		ok "T16.11 $hook reports reload failure once and exits successfully"
	else
		bad "T16.11 $hook reports reload failure once and exits successfully"
	fi
	printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$T/reload.log" >"$hook_rpcd"
	rm -f "$T/reload.log"
	if IPKG_INSTROOT= sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
		[ -f "$T/reload.log" ] && [ "$(wc -l <"$T/reload.log")" -eq 1 ] &&
		[ "$(<"$T/reload.log")" = reload ] && [ ! -s "$T/hook.out" ] && [ ! -s "$T/hook.err" ]; then
		ok "T16.11 $hook reloads rpcd silently on success"
	else
		bad "T16.11 $hook reloads rpcd silently on success"
	fi
	if [ "$hook" = postinst ]; then
		if [[ "$body" == *'rm -f /tmp/luci-indexcache.*'* ]] &&
			[[ "$body" == *'rm -rf /tmp/luci-modulecache/'* ]] &&
			[[ "$body" != *default_postinst* ]]; then
			ok "T16.61 postinst clears LuCI index/module caches without calling default_postinst"
		else
			bad "T16.61 postinst clears LuCI index/module caches without calling default_postinst"
		fi
		# Online upgrade with stale caches and unrelated neighbor files.
		rm -rf "$hook_tmp"
		mkdir -p "$hook_tmp/luci-modulecache/sub" "$hook_tmp/unrelated-dir"
		printf 'old-en\n' >"$hook_tmp/luci-indexcache.en.json"
		printf 'old-zh\n' >"$hook_tmp/luci-indexcache.zh-cn.json"
		printf 'old-mod\n' >"$hook_tmp/luci-modulecache/aether-proxy.uc"
		printf 'old-sub\n' >"$hook_tmp/luci-modulecache/sub/entry.json"
		printf 'keep-nodot\n' >"$hook_tmp/luci-indexcache"
		printf 'keep-other\n' >"$hook_tmp/luci-other.tmp"
		printf 'keep-dir\n' >"$hook_tmp/unrelated-dir/keep.txt"
		rm -f "$T/reload.log"
		if IPKG_INSTROOT= sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
			[ ! -e "$hook_tmp/luci-indexcache.en.json" ] &&
			[ ! -e "$hook_tmp/luci-indexcache.zh-cn.json" ] &&
			[ ! -e "$hook_tmp/luci-modulecache" ] &&
			[ "$(<"$hook_tmp/luci-indexcache")" = "keep-nodot" ] &&
			[ "$(<"$hook_tmp/luci-other.tmp")" = "keep-other" ] &&
			[ "$(<"$hook_tmp/unrelated-dir/keep.txt")" = "keep-dir" ] &&
			[ -f "$T/reload.log" ] && [ "$(wc -l <"$T/reload.log")" -eq 1 ] &&
			[ "$(<"$T/reload.log")" = reload ] &&
			[ ! -s "$T/hook.out" ] && [ ! -s "$T/hook.err" ]; then
			ok "T16.61 postinst clears stale LuCI caches, preserves unrelated files, and reloads rpcd once"
		else
			bad "T16.61 postinst clears stale LuCI caches, preserves unrelated files, and reloads rpcd once"
		fi
		# Online upgrade when caches do not exist.
		rm -f "$T/reload.log"
		if IPKG_INSTROOT= sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
			[ "$(<"$hook_tmp/luci-other.tmp")" = "keep-other" ] &&
			[ -f "$T/reload.log" ] && [ "$(wc -l <"$T/reload.log")" -eq 1 ] &&
			[ "$(<"$T/reload.log")" = reload ] &&
			[ ! -s "$T/hook.out" ] && [ ! -s "$T/hook.err" ]; then
			ok "T16.61 postinst succeeds when LuCI caches are absent and reloads rpcd once"
		else
			bad "T16.61 postinst succeeds when LuCI caches are absent and reloads rpcd once"
		fi
		# Offline install (IPKG_INSTROOT set): must not touch host caches or reload rpcd.
		mkdir -p "$hook_tmp/luci-modulecache"
		printf 'host-idx\n' >"$hook_tmp/luci-indexcache.en.json"
		printf 'host-mod\n' >"$hook_tmp/luci-modulecache/stale.uc"
		rm -f "$T/reload.log"
		if IPKG_INSTROOT="$T/image" sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
			[ "$(<"$hook_tmp/luci-indexcache.en.json")" = "host-idx" ] &&
			[ "$(<"$hook_tmp/luci-modulecache/stale.uc")" = "host-mod" ] &&
			[ ! -e "$T/reload.log" ] &&
			[ ! -s "$T/hook.out" ] && [ ! -s "$T/hook.err" ]; then
			ok "T16.61 postinst skips cache cleanup and rpcd reload when IPKG_INSTROOT is set"
		else
			bad "T16.61 postinst skips cache cleanup and rpcd reload when IPKG_INSTROOT is set"
		fi
	else
		if [[ "$body" != *luci-indexcache* ]] && [[ "$body" != *luci-modulecache* ]]; then
			ok "T16.61 postrm does not touch LuCI caches"
		else
			bad "T16.61 postrm does not touch LuCI caches"
		fi
	fi
	rm -f "$hook_rpcd" "$T/reload.log"
	if IPKG_INSTROOT= sh "$T/$hook" >"$T/hook.out" 2>"$T/hook.err" &&
		[ ! -s "$T/hook.out" ] && [ ! -s "$T/hook.err" ]; then
		ok "T16.11 $hook skips missing rpcd silently"
	else
		bad "T16.11 $hook skips missing rpcd silently"
	fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
