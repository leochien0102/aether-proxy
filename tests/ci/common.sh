# Shared helpers for tests/ci/*.sh. Source it; do not execute.
# Env: CI_TOOLS_DIR  where downloaded binaries live (default: $RUNNER_TEMP/ci-tools or /tmp/ci-tools)

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CONST_UC="$ROOT/aether-proxy/src/lib/const.uc"
TOOLS_DIR=${CI_TOOLS_DIR:-${RUNNER_TEMP:-/tmp}/ci-tools}

# const_value NAME  -> the string literal assigned to `export const NAME = '...';`
const_value() {
	local v
	v=$(sed -n "s/^export const $1 = '\\([^']*\\)';.*/\\1/p" "$CONST_UC")
	if [ -z "$v" ]; then
		echo "error: cannot parse $1 from $CONST_UC" >&2
		return 1
	fi
	printf '%s\n' "$v"
}

# fixtures EXPECTED_FILE -> sorted list of tests/fixtures/*/expected/EXPECTED_FILE
fixtures() {
	local f
	for f in "$ROOT"/tests/fixtures/*/expected/"$1"; do
		[ -e "$f" ] && printf '%s\n' "$f"
	done
	return 0
}

# fixture_name PATH -> fixture directory name
fixture_name() {
	basename "$(dirname "$(dirname "$1")")"
}

# download URL DEST
download() {
	curl --fail --silent --show-error --location --retry 3 --output "$2" "$1" || {
		echo "error: download failed: $1" >&2
		return 1
	}
}
