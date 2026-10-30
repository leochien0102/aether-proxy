#!/usr/bin/env python3
"""T9.43 revision: follow the actual child-process paths, not just rendered text."""

from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('applied_fixture', ROOT / 'tests/monitor/applied-context.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
PASS = 0


def check(condition, label):
	global PASS
	if not condition:
		raise AssertionError(label)
	PASS += 1
	print('PASS  T9.43 frozen: ' + label, flush=True)


class Service:
	def __init__(self, base):
		self.base = base
		self.root, self.bin, self.env = fixture.prepare(base)
		self.run = self.root / 'var/run/aether-proxy'
		self.data = base / 'A/data'
		self.custom = base / 'A/custom'
		# Use the same source paths for A and B; unlike a baseline/data switch this
		# reproduces update data's in-place replacement of referenced files.
		(self.data / 'gfwlist.txt').write_text('a.example.com\n')
		for name in ('proxy', 'direct'):
			(self.custom / (name + '_domain.txt')).write_text('a-' + name + '.example.com\n')
		self.config = self.root / 'etc/config/aetherproxy'
		self.original = self.config.read_text()
		self.args = ['--sys-root', str(self.root), '--bin-dir', str(self.bin),
			'--confdir', str(self.config.parent), '--data-dir', str(self.data),
			'--baseline-dir', str(base / 'A/baseline'), '--custom-dir', str(self.custom)]
		self.child = None
		# One-shot fault injection in a temporary module copy; normal reads/renderers
		# still run unchanged, and the product has no test switches.
		self.modules = base / 'modules/aetherproxy'
		shutil.copytree(ROOT / 'aether-proxy/src/lib', self.modules)
		pipeline = self.modules / 'pipeline.uc'
		anchor = 'export function render(loaded, runtime, only) {'
		fault = json.dumps(str(self.root / 'render-fail'))
		hook = f'''
	if (fs.stat({fault}) != null) {{
		if (!fs.unlink({fault})) die('cannot consume render failure');
		return {{ ok: false, exit: 1, code: 'RENDER_INVALID', detail: 'injected render failure', errors: [] }};
	}}
'''
		text = pipeline.read_text()
		if text.count(anchor) != 1:
			raise AssertionError('render injection anchor is not unique')
		pipeline.write_text(text.replace(anchor, anchor + hook))
		self.env['LD_LIBRARY_PATH'] = str(ROOT / 'tests/host/prefix/lib')

	def state(self):
		path = self.run / 'state.json'
		return json.loads(path.read_text()) if path.exists() else {}

	def events(self):
		path = self.run / 'events.jsonl'
		return path.read_text().splitlines() if path.exists() else []

	def calls(self, text):
		return (self.root / 'calls.log').read_text().count(text)

	def wait(self, predicate):
		deadline = time.monotonic() + 20
		while time.monotonic() < deadline:
			if self.child.poll() is not None:
				raise AssertionError((self.base / 'stderr').read_text())
			if predicate():
				return
			time.sleep(0.025)
		raise AssertionError('timeout: ' + (self.base / 'stderr').read_text())

	def settled(self):
		with (self.root / 'var/lock/aether-proxy.lock').open() as lock:
			fcntl.flock(lock, fcntl.LOCK_EX)

	def tick(self):
		before = self.calls('curl ')
		self.child.send_signal(signal.SIGUSR1)
		self.wait(lambda: self.calls('curl ') > before)
		self.settled()

	def reload(self):
		before = self.calls('nft -c -f ')
		events = len(self.events())
		self.child.send_signal(signal.SIGHUP)
		self.wait(lambda: self.calls('nft -c -f ') > before or len(self.events()) > events)
		# A queued tick is processed only after the reload transaction has finished.
		self.tick()

	def generations(self):
		parent = self.run / 'applied'
		return sorted(parent.iterdir()) if parent.exists() else []

	def paths(self):
		group = None
		paths = {}
		for line in (self.run / 'current/chinadns.conf').read_text().splitlines():
			key, _, value = line.partition(' ')
			if key == 'gfwlist-file':
				paths['gfwlist'] = Path(value)
			elif key == 'group':
				group = value
			elif key == 'group-dnl':
				paths[group] = Path(value)
		return paths

	def contents(self):
		def read(path):
			if not path.exists() and str(path).startswith('/var/run/'):
				path = self.root / path.relative_to('/')
			return path.read_text()
		return {key: read(path) for key, path in self.paths().items()}

	@contextmanager
	def running(self, state='running'):
		with (self.base / 'stdout').open('w') as out, (self.base / 'stderr').open('w') as err:
			command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(self.modules.parent / '*.uc'),
				'-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'daemon', *self.args]
			with subprocess.Popen(command, env=self.env, stdout=out, stderr=err) as self.child:
				try:
					self.wait(lambda: self.state().get('state') == state)
					self.settled()
					yield self
				finally:
					if self.child.poll() is None:
						self.child.terminate()
					self.child.wait(timeout=20)
				check(self.child.returncode == 0, 'daemon exits cleanly')


def overwrite(s, generation):
	(s.data / 'gfwlist.txt').write_text(generation + '.example.com\n')
	for name in ('proxy', 'direct'):
		(s.custom / (name + '_domain.txt')).write_text(generation + '-' + name + '.example.com\n')


def test_overwrite(base):
	s = Service(base)
	with s.running():
		a_paths, a_contents = s.paths(), s.contents()
		overwrite(s, 'b')
		(s.root / 'health-fail').touch()
		s.tick()
		s.wait(lambda: s.state().get('dns_tier') == 'T2')
		check(s.contents() == a_contents, 'T1 to T2 reads A after same-path source overwrite')
		check(a_paths['gfwlist'] != s.data / 'gfwlist.txt', 'gfwlist-file is not the mutable source')
		check(a_paths['uproxy'] != s.custom / 'proxy_domain.txt', 'group-dnl is not the mutable source')
		# Removing/recovering the DNS listener invokes the real dnsmasq recovery action.
		tcp = s.root / 'proc/net/tcp'
		original_tcp = tcp.read_text()
		tcp.write_text(''.join(line + '\n' for line in original_tcp.splitlines() if ':794D ' not in line))
		s.tick()
		s.tick()
		check(s.state().get('dns_failsafe'), 'DNS outage enters failsafe')
		tcp.write_text(original_tcp)
		s.tick()
		check(not s.state().get('dns_failsafe') and s.contents() == a_contents,
			'dnsmasq recovery still opens A files')
		a_dir = a_paths['gfwlist'].parent
		check(s.generations() == [a_dir] and a_dir.stat().st_mode & 0o777 == 0o700,
			'current generation is the only directory and has mode 0700')
		check(all((a_dir / name).is_file() for name in ('gfwlist.txt', 'chnlist.txt', 'apple.txt',
			'proxy_domain.txt', 'direct_domain.txt', 'boot.txt')), 'all six files are frozen')
		check((a_dir / 'boot.txt').read_text() == 'a.example.com\n', 'boot domains are frozen before startup')
		manifest = (a_dir / 'sources.json').read_bytes()
		rows = json.loads(manifest)
		check(a_dir.name == hashlib.sha256(manifest).hexdigest()
			and rows[0]['source'] == str(s.data / 'gfwlist.txt')
			and all(row['hash'] == hashlib.sha256((a_dir / (
				'boot.txt' if row['key'] == 'boot_list' else row['key'] + '.txt')).read_bytes()).hexdigest()
				for row in rows), 'generation identity contains source paths and hashes of frozen bytes')
		for kind in ('read', 'render', 'validation', 'action'):
			overwrite(s, 'b-' + kind)
			s.config.write_text(s.original.replace("option mode 'gfw'", "option mode 'bypass_cn'"))
			if kind == 'read':
				s.config.write_text("config main 'main'\n option mode 'invalid'\n")
			elif kind == 'render':
				(s.root / 'render-fail').touch()
			elif kind == 'validation':
				(s.root / 'nft-check-fail-after').write_text('1\n')
			else:
				(s.root / 'nft-load-fail').touch()
			events_before = len(s.events())
			s.reload()
			for flag in ('render-fail', 'nft-check-fail-after', 'nft-load-fail'):
				(s.root / flag).unlink(missing_ok=True)
			check(any(json.loads(line)['code'] in ('CONFIG_INVALID', 'RENDER_INVALID', 'START_FAILED')
				for line in s.events()[events_before:]), kind + ' reload really fails')
			check(s.generations() == [a_dir] and s.paths() == a_paths and s.contents() == a_contents,
				kind + ' failure removes candidate and preserves current paths and bytes')
		s.config.write_text(s.original)
		overwrite(s, 'b')
		s.reload()
		b_paths, b_contents = s.paths(), s.contents()
		b_dir = b_paths['gfwlist'].parent
		check(b_dir != a_dir and not a_dir.exists() and s.generations() == [b_dir],
			'B success switches generation and deletes A')
		check(b_contents['gfwlist'] == 'b.example.com\n' and b_contents['uproxy'] == 'b-proxy.example.com\n'
			and b_contents['udirect'] == 'b-direct.example.com\n', 'B success freezes B contents')
		(s.root / 'nft-table').unlink()
		s.tick()
		s.tick()
		(s.root / 'health-fail').unlink()
		s.tick()
		check(s.state()['dns_tier'] == 'T1' and s.paths() == b_paths and s.contents() == b_contents,
			'B missing-table recovery and T2 to T1 keep new generation')
		# Force T3 directly through the normal two-failure DNS probe path.
		(s.root / 'health-fail').touch()
		(s.root / 'dns-fail').touch()
		s.tick()
		s.tick()
		s.tick()
		check(s.state()['dns_tier'] == 'T3' and s.paths() == b_paths and s.contents() == b_contents,
			'B T1 to T3 recovery uses frozen B')
		(s.root / 'health-fail').unlink()
		(s.root / 'dns-fail').unlink()
		s.tick()
		check(s.state()['dns_tier'] == 'T1' and s.contents() == b_contents, 'B T3 to T1 uses frozen B')
		before = {p.name: (p.stat().st_ino, p.stat().st_mtime_ns) for p in b_dir.iterdir()}
		for _ in range(3):
			s.reload()
		check(s.generations() == [b_dir] and before == {
			p.name: (p.stat().st_ino, p.stat().st_mtime_ns) for p in b_dir.iterdir()},
			'same sources and contents reuse current generation without rewriting any file')
		(s.root / 'nft-check-fail-after').write_text('1\n')
		s.reload()
		(s.root / 'nft-check-fail-after').unlink()
		check(s.generations() == [b_dir] and s.paths() == b_paths and s.contents() == b_contents,
			'failed validation of a reused generation never deletes the current files')
		# Equal bytes at a different source must not reuse a source-addressed generation.
		(s.base / 'A/baseline/gfwlist.txt').write_text('b.example.com\n')
		(s.data / 'gfwlist.txt').unlink()
		s.reload()
		c_dir = s.paths()['gfwlist'].parent
		check(c_dir != b_dir and s.contents() == b_contents and s.generations() == [c_dir],
			'equal content from a different source gets a new generation without growth')


def test_missing(base):
	s = Service(base)
	for name in ('proxy', 'direct'):
		(s.custom / (name + '_domain.txt')).unlink()
	with s.running():
		paths = s.paths()
		check(paths['uproxy'].is_file() and paths['udirect'].is_file()
			and paths['uproxy'].read_text() == paths['udirect'].read_text() == '',
			'missing custom sources become real empty files')
		overwrite(s, 'later-b')
		(s.root / 'health-fail').touch()
		s.tick()
		check(s.paths() == paths and paths['uproxy'].read_text() == paths['udirect'].read_text() == '',
			'creating missing custom sources later cannot change monitor inputs')
		(s.run / 'boot.txt').unlink()
		s.reload()
		boot = s.paths()['boot']
		check(boot.is_file() and boot.read_text() == '', 'missing boot source is frozen as empty')
		(s.run / 'boot.txt').write_text('late-boot.example.com\n')
		s.tick()
		check(boot.read_text() == '', 'creating boot source later does not alter frozen content')


def test_startup(base):
	s = Service(base)
	stale = s.run / 'applied/stale'
	stale.mkdir(parents=True)
	(stale / 'leftover').touch()
	resolve = s.bin / 'resolveip'
	resolve.write_text(f'''#!/bin/sh
printf 'b.example.com\\n' > '{s.data}/gfwlist.txt' || exit 3
printf 'b-proxy.example.com\\n' > '{s.custom}/proxy_domain.txt' || exit 3
printf 'b-boot.example.com\\n' > '{s.run}/boot.txt' || exit 3
exec "$(dirname "$0")/resolveip-original" "$@"
''')
	with s.running():
		content = s.contents()
		check(content['gfwlist'] == 'a.example.com\n' and content['uproxy'] == 'a-proxy.example.com\n'
			and content['boot'] == 'a.example.com\n', 'startup source overwrite cannot alter captured generation')
		check(not stale.exists() and len(s.generations()) == 1, 'startup success cleans crash residue')


def test_startup_failure(base, kind):
	s = Service(base)
	stale = s.run / 'applied/stale'
	stale.mkdir(parents=True)
	if kind == 'read':
		s.config.write_text("config main 'main'\n option mode 'invalid'\n")
	elif kind == 'render':
		# Consume the fault only for the published render, not the early check build.
		pipeline = s.modules / 'pipeline.uc'
		text = pipeline.read_text().replace(
			f'if (fs.stat({json.dumps(str(s.root / "render-fail"))}) != null)',
			f'if (loaded.generation_dir != null && fs.stat({json.dumps(str(s.root / "render-fail"))}) != null)')
		pipeline.write_text(text)
		(s.root / 'render-fail').touch()
	elif kind == 'validation':
		(s.root / 'nft-check-fail-after').write_text('1\n')
	else:
		(s.root / 'nft-load-fail').touch()
	with s.running('error'):
		check(not s.generations(), 'startup ' + kind + ' failure leaves no candidate or crash residue')


if __name__ == '__main__':
	for test in (test_overwrite, test_missing, test_startup):
		with tempfile.TemporaryDirectory(prefix='.frozen-', dir=ROOT / 'tests/monitor') as temp:
			test(Path(temp))
	for kind in ('read', 'render', 'validation', 'action'):
		with tempfile.TemporaryDirectory(prefix='.frozen-fail-', dir=ROOT / 'tests/daemon') as temp:
			test_startup_failure(Path(temp), kind)
	print(f'frozen-paths: {PASS} passed, 0 failed', flush=True)
