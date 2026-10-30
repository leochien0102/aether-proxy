#!/usr/bin/env python3
"""T9.27 lifecycle integration: real daemon, isolated state/config and command stubs (docs/04)."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
UCODE = ROOT / 'tests/host/ucode'
LIB = ROOT / 'aether-proxy/src/lib'


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS  T9.27 lifecycle: ' + name, flush=True)


def wait_for(predicate, child=None, timeout=12):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		if predicate():
			return
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited early: {child.returncode}')
		time.sleep(0.02)
	raise AssertionError('timed out waiting for lifecycle transition')


with tempfile.TemporaryDirectory(prefix='.start-stop-', dir=ROOT / 'tests/daemon') as temp:
	base = Path(temp)
	binaries = base / 'bin'
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	# Failure injection is local: shared stubs and other cards' expectations are unchanged.
	(binaries / 'nft').rename(binaries / 'nft-original')
	(binaries / 'nft').write_text('''#!/bin/sh
if [ "$1" = -j ] && [ -e "$SYSROOT/export-fail" ]; then
	printf 'nft %s\\n' "$*" >> "$STUB_LOG"
	echo 'stub sets export failure' >&2
	exit 7
fi
exec "$(dirname "$0")/nft-original" "$@"
''')
	(binaries / 'nft').chmod(0o755)
	for directory in ('data', 'base', 'custom'):
		(base / directory).mkdir()
	for name in ('gfwlist', 'chnlist', 'apple'):
		(base / 'base' / (name + '.txt')).write_text('example.com\n')
	(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
	(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

	# Observe the real validation entry, not a polling race against a very short starting state.
	# Only a temporary module copy is instrumented; production behavior and validation stay intact.
	modules = base / 'modules/aetherproxy'
	shutil.copytree(LIB, modules)
	# T10.70 moves the first validation into the locked recovery boundary.
	config_source = (modules / 'sub.uc').read_text()
	config_source = config_source.replace("'use strict';", "'use strict';\nimport * as trace_fs from 'fs';", 1)
	hook = '''export function prepare_config(ctx) {
	let trace = getenv('LIFECYCLE_TRACE');
	if (trace != null) {
		let root = getenv('SYSROOT');
		let fp = trace_fs.open(trace, 'a');
		if (fp == null) die('cannot open lifecycle trace');
		fp.write(sprintf('%J\\n', {
			state: trace_fs.readfile(root + '/var/run/aether-proxy/state.json'),
			pid: trace_fs.readfile(root + '/var/run/aether-proxy/daemon.pid')
		}));
		fp.close();
	}
'''
	assert config_source.count('export function prepare_config(ctx) {') == 1
	(modules / 'sub.uc').write_text(config_source.replace('export function prepare_config(ctx) {', hook, 1))

	class Fixture:
		def __init__(self, name):
			self.root = base / name
			self.run = self.root / 'var/run/aether-proxy'
			self.conf = self.root / 'etc/config'
			for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
					'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
					'var/run/aether-proxy', 'etc/config'):
				(self.root / directory).mkdir(parents=True, exist_ok=True)
			shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', self.conf / 'aetherproxy')
			(self.root / 'var/etc/dnsmasq.conf.test').write_text(
				'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
			dnsmasq = self.root / 'etc/init.d/dnsmasq'
			dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
			dnsmasq.chmod(0o755)
			(self.root / 'proc/net/tcp').write_text(
				'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
			for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
				(self.root / file).touch()
			self.calls = self.root / 'calls.log'
			self.trace = self.root / 'validation.jsonl'
			self.env = dict(os.environ, SYSROOT=str(self.root), STUB_LOG=str(self.calls),
				LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
				STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'), PATH=str(binaries) + ':' + os.environ['PATH'],
				AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
				LIFECYCLE_TRACE=str(self.trace))
			self.args = ['--sys-root', str(self.root), '--bin-dir', str(binaries), '--confdir', str(self.conf),
				'--data-dir', str(base / 'data'), '--baseline-dir', str(base / 'base'),
				'--custom-dir', str(base / 'custom')]

		def state(self):
			path = self.run / 'state.json'
			return json.loads(path.read_text()) if path.exists() else {}

		def events(self):
			path = self.run / 'events.jsonl'
			return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

		@contextmanager
		def daemon(self):
			with (self.root / 'stdout').open('w') as stdout, (self.root / 'stderr').open('w') as stderr:
				command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(base / 'modules/*.uc'),
					'-S', str(ENTRY), '--', 'daemon', *self.args]
				with subprocess.Popen(command, env=self.env, stdout=stdout, stderr=stderr) as child:
					try:
						yield child
					finally:
						if child.poll() not in (None, 0):
							print((self.root / 'stderr').read_text(), flush=True)
						if child.poll() is None:
							child.terminate()
						child.wait(timeout=12)

		def stop(self, child):
			child.terminate()
			child.wait(timeout=12)
			check('normal exit removes daemon pid and writes stopped',
				child.returncode == 0 and not (self.run / 'daemon.pid').exists()
				and self.state()['state'] == 'stopped')
			check('stop removes child pid files',
				not (self.run / 'xray.pid').exists() and not (self.run / 'chinadns-ng.pid').exists())

	# T9.48: exercise the real startup caller with each corruption class.
	for label, text in (
			('json', '{broken'), ('structure', '[]'), ('missing', '{"gfw4":[]}'),
			('element', '{"gfw4":["bad"],"udirect4":[],"uproxy4":[]}')):
		fixture = Fixture('sets-' + label)
		save = fixture.run / 'sets.save'
		bad = fixture.run / 'sets.save.bad'
		save.write_text(text)
		bad.write_text('old quarantine')
		with fixture.daemon() as child:
			wait_for(lambda: fixture.state().get('state') in ('running', 'error'), child)
			check('T9.48 startup ' + label + ' continues running with empty sets',
				fixture.state()['state'] == 'running'
				and all('elements = {' not in (fixture.run / 'current/aether-proxy.nft').read_text()
					.split('set ' + name + ' {')[1].split('}')[0]
					for name in ('gfw4', 'udirect4', 'uproxy4')))
			warnings = [e for e in fixture.events() if e['code'] == 'SETS_RESTORE_FAILED']
			check('T9.48 startup ' + label + ' quarantines exact bytes and emits WARN once',
				not save.exists() and bad.read_text() == text and len(warnings) == 1
				and warnings[0]['level'] == 'warn' and bool(warnings[0]['args']['detail']))
			child.send_signal(signal.SIGUSR1)
			time.sleep(0.3)
			check('T9.48 startup ' + label + ' polling preserves bad file without repeat warning',
				bad.read_text() == text
				and len([e for e in fixture.events() if e['code'] == 'SETS_RESTORE_FAILED']) == 1)
			fixture.stop(child)

	invalid = Fixture('invalid')
	conf = invalid.conf / 'aetherproxy'
	conf.write_text(conf.read_text().replace("option mode 'gfw'", "option mode 'raw-invalid-mode'")
		.replace("option node 'n_00000000000000000000000000000001'", "option node 'raw-unknown-node'"))
	with invalid.daemon() as child:
		wait_for(lambda: invalid.state().get('state') == 'error', child)
		observed = json.loads(invalid.trace.read_text().splitlines()[0])
		early = json.loads(observed['state'])
		check('invalid config sees starting with raw UCI node/mode and pid before validation',
			early['state'] == 'starting' and early['node_id'] == 'raw-unknown-node'
			and early['mode'] == 'raw-invalid-mode' and early['since'] > 0 and int(observed['pid']) == child.pid)
		wait_for(lambda: any(e['code'] == 'CONFIG_INVALID' for e in invalid.events()), child)
		check('invalid config records CONFIG_INVALID and error without system mutation',
			invalid.state()['last_error'] == 'CONFIG_INVALID' and invalid.calls.read_text() == '')
		time.sleep(0.3)
		check('configuration error keeps daemon pid while awaiting HUP, without automatic retry',
			(invalid.run / 'daemon.pid').read_text().strip() == str(child.pid)
			and len(invalid.trace.read_text().splitlines()) == 1 and child.poll() is None)
		invalid.stop(child)

	pid_failure = Fixture('pid-write-failure')
	(pid_failure.run / 'daemon.pid').mkdir()
	with pid_failure.daemon() as child:
		child.wait(timeout=5)
		check('pid publication failure records FS_FAILED and starts no untrackable children',
			child.returncode == 1 and not pid_failure.trace.exists() and pid_failure.calls.read_text() == ''
			and any(e['code'] == 'FS_FAILED' for e in pid_failure.events()))

	for case in ('absent-table', 'export-failure', 'invalid-export', 'live-table'):
		fixture = Fixture(case)
		with fixture.daemon() as child:
			wait_for(lambda: fixture.state().get('state') == 'running', child)
			check('running daemon publishes its own pid: ' + case,
				(fixture.run / 'daemon.pid').read_text().strip() == str(child.pid))
			fixture.calls.write_text('')
			(fixture.run / 'events.jsonl').write_text('')
			saved_sets = {'gfw4': ['198.51.100.9'], 'udirect4': [], 'uproxy4': []}
			save = fixture.run / 'sets.save'
			save.write_text(json.dumps(saved_sets))
			if case == 'absent-table':
				(fixture.root / 'nft-table').unlink()
			elif case == 'export-failure':
				(fixture.root / 'export-fail').touch()
			elif case == 'invalid-export':
				(fixture.root / 'gfw4-elem').write_text('["not-an-ip"]')
			else:
				(fixture.root / 'gfw4-elem').write_text('["1.2.3.4"]')
			fixture.stop(child)
			codes = [e['code'] for e in fixture.events()]
			calls = fixture.calls.read_text()
			check('stop still deletes routes and DNS fragment: ' + case,
				not (fixture.root / 'nft-table').exists() and (fixture.root / 'ip-rules').read_text() == ''
				and (fixture.root / 'ip-routes').read_text() == ''
				and not (fixture.root / 'tmp/dnsmasq.d/aether-proxy.conf').exists()
				and 'dnsmasq restart' in calls and 'SERVICE_STOPPED' in codes)
			if case == 'absent-table':
				check('missing table skips export without CMD_FAILED or START_FAILED and preserves sets.save',
					'nft -j list set' not in calls and 'CMD_FAILED' not in codes
					and 'START_FAILED' not in codes and json.loads(save.read_text()) == saved_sets)
			elif case == 'export-failure':
				check('shutdown export command failure records only CMD_FAILED, preserves old sets and continues',
					codes.count('CMD_FAILED') == 1 and 'START_FAILED' not in codes
					and json.loads(save.read_text()) == saved_sets)
			elif case == 'invalid-export':
				check('stop decode failure preserves old sets without START_FAILED under stop-only policy',
					'CMD_FAILED' not in codes and 'START_FAILED' not in codes
					and 'nft -j list set' in calls and json.loads(save.read_text()) == saved_sets)
			else:
				check('live table exports all three sets before deletion',
					calls.count('nft -j list set') == 3
					and calls.index('nft -j list set') < calls.index('nft delete table')
					and json.loads(save.read_text()) == {'gfw4': ['1.2.3.4'], 'udirect4': [], 'uproxy4': []})
		if case == 'live-table':
			with fixture.daemon() as child:
				wait_for(lambda: fixture.state().get('state') == 'running', child)
				check('restart restores saved dynamic set elements into the new table',
					'elements = { 1.2.3.4 }' in (fixture.run / 'current/aether-proxy.nft').read_text()
					and not save.exists())
				fixture.stop(child)
		if case == 'export-failure':
			(fixture.root / 'nft-table').touch()
			(fixture.run / 'events.jsonl').write_text('')
			result = subprocess.run([str(UCODE), '-S', str(ENTRY), '--', 'cleanup', *fixture.args],
				env=fixture.env, capture_output=True, text=True, timeout=12)
			codes = [e['code'] for e in fixture.events()]
			check('fallback cleanup export command failure records only CMD_FAILED and continues',
				result.returncode == 0 and codes == ['CMD_FAILED']
				and fixture.state()['state'] == 'stopped' and not (fixture.root / 'nft-table').exists())

	# Exercise the unchanged default through real reload and monitor recovery, not a direct apply call.
	fixture = Fixture('default-policy')
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('state') == 'running', child)
		(fixture.root / 'export-fail').touch()
		conf = fixture.conf / 'aetherproxy'
		conf.write_text(conf.read_text().replace("option mode 'gfw'", "option mode 'global'"))
		(fixture.run / 'events.jsonl').write_text('')
		child.send_signal(signal.SIGHUP)
		wait_for(lambda: any(e['code'] == 'START_FAILED' and e['args'].get('step') == 'sets_export'
			for e in fixture.events()), child)
		check('reload export failure still records START_FAILED and retains applied mode',
			any(e['code'] == 'CMD_FAILED' for e in fixture.events()) and fixture.state()['mode'] == 'gfw')
		(fixture.root / 'export-fail').unlink()
		(fixture.root / 'gfw4-elem').write_text('["not-an-ip"]')
		(fixture.run / 'events.jsonl').write_text('')
		child.send_signal(signal.SIGHUP)
		wait_for(lambda: any(e['code'] == 'START_FAILED' and e['args'].get('step') == 'sets_export'
			for e in fixture.events()), child)
		check('default reload decode failure still records START_FAILED without CMD_FAILED',
			not any(e['code'] == 'CMD_FAILED' for e in fixture.events()) and fixture.state()['mode'] == 'gfw')
		(fixture.root / 'gfw4-elem').unlink()
		(fixture.root / 'export-fail').touch()
		# Hide the Xray listener for two rounds, then restore it: failsafe recovery needs sets export.
		tcp6 = fixture.root / 'proc/net/tcp6'
		listener = tcp6.read_text()
		tcp6.write_text('')
		for expected in (1, 2):
			child.send_signal(signal.SIGUSR1)
			# Missing-listener rounds do not run curl. Wait for committed monitor samples.
			wait_for(lambda: fixture.state().get('monitor', {}).get('xray_down_count', 0) >= expected, child)
		wait_for(lambda: fixture.state().get('state') == 'failsafe', child)
		(fixture.run / 'events.jsonl').write_text('')
		tcp6.write_text(listener)
		child.send_signal(signal.SIGUSR1)
		wait_for(lambda: any(e['code'] == 'START_FAILED' and e['args'].get('step') == 'sets_export'
			for e in fixture.events()), child)
		check('monitor recovery export failure still records CMD_FAILED and START_FAILED',
			any(e['code'] == 'CMD_FAILED' for e in fixture.events()))
		(fixture.root / 'export-fail').unlink()
		fixture.stop(child)
