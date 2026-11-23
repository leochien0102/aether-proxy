#!/usr/bin/env python3
"""T16.58 regression: distinct pending daemon control requests must not swallow each other."""

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
TCP_LISTEN_LINE = (
	'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00000000:00000000 00000000 0 0 0\n'
)


def check(name, condition, detail=''):
	if not condition:
		msg = f'FAIL  T16.58 {name}'
		if detail:
			msg += f': {detail}'
		raise AssertionError(msg)
	print('PASS  T16.58 ' + name, flush=True)


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


def wait_for(predicate, child=None, timeout=10.0, label='condition', detail_fn=None):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		value = predicate()
		if value:
			return value
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited early ({child.returncode}) while waiting for {label}')
		time.sleep(0.01)
	extra = f' ({detail_fn()})' if detail_fn is not None else ''
	raise AssertionError(f'timed out ({timeout}s) waiting for {label}{extra}')


def read_proc_status(pid):
	fields = {}
	for line in Path(f'/proc/{pid}/status').read_text().splitlines():
		if ':' in line:
			key, val = line.split(':', 1)
			fields[key.strip()] = val.strip()
	return fields


def proc_signal_pending(pid, sig):
	fields = read_proc_status(pid)
	bit = 1 << (int(sig) - 1)
	sig_pnd = int(fields.get('SigPnd', '0'), 16)
	shd_pnd = int(fields.get('ShdPnd', '0'), 16)
	return bool((sig_pnd | shd_pnd) & bit)


def proc_voluntary_switches(pid):
	fields = read_proc_status(pid)
	return int(fields.get('voluntary_ctxt_switches', '0'))


def send_and_wait_received(child, sig, label, timeout=3.0):
	"""Send sig once and wait until the kernel cleared it from pending masks and
	the daemon completed at least one uloop wakeup/return cycle."""
	before_switches = proc_voluntary_switches(child.pid)
	child.send_signal(sig)
	wait_for(
		lambda: (not proc_signal_pending(child.pid, sig))
		and proc_voluntary_switches(child.pid) > before_switches,
		child, timeout=timeout, label=f'daemon received {label}',
	)


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
	trap_needle = '\ttrap cleanup TERM INT\n'
	assert source.count(trap_needle) == 1, 'xray stub trap anchor changed'
	cleanup_hook = '''cleanup() {
		if [ -e "$SYSROOT/hold-xray-exit" ]; then
			printf '%s\\n' "$$" > "$SYSROOT/xray-exiting.tmp"
			mv "$SYSROOT/xray-exiting.tmp" "$SYSROOT/xray-exiting"
			i=0
			while [ -e "$SYSROOT/hold-xray-exit" ] && [ "$i" -lt 800 ]; do
				i=$((i + 1))
				sleep 0.01
			done
		fi
		printf 'exited %s\\n' "$$" >> "$SYSROOT/xray-launches.log"'''
	source = source.replace(cleanup_needle, cleanup_hook, 1)
	# Install trap before publishing readiness so immediate stop after ready still logs exited.
	proc_needle = '\tproc="$SYSROOT/proc/$$"\n\tmkdir -p "$proc/fd" "$proc/net"\n\tcp "/proc/$$/stat" "$proc/stat"\n'
	assert source.count(proc_needle) == 1, 'xray stub proc anchor changed'
	cleanup_start = source.index('\tcleanup() {')
	cleanup_end = source.index(trap_needle) + len(trap_needle)
	cleanup_block = source[cleanup_start:cleanup_end]
	source = source[:cleanup_start] + source[cleanup_end:]
	source = source.replace(proc_needle, proc_needle + cleanup_block, 1)
	xray.write_text(source)
	xray.chmod(0o755)


