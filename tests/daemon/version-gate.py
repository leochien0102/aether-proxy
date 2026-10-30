#!/usr/bin/env python3
"""T9.44: real daemon/check version gates with private binaries and runtime (docs/04, 06)."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
MINIMUM = {'xray': '26.3.27', 'chinadns-ng': '2025.08.09'}
BANNERS = {'xray': 'Xray', 'chinadns-ng': 'ChinaDNS-NG'}
passed = 0
failed = 0


def check(name, condition):
	global passed, failed
	if condition:
		passed += 1
	else:
		failed += 1
	print(('PASS  ' if condition else 'FAIL  ') + 'T9.44 ' + name, flush=True)


class Fixture:
	def __init__(self, base, name, component, version, mode='banner'):
		self.root = base / name
		self.run = self.root / 'var/run/aether-proxy'
		self.bin = self.root / 'bin'
		shutil.copytree(ROOT / 'tests/stubs/daemon-bin', self.bin)
		for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
				'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
				'var/run/aether-proxy', 'etc/config', 'base', 'data', 'custom'):
			(self.root / directory).mkdir(parents=True, exist_ok=True)
		shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', self.root / 'etc/config/aetherproxy')
		(self.root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
		dnsmasq = self.root / 'etc/init.d/dnsmasq'
		dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
		dnsmasq.chmod(0o755)
		(self.root / 'proc/net/tcp').write_text(
			'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
		for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
			(self.root / file).touch()
		for file in ('gfwlist', 'chnlist', 'apple'):
			(self.root / 'base' / (file + '.txt')).write_text('example.com\n')
		(self.root / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
		(self.root / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')
		# Wrap only version queries; validators and supervised children remain the real stubs.
		for name, minimum in MINIMUM.items():
			binary = self.bin / name
			binary.rename(self.bin / (name + '-original'))
			arg = 'version' if name == 'xray' else '-V'
			binary.write_text(f'''#!/bin/sh
if [ "$1" = {arg} ]; then
	printf '{name} version-query\\n' >> "$STUB_LOG"
	case "$(cat "$SYSROOT/{name}-mode")" in
		fail) cat "$SYSROOT/{name}-banner"; exit 7 ;;
		timeout) exec sleep 30 ;;
	esac
	cat "$SYSROOT/{name}-banner"
	exit 0
fi
exec "$(dirname "$0")/{name}-original" "$@"
''')
			binary.chmod(0o755)
			(self.root / (name + '-mode')).write_text(mode if name == component else 'banner')
			value = version if name == component else minimum
			banner = f'{BANNERS[name]} {value} extra\n'
			if name == component:
				if mode == 'empty':
					banner = ''
				elif mode == 'bad-banner':
					banner = 'not-a-banner\n'
				elif mode == 'missing-field':
					banner = BANNERS[name] + ' \n'
			(self.root / (name + '-banner')).write_text(banner)
		self.calls = self.root / 'calls.log'
		self.env = dict(os.environ, SYSROOT=str(self.root), STUB_LOG=str(self.calls),
			STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'), PATH=str(self.bin) + ':' + os.environ['PATH'],
			AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'))
		self.args = ['--sys-root', str(self.root), '--bin-dir', str(self.bin),
			'--confdir', str(self.root / 'etc/config'), '--data-dir', str(self.root / 'data'),
			'--baseline-dir', str(self.root / 'base'), '--custom-dir', str(self.root / 'custom')]

	def state(self):
		path = self.run / 'state.json'
		return json.loads(path.read_text()) if path.exists() else {}

	def events(self):
		path = self.run / 'events.jsonl'
		return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

	@contextmanager
	def daemon(self, boot=False):
		with (self.root / 'stdout').open('w') as stdout, (self.root / 'stderr').open('w') as stderr:
			command = [str(UCODE), '-S', str(ENTRY), '--', 'daemon', *self.args]
			if boot:
				command += ['--boot']
			with subprocess.Popen(command, env=self.env, stdout=stdout, stderr=stderr) as child:
				try:
					yield child
				finally:
					if child.poll() is None:
						child.terminate()
					child.wait(timeout=15)

	def wait_started(self, child):
		deadline = time.monotonic() + 16
		while time.monotonic() < deadline:
			if self.state().get('state') in ('running', 'error'):
				return
			if child.poll() is not None:
				raise AssertionError((child.returncode, (self.root / 'stderr').read_text()))
			time.sleep(0.02)
		raise AssertionError(('startup timed out', self.state(), self.calls.read_text()))


def scenarios(reproduce):
	for name in MINIMUM:
		values = ['26.3.26', '26.3.27', '26.3.28'] if name == 'xray' else [
			'2025.08.08', '2025.08.09', '2025.08.10']
		for i, value in enumerate(values[:1] if reproduce else values):
			yield name, value, 'banner', i == 0
		if not reproduce:
			for mode in ('fail', 'timeout', 'empty', 'bad-banner', 'missing-field'):
				yield name, MINIMUM[name], mode, False
			for value in ('garbage', '26..3' if name == 'xray' else '2025..08'):
				yield name, value, 'banner', False
			values = ['26.10.21', 'v026.003.027-r1', '26.3.27+abc'] if name == 'xray' else [
				'2026.1.1', 'v02025.008.009-r1', '2025.08.09+abc']
			for value in values:
				yield name, value, 'banner', False


def main():
	check_only = '--check-only' in sys.argv
	reproduce = '--reproduce' in sys.argv
	with tempfile.TemporaryDirectory(prefix='.version-gate-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		for index, (name, version, mode, old) in enumerate(scenarios(reproduce)):
			f = Fixture(base, str(index), name, version, mode)
			label = f'{"check" if check_only else "start"} {name} {mode} {version}'
			expected = {'component': name, 'version': version, 'min': MINIMUM[name]}
			if check_only:
				started = time.monotonic()
				r = subprocess.run([str(UCODE), '-S', str(ENTRY), '--', 'check', '--json', *f.args,
					'--run-dir', str(f.run)],
					env=f.env, capture_output=True, text=True, timeout=16)
				value = json.loads(r.stdout)
				if r.returncode != 0:
					print(f'INFO  {label}: {r.stdout} {r.stderr}', flush=True)
				check(label + ': success exit 0', r.returncode == 0 and value['ok'] and r.stderr == '')
				warnings = [w for w in value.get('warnings', []) if w['code'] == 'COMPONENT_TOO_OLD']
				check(label + ': exact warning policy', warnings == (
					[{'code': 'COMPONENT_TOO_OLD', 'args': expected}] if old else []))
				check(label + ': no version failure events', not f.events())
				if mode == 'timeout':
					check(label + ': bounded real timeout', 4.5 <= time.monotonic() - started < 10)
				continue
			started = time.monotonic()
			with f.daemon(boot=old and not reproduce) as child:
				f.wait_started(child)
				if reproduce:
					print(f'INFO  {label}: observed state={f.state().get("state")}', flush=True)
				if old:
					check(label + ': state error at component_version',
						f.state().get('state') == 'error' and f.state().get('failed_step') == 'component_version')
					calls = f.calls.read_text()
					check(label + ': rejected before boot waiting',
						f.state().get('state') == 'error' and 'wait_network' not in f.state().get('steps', {})
						and not f.state().get('waiting_network') and time.monotonic() - started < 4)
					check(label + ': no child launch or validation',
						'chinadns-ng -C ' not in calls and 'xray run ' not in calls
						and not (f.root / 'xray.pid').exists() and not (f.root / 'chinadns.pid').exists())
					check(label + ': no nft or DNS takeover',
						not (f.root / 'nft-table').exists() and 'nft -f ' not in calls and 'dnsmasq ' not in calls
						and not (f.root / 'tmp/dnsmasq.d/aether-proxy.conf').exists()
						and (f.root / 'ip-rules').read_text() == '' and (f.root / 'ip-routes').read_text() == '')
				else:
					check(label + ': running with both children and takeover',
						f.state().get('state') == 'running' and (f.root / 'xray.pid').exists()
						and (f.root / 'chinadns.pid').exists() and (f.root / 'nft-table').exists()
						and (f.root / 'tmp/dnsmasq.d/aether-proxy.conf').exists())
					if mode == 'banner':
						check(label + ': inventory version unchanged',
							f.state()['components'][name]['version'] == version)
					else:
						check(label + ': unknown version is null', f.state()['components'][name]['version'] is None)
						check(label + ': no failed-query event',
							not any(e['code'] == 'CMD_FAILED' for e in f.events()))
					if mode == 'timeout':
						check(label + ': bounded real timeout', 4.5 <= time.monotonic() - started < 10)
				too_old = [e for e in f.events() if e['code'] == 'COMPONENT_TOO_OLD']
				check(label + ': exact error event policy',
					len(too_old) == 1 and too_old[0]['level'] == 'error' and too_old[0]['args'] == expected
					if old else not too_old)
	print(f'T9.44 version gate: {passed} passed, {failed} failed', flush=True)
	return 1 if failed else 0


if __name__ == '__main__':
	sys.exit(main())
