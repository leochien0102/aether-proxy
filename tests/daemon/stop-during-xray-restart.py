#!/usr/bin/env python3
"""T16.57 regression: stop accepted while Xray restart is in flight must not launch a new Xray."""

from contextlib import contextmanager
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
UCODE = ROOT / 'tests/host/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'


def check(name, condition, detail=''):
	if not condition:
		msg = f'FAIL  T16.57 {name}'
		if detail:
			msg += f': {detail}'
		raise AssertionError(msg)
	print('PASS  T16.57 ' + name, flush=True)


def pid_alive(pid):
	if pid is None or pid <= 0:
		return False
	try:
		os.kill(pid, 0)
		return True
	except ProcessLookupError:
		return False
	except PermissionError:
		return True


def kill_pid_bounded(pid):
	if not pid_alive(pid):
		return
	try:
		os.kill(pid, signal.SIGTERM)
	except ProcessLookupError:
		return
	deadline = time.monotonic() + 1.0
	while time.monotonic() < deadline:
		if not pid_alive(pid):
			return
		time.sleep(0.01)
	try:
		os.kill(pid, signal.SIGKILL)
	except ProcessLookupError:
		pass


def wait_for(predicate, child=None, timeout=10.0, label='condition'):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		value = predicate()
		if value:
			return value
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited early ({child.returncode}) while waiting for {label}')
		time.sleep(0.01)
	raise AssertionError(f'timed out ({timeout}s) waiting for {label}')


def build_stubs(binaries):
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	xray = binaries / 'xray'
	source = xray.read_text()

	start_needle = 'printf \'xray %s\\n\' "$*" >> "$STUB_LOG"\n\techo "$$" > "$SYSROOT/xray.pid"'
	assert source.count(start_needle) == 1, 'xray stub start anchor changed'
	start_hook = start_needle + '''
	printf 'start %s\\n' "$$" >> "$SYSROOT/xray-launches.log"'''
	source = source.replace(start_needle, start_hook, 1)

	cleanup_needle = 'cleanup() {'
	assert source.count(cleanup_needle) == 1, 'xray stub cleanup anchor changed'
	cleanup_hook = '''cleanup() {
		if [ -e "$SYSROOT/hold-xray-exit" ]; then
			printf '%s\\n' "$$" > "$SYSROOT/xray-exiting.tmp"
			mv "$SYSROOT/xray-exiting.tmp" "$SYSROOT/xray-exiting"
			i=0
			while [ -e "$SYSROOT/hold-xray-exit" ] && [ "$i" -lt 500 ]; do
				i=$((i + 1))
				sleep 0.01
			done
		fi
		printf 'exited %s\\n' "$$" >> "$SYSROOT/xray-launches.log"'''
	source = source.replace(cleanup_needle, cleanup_hook, 1)
	xray.write_text(source)
	xray.chmod(0o755)