class Fixture:
	def __init__(self, base, binaries, name, initial_tcp=TCP_LISTEN_LINE):
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
		(self.root / 'proc/net/tcp').write_text(initial_tcp)
		for filename in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log', 'xray-launches.log'):
			(self.root / filename).touch()
		self.calls = self.root / 'calls.log'
		self.launches = self.root / 'xray-launches.log'
		self.curl_count_file = self.root / 'curl-count'
		self.env = dict(
			os.environ,
			SYSROOT=str(self.root),
			STUB_LOG=str(self.calls),
			STUB_CURL_COUNT_FILE=str(self.curl_count_file),
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

	def curl_count(self):
		text = self.curl_count_file.read_text().strip() if self.curl_count_file.exists() else ''
		return int(text) if text.isdigit() else 0

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

	def xray_serial_valid(self):
		"""Verify no two Xray launches overlapped: start/exited strictly alternate."""
		active = None
		for kind, pid in self.xray_records():
			if kind == 'start':
				if active is not None:
					return False
				active = pid
			elif kind == 'exited':
				if active != pid:
					return False
				active = None
		return True

	def read_pidfile(self, name):
		path = self.run / name
		if not path.exists():
			return None
		text = path.read_text().strip()
		return int(text) if text.isdigit() else None

	def update_config(self, old, new):
		cfg_path = self.conf / 'aetherproxy'
		text = cfg_path.read_text()
		assert old in text, f'config needle not found: {old!r}'
		cfg_path.write_text(text.replace(old, new, 1))

	def arm_xray_barrier(self):
		exiting = self.root / 'xray-exiting'
		if exiting.exists():
			exiting.unlink()
		hold = self.root / 'hold-xray-exit'
		hold.touch()
		return hold, exiting

	def wait_xray_exiting(self, child, exiting, expected_pid, label='xray exiting barrier'):
		pid = wait_for(
			lambda: int(exiting.read_text().strip())
			if exiting.exists() and exiting.read_text().strip().isdigit() else None,
			child, timeout=5.0, label=label,
		)
		check(label, pid == expected_pid, f'exiting={pid} expected={expected_pid}')
		return pid

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


def scenario_busy_usr2_with_hup_and_usr1(base, binaries):
	"""While SIGUSR2 (Xray restart) is in flight, both SIGHUP and SIGUSR1 arrive.
	Neither may re-enter while busy, and both must execute after restart completes
	(with SIGUSR1 producing its own tick distinct from the restart-attached tick)."""
	f = Fixture(base, binaries, 'busy-usr2-hup-usr1')
	with f.daemon() as child:
		t0 = time.monotonic()
		wait_for(lambda: f.state().get('state') == 'running', child, label='s1 initial running')
		pid1 = f.xray_starts()[0]
		check('s1: initial state running with 1 xray and 1 curl',
			f.xray_starts() == [pid1] and f.curl_count() == 1 and f.state().get('mode') == 'gfw',
			f'starts={f.xray_starts()} curl={f.curl_count()} mode={f.state().get("mode")}')

		hold, exiting = f.arm_xray_barrier()
		child.send_signal(signal.SIGUSR2)
		f.wait_xray_exiting(child, exiting, pid1, label='s1: T1 SIGUSR2 in flight at xray barrier')

		# Mode change triggers nft_replace only (no xray restart, no node/ip change tick).
		f.update_config("option mode 'gfw'", "option mode 'bypass_cn'")

		send_and_wait_received(child, signal.SIGUSR1, 's1 SIGUSR1')
		send_and_wait_received(child, signal.SIGHUP, 's1 SIGHUP')

		check('s1: T2 no re-entry while SIGUSR2 held at barrier',
			pid_alive(pid1)
			and f.xray_starts() == [pid1]
			and f.state().get('mode') == 'gfw'
			and f.curl_count() == 1,
			f'alive={pid_alive(pid1)} starts={f.xray_starts()} mode={f.state().get("mode")} curl={f.curl_count()}')

		hold.unlink()

		wait_for(lambda: len(f.xray_starts()) >= 2, child, timeout=5.0, label='s1 new xray started')
		wait_for(
			lambda: f.state().get('mode') == 'bypass_cn'
			and any(e.get('code') == 'RELOAD_APPLIED' for e in f.events()),
			child, timeout=5.0, label='s1 SIGHUP reload applied',
		)
		wait_for(
			lambda: f.curl_count() >= 3,
			child, timeout=5.0, label='s1 SIGUSR1 tick executed (distinct from restart-attached tick)',
			detail_fn=lambda: f'starts={f.xray_starts()} curl={f.curl_count()} mode={f.state().get("mode")}',
		)
		elapsed = time.monotonic() - t0
		starts = f.xray_starts()
		check('s1: all three heterogeneous actions completed serially without automatic tick',
			len(starts) == 2
			and f.xray_serial_valid()
			and f.state().get('mode') == 'bypass_cn'
			and f.curl_count() == 3
			and elapsed < 15.0,
			f'starts={starts} records={f.xray_records()} mode={f.state().get("mode")} curl={f.curl_count()} elapsed={elapsed:.2f}s')

		child.terminate()
		rc = child.wait(timeout=10.0)
		check('s1: clean stop', rc == 0 and f.state().get('state') == 'stopped', f'rc={rc} state={f.state()}')


def scenario_busy_hup_with_coalesced_usr2_and_usr1(base, binaries):
	"""While SIGHUP (reload restarting Xray) is in flight, 2x SIGUSR2 and 2x SIGUSR1 arrive.
	Heterogeneous requests must not drop each other; duplicate pending requests of the same
	type must coalesce; Xray restarts must remain strictly serial."""
	f = Fixture(base, binaries, 'busy-hup-coalesce')
	with f.daemon() as child:
		t0 = time.monotonic()
		wait_for(lambda: f.state().get('state') == 'running', child, label='s2 initial running')
		pid1 = f.xray_starts()[0]
		check('s2: initial running', f.xray_starts() == [pid1] and f.curl_count() == 1,
			f'starts={f.xray_starts()} curl={f.curl_count()}')

		# Password change alters xray.json only -> reload restarts xray without changing node/ip.
		f.update_config("option password 'secret'", "option password 'secret2'")
		hold, exiting = f.arm_xray_barrier()
		child.send_signal(signal.SIGHUP)
		f.wait_xray_exiting(child, exiting, pid1, label='s2: T1 SIGHUP reload in flight at xray barrier')

		send_and_wait_received(child, signal.SIGUSR2, 's2 SIGUSR2 #1')
		send_and_wait_received(child, signal.SIGUSR2, 's2 SIGUSR2 #2')
		send_and_wait_received(child, signal.SIGUSR1, 's2 SIGUSR1 #1')
		send_and_wait_received(child, signal.SIGUSR1, 's2 SIGUSR1 #2')

		check('s2: T2 no re-entry while SIGHUP held at barrier',
			pid_alive(pid1)
			and f.xray_starts() == [pid1]
			and f.curl_count() == 1
			and not any(e.get('code') == 'RELOAD_APPLIED' for e in f.events()),
			f'starts={f.xray_starts()} curl={f.curl_count()}')

		hold.unlink()

		wait_for(
			lambda: any(e.get('code') == 'RELOAD_APPLIED' for e in f.events()),
			child, timeout=5.0, label='s2 SIGHUP reload applied',
		)
		wait_for(
			lambda: len(f.xray_starts()) >= 3,
			child, timeout=5.0, label='s2 coalesced SIGUSR2 restarted xray',
			detail_fn=lambda: f'starts={f.xray_starts()} curl={f.curl_count()} events={[e.get("code") for e in f.events()]}',
		)
		wait_for(
			lambda: f.curl_count() >= 3,
			child, timeout=5.0, label='s2 coalesced SIGUSR1 tick completed',
			detail_fn=lambda: f'starts={f.xray_starts()} curl={f.curl_count()} events={[e.get("code") for e in f.events()]}',
		)
		elapsed = time.monotonic() - t0
		# Allow a bounded readiness check that pid3 is active and no 4th launch happened.
		pid3 = f.xray_starts()[2]
		wait_for(
			lambda: f.read_pidfile('xray.pid') == pid3 and f.state().get('state') == 'running',
			child, timeout=5.0, label='s2 pid3 settled',
		)
		check('s2: heterogeneous consumed, same-type coalesced, strictly serial',
			len(f.xray_starts()) == 3
			and f.xray_serial_valid()
			and f.curl_count() == 3
			and elapsed < 15.0,
			f'starts={f.xray_starts()} records={f.xray_records()} curl={f.curl_count()} elapsed={elapsed:.2f}s')

		child.terminate()
		rc = child.wait(timeout=10.0)
		check('s2: clean stop', rc == 0 and f.state().get('state') == 'stopped', f'rc={rc} state={f.state()}')


def scenario_usr2_alone_vs_usr2_with_usr1(base, binaries):
	"""Explicit control: SIGUSR2 alone adds exactly 1 restart-attached tick (curl_count=2),
	whereas SIGUSR2 with SIGUSR1 while busy must produce 2 ticks (curl_count=3)."""
	# Control: SIGUSR2 alone
	f_ctrl = Fixture(base, binaries, 'ctrl-usr2-alone')
	with f_ctrl.daemon() as child:
		t0 = time.monotonic()
		wait_for(lambda: f_ctrl.state().get('state') == 'running', child, label='ctrl initial running')
		pid1 = f_ctrl.xray_starts()[0]
		hold, exiting = f_ctrl.arm_xray_barrier()
		child.send_signal(signal.SIGUSR2)
		f_ctrl.wait_xray_exiting(child, exiting, pid1, label='ctrl: SIGUSR2 at barrier')
		hold.unlink()
		wait_for(lambda: len(f_ctrl.xray_starts()) >= 2, child, timeout=5.0, label='ctrl new xray')
		pid2 = f_ctrl.xray_starts()[1]
		wait_for(
			lambda: f_ctrl.read_pidfile('xray.pid') == pid2 and f_ctrl.curl_count() >= 2,
			child, timeout=5.0, label='ctrl restart-attached tick',
		)
		elapsed = time.monotonic() - t0
		check('ctrl: SIGUSR2 alone produces exactly 1 restart-attached tick (curl=2)',
			len(f_ctrl.xray_starts()) == 2 and f_ctrl.curl_count() == 2 and elapsed < 15.0,
			f'starts={f_ctrl.xray_starts()} curl={f_ctrl.curl_count()} elapsed={elapsed:.2f}s')
		child.terminate()
		rc = child.wait(timeout=10.0)
		check('ctrl: clean stop', rc == 0 and f_ctrl.state().get('state') == 'stopped', f'rc={rc}')

	# Treatment: SIGUSR2 + SIGUSR1 while busy
	f_usr1 = Fixture(base, binaries, 'busy-usr2-with-usr1')
	with f_usr1.daemon() as child:
		t0 = time.monotonic()
		wait_for(lambda: f_usr1.state().get('state') == 'running', child, label='s3 initial running')
		pid1 = f_usr1.xray_starts()[0]
		hold, exiting = f_usr1.arm_xray_barrier()
		child.send_signal(signal.SIGUSR2)
		f_usr1.wait_xray_exiting(child, exiting, pid1, label='s3: SIGUSR2 at barrier')
		send_and_wait_received(child, signal.SIGUSR1, 's3 SIGUSR1 while busy')
		hold.unlink()
		wait_for(lambda: len(f_usr1.xray_starts()) >= 2, child, timeout=5.0, label='s3 new xray')
		wait_for(lambda: f_usr1.curl_count() >= 3, child, timeout=5.0, label='s3 SIGUSR1 tick after restart')
		elapsed = time.monotonic() - t0
		check('s3: SIGUSR1 while SIGUSR2 busy adds its own tick (curl=3, distinct from attached tick)',
			len(f_usr1.xray_starts()) == 2 and f_usr1.curl_count() == 3 and elapsed < 15.0,
			f'starts={f_usr1.xray_starts()} curl={f_usr1.curl_count()} elapsed={elapsed:.2f}s')
		child.terminate()
		rc = child.wait(timeout=10.0)
		check('s3: clean stop', rc == 0 and f_usr1.state().get('state') == 'stopped', f'rc={rc}')


def scenario_term_preempts_pending_controls(base, binaries):
	"""SIGTERM arriving while SIGUSR2 is in flight and SIGHUP/SIGUSR1 are pending
	must discard unstarted control requests, cancel the in-flight restart (T16.57),
	and stop cleanly with no new Xray start."""
	f = Fixture(base, binaries, 'term-preempts')
	with f.daemon() as child:
		wait_for(lambda: f.state().get('state') == 'running', child, label='s4 initial running')
		pid1 = f.xray_starts()[0]
		dns_pid = f.read_pidfile('chinadns-ng.pid')

		hold, exiting = f.arm_xray_barrier()
		child.send_signal(signal.SIGUSR2)
		f.wait_xray_exiting(child, exiting, pid1, label='s4: T1 SIGUSR2 at barrier')

		f.update_config("option mode 'gfw'", "option mode 'bypass_cn'")
		send_and_wait_received(child, signal.SIGHUP, 's4 SIGHUP pending')
		send_and_wait_received(child, signal.SIGUSR1, 's4 SIGUSR1 pending')

		child.terminate()
		wait_for(lambda: f.state().get('state') == 'stopping', child, timeout=2.0, label='s4 T2 daemon stopping')
		check('s4: T2 stop accepted while old xray still held',
			hold.exists() and pid_alive(pid1) and pid1 not in f.xray_exits(),
			f'hold={hold.exists()} alive={pid_alive(pid1)} exits={f.xray_exits()}')

		hold.unlink()
		rc = child.wait(timeout=10.0)
		events = f.events()
		check('s4: stop preempted pending HUP/USR1 and cancelled in-flight USR2',
			rc == 0
			and f.state().get('state') == 'stopped'
			and f.xray_starts() == [pid1]
			and pid1 in f.xray_exits()
			and f.curl_count() == 1
			and not any(e.get('code') == 'RELOAD_APPLIED' for e in events)
			and any(e.get('code') == 'SERVICE_STOPPED' for e in events)
			and not any(e.get('code') in ('CMD_FAILED', 'START_FAILED') for e in events)
			and not pid_alive(pid1)
			and not pid_alive(dns_pid),
			f'rc={rc} state={f.state()} starts={f.xray_starts()} curl={f.curl_count()} events={[e.get("code") for e in events]}')


def scenario_startup_non_stop_signal_not_stop(base, binaries):
	"""A non-stop signal (SIGUSR1) during startup readiness wait must not be treated as stop."""
	f = Fixture(base, binaries, 'startup-non-stop', initial_tcp='')
	with f.daemon() as child:
		wait_for(lambda: len(f.xray_starts()) >= 1, child, timeout=5.0, label='s5 xray started during startup')
		send_and_wait_received(child, signal.SIGUSR1, 's5 SIGUSR1 during startup')
		check('s5: daemon did not treat SIGUSR1 as stop during startup',
			f.state().get('state') != 'stopping' and child.poll() is None,
			f'state={f.state()} poll={child.poll()}')

		(f.root / 'proc/net/tcp').write_text(TCP_LISTEN_LINE)
		wait_for(lambda: f.state().get('state') == 'running', child, timeout=10.0, label='s5 reached running')
		check('s5: startup completed after non-stop signal',
			f.state().get('state') == 'running' and len(f.xray_starts()) == 1,
			f'state={f.state()} starts={f.xray_starts()}')

		child.terminate()
		rc = child.wait(timeout=10.0)
		check('s5: clean stop', rc == 0 and f.state().get('state') == 'stopped', f'rc={rc}')


def scenario_single_requests_normal(base, binaries):
	"""Positive control: normal single SIGHUP and SIGUSR1 still work cleanly."""
	f = Fixture(base, binaries, 'single-normal')
	with f.daemon() as child:
		t0 = time.monotonic()
		wait_for(lambda: f.state().get('state') == 'running', child, label='s6 initial running')
		check('s6: initial running', f.curl_count() == 1 and f.state().get('mode') == 'gfw',
			f'curl={f.curl_count()} mode={f.state().get("mode")}')

		child.send_signal(signal.SIGUSR1)
		wait_for(lambda: f.curl_count() >= 2, child, timeout=5.0, label='s6 single SIGUSR1')
		check('s6: single SIGUSR1 ran one tick', f.curl_count() == 2 and time.monotonic() - t0 < 15.0,
			f'curl={f.curl_count()}')

		f.update_config("option mode 'gfw'", "option mode 'bypass_cn'")
		child.send_signal(signal.SIGHUP)
		wait_for(lambda: f.state().get('mode') == 'bypass_cn', child, timeout=5.0, label='s6 single SIGHUP')
		check('s6: single SIGHUP applied config', f.state().get('mode') == 'bypass_cn', f'state={f.state()}')

		child.terminate()
		rc = child.wait(timeout=10.0)
		check('s6: clean stop', rc == 0 and f.state().get('state') == 'stopped', f'rc={rc}')


def main():
	with tempfile.TemporaryDirectory(prefix='.pending-requests-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		binaries = base / 'bin'
		build_stubs(binaries)
		for directory in ('data', 'base', 'custom'):
			(base / directory).mkdir()
		for name in ('gfwlist', 'chnlist', 'apple'):
			(base / 'base' / f'{name}.txt').write_text('example.com\n')
		(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
		(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

		scenario_busy_usr2_with_hup_and_usr1(base, binaries)
		scenario_busy_hup_with_coalesced_usr2_and_usr1(base, binaries)
		scenario_usr2_alone_vs_usr2_with_usr1(base, binaries)
		scenario_term_preempts_pending_controls(base, binaries)
		scenario_startup_non_stop_signal_not_stop(base, binaries)
		scenario_single_requests_normal(base, binaries)


if __name__ == '__main__':
	try:
		main()
	except AssertionError as exc:
		print(str(exc), file=sys.stderr, flush=True)
		sys.exit(1)
