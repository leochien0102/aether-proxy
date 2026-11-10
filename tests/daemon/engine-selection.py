#!/usr/bin/env python3
"""M4-03a S1-S9: real discovery/check/start/reload with private engine executables."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('version_gate', ROOT / 'tests/daemon/version-gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
passed = 0


def check(name, condition):
	global passed
	if not condition:
		raise AssertionError(name)
	passed += 1
	print('PASS  M4-03a ' + name, flush=True)


def engine(path, version):
	# Embed the version in each executable, not a mutable external banner file.
	body = (ROOT / 'tests/stubs/daemon-bin/chinadns-ng').read_text()
	prefix = f'''#!/bin/sh
if [ "$1" = -V ]; then
	printf 'engine version-query\\n' >> "$STUB_LOG"
	printf 'Aether-DNS {version}\\n'
	exit 0
fi
root=${{2%/var/run/aether-proxy/current/*}}
printf '{version}\\n' > "$root/engine-version-$$"
'''
	candidate = path.with_name(path.name + '.new')
	candidate.write_text(prefix + body.removeprefix('#!/bin/sh\n'))
	candidate.chmod(0o755)
	candidate.replace(path)


def override(f, path):
	config = f.root / 'etc/config/aetherproxy'
	lines = [line for line in config.read_text().splitlines() if 'option chinadns_bin ' not in line]
	text = '\n'.join(lines) + '\n'
	config.write_text(text.replace("config main 'main'\n",
		"config main 'main'\n\toption chinadns_bin '" + str(path) + "'\n"))


def command_check(f):
	r = subprocess.run([str(gate.UCODE), '-S', str(gate.ENTRY), '--', 'check', '--json',
		*f.args, '--run-dir', str(f.run)], env=f.env, capture_output=True, text=True, timeout=20)
	check('check exit remains zero', r.returncode == 0 and not r.stderr)
	return json.loads(r.stdout)


def wait_reload(f, child, before):
	deadline = time.monotonic() + 15
	while time.monotonic() < deadline:
		state = f.state()
		if state.get('last_reload', {}).get('at', 0) > before:
			check('reload completed successfully', state['last_reload']['ok'])
			return
		if child.poll() is not None:
			raise AssertionError((f.root / 'stderr').read_text())
		time.sleep(.03)
	raise AssertionError(('reload timed out', f.state(), (f.root / 'stderr').read_text()))


def running_identity(f, path, version, label):
	state = f.state()['components']['dns']
	pid = int((f.root / 'chinadns.pid').read_text())
	argv = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
	check(label + ' process argv matches state path', str(path).encode() in argv and state['path'] == str(path))
	check(label + ' process version matches state version',
		(f.root / f'engine-version-{pid}').read_text().strip() == version == state['version'])
	return pid


def discovery_real(f):
	# Exercise the non-bin-dir branch without touching host /usr/bin. Only relocate its
	# absolute constant in a private module copy; find_component itself is unmodified.
	modules = f.root / 'modules'
	shutil.copytree(ROOT / 'aether-proxy/src/lib', modules / 'aetherproxy')
	const = modules / 'aetherproxy/const.uc'
	const.write_text(const.read_text().replace("'/usr/bin/aether-dns'", repr(str(f.bin / 'aether-dns'))))
	script = f.root / 'discover.uc'
	script.write_text("'use strict';\nimport * as c from 'aetherproxy.cmd.check';\n"
		"import * as i from 'aetherproxy.component_id';\n"
		"let r = c.find_component('chinadns-ng', null, {});\n"
		"print(sprintf('%.J', { path: r.path, engine: i.engine(r.path) }));\n")
	env = dict(f.env, LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib'))
	r = subprocess.run([str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(modules / '*.uc'), str(script)],
		env=env, capture_output=True, text=True, check=True)
	value = json.loads(r.stdout)
	check('S1 real-path branch prefers aether-dns', value == {
		'path': str(f.bin / 'aether-dns'), 'engine': 'aether-dns'})


def gate_scenarios(base):
	for name, version, old, scenario in [
		('aether-dns', '0.9.9', True, 'S4'), ('aether-dns', '1.0.0', False, 'S4'),
		('aether-dns', '2026.11.04', False, 'S4'),
		('chinadns-ng', '2025.08.08', True, 'S5'),
		('chinadns-ng', '2025.08.09', False, 'S5'), ('custom-dns', '0.0.1', False, 'S6')]:
		if '--reload-only' in sys.argv or '--same-path-only' in sys.argv or '--selection-only' in sys.argv:
			continue
		if '--chinadns-only' in sys.argv and name != 'chinadns-ng':
			continue
		f = gate.Fixture(base, name + version, 'chinadns-ng', '2025.08.09')
		path = f.bin / name
		engine(path, version)
		if name == 'custom-dns':
			override(f, path)
		minimum = '1.0.0' if name == 'aether-dns' else '2025.08.09'
		value = command_check(f)
		warnings = [w['args'] for w in value['warnings'] if w['code'] == 'COMPONENT_TOO_OLD']

		with f.daemon() as child:
			f.wait_started(child)
			check(f'{scenario} {name} {version} startup gate', f.state()['state'] == ('error' if old else 'running'))
			if old:
				check(f'{scenario} {version} exact min event', any(e['code'] == 'COMPONENT_TOO_OLD'
					and e['args'] == {'component': 'dns', 'version': version, 'min': minimum} for e in f.events()))
				check(f'{scenario} no fallback child or takeover', not (f.root / 'chinadns.pid').exists()
					and not (f.root / 'nft-table').exists())
			else:
				check(f'{scenario} selected engine identity', f.state()['components']['dns']['engine'] == (
					None if name == 'custom-dns' else name))
				running_identity(f, path, version, scenario)
		check(f'S7 {name} {version} exact warning policy', warnings == (
			[{'component': 'dns', 'version': version, 'min': minimum}] if old else []))


def selection_scenarios(base):
	# Both binaries exist for S1 and S3; an invalid pin must not use either.
	f = gate.Fixture(base, 'selection', 'chinadns-ng', '2025.08.09')
	path = f.bin / 'aether-dns'
	engine(path, '1.0.0')
	discovery_real(f)
	with f.daemon() as child:
		f.wait_started(child)
		check('S1 bin-dir prefers aether-dns', f.state()['components']['dns']['engine'] == 'aether-dns')
		running_identity(f, path, '1.0.0', 'S1')
	override(f, path)
	with f.daemon() as child:
		f.wait_started(child)
		check('S3 explicit aether-dns selected', f.state()['components']['dns']['path'] == str(path))
	path.chmod(0o644)
	with f.daemon() as child:
		f.wait_started(child)
		check('S3 invalid override fails closed', f.state()['state'] == 'error' and
			any(e['code'] == 'COMPONENT_MISSING' and e['args']['component'] == 'dns' for e in f.events()))


def reload_scenarios(base):
	# S8/S9 keep all rendered bytes identical; only executable identity changes.
	f = gate.Fixture(base, 'reload', 'chinadns-ng', '2025.08.09')
	path = f.bin / 'chinadns-ng'
	engine(path, '2025.08.09')
	if '--same-path-only' in sys.argv:
		override(f, f.bin / 'aether-dns')
		engine(f.bin / 'aether-dns', '1.0.0')
	with f.daemon() as child:
		f.wait_started(child)
		if '--same-path-only' not in sys.argv:
			check('S2 only chinadns-ng selected', f.state()['components']['dns']['engine'] == 'chinadns-ng')
			pid = running_identity(f, path, '2025.08.09', 'S2')
		else:
			pid = running_identity(f, f.bin / 'aether-dns', '1.0.0', 'S9 setup')
		new_path = f.bin / 'aether-dns'
		engine(new_path, '1.0.0')
		override(f, new_path)
		for scenario, version in [('S8', '1.0.0'), ('S9', '1.0.1')]:
			if scenario == 'S8' and '--same-path-only' in sys.argv:
				continue
			if scenario == 'S9':
				engine(new_path, version)
			before = f.state().get('last_reload', {}).get('at', 0)
			time.sleep(1.05)
			child.send_signal(signal.SIGHUP)
			wait_reload(f, child, before)
			fresh = running_identity(f, new_path, version, scenario)
			check(scenario + ' restarts actual child', fresh != pid and not Path(f'/proc/{pid}').exists())
			check(scenario + ' emits restart_chinadns only',
				[e for e in f.events() if e['code'] == 'RELOAD_APPLIED'][-1]['args']['actions'] == ['restart_chinadns'])
			pid = fresh
		queries = f.calls.read_text().count('engine version-query')
		before = f.state()['last_reload']['at']
		time.sleep(1.05)
		child.send_signal(signal.SIGHUP)
		wait_reload(f, child, before)
		check('S9 unchanged reload avoids version query', f.calls.read_text().count('engine version-query') == queries)
		# An mtime-only signal warrants a query, not a restart when the version is equal.
		st = new_path.stat()
		os.utime(new_path, (st.st_atime, st.st_mtime + 2))
		before = f.state()['last_reload']['at']
		time.sleep(1.05)
		child.send_signal(signal.SIGHUP)
		wait_reload(f, child, before)
		check('S9 stat-only same version queries once without restart',
			f.calls.read_text().count('engine version-query') == queries + 1
			and int((f.root / 'chinadns.pid').read_text()) == pid)
		before = f.state()['last_reload']['at']
		time.sleep(1.05)
		child.send_signal(signal.SIGHUP)
		wait_reload(f, child, before)
		check('S9 successful no-op retains new stat cache',
			f.calls.read_text().count('engine version-query') == queries + 1)


def main():
	with tempfile.TemporaryDirectory(prefix='.engine-selection-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		gate_scenarios(base)
		if '--reload-only' not in sys.argv and '--same-path-only' not in sys.argv:
			selection_scenarios(base)
		if '--selection-only' not in sys.argv:
			reload_scenarios(base)
	print(f'M4-03a engine selection: {passed} passed, 0 failed', flush=True)


if __name__ == '__main__':
	main()