class Fixture:
	def __init__(self, base, binaries, name):
		self.base = base
		self.binaries = binaries
		self.root = base / name
		self.run = self.root / 'var/run/aether-proxy'
		self.conf = self.root / 'etc/config'
		for directory in (
			'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
			'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
			'var/run/aether-proxy', 'etc/config',
		):
			(self.root / directory).mkdir(parents=True, exist_ok=True)
		shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', self.conf / 'aetherproxy')
		(self.root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
		dnsmasq = self.root / 'etc/init.d/dnsmasq'
		dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
		dnsmasq.chmod(0o755)
		subprocess.run(
			['python3', str(ROOT / 'tests/xray-ready/proc_fixture.py'), str(self.root)],
			check=True,
		)
		(self.root / 'proc/net/tcp').write_text(
			'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00000000:00000000 00000000 0 0 0\n'
		)
		for filename in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log', 'xray-launches.log'):
			(self.root / filename).touch()
		self.calls = self.root / 'calls.log'
		self.launches = self.root / 'xray-launches.log'
		self.env = dict(
			os.environ,
			SYSROOT=str(self.root),
			STUB_LOG=str(self.calls),
			STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
			PATH=str(binaries) + ':' + os.environ['PATH'],
			AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
		)
		self.args = [
			'--sys-root', str(self.root),
			'--bin-dir', str(binaries),
			'--confdir', str(self.conf),
			'--data-dir', str(base / 'data'),
			'--baseline-dir', str(base / 'base'),
			'--custom-dir', str(base / 'custom'),
		]

	def state(self):
		path = self.run / 'state.json'
		return json.loads(path.read_text()) if path.exists() and path.is_file() else {}

	def events(self):
		path = self.run / 'events.jsonl'
		return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []

	def xray_records(self):
		records = []
		if not self.launches.exists():
			return records
		for line in self.launches.read_text().splitlines():
			parts = line.split()
			if len(parts) == 2 and parts[1].isdigit():
				records.append((parts[0], int(parts[1])))
		return records

	def xray_starts(self):
		return [pid for kind, pid in self.xray_records() if kind == 'start']

	def xray_exits(self):
		return [pid for kind, pid in self.xray_records() if kind == 'exited']

	def read_pidfile(self, name):
		path = self.run / name
		if not path.exists():
			return None
		text = path.read_text().strip()
		return int(text) if text.isdigit() else None

	def cleanup_leftovers(self):
		hold = self.root / 'hold-xray-exit'
		if hold.exists():
			hold.unlink()
		pids = set(self.xray_starts())
		for name in ('daemon.pid', 'xray.pid', 'chinadns-ng.pid', 'aether-dns.pid', 'raw-log.pid'):
			pid = self.read_pidfile(name)
			if pid is not None:
				pids.add(pid)
		for pid in pids:
			kill_pid_bounded(pid)

	@contextmanager
	def daemon(self):
		with (self.root / 'stdout').open('w') as stdout, (self.root / 'stderr').open('w') as stderr:
			command = [str(UCODE), '-S', str(ENTRY), '--', 'daemon', *self.args]
			with subprocess.Popen(
				command, env=self.env, stdout=stdout, stderr=stderr, start_new_session=True,
			) as child:
				try:
					yield child
				finally:
					hold = self.root / 'hold-xray-exit'
					if hold.exists():
						hold.unlink()
					if child.poll() is None:
						child.terminate()
					try:
						child.wait(timeout=10)
					except subprocess.TimeoutExpired:
						os.killpg(child.pid, signal.SIGKILL)
						child.wait(timeout=5)
						self.cleanup_leftovers()
						raise
					self.cleanup_leftovers()


def main():
	with tempfile.TemporaryDirectory(prefix='.stop-during-restart-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		binaries = base / 'bin'
		build_stubs(binaries)
		for directory in ('data', 'base', 'custom'):
			(base / directory).mkdir()
		for name in ('gfwlist', 'chnlist', 'apple'):
			(base / 'base' / f'{name}.txt').write_text('example.com\n')
		(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
		(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

		# 1. Core scenario: SIGUSR2 accepted -> old Xray begins exiting (held) ->
		#    SIGTERM accepted (state.json == stopping) -> old Xray allowed to exit ->
		#    no new Xray may be started, and stop must complete cleanly without hanging.
		f_stop = Fixture(base, binaries, 'stop-during-restart')
		with f_stop.daemon() as child:
			wait_for(lambda: f_stop.state().get('state') == 'running', child, label='initial running')
			initial_starts = f_stop.xray_starts()
			check('core: initial single xray started', len(initial_starts) == 1, f'starts={initial_starts}')
			old_pid = initial_starts[0]
			check('core: initial xray pid alive', pid_alive(old_pid), f'old_pid={old_pid}')
			dns_pid = f_stop.read_pidfile('chinadns-ng.pid')

			hold = f_stop.root / 'hold-xray-exit'
			exiting = f_stop.root / 'xray-exiting'
			hold.touch()

			# Trigger real daemon SIGUSR2 path.
			child.send_signal(signal.SIGUSR2)

			# Timepoint 1: old Xray received SIGTERM from daemon and entered exit barrier.
			exiting_pid = wait_for(
				lambda: int(exiting.read_text().strip()) if exiting.exists() and exiting.read_text().strip().isdigit() else None,
				child, timeout=5.0, label='T1 old xray exiting barrier',
			)
			check('core: T1 old xray started exiting', exiting_pid == old_pid, f'exiting={exiting_pid} old={old_pid}')

			# Trigger real daemon SIGTERM path while old Xray is held exiting.
			child.terminate()

			# Timepoint 2: daemon processed SIGTERM and published state=stopping while old Xray is still held.
			wait_for(lambda: f_stop.state().get('state') == 'stopping', child, timeout=2.0, label='T2 daemon accepted stop')
			check(
				'core: T2 daemon accepted stop while old xray still held alive',
				hold.exists() and pid_alive(old_pid) and old_pid not in f_stop.xray_exits(),
				f'hold={hold.exists()} alive={pid_alive(old_pid)} exits={f_stop.xray_exits()}',
			)

			# Timepoint 3: release barrier so old Xray exits cleanly (before 1s SIGKILL grace timer).
			hold.unlink()

			rc = child.wait(timeout=10.0)
			starts = f_stop.xray_starts()
			exits = f_stop.xray_exits()
			xray_run_calls = [line for line in f_stop.calls.read_text().splitlines() if line.startswith('xray run -c ')]
			events = f_stop.events()
			sigusr2_failures = [e for e in events if e.get('code') == 'CMD_FAILED' and e.get('args', {}).get('cmd') == 'stop:sigusr2']

			check(
				'core: T3 old xray exited via barrier (not SIGKILLed)',
				old_pid in exits,
				f'old_pid={old_pid} exits={exits}',
			)
			check(
				'core: no new xray started after stop accepted',
				starts == [old_pid] and len(xray_run_calls) == 1,
				f'starts={starts} xray_run_calls={len(xray_run_calls)} sigusr2_failures={len(sigusr2_failures)}',
			)
			check(
				'core: no spurious stop:sigusr2 CMD_FAILED',
				len(sigusr2_failures) == 0,
				f'sigusr2_failures={sigusr2_failures}',
			)
			check(
				'core: daemon exited cleanly in stopped state with no leftovers',
				rc == 0
				and f_stop.state().get('state') == 'stopped'
				and any(e.get('code') == 'SERVICE_STOPPED' for e in events)
				and not pid_alive(old_pid)
				and not pid_alive(dns_pid)
				and not any((f_stop.run / p).exists() for p in ('daemon.pid', 'xray.pid', 'chinadns-ng.pid')),
				f'rc={rc} state={f_stop.state()} old_alive={pid_alive(old_pid)} dns_alive={pid_alive(dns_pid)}',
			)

		# 2. Positive control: same fixture & barrier, SIGUSR2 without SIGTERM ->
		#    restarts Xray exactly once and returns to running/available.
		f_pos = Fixture(base, binaries, 'positive-restart')
		with f_pos.daemon() as child:
			wait_for(lambda: f_pos.state().get('state') == 'running', child, label='pos initial running')
			old_pid = f_pos.xray_starts()[0]
			version_before = sum(1 for line in f_pos.calls.read_text().splitlines() if line == 'xray version')
			hold = f_pos.root / 'hold-xray-exit'
			exiting = f_pos.root / 'xray-exiting'
			hold.touch()

			child.send_signal(signal.SIGUSR2)
			wait_for(lambda: exiting.exists(), child, timeout=5.0, label='pos old xray exiting')
			hold.unlink()

			wait_for(lambda: len(f_pos.xray_starts()) >= 2, child, timeout=5.0, label='pos new xray started')
			starts = f_pos.xray_starts()
			new_pid = starts[1]
			wait_for(
				lambda: f_pos.read_pidfile('xray.pid') == new_pid
				and f_pos.state().get('state') == 'running'
				and sum(1 for line in f_pos.calls.read_text().splitlines() if line == 'xray version') > version_before,
				child, timeout=5.0, label='pos restart completed and running',
			)
			check(
				'positive: restarted once with new pid and stayed running',
				len(starts) == 2 and new_pid != old_pid and not pid_alive(old_pid) and pid_alive(new_pid)
				and f_pos.state().get('state') == 'running',
				f'starts={starts} old_alive={pid_alive(old_pid)} new_alive={pid_alive(new_pid)} state={f_pos.state()}',
			)

			child.terminate()
			rc = child.wait(timeout=10.0)
			check(
				'positive: clean stop after restart',
				rc == 0 and f_pos.state().get('state') == 'stopped' and not pid_alive(new_pid),
				f'rc={rc} state={f_pos.state()} new_alive={pid_alive(new_pid)}',
			)

		# 3. Normal stop control: SIGTERM without SIGUSR2 completes cleanly.
		f_norm = Fixture(base, binaries, 'normal-stop')
		with f_norm.daemon() as child:
			wait_for(lambda: f_norm.state().get('state') == 'running', child, label='normal initial running')
			old_pid = f_norm.xray_starts()[0]
			dns_pid = f_norm.read_pidfile('chinadns-ng.pid')
			child.terminate()
			rc = child.wait(timeout=10.0)
			events = f_norm.events()
			check(
				'normal-stop: clean exit with single xray start and no leftovers',
				rc == 0
				and f_norm.state().get('state') == 'stopped'
				and f_norm.xray_starts() == [old_pid]
				and any(e.get('code') == 'SERVICE_STOPPED' for e in events)
				and not any(e.get('code') in ('CMD_FAILED', 'START_FAILED') for e in events)
				and not pid_alive(old_pid)
				and not pid_alive(dns_pid),
				f'rc={rc} state={f_norm.state()} starts={f_norm.xray_starts()}',
			)


if __name__ == '__main__':
	try:
		main()
	except AssertionError as exc:
		print(str(exc), file=sys.stderr, flush=True)
		sys.exit(1)
