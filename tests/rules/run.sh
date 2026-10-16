#!/usr/bin/env bash
# T8.8 rules/DNS model and isolated real-CLI scenarios (docs/tasks/m8.md).
# Uses only node's built-in test runner; never fetches packages or remote data.
set -euo pipefail
cd "$(dirname "$0")/../.."
output=$(mktemp)
trap 'rm -f "$output"' EXIT
if node --test --test-reporter=tap tests/luci/rules.test.js > "$output" 2>&1; then
	awk '/^ok [0-9]+ - / { sub(/^ok [0-9]+ - /, "PASS  "); print }
		/^# (tests|pass|fail|skipped) / { print }' "$output"
	echo 'rules: 7 passed, 0 failed'
else
	cat "$output"
	exit 1
fi
