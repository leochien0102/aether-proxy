#!/usr/bin/env python3
"""T9.47: capture the syslog boundary, retaining the real log filtering/history code."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
	with tempfile.TemporaryDirectory(prefix='.debug-', dir=ROOT / 'tests/monitor') as temp:
		base = Path(temp)
		modules = base / 'aetherproxy'
		shutil.copytree(ROOT / 'aether-proxy/src/lib', modules)
		# Only the native syslog sink is replaced. observe is exposed in this private copy
		# so samples do not trigger recovery actions or need a running system daemon.
		log = modules / 'log.uc'
		log.write_text(log.read_text().replace("from 'log'", f"from '{base}/sink.uc'"))
		monitor = modules / 'monitor.uc'
		monitor.write_text(monitor.read_text() + '\nexport { observe };\n')
		(base / 'sink.uc').write_text(''' 'use strict';
import * as fs from 'fs';
export function openlog(a, b, c) { return true; };
export function syslog(priority, fmt, line) {
	let f = fs.open(getenv('CAPTURE'), 'a');
	f.write(sprintf('%J', { priority, line }) + '\\n');
	f.close();
	return true;
};
''')
		shutil.copytree(ROOT / 'tests/stubs/daemon-bin', base / 'bin')
		(base / 'proc/net').mkdir(parents=True)
		(base / 'nft-table').touch()
		(base / 'calls').touch()
		(base / 'curl-count').write_text('0\n')
		(base / 'bin/curl').write_text('#!/bin/sh\n'
			'if [ -f "$SYSROOT/fail" ]; then exit 7; fi\n'
			'printf "204 0.012\\n"\n')
		(base / 'bin/curl').chmod(0o755)
		(base / 'bin/resolveip').write_text('#!/bin/sh\n'
			'if [ -f "$SYSROOT/dns-fail" ]; then exit 7; fi\n'
			'printf "203.0.113.1\\n"\n')
		(base / 'bin/resolveip').chmod(0o755)
		script = ROOT / 'tests/monitor/debug-logging.uc'
		env = dict(os.environ, LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib'),
			CAPTURE=str(base / 'capture'), TEST_ROOT=str(base), SYSROOT=str(base),
			STUB_LOG=str(base / 'calls'), STUB_CURL_COUNT_FILE=str(base / 'curl-count'),
			PATH=str(base / 'bin') + ':' + os.environ['PATH'])
		command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(base / '*.uc')]
		rc = subprocess.run([*command, str(script)], env=env).returncode
		# Equal monotonic readings are legal on coarse clocks; force this boundary in
		# the private module, without adding a production clock injection API.
		sys_module = modules / 'sys.uc'
		original = sys_module.read_text()
		zero = '''import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as fs from 'fs';
log.set_run_dir(getenv('TEST_ROOT'));
log.set_level('debug');
fs.writefile(getenv('CAPTURE'), '');
sys.run([ 'true' ], { quiet: true });
let text = fs.readfile(getenv('CAPTURE'));
let ok = match(text, /ms=0\\]/) != null;
printf('%s  T9.47 %s produces zero ms\\n', ok ? 'PASS' : 'FAIL', getenv('CLOCK_CASE'));
exit(ok ? 0 : 1);
'''
		for label, value in [('equal monotonic readings', '[ 1, 0 ]'), ('unavailable monotonic clock', 'null')]:
			sys_module.write_text(original.replace('clock(true)', value))
			rc = max(rc, subprocess.run([*command, '-e', zero], env=dict(env, CLOCK_CASE=label)).returncode)
		return rc


if __name__ == '__main__':
	raise SystemExit(main())
