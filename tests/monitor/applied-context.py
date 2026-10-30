#!/usr/bin/env python3
"""T9.43: isolated A/B inputs for real monitor/reload code and daemon startup."""

import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def prepare(base):
	root = base / 'root'
	for directory in ('etc/config', 'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
			'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state', 'var/run/aether-proxy'):
		(root / directory).mkdir(parents=True, exist_ok=True)
	binaries = base / 'bin'
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	# Add dynamic controls without changing shared substitutes or their defaults.
	for name in ('curl', 'resolveip'):
		(binaries / name).rename(binaries / (name + '-original'))
	(binaries / 'curl').write_text('''#!/bin/sh
if [ -f "$SYSROOT/health-fail" ]; then export STUB_CURL_FAIL_FROM=1; fi
exec "$(dirname "$0")/curl-original" "$@"
''')
	(binaries / 'resolveip').write_text('''#!/bin/sh
if [ -f "$SYSROOT/dns-fail" ]; then exit 1; fi
exec "$(dirname "$0")/resolveip-original" "$@"
''')
	for name in ('curl', 'resolveip'):
		(binaries / name).chmod(0o755)
	(root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
	dnsmasq = root / 'etc/init.d/dnsmasq'
	dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
	dnsmasq.chmod(0o755)
	(root / 'proc/net/tcp').write_text(
		'  0: 0100007F:7968 00000000:0000 0A 0 0 0 0 0 0\n'
		'  1: 0100007F:794D 00000000:0000 0A 0 0 0 0 0 0\n')
	for name in ('ip-rules', 'ip-routes', 'conflicts', 'calls.log', 'curl-count', 'nft-table'):
		(root / name).touch()
	for generation, suffix in (('A', '10'), ('B', '20')):
		directory = base / generation
		for name in ('data', 'baseline', 'custom'):
			(directory / name).mkdir(parents=True)
		for name in ('gfwlist', 'chnlist', 'apple'):
			(directory / 'baseline' / (name + '.txt')).write_text(generation.lower() + '.example.com\n')
		(directory / 'baseline/chnroute4.txt').write_text(f'{suffix}.0.0.0/8\n')
		(directory / 'baseline/gfw_static4.txt').write_text(f'198.51.100.{suffix}\n')
		(directory / 'custom/direct_ip.txt').write_text(f'192.0.2.{suffix}\n')
		(directory / 'custom/proxy_ip.txt').write_text(f'192.0.2.{int(suffix) + 1}\n')
		config = f'''config main 'main'
	option enabled '1'
	option mode '{'gfw' if generation == 'A' else 'global'}'
	option node 'n_000000000000000000000000000000{suffix}'
	list lan_ifaces 'br-lan'
config dns 'dns'
	option direct_dns_enabled '1'
	list china_dns 'wan'
	list trust_dns 'tcp://203.0.113.{suffix}'
	list direct_dns 'tcp://203.0.113.{int(suffix) + 1}'
config node 'n_000000000000000000000000000000{suffix}'
	option protocol 'trojan'
	option security 'tls'
	option address '{generation.lower()}.example.com'
	option port '443'
	option password 'secret-{generation}'
config host
	option policy '{'gfw' if generation == 'A' else 'direct'}'
	list ip '192.168.1.{suffix}'
config probe 'probe'
	option fail_threshold '1'
	option recover_threshold '1'
'''
		(directory / 'aetherproxy').write_text(config)
		(directory / 'wan.json').write_text(json.dumps({'interface': [{
			'interface': 'wan', 'up': True, 'route': [{'target': '0.0.0.0', 'mask': 0}],
			'dns-server': [f'203.0.113.{int(suffix) + 2}']}]}))
	shutil.copy(base / 'A/aetherproxy', root / 'etc/config/aetherproxy')
	shutil.copy(base / 'A/wan.json', base / 'wan.json')
	env = dict(os.environ, SYSROOT=str(root), STUB_LOG=str(root / 'calls.log'),
		STUB_CURL_COUNT_FILE=str(root / 'curl-count'), WAN_DNS_REPLY=str(base / 'wan.json'),
		WAN_DNS_CALLS=str(base / 'wan-calls'), PATH=str(binaries) + ':' + os.environ['PATH'],
		AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'))
	return root, binaries, env


def normalize_frozen_paths(actual, expected, run):
	# The focused frozen-path suite checks exact bytes. Retain the original full
	# snapshot/runtime comparison here, while requiring valid immutable child inputs.
	lines = actual.splitlines()
	for i, line in enumerate(expected.splitlines()):
		if not line.startswith(('gfwlist-file ', 'chnlist-file ', 'group-dnl ')):
			continue
		key = line.split(' ', 1)[0]
		if not lines[i].startswith(key + ' '):
			raise AssertionError('frozen config changed a path directive')
		for value in lines[i].split(' ', 1)[1].split(','):
			path = Path(value)
			if not path.is_file() or path.parent.parent != run / 'applied':
				raise AssertionError('child input is not a frozen file')
		lines[i] = line
	return '\n'.join(lines) + '\n'


def startup_test(base, ucode=None):
	root, binaries, env = prepare(base)
	options = dict(sys_root=str(root), bin_dir=str(binaries), confdir=str(root / 'etc/config'),
		data_dir=str(base / 'A/data'), baseline_dir=str(base / 'A/baseline'), custom_dir=str(base / 'A/custom'))
	ucode = ucode or str(ROOT / 'tests/host/ucode')
	entry = str(ROOT / 'aether-proxy/src/aether-proxy')

	def check(condition, label):
		if not condition:
			raise AssertionError(label)
		print('PASS  T9.43: ' + label, flush=True)

	def build():
		script = ("import * as p from 'aetherproxy.pipeline'; let opts = " + json.dumps(options) +
			"; print(sprintf('%.J', p.build({ ...opts, runtime: { node_ip: '203.0.113.20', dns_tier: 'T1' } }))); ")
		return json.loads(subprocess.check_output([ucode, '-e', script], env=env, text=True))['artifacts']

	expected_a = build()
	# Save B after the render used to start chinadns, while startup resolves A's node.
	resolve = binaries / 'resolveip'
	resolve.write_text(f'''#!/bin/sh
if [ -f "$SYSROOT/switch-on-resolve" ]; then
	rm "$SYSROOT/switch-on-resolve" || exit 3
	cp '{base}/B/aetherproxy' "$SYSROOT/etc/config/aetherproxy" || exit 3
	cp '{base}/B/wan.json' '{base}/wan.json' || exit 3
	cp '{base}/B/baseline/chnroute4.txt' '{base}/A/baseline/chnroute4.txt' || exit 3
	cp '{base}/B/baseline/gfw_static4.txt' '{base}/A/baseline/gfw_static4.txt' || exit 3
	cp '{base}/B/baseline/'*.txt '{base}/A/data/' || exit 3
fi
exec "$(dirname "$0")/resolveip-original" "$@"
''')
	(root / 'switch-on-resolve').touch()
	args = [part for key, value in options.items() for part in ('--' + key.replace('_', '-'), value)]
	run = root / 'var/run/aether-proxy'

	def state():
		path = run / 'state.json'
		return json.loads(path.read_text()) if path.exists() else {}

	def count():
		return (root / 'calls.log').read_text().count('curl ')

	with (base / 'stdout').open('w') as stdout, (base / 'stderr').open('w') as stderr:
		with subprocess.Popen([ucode, entry, '--', 'daemon', *args], env=env,
				stdout=stdout, stderr=stderr) as child:
			def wait(predicate):
				deadline = time.monotonic() + 20
				while time.monotonic() < deadline:
					if child.poll() is not None:
						raise AssertionError((base / 'stderr').read_text())
					if predicate():
						return
					time.sleep(0.025)
				raise AssertionError('startup test timed out: ' + (base / 'stderr').read_text())

			def tick():
				before = count()
				child.send_signal(signal.SIGUSR1)
				wait(lambda: count() > before)
				with (root / 'var/lock/aether-proxy.lock').open() as lock:
					fcntl.flock(lock, fcntl.LOCK_EX)

			def artifacts(expected, label):
				for name, file in (('nft', 'aether-proxy.nft'), ('chinadns', 'chinadns.conf'),
						('xray', 'xray.json'), ('dnsmasq', 'dnsmasq.conf')):
					actual = (run / 'current' / file).read_text()
					if name == 'chinadns':
						actual = normalize_frozen_paths(actual, expected[name], run)
					check(actual == expected[name], label + ' keeps ' + name)

			try:
				wait(lambda: state().get('state') == 'running')
				check(not (root / 'switch-on-resolve').exists(), 'B was saved during startup node resolution')
				artifacts(expected_a, 'startup pinned generation A')
				wan_before = (base / 'wan-calls').read_text()
				(root / 'nft-table').unlink()
				tick()
				tick()
				artifacts(expected_a, 'real daemon monitor after startup')
				check((base / 'wan-calls').read_text() == wan_before, 'real daemon recovery does not query WAN')
				expected_b = build()
				child.send_signal(signal.SIGHUP)
				wait(lambda: state().get('node_id', '').endswith('20'))
				(root / 'nft-table').unlink()
				tick()
				tick()
				artifacts(expected_b, 'real daemon monitor after successful HUP')
			finally:
				if child.poll() is None:
					child.terminate()
				child.wait(timeout=20)
			check(child.returncode == 0, 'real daemon exits cleanly')


if __name__ == '__main__':
	with tempfile.TemporaryDirectory(prefix='.applied-', dir=ROOT / 'tests/monitor') as temp:
		base = Path(temp)
		root, binaries, env = prepare(base)
		subprocess.run([str(ROOT / 'tests/host/ucode'), str(ROOT / 'tests/monitor/applied-context.uc'),
			'--', str(base)], env=env, check=True)
	with tempfile.TemporaryDirectory(prefix='.applied-start-', dir=ROOT / 'tests/daemon') as temp:
		startup_test(Path(temp))
