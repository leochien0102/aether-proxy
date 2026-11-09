#!/usr/bin/env bash
# T15.10 unified entry: original business oracles + actual init/rc.common contract.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$HERE/run.sh"
python3 "$HERE/contract.py"
if command -v busybox >/dev/null && busybox ash -c ':'; then
	# Python's executable accepts a single path; use a local wrapper for the ash argv.
	wrapper="$(mktemp "$HERE/.ash-XXXXXX")"
	trap 'rm -f "$wrapper"' EXIT
	printf '#!/bin/sh\nexec busybox ash "$@"\n' > "$wrapper"
	chmod +x "$wrapper"
	CONTRACT_SHELL="$wrapper" python3 "$HERE/contract.py"
else
	printf 'UNSUPPORTED BusyBox ash not available; /bin/sh is local host coverage only\n'
fi
