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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
