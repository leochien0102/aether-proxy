#!/usr/bin/env python3
"""T12.4 integration: usage.json persistence on a real clean stop (docs/b25-heatmap.md §5).

A closed switch must leave the file untouched; a corrupt file must warn once and be
overwritten by the stop flush; a blocked target must not break the stop. Cross-day
write and 90-day trim are driver/unit-covered (fake clock); this file pins the
daemon stop path, the file mode and the real event stream.
"""

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
LIB = Path(os.environ.get('T946_SOURCE_DIR', ROOT / 'aether-proxy/src/lib'))

HEATMAP_ON = "\nconfig stats 'stats'\n\toption heatmap_enabled '1'\n"
SEED = json.dumps({'schema': 1, 'updated_at': 1790000000,
	'days': {'2026-01-01': {'tx': 11, 'rx': 22, 'observed': 30, 'healthy': 20}}}) + '\n'


def check(name, condition, detail=''):
	if not condition:
		raise AssertionError(f'{name}{": " + detail if detail else ""}')
	print('PASS  T12.4 usage-persist: ' + name, flush=True)


def wait_for(predicate, child=None, timeout=12):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		if predicate():
			return
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited early: {child.returncode}')
		time.sleep(0.02)
	raise AssertionError('timed out waiting for lifecycle transition')


def usage_events(fixture):
	return [e for e in fixture.events()
		if e.get('code') == 'FS_FAILED' and 'usage.json' in json.dumps(e.get('args', {}))]


def today_entry(document):
	from datetime import date
	today = date.today().isoformat()
	return document['days'].get(today)


with tempfile.TemporaryDirectory(prefix='.usage-persist-', dir=ROOT / 'tests/daemon') as temp:
	base = Path(temp)
	binaries = base / 'bin'
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	# The daemon imports aetherproxy.* from this copy; no instrumentation needed here.
	modules = base / 'modules/aetherproxy'
	shutil.copytree(LIB, modules)
	for directory in ('data', 'base', 'custom'):
		(base / directory).mkdir()
	for name in ('gfwlist', 'chnlist', 'apple'):
		(base / 'base' / (name + '.txt')).write_text('example.com\n')
	(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
	(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

	class Fixture:
		def __init__(self, name, extra_config=''):
			self.root = base / name
			self.run = self.root / 'var/run/aether-proxy'
			self.usage = self.root / 'etc/aether-proxy/usage.json'
			self.conf = self.root / 'etc/config'
			for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net', 'sys/class/net/br-lan',
					'var/lock', 'etc/aether-proxy/state', 'var/run/aether-proxy', 'etc/config'):
				(self.root / directory).mkdir(parents=True, exist_ok=True)
			shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', self.conf / 'aetherproxy')
			if extra_config:
				with (self.conf / 'aetherproxy').open('a') as fp:
					fp.write(extra_config)
			(self.root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
			dnsmasq = self.root / 'etc/init.d/dnsmasq'
			dnsmasq.write_text('#!/bin/sh\nexit 0\n')
			dnsmasq.chmod(0o755)
			(self.root / 'proc/net/tcp').write_text(
				'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
			for file in ('ip-rules', 'ip-routes', 'conflicts'):
				(self.root / file).touch()
			# The curl stub counts every probe into this file (start-stop.py's contract).
			(self.root / 'curl-count').touch()
			self.env = dict(os.environ, SYSROOT=str(self.root), STUB_LOG=str(self.root / 'stub.log'),
				STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
				LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
				PATH=str(binaries) + ':' + os.environ['PATH'],
				AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'))
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
				with subprocess.Popen(command, env=self.env, stdout=stdout, stderr=stderr,
						start_new_session=True) as child:
					try:
						yield child
					finally:
						if child.poll() is None:
							child.terminate()
						try:
							child.wait(timeout=12)
						except subprocess.TimeoutExpired:
							os.killpg(child.pid, signal.SIGKILL)
							child.wait()
							raise

	def run_and_stop(fixture):
		with fixture.daemon() as child:
			wait_for(lambda: fixture.state().get('state') == 'running', child)
			child.terminate()
			child.wait(timeout=12)
		check(f'{fixture.root.name}: the daemon exits cleanly on TERM',
			child.returncode == 0 and fixture.state()['state'] == 'stopped')

	# Scenario 1: an open switch persists the sampled days on the clean stop.
	on = Fixture('on', HEATMAP_ON)
	run_and_stop(on)
	check('on: usage.json is written under the sysroot', on.usage.is_file())
	check('on: usage.json has mode 0600', (on.usage.stat().st_mode & 0o777) == 0o600)
	document = json.loads(on.usage.read_text())
	check('on: the document carries schema 1 and a fresh updated_at',
		document.get('schema') == 1 and isinstance(document.get('updated_at'), int))
	entry = today_entry(document)
	check('on: the live day is written as an entry with the four counters',
		entry is not None and set(entry) >= {'tx', 'rx', 'observed', 'healthy'})
	check('on: no bytes are counted without readable proxy counters',
		entry['tx'] == 0 and entry['rx'] == 0 and entry['observed'] >= 0 and entry['healthy'] <= entry['observed'])
	check('on: a successful stop flush is silent', len(usage_events(on)) == 0)
	check('on: no atomic-write residue', not list((on.root / 'etc/aether-proxy').glob('usage.json.tmp.*')))

	# Scenario 2: a closed switch keeps the existing file byte for byte.
	off = Fixture('off')
	off.usage.write_text(SEED)
	run_and_stop(off)
	check('off: a closed switch leaves usage.json untouched', off.usage.read_text() == SEED)

	# Scenario 3: a corrupt file warns once and is overwritten by the stop flush.
	corrupt = Fixture('corrupt', HEATMAP_ON)
	corrupt.usage.write_text('{not json')
	run_and_stop(corrupt)
	events = usage_events(corrupt)
	check('corrupt: the unparsable file warns exactly once',
		len(events) == 1 and events[0]['level'] == 'warn', json.dumps(events))
	document = json.loads(corrupt.usage.read_text())
	check('corrupt: the stop flush overwrites the corrupt file',
		document.get('schema') == 1 and today_entry(document) is not None)

	# Scenario 4: a blocked target must not delete it nor break the stop.
	blocked = Fixture('blocked', HEATMAP_ON)
	blocked.usage.mkdir()
	run_and_stop(blocked)
	check('blocked: the stop flush leaves the blocked target in place', blocked.usage.is_dir())
	check('blocked: the failed rewrite warns', len(usage_events(blocked)) >= 1,
		json.dumps(usage_events(blocked)))