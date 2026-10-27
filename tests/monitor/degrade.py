#!/usr/bin/env python3
"""T9.40: exercise the real daemon/reload/status with isolated system-command substitutes."""

from contextlib import contextmanager
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
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
UCODE = ROOT / 'tests/host/ucode'
NODE_A = 'n_00000000000000000000000000000001'
NODE_B = 'n_00000000000000000000000000000002'


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS  T9.40: ' + name, flush=True)


def wait_for(predicate, child=None, timeout=15):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		if predicate():
			return
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited: {child.returncode}')
		time.sleep(0.025)
	raise AssertionError('timed out waiting for degradation transaction')


def chain(text, name):
	return text.split('\tchain ' + name + ' {\n', 1)[1].split('\t}\n', 1)[0]


with tempfile.TemporaryDirectory(prefix='.degrade-', dir=ROOT / 'tests/monitor') as temp:
	base = Path(temp)
	binaries = base / 'bin'
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	# Add only dynamic health control; keep all shared substitute capabilities unchanged.
	(binaries / 'curl').rename(binaries / 'curl-original')
	(binaries / 'curl').write_text('''#!/bin/sh
if [ -f "$SYSROOT/health-fail" ]; then export STUB_CURL_FAIL_FROM=1; fi
exec "$(dirname "$0")/curl-original" "$@"
''')
	(binaries / 'curl').chmod(0o755)
	(binaries / 'sha256sum').write_text('''#!/bin/sh
case "$1" in
	*/current/*)
		if [ -f "$SYSROOT/hash-fail" ]; then echo 'stub current hash failure' >&2; exit 7; fi ;;
esac
exec "$HOST_SHA256" "$@"
''')
	(binaries / 'sha256sum').chmod(0o755)
	for directory in ('data', 'base', 'custom'):
		(base / directory).mkdir()
	for name in ('gfwlist', 'chnlist', 'apple'):
		(base / 'base' / (name + '.txt')).write_text('example.com\n')
	(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
	(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

	class Fixture:
		def __init__(self, name, mode, disabled=False, hosts=False, cold=False):
			self.root = base / name
			self.run = self.root / 'var/run/aether-proxy'
			self.conf = self.root / 'etc/config'
			for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
					'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
					'var/run/aether-proxy', 'etc/config'):
				(self.root / directory).mkdir(parents=True, exist_ok=True)
			self.config = self.conf / 'aetherproxy'
			text = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
			text = text.replace("option mode 'gfw'", f"option mode '{mode}'")
			if disabled:
				text = text.replace("option enabled '1'", "option enabled '1'\n\toption degrade_gfw '0'")
			text += "\nconfig probe 'probe'\n\toption fail_threshold '3'\n\toption recover_threshold '2'\n"
			text += f"\nconfig node '{NODE_B}'\n\toption protocol 'trojan'\n\toption security 'tls'\n"
			text += "\toption address 'second.example.com'\n\toption port '443'\n\toption password 'other'\n"
			if hosts:
				policies = (('proxy', '11'),) if hosts == 'proxy' else (
					('bypass_cn', '10'), ('proxy', '11'), ('direct', '12'))
				for policy, ip in policies:
					text += f"\nconfig host\n\toption policy '{policy}'\n\tlist ip '192.168.1.{ip}'\n"
			self.config.write_text(text)
			(self.root / 'var/etc/dnsmasq.conf.test').write_text(
				'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
			dnsmasq = self.root / 'etc/init.d/dnsmasq'
			dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
			dnsmasq.chmod(0o755)
			(self.root / 'proc/net/tcp').write_text(
				'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
			for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
				(self.root / file).touch()
			if cold:
				(self.root / 'health-fail').touch()
			self.calls = self.root / 'calls.log'
			self.env = dict(os.environ, SYSROOT=str(self.root), STUB_LOG=str(self.calls),
				STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'), PATH=str(binaries) + ':' + os.environ['PATH'],
				HOST_SHA256=shutil.which('sha256sum'),
				AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'))
			self.args = ['--sys-root', str(self.root), '--bin-dir', str(binaries), '--confdir', str(self.conf),
				'--data-dir', str(base / 'data'), '--baseline-dir', str(base / 'base'),
				'--custom-dir', str(base / 'custom')]

		def state(self):
			path = self.run / 'state.json'
			return json.loads(path.read_text()) if path.exists() else {}

		def events(self, code):
			path = self.run / 'events.jsonl'
			if not path.exists():
				return []
			return [e for e in map(json.loads, path.read_text().splitlines()) if e['code'] == code]

		def nft(self):
			return (self.run / 'current/aether-proxy.nft').read_text()

		def count(self, token):
			return self.calls.read_text().count(token)

		def tick(self, child):
			before = self.count('curl ')
			child.send_signal(signal.SIGUSR1)
			wait_for(lambda: self.count('curl ') > before, child)
			# The monitor owns flock until state/events are committed, not just until curl exits.
			with (self.root / 'var/lock/aether-proxy.lock').open() as lock:
				fcntl.flock(lock, fcntl.LOCK_EX)

		def reload(self, child, predicate):
			child.send_signal(signal.SIGHUP)
			wait_for(predicate, child)

		@contextmanager
		def daemon(self):
			with (self.root / 'stdout').open('w') as stdout, (self.root / 'stderr').open('w') as stderr:
				command = [str(UCODE), str(ENTRY), '--', 'daemon', *self.args]
				with subprocess.Popen(command, env=self.env, stdout=stdout, stderr=stderr) as child:
					try:
						wait_for(lambda: self.state().get('monitor') is not None, child)
						yield child
					finally:
						if child.poll() is None:
							child.terminate()
						child.wait(timeout=15)
						if child.returncode != 0:
							print((self.root / 'stderr').read_text(), flush=True)
						check('daemon exits cleanly', child.returncode == 0)

		def unhealthy(self, child):
			(self.root / 'health-fail').touch()
			for _ in range(3):
				self.tick(child)

		def check_degraded(self, label):
			s = self.state()
			body = chain(self.nft(), 'by_mode')
			check(label + ' applies GFW rules with one WARN event and T3 DNS',
				s.get('degraded_mode') == 'gfw' and s.get('degraded_since', 0) > 0
				and '@gfw4 goto proxy' in body and '@chnroute4 return' not in body
				and len(self.events('MODE_DEGRADED')) == 1 and self.events('MODE_DEGRADED')[0]['level'] == 'warn'
				and s['dns_tier'] == 'T3'
				and 'default-tag chn' in (self.run / 'current/chinadns.conf').read_text())

	for mode in ('bypass_cn',):
		f = Fixture(mode, mode)
		with f.daemon() as child:
			original = f.nft()
			original_config = f.config.read_text()
			xray_pid = (f.run / 'xray.pid').read_text()
			starts = f.count('xray run -c ')
			f.unhealthy(child)
			f.check_degraded(mode)
			check(mode + ' degradation leaves UCI unchanged and records exact transition arguments',
				f.config.read_text() == original_config
				and f.events('MODE_DEGRADED')[0]['args'] == {'from': mode, 'to': 'gfw'})
			status_args = ['--sys-root', str(f.root), '--bin-dir', str(binaries),
				'--confdir', str(f.conf), '--run-dir', str(f.run)]
			result = subprocess.run([str(UCODE), str(ENTRY), '--', 'status', '--json', *status_args],
				env=f.env, capture_output=True, text=True, check=True)
			status = json.loads(result.stdout)
			check(mode + ' status keeps configured mode and exposes applied degradation',
				status['mode'] == mode and status['degraded_mode'] == 'gfw' and status['degraded_since'] > 0)
			human = subprocess.run([str(UCODE), str(ENTRY), '--', 'status', *status_args],
				env=f.env, capture_output=True, text=True, check=True).stdout
			check(mode + ' human status exposes configured mode and degradation',
				f'mode: "{mode}"' in human and 'degraded_mode: "gfw"' in human
				and 'degraded_since: ' in human)
			check(mode + ' degradation does not restart Xray',
				f.count('xray run -c ') == starts and (f.run / 'xray.pid').read_text() == xray_pid)
			f.tick(child)
			check(mode + ' repeated unhealthy sample emits no duplicate event', len(f.events('MODE_DEGRADED')) == 1)
			(f.root / 'health-fail').unlink()
			f.tick(child)
			check(mode + ' first recovery sample retains override', f.state()['degraded_mode'] == 'gfw')
			busy = len(f.events('BUSY'))
			with (f.root / 'var/lock/aether-proxy.lock').open() as lock:
				fcntl.flock(lock, fcntl.LOCK_EX)
				child.send_signal(signal.SIGUSR1)
				wait_for(lambda: len(f.events('BUSY')) > busy, child)
				check(mode + ' recovery lock conflict retains applied override without restored event',
					f.state()['degraded_mode'] == 'gfw' and not f.events('MODE_RESTORED'))
			f.tick(child)
			check(mode + ' recovery restores exact rules and one NOTICE event without Xray restart',
				f.nft() == original and f.state()['degraded_mode'] is None and f.state()['degraded_since'] is None
				and len(f.events('MODE_RESTORED')) == 1 and f.events('MODE_RESTORED')[0]['level'] == 'notice'
				and f.events('MODE_RESTORED')[0]['args'] == {'mode': mode}
				and f.count('xray run -c ') == starts)
		check(mode + ' stop clears applied degradation',
			f.state()['state'] == 'stopped' and f.state()['degraded_mode'] is None
			and f.state()['degraded_since'] is None)

	for name, mode, disabled, hosts in (
			('no-target', 'gfw', False, False), ('disabled', 'bypass_cn', True, False),
			('global-no-target', 'global', False, False), ('global-proxy', 'global', False, 'proxy')):
		f = Fixture(name, mode, disabled=disabled, hosts=hosts)
		with f.daemon() as child:
			original = f.nft()
			loads = f.count('nft -f ')
			f.unhealthy(child)
			check(name + ' unhealthy verdict does not change rules or emit mode events',
				f.state()['state'] == 'degraded' and f.state()['degraded_mode'] is None
				and f.nft() == original and f.count('nft -f ') == loads
				and not f.events('MODE_DEGRADED') and not f.events('MODE_RESTORED'))
			if mode == 'global':
				check(name + ' keeps global DNS and null degradation timestamps',
					'default-tag gfw\n' in (f.run / 'current/chinadns.conf').read_text()
					and 'add-taggfw-ip' not in (f.run / 'current/chinadns.conf').read_text()
					and f.state()['mode'] == 'global' and f.state()['degraded_since'] is None)

	f = Fixture('global-bypass-host', 'global', hosts=True)
	with f.daemon() as child:
		original = f.nft()
		starts = f.count('xray run -c ')
		xray_pid = (f.run / 'xray.pid').read_text()
		f.unhealthy(child)
		gfw_body = ('\t\tip daddr @proxy_ip4 goto proxy\n\t\tip daddr @uproxy4 goto proxy\n'
			'\t\tip daddr @gfw4 goto proxy\n\t\tip daddr @gfw_static4 goto proxy\n')
		expected = original.replace('mode_bypass_cn', 'mode_gfw').replace(
			chain(original, 'mode_bypass_cn'), gfw_body)
		check('global bypass device alone changes nft to mode_gfw while proxy and other rules stay exact',
			f.nft() == expected and '@host_proxy4 goto proxy' in f.nft()
			and f.state()['mode'] == 'global' and f.state()['degraded_mode'] == 'gfw'
			and f.state()['degraded_since'] > 0)
		dns = (f.run / 'current/chinadns.conf').read_text()
		check('global bypass device fills gfw4 without changing global DNS default or restarting Xray',
			'default-tag gfw\n' in dns and 'add-taggfw-ip inet@aetherproxy@gfw4,null\n' in dns
			and 'gfwlist-file ' in dns and len(f.events('MODE_DEGRADED')) == 1
			and f.events('MODE_DEGRADED')[0]['args'] == {'from': 'global', 'to': 'gfw'}
			and f.count('xray run -c ') == starts and (f.run / 'xray.pid').read_text() == xray_pid)
		(f.root / 'health-fail').unlink()
		f.tick(child)
		f.tick(child)
		check('global bypass device recovery restores exact nft and removes temporary gfw4 filling',
			f.nft() == original and f.state()['degraded_mode'] is None
			and 'add-taggfw-ip' not in (f.run / 'current/chinadns.conf').read_text()
			and len(f.events('MODE_RESTORED')) == 1)

	f = Fixture('gfw-bypass-host', 'gfw', hosts=True)
	with f.daemon() as child:
		starts = f.count('xray run -c ')
		f.unhealthy(child)
		f.check_degraded('GFW default with bypass host')
		check('GFW default degrades only eligible device overrides without Xray restart',
			f.state()['mode'] == 'gfw' and '@host_bypass_cn4 goto mode_gfw' in f.nft()
			and '@host_proxy4 goto proxy' in f.nft() and f.count('xray run -c ') == starts)

	f = Fixture('cold-start', 'bypass_cn', cold=True)
	with f.daemon() as child:
		f.tick(child)
		check('never-healthy startup waits for failure threshold', f.state()['degraded_mode'] is None)
		f.tick(child)
		f.check_degraded('never-healthy startup')
		(f.root / 'health-fail').unlink()
		f.tick(child)
		check('never-healthy first success restores mode',
			f.state()['state'] == 'running' and f.state()['degraded_mode'] is None)

	f = Fixture('reloads', 'bypass_cn', hosts=True)
	with f.daemon() as child:
		f.unhealthy(child)
		f.check_degraded('reload setup')
		since = f.state()['degraded_since']
		check('bypass host goes to mode_gfw while forced proxy and direct hosts stay unchanged',
			'@host_bypass_cn4 goto mode_gfw' in f.nft()
			and '@host_proxy4 goto proxy' in f.nft() and '@host_direct4 return' in f.nft())
		f.config.write_text(f.config.read_text().replace(f"option node '{NODE_A}'", f"option node '{NODE_B}'"))
		f.reload(child, lambda: f.state().get('node_id') == NODE_B)
		check('node switch retains applied override and original since',
			f.state()['degraded_mode'] == 'gfw' and f.state()['degraded_since'] == since
			and '@gfw4 goto proxy' in chain(f.nft(), 'by_mode'))
		before_mode_switch = f.nft()
		f.config.write_text(f.config.read_text().replace("option mode 'bypass_cn'", "option mode 'gfw'"))
		f.reload(child, lambda: f.state().get('mode') == 'gfw')
		check('mode switch with byte-identical degraded artifacts updates mode but retains override',
			f.state()['degraded_mode'] == 'gfw' and f.state()['degraded_since'] == since
			and f.nft() == before_mode_switch
			and len(f.events('MODE_DEGRADED')) == 1 and not f.events('MODE_RESTORED'))
		f.config.write_text(f.config.read_text().replace("option mode 'gfw'", "option mode 'global'"))
		f.reload(child, lambda: f.state().get('mode') == 'global')
		check('mode switch to global keeps bypass device degraded but never degrades global default',
			f.state()['degraded_mode'] == 'gfw' and f.state()['degraded_since'] == since
			and '@gfw4 goto proxy' not in chain(f.nft(), 'by_mode')
			and '@host_bypass_cn4 goto mode_gfw' in f.nft() and '@host_proxy4 goto proxy' in f.nft())
		f.config.write_text(f.config.read_text().replace(
			"option enabled '1'", "option enabled '1'\n\toption degrade_gfw '0'"))
		f.reload(child, lambda: f.state().get('degraded_mode') is None and len(f.events('MODE_RESTORED')) == 1)
		check('disabling switch during reload restores configured global mode and bypass host',
			'@gfw4 goto proxy' not in chain(f.nft(), 'by_mode')
			and '@host_bypass_cn4 goto mode_bypass_cn' in f.nft()
			and len(f.events('MODE_RESTORED')) == 1)

	f = Fixture('locked-and-failed', 'bypass_cn')
	with f.daemon() as child:
		(f.root / 'health-fail').touch()
		f.tick(child)
		f.tick(child)
		before = f.count('curl ')
		with (f.root / 'var/lock/aether-proxy.lock').open() as lock:
			fcntl.flock(lock, fcntl.LOCK_EX)
			child.send_signal(signal.SIGUSR1)
			wait_for(lambda: bool(f.events('BUSY')), child)
			check('lock conflict leaves applied state and health threshold pending',
				f.state()['degraded_mode'] is None and f.count('curl ') == before
				and not f.events('MODE_DEGRADED'))
		# A failed live hash must not plan against stale state hashes or mutate current/.
		original = f.nft()
		(f.root / 'hash-fail').touch()
		f.tick(child)
		check('failed live hash preserves applied state and rules for retry',
			f.state()['degraded_mode'] is None and f.nft() == original
			and not f.events('MODE_DEGRADED'))
		(f.root / 'hash-fail').unlink()
		# Fail the nft transaction once; no mode state/event may claim it was applied.
		(f.root / 'nft-load-fail').touch()
		f.tick(child)
		check('failed reload preserves applied mode and original rules without mode event',
			f.state()['degraded_mode'] is None and f.nft() == original and not f.events('MODE_DEGRADED'))
		(f.root / 'nft-load-fail').unlink()
		f.tick(child)
		f.check_degraded('next unlocked successful round')
		check('lock conflict and apply failure retry without Xray restart', f.count('xray run -c ') == 1)
	check('stop while degraded clears both runtime fields and records restoration once',
		f.state()['state'] == 'stopped' and f.state()['degraded_mode'] is None
		and f.state()['degraded_since'] is None and len(f.events('MODE_RESTORED')) == 1)
	# cleanup is also the fallback after SIGKILL; it must clear a stale applied override.
	(f.run / 'state.json').write_text(json.dumps({
		'state': 'degraded', 'mode': 'global', 'degraded_mode': 'gfw', 'degraded_since': 1000
	}))
	subprocess.run([str(UCODE), str(ENTRY), '--', 'cleanup', *f.args],
		env=f.env, capture_output=True, text=True, check=True)
	check('cleanup clears stale applied degradation and records one restoration',
		f.state()['degraded_mode'] is None and f.state()['degraded_since'] is None
		and len(f.events('MODE_RESTORED')) == 2
		and f.events('MODE_RESTORED')[-1]['args'] == {'mode': 'global'})

print('degrade: all scenarios passed', flush=True)
