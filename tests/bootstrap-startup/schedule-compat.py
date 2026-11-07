#!/usr/bin/env python3
"""Run unchanged schedule oracles through B3-aware fixture boundaries.

The task does not authorize editing tests/schedule. Only a temporary copy in
this allowed directory is adapted; the original command's failure is reported.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
source = (ROOT / 'tests/schedule/run.sh').read_text()
original = source
root_line = 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
assert source.count(root_line) == 1
source = source.replace(root_line, f'ROOT="{ROOT}"')
start = 'start_daemon() {\n\tlocal root="$1"; shift\n'
assert source.count(start) == 1
source = source.replace(start, start + '''	# Same unresolved/successful node fixture as the old inherited flag.
	if [ "${SCHEDULE_RESOLVE_FAIL:-1}" = 1 ]; then
		touch "$root/resolve-always-fail"
	else
		rm -f "$root/resolve-always-fail"
	fi
''')
begin = source.index('cat > "$T/bin/chinadns-ng" <<\'EOF\'')
end = source.index('chmod +x "$T/bin/chinadns-ng"', begin) + len('chmod +x "$T/bin/chinadns-ng"')
# The original custom DNS has only one purpose: hold stop for 0.8 seconds.
# Keep that delay, now using the shared rooted owned-ready formal DNS fixture;
# do not change timer deadlines, expected state or any scheduling assertion.
source = source[:begin] + '''cp "$STUB_SRC/chinadns-ng" "$T/bin/chinadns-ng"
printf '0.8\\n' > "$R/dns-stop-delay"
''' + source[end:]
pattern = r'^.*\b(?:ok|bad|expect) [^\n]*$'
assert re.findall(pattern, source, re.M) == re.findall(pattern, original, re.M), 'schedule oracles changed'
with tempfile.TemporaryDirectory(prefix='.runtime-schedule-', dir=HERE) as directory:
    path = Path(directory) / 'run.sh'
    path.write_text(source)
    result = subprocess.run(['bash', str(path)], cwd=ROOT)
    if result.returncode:
        raise SystemExit(result.returncode)
print('PASS  additional schedule compatibility run preserves every original scheduling oracle', flush=True)
