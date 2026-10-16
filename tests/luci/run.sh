#!/usr/bin/env bash
# LuCI JS checks for luci-app-aether-proxy (docs/tasks/m8.md T8.3): node --check
# on every .js of the app, then the scenario tests via node --test. The tests
# load the JS modules the way LuCI does (tests/luci/loader.js) with doubles for
# rpc / baseclass / document; time comes from node:test mock timers. Nothing
# outside this repository is touched and no network access happens.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ $# -gt 1 ] && echo "      $2"; }

# --- 1. node --check on every JS file of the app ------------------------------
while IFS= read -r f; do
	rel="${f#"$ROOT"/}"
	if err=$(node --check "$f" 2>&1); then
		ok "node --check $rel"
	else
		bad "node --check $rel" "$err"
	fi
done < <(find "$ROOT/luci-app-aether-proxy" -name '*.js' -type f | sort)

# --- 2. scenario tests: node --test over tests/luci/*.test.js -----------------
cd "$ROOT"
# The per-test timeout keeps a broken implementation (a promise that never
# settles) from hanging the whole suite.
tap=$(node --test --test-reporter=tap --test-timeout=10000 tests/luci/*.test.js 2>&1)
rc=$?

printf '%s\n' "$tap"

# The runner nests the tests of each file, so the scenario lines are the
# (possibly indented) "ok <n> - <name>" lines of the TAP output.
while IFS= read -r line; do
	name="${line#*ok [0-9]* - }"
	case $line in
		*not\ ok*)
			bad "luci: $name"
			;;
		*)
			ok "luci: $name"
			;;
	esac
done < <(printf '%s\n' "$tap" | grep -E '^[[:space:]]*(not )?ok [0-9]+ - ')

if [ "$rc" -eq 0 ]; then
	ok "node --test tests/luci"
else
	bad "node --test tests/luci" "runner exited with code $rc"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
