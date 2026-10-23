#!/usr/bin/env python3
"""T9.32 integration: `stopping` state, early dns_tier, real daemon with isolated stubs (docs/04)."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
LIB = ROOT / 'aether-proxy/src/lib'


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS  T9.32 stop-state: ' + name, flush=True)


def wait_for(predicate, child=None, timeout=12):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		if predicate():
			return
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited early: {child.returncode}')
		time.sleep(0.02)
	raise AssertionError('timed out waiting for lifecycle transition')


def objects(text):
	"""state.json is pretty-printed, so a concatenation is decoded object by object."""
	decoder, position, found = json.JSONDecoder(), 0, []
	while True:
		while position < len(text) and text[position].isspace():
			position += 1
		if position >= len(text):
			return found
		value, position = decoder.raw_decode(text, position)
		found.append(value)


with tempfile.TemporaryDirectory(prefix='.stop-state-', dir=ROOT / 'tests/daemon') as temp:
	base = Path(temp)
	binaries = base / 'bin'
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	# `ip rule show` is the first command of the stop sequence after the table work; while the
	# capture flag exists it records state.json, i.e. what a page would read mid-stop.
	(binaries / 'ip').rename(binaries / 'ip-original')
	(binaries / 'ip').write_text('''#!/bin/sh
if [ -e "$SYSROOT/capture" ] && [ "$1 $2" = "rule show" ]; then
	cat "$SYSROOT/var/run/aether-proxy/state.json" >> "$SYSROOT/state-during-stop.jsonl" 2>/dev/null
fi
exec "$(dirname "$0")/ip-original" "$@"
''')
	(binaries / 'ip').chmod(0o755)
	for directory in ('data', 'base', 'custom'):
		(base / directory).mkdir()
	for name in ('gfwlist', 'chnlist', 'apple'):
		(base / 'base' / (name + '.txt')).write_text('example.com\n')
	(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
	(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

	# Instrument a module copy only: record state.json when validation starts (first health
	# check is later still), as T9.27 does.
	modules = base / 'modules/aetherproxy'
	shutil.copytree(LIB, modules)
	source = (modules / 'config.uc').read_text()
	source = source.replace("'use strict';", "'use strict';\nimport * as trace_fs from 'fs';", 1)
	hook = '''export function load(cursor) {
	let trace = getenv('LIFECYCLE_TRACE');
	if (trace != null) {
		let fp = trace_fs.open(trace, 'a');
		fp.write(trace_fs.readfile(getenv('SYSROOT') + '/var/run/aether-proxy/state.json') + '\\n');
		fp.close();
	}
'''
	assert source.count('export function load(cursor) {') == 1
	(modules / 'config.uc').write_text(source.replace('export function load(cursor) {', hook, 1))

	class Fixture:
		def __init__(self, name, dns_section=None):
			self.root = base / name
			self.run = self.root / 'var/run/aether-proxy'
			self.conf = self.root / 'etc/config'
			for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net', 'sys/class/net/br-lan',
					'var/lock', 'etc/aether-proxy/state', 'var/run/aether-proxy', 'etc/config'):
				(self.root / directory).mkdir(parents=True, exist_ok=True)
			shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', self.conf / 'aetherproxy')
			if dns_section is not None:
				with (self.conf / 'aetherproxy').open('a') as fp:
					fp.write(dns_section)
			(self.root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
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
			return json.loads(path.read_text()) if path.exists() and path.is_file() else {}

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
						if child.poll() is None:
							child.terminate()
						child.wait(timeout=12)

		def captured(self):
			path = self.root / 'state-during-stop.jsonl'
			return objects(path.read_text()) if path.exists() else []

	# Scenario 2: early starting state carries dns_tier from the raw UCI value.
	for name, section, expected in (
			('tier-unset', None, 'T1'),
			('tier-direct', "\nconfig dns 'dns'\n\toption direct_dns_enabled '1'\n", 'T2')):
		fixture = Fixture(name, section)
		with fixture.daemon() as child:
			wait_for(lambda: fixture.state().get('state') == 'running', child)
			early = objects(fixture.trace.read_text())[0]
			check(f'early state before validation is starting with dns_tier {expected}: {name}',
				early['state'] == 'starting' and early['dns_tier'] == expected)
			child.terminate()
			child.wait(timeout=12)

	# Scenario 1: stopping is published first, other fields kept, stopped last.
	fixture = Fixture('stop-flow')
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('state') == 'running', child)
		before = fixture.state()
		(fixture.root / 'capture').touch()
		stop_started = int(time.time())
		child.terminate()
		child.wait(timeout=12)
		seen = fixture.captured()
		check('state.json is stopping while cleanup runs, with node_id and mode kept',
			len(seen) >= 1 and seen[0]['state'] == 'stopping' and seen[0]['node_id'] == before['node_id']
			and seen[0]['mode'] == before['mode'] and seen[0]['since'] >= stop_started - 1)
		check('final state is stopped after a clean exit',
			child.returncode == 0 and fixture.state()['state'] == 'stopped')

	# Scenario 1 (cont.): a failing stopping write only logs FS_FAILED; the other steps go on.
	fixture = Fixture('stop-write-fails')
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('state') == 'running', child)
		# A directory in place of state.json makes every atomic rename onto it fail.
		(fixture.run / 'state.json').unlink()
		(fixture.run / 'state.json').mkdir()
		(fixture.run / 'events.jsonl').write_text('')
		child.terminate()
		child.wait(timeout=12)
		codes = [(e['code'], e['args'].get('op')) for e in fixture.events()]
		calls = fixture.calls.read_text()
		check('failed stopping write is logged as FS_FAILED', ('FS_FAILED', 'write') in codes)
		check('failed stopping write does not abort the stop sequence',
			not (fixture.root / 'nft-table').exists() and (fixture.root / 'ip-rules').read_text() == ''
			and 'dnsmasq restart' in calls and not (fixture.run / 'daemon.pid').exists()
			and any(c == 'SERVICE_STOPPED' for c, _ in codes))

	# Scenario 1 (cont.): SIGTERM during the start sequence (waiting for the network) also
	# writes stopping first. The network wait is held open by an unreachable gateway.
	fixture = Fixture('stop-while-starting')
	conf = fixture.conf / 'aetherproxy'
	conf.write_text(conf.read_text().replace("config main 'main'\n", "config main 'main'\n\toption boot_wait_timeout '30'\n", 1))
	fixture.args.append('--boot')
	# `ip -4 route show default` empty would make the network wait block; reuse the stub's
	# hook by swapping in a variant for this fixture only.
	local_bin = base / 'bin-nonet'
	shutil.copytree(binaries, local_bin)
	original = (local_bin / 'ip-original').read_text()
	(local_bin / 'ip-original').write_text(original.replace(
		"*\" -4 route show default \"*) echo 'default dev lo'; exit 0 ;;", "*\" -4 route show default \"*) exit 0 ;;"))
	fixture.env['PATH'] = str(local_bin) + ':' + os.environ['PATH']
	idx = fixture.args.index('--bin-dir')
	fixture.args[idx + 1] = str(local_bin)
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('waiting_network') is True, child)
		check('network wait publishes starting and keeps the T1 dns_tier of the unset option',
			fixture.state()['state'] == 'starting' and fixture.state()['dns_tier'] == 'T1')
		(fixture.root / 'capture').touch()
		child.terminate()
		child.wait(timeout=12)
		seen = fixture.captured()
		check('SIGTERM during start writes stopping before cleanup',
			len(seen) >= 1 and seen[0]['state'] == 'stopping' and seen[0]['mode'] == 'gfw')
		check('SIGTERM during start still ends in stopped', fixture.state()['state'] == 'stopped')
