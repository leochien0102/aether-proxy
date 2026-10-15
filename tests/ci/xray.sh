#!/usr/bin/env bash
# Validate every tests/fixtures/*/expected/xray.json with the real Xray (`xray run -test`).
# Runs twice: XRAY_MIN_VERSION from const.uc (the latest stable release, whose field names the
# renderer must stick to) and XRAY_LATEST_TESTED below (a newer release, usually a prerelease),
# so a field one of them does not know is caught in CI rather than on a device (06). Each
# archive is verified against the upstream .dgst file (SHA2-256) before it is unpacked.
# Bump XRAY_LATEST_TESTED when a newer Xray release appears.
XRAY_LATEST_TESTED=26.10.10
set -u
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Xray looks for geoip.dat/geosite.dat next to itself or in XRAY_LOCATION_ASSET; the rendered
# configs must not need them. Point it at an empty dir so a hidden dependency shows up as a failure.
assets=$(mktemp -d) || exit 2
trap 'rm -rf "$assets"' EXIT
export XRAY_LOCATION_ASSET="$assets"

check_version() {
	local ver="$1" dir bin want got name out rc fail=0 n=0
	dir="$TOOLS_DIR/xray-$ver"
	bin="$dir/xray"

	if [ ! -x "$bin" ]; then
		mkdir -p "$dir" || return 2
		base="https://github.com/XTLS/Xray-core/releases/download/v$ver"
		download "$base/Xray-linux-64.zip" "$dir/Xray-linux-64.zip" || return 2
		download "$base/Xray-linux-64.zip.dgst" "$dir/Xray-linux-64.zip.dgst" || return 2
		want=$(sed -n 's/^SHA2-256= *\([0-9a-fA-F]\{64\}\).*/\1/p' "$dir/Xray-linux-64.zip.dgst" | tr 'A-F' 'a-f')
		if [ -z "$want" ]; then
			echo "error: no SHA2-256 line in Xray-linux-64.zip.dgst" >&2
			return 2
		fi
		got=$(sha256sum "$dir/Xray-linux-64.zip" | cut -d' ' -f1)
		if [ "$got" != "$want" ]; then
			echo "error: Xray-linux-64.zip SHA2-256 mismatch: want $want, got $got" >&2
			return 2
		fi
		echo "Xray $ver: SHA2-256 verified ($got)"
		unzip -q -o "$dir/Xray-linux-64.zip" xray -d "$dir" || { echo "error: unzip failed" >&2; return 2; }
		chmod +x "$bin"
	fi

	"$bin" version | head -n1

	fail=0 n=0
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		name=$(fixture_name "$f")
		n=$((n + 1))
		if out=$("$bin" run -test -c "$f" 2>&1); then
			echo "ok   $name"
		else
			rc=$?
			echo "FAIL $name (xray exit $rc): $f"
			printf '%s\n' "$out" | sed 's/^/     /'
			fail=$((fail + 1))
		fi
	done < <(fixtures xray.json)

	echo "xray $ver: $n checked, $fail failed"
	[ "$n" -gt 0 ] || { echo "error: no xray.json fixtures found" >&2; return 2; }
	[ "$fail" -eq 0 ]
}

min=$(const_value XRAY_MIN_VERSION) || exit 2
status=0
check_version "$min" || status=1
check_version "$XRAY_LATEST_TESTED" || status=1
exit "$status"
