#!/usr/bin/env python3
"""T16.59 regression: daemon instance exclusivity across full lifecycle."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
TCP_LISTEN_LINE = (
	'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00000000:00000000 00000000 0 0 0\n'
)


FAILURES = []


def check(name, condition, detail=''):
	if not condition:
		msg = f'FAIL  T16.59 {name}'
		if detail:
			msg += f': {detail}'
		print(msg, flush=True)
		FAILURES.append(msg)
		return False
	print('PASS  T16.59 ' + name, flush=True)
	return True


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


def build_stubs(binaries):
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	nft = binaries / 'nft'
	source = nft.read_text()
	needle = '\t\t\t*/aether-proxy.nft)\n'
	assert source.count(needle) == 1, 'nft stub anchor changed'
	hook = needle + '''\t\t\t\tif [ -e "$SYSROOT/hold-nft-check" ]; then
\t\t\t\t\tprintf '%s\\n' "$$" > "$SYSROOT/nft-check-entered.tmp"
\t\t\t\t\tmv "$SYSROOT/nft-check-entered.tmp" "$SYSROOT/nft-check-entered"
\t\t\t\t\ti=0
\t\t\t\t\twhile [ -e "$SYSROOT/hold-nft-check" ] && [ "$i" -lt 800 ]; do
\t\t\t\t\t\ti=$((i + 1))
\t\t\t\t\t\tsleep 0.01
\t\t\t\t\tdone
\t\t\t\tfi
'''
	nft.write_text(source.replace(needle, hook, 1))
	nft.chmod(0o755)

	xray = binaries / 'xray'
	xsrc = xray.read_text()
	xneedle = 'printf \'xray %s\\n\' "$*" >> "$STUB_LOG"\n\techo "$$" > "$SYSROOT/xray.pid"'
	assert xsrc.count(xneedle) == 1, 'xray stub start anchor changed'
	xhook = xneedle + '\n\tprintf \'start %s\\n\' "$$" >> "$SYSROOT/xray-launches.log"'
	xray.write_text(xsrc.replace(xneedle, xhook, 1))
	xray.chmod(0o755)


class SnapshotWatcher:
	"""Poll daemon.pid and state.json continuously during a contention window."""

	def __init__(self, run_dir):
		self.run_dir = run_dir
		self.stop_event = threading.Event()
		self.pids_seen = set()
		self.pid_missing = False
		self.states_seen = []
		self.started_ats_seen = set()
		self.parse_errors = 0
		self.samples = 0
		self.thread = threading.Thread(target=self._loop, daemon=True)

	def _sample(self):
		self.samples += 1
		pid_path = self.run_dir / 'daemon.pid'
		if not pid_path.exists():
			self.pid_missing = True
		else:
			try:
				text = pid_path.read_text().strip()
				if text.isdigit():
					self.pids_seen.add(int(text))
				elif text:
					self.pids_seen.add(text)
			except OSError:
				self.pid_missing = True
		state_path = self.run_dir / 'state.json'
		if state_path.exists():
			try:
				data = json.loads(state_path.read_text())
				if isinstance(data, dict):
					st = data.get('state')
					if st is not None and (not self.states_seen or self.states_seen[-1] != st):
						self.states_seen.append(st)
					if data.get('started_at') is not None:
						self.started_ats_seen.add(data['started_at'])
			except (OSError, ValueError):
				self.parse_errors += 1

	def _loop(self):
		while not self.stop_event.is_set():
			self._sample()
			time.sleep(0.002)
		self._sample()

	def __enter__(self):
		self.thread.start()
		return self

	def __exit__(self, exc_type, exc, tb):
		self.stop_event.set()
		self.thread.join(timeout=2.0)


def is_mutating_call(line):
	"""Return True for component start/stop or dataplane mutation calls (excluding monitor read-only probes)."""
	if line.startswith('xray ') and not line.startswith('xray version'):
		return True
	if line.startswith('chinadns-ng ') or line.startswith('aether-dns '):
		return True
	if line.startswith('dnsmasq '):
		return True
	if line.startswith('nft '):
		# Monitor ticks may read `nft list table inet aetherproxy` or `nft -j list counters`;
		# dataplane mutations use `-c`, `-f`, `delete`, `flush`.
		for token in (' -c ', ' -f ', ' delete ', ' flush '):
			if token in f' {line} ':
				return True
	if line.startswith('ip '):
		if ' rule ' in line or ' route add ' in line or ' route del ' in line:
			return True
	return False


class Fixture:
	def __init__(self, base, binaries, name, create_run_dir=True, run_dir_rel='var/run/aether-proxy'):
		self.base = base
		self.binaries = binaries
		self.root = base / name
		self.run_dir_rel = run_dir_rel
		self.run = self.root / run_dir_rel
		self.conf = self.root / 'etc/config'
		dirs = [
			'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
			'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
			'etc/config',
		]
		if create_run_dir:
			dirs.append(run_dir_rel)
		for directory in dirs:
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
		(self.root / 'proc/net/tcp').write_text(TCP_LISTEN_LINE)
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
			AETHER_PROXY_TEST_RAW_LOG_COLLECTOR=str(ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'),
		)
		self.args = [
			'--sys-root', str(self.root),
			'--bin-dir', str(binaries),
			'--confdir', str(self.conf),
			'--data-dir', str(base / 'data'),
			'--baseline-dir', str(base / 'base'),
			'--custom-dir', str(base / 'custom'),
		]
		if run_dir_rel != 'var/run/aether-proxy':
			self.args.extend(['--run-dir', '/' + run_dir_rel.lstrip('/')])

	def daemon_command(self):
		return [str(UCODE), '-S', str(ENTRY), '--', 'daemon', *self.args]

	def state(self):
		path = self.run / 'state.json'
		return json.loads(path.read_text()) if path.exists() and path.is_file() else {}

	def events(self):
		path = self.run / 'events.jsonl'
		return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []

	def call_lines(self):
		return self.calls.read_text().splitlines() if self.calls.exists() else []

	def curl_count(self):
		text = self.curl_count_file.read_text().strip() if self.curl_count_file.exists() else ''
		return int(text) if text.isdigit() else 0

	def xray_starts(self):
		if not self.launches.exists():
			return []
		out = []
		for line in self.launches.read_text().splitlines():
			parts = line.split()
			if len(parts) == 2 and parts[0] == 'start' and parts[1].isdigit():
				out.append(int(parts[1]))
		return out

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

	def arm_nft_barrier(self):
		entered = self.root / 'nft-check-entered'
		if entered.exists():
			entered.unlink()
		hold = self.root / 'hold-nft-check'
		hold.touch()
		return hold, entered

	def release_nft_barrier(self):
		hold = self.root / 'hold-nft-check'
		if hold.exists():
			hold.unlink()

	def cleanup_leftovers(self):
		self.release_nft_barrier()
		pids = set(self.xray_starts())
		for name in ('daemon.pid', 'xray.pid', 'chinadns-ng.pid', 'aether-dns.pid', 'raw-log.pid'):
			pid = self.read_pidfile(name)
			if pid is not None:
				pids.add(pid)
		for filename in ('xray.pid', 'chinadns.pid'):
			p = self.root / filename
			if p.exists():
				text = p.read_text().strip()
				if text.isdigit():
					pids.add(int(text))
		for pid in pids:
			kill_pid_bounded(pid)

	@contextmanager
	def daemon(self, tag='primary'):
		stdout_path = self.root / f'{tag}.stdout'
		stderr_path = self.root / f'{tag}.stderr'
		with stdout_path.open('w') as stdout, stderr_path.open('w') as stderr:
			with subprocess.Popen(
				self.daemon_command(), env=self.env, stdout=stdout, stderr=stderr, start_new_session=True,
			) as child:
				try:
					yield child
				finally:
					self.release_nft_barrier()
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

	def run_contender(self, tag='contender', timeout=5.0):
		"""Run a competing daemon bounded in time; kill it if it does not exit quickly."""
		stdout_path = self.root / f'{tag}.stdout'
		stderr_path = self.root / f'{tag}.stderr'
		with stdout_path.open('w') as stdout, stderr_path.open('w') as stderr:
			proc = subprocess.Popen(
				self.daemon_command(), env=self.env, stdout=stdout, stderr=stderr, start_new_session=True,
			)
			timed_out = False
			try:
				rc = proc.wait(timeout=timeout)
			except subprocess.TimeoutExpired:
				timed_out = True
				os.killpg(proc.pid, signal.SIGKILL)
				proc.wait(timeout=5)
				rc = proc.returncode
		return {
			'pid': proc.pid,
			'rc': rc,
			'timed_out': timed_out,
			'stdout': stdout_path.read_text(),
			'stderr': stderr_path.read_text(),
		}


def scenario_duplicate_while_running(base, binaries):
	"""Scenario 1: running daemon encounters duplicate start in same sys-root."""
	f = Fixture(base, binaries, 'dup-running')
	with f.daemon('owner') as owner:
		wait_for(lambda: f.state().get('state') == 'running', owner, label='owner running')
		owner_pid = owner.pid
		owner_state = f.state()
		owner_started_at = owner_state.get('started_at')
		check('S1 owner publishes own pid and running state',
			f.read_pidfile('daemon.pid') == owner_pid and owner_started_at is not None,
			f'pidfile={f.read_pidfile("daemon.pid")} owner={owner_pid} started_at={owner_started_at}')

		# Wait past the owner's startup second so any contender state write has a distinct started_at.
		while int(time.time()) <= int(owner_started_at):
			time.sleep(0.05)

		calls_before = len(f.call_lines())
		xray_before = list(f.xray_starts())
		busy_before = sum(1 for e in f.events() if e.get('code') == 'BUSY')

		with SnapshotWatcher(f.run) as watcher:
			contender = f.run_contender('contender', timeout=4.0)

		new_calls = f.call_lines()[calls_before:]
		mutating = [line for line in new_calls if is_mutating_call(line)]
		xray_after = list(f.xray_starts())
		busy_after = sum(1 for e in f.events() if e.get('code') == 'BUSY')

		check('S1 contender exits BUSY (3) quickly without timeout',
			(not contender['timed_out']) and contender['rc'] == 3,
			f'rc={contender["rc"]} timed_out={contender["timed_out"]} stderr={contender["stderr"]!r}')
		check('S1 contender emitted BUSY event',
			busy_after >= busy_before + 1,
			f'busy_before={busy_before} busy_after={busy_after}')
		check('S1 owner daemon.pid never overwritten or deleted during contention',
			(not watcher.pid_missing) and watcher.pids_seen == {owner_pid} and f.read_pidfile('daemon.pid') == owner_pid,
			f'pids_seen={watcher.pids_seen} missing={watcher.pid_missing} final={f.read_pidfile("daemon.pid")} contender={contender["pid"]}')
		check('S1 owner state.json never overwritten to starting or new started_at',
			'starting' not in watcher.states_seen
			and watcher.started_ats_seen == {owner_started_at}
			and f.state().get('state') == 'running'
			and f.state().get('started_at') == owner_started_at,
			f'states={watcher.states_seen} started_ats={watcher.started_ats_seen} final={f.state()}')
		check('S1 contender triggered zero component/dataplane mutations',
			len(mutating) == 0 and xray_after == xray_before,
			f'mutating={mutating} xray_before={xray_before} xray_after={xray_after}')

		# Owner must still serve normal control requests (SIGUSR1, SIGHUP) and clean SIGTERM.
		curls_before = f.curl_count()
		owner.send_signal(signal.SIGUSR1)
		wait_for(lambda: f.curl_count() > curls_before, owner, label='owner SIGUSR1 probe')
		check('S1 owner handles SIGUSR1 after contention', f.curl_count() > curls_before)

		f.update_config("option mode 'gfw'", "option mode 'global'")
		owner.send_signal(signal.SIGHUP)
		wait_for(lambda: f.state().get('mode') == 'global', owner, label='owner SIGHUP reload')
		check('S1 owner handles SIGHUP reload after contention', f.state().get('mode') == 'global')

		owner.terminate()
		rc = owner.wait(timeout=10)
		check('S1 owner stops cleanly on SIGTERM',
			rc == 0 and f.state().get('state') == 'stopped' and f.read_pidfile('daemon.pid') is None,
			f'rc={rc} state={f.state().get("state")} pid={f.read_pidfile("daemon.pid")}')


def scenario_duplicate_during_startup(base, binaries):
	"""Scenario 2: owner paused inside startup (holding op lock) encounters duplicate start."""
	f = Fixture(base, binaries, 'dup-startup')
	hold, entered = f.arm_nft_barrier()
	with f.daemon('owner') as owner:
		wait_for(lambda: entered.exists(), owner, label='owner enters nft -c barrier')
		owner_pid = owner.pid
		owner_started_at = f.state().get('started_at')
		check('S2 owner owns daemon.pid during startup',
			f.read_pidfile('daemon.pid') == owner_pid and owner_started_at is not None,
			f'pidfile={f.read_pidfile("daemon.pid")} owner={owner_pid}')

		while int(time.time()) <= int(owner_started_at):
			time.sleep(0.05)

		calls_before = len(f.call_lines())
		with SnapshotWatcher(f.run) as watcher:
			contender = f.run_contender('contender', timeout=4.0)

		new_calls = f.call_lines()[calls_before:]
		mutating = [line for line in new_calls if is_mutating_call(line)]
		check('S2 contender exits BUSY (3) quickly during startup',
			(not contender['timed_out']) and contender['rc'] == 3,
			f'rc={contender["rc"]} timed_out={contender["timed_out"]}')
		check('S2 owner daemon.pid never overwritten during startup contention',
			(not watcher.pid_missing) and watcher.pids_seen == {owner_pid} and f.read_pidfile('daemon.pid') == owner_pid,
			f'pids_seen={watcher.pids_seen} missing={watcher.pid_missing} final={f.read_pidfile("daemon.pid")} contender={contender["pid"]}')
		check('S2 owner state.json started_at never overwritten during startup contention',
			watcher.started_ats_seen == {owner_started_at} and f.state().get('started_at') == owner_started_at,
			f'started_ats={watcher.started_ats_seen} owner_started_at={owner_started_at}')
		check('S2 contender made zero mutating calls during startup contention',
			len(mutating) == 0, f'mutating={mutating}')

		hold.unlink()
		wait_for(lambda: f.state().get('state') == 'running', owner, label='owner finishes startup')
		owner.terminate()
		rc = owner.wait(timeout=10)
		check('S2 owner finishes startup and stops cleanly',
			rc == 0 and f.state().get('state') == 'stopped',
			f'rc={rc} state={f.state().get("state")}')


def scenario_duplicate_while_error_waiting(base, binaries):
	"""Scenario 3: owner waiting in error state (config invalid, op lock released) retains exclusivity."""
	f = Fixture(base, binaries, 'dup-error')
	f.update_config("option mode 'gfw'", "option mode 'invalid_mode'")
	with f.daemon('owner') as owner:
		wait_for(lambda: f.state().get('state') == 'error', owner, label='owner error state')
		owner_pid = owner.pid
		check('S3 owner enters error state with own pid',
			f.read_pidfile('daemon.pid') == owner_pid,
			f'pidfile={f.read_pidfile("daemon.pid")} owner={owner_pid}')

		calls_before = len(f.call_lines())
		with SnapshotWatcher(f.run) as watcher:
			contender = f.run_contender('contender', timeout=4.0)

		new_calls = f.call_lines()[calls_before:]
		mutating = [line for line in new_calls if is_mutating_call(line)]
		check('S3 contender exits BUSY (3) while owner waits in error state',
			(not contender['timed_out']) and contender['rc'] == 3,
			f'rc={contender["rc"]} timed_out={contender["timed_out"]}')
		check('S3 owner pid and error state untouched during contention',
			(not watcher.pid_missing)
			and watcher.pids_seen == {owner_pid}
			and watcher.states_seen == ['error']
			and f.state().get('state') == 'error'
			and len(mutating) == 0,
			f'pids={watcher.pids_seen} states={watcher.states_seen} mutating={mutating}')

		# Fix config and recover owner via SIGHUP, then stop cleanly.
		f.update_config("option mode 'invalid_mode'", "option mode 'gfw'")
		owner.send_signal(signal.SIGHUP)
		wait_for(lambda: f.state().get('state') == 'running', owner, label='owner recovers on SIGHUP')
		owner.terminate()
		rc = owner.wait(timeout=10)
		check('S3 owner recovers via SIGHUP and stops cleanly',
			rc == 0 and f.state().get('state') == 'stopped',
			f'rc={rc} state={f.state().get("state")}')


def scenario_interleaved_first_starts(base, binaries):
	"""Scenario 4: two first-time daemon starts race simultaneously from a barrier."""
	# Deliberately do not pre-create var/run/aether-proxy so mkdir_p race is also exercised.
	f = Fixture(base, binaries, 'interleaved', create_run_dir=False)
	hold, entered = f.arm_nft_barrier()

	r_go, w_go = os.pipe()
	r_ready, w_ready = os.pipe()
	cmd = f.daemon_command()
	stdout_a = (f.root / 'race-a.stdout').open('w')
	stderr_a = (f.root / 'race-a.stderr').open('w')
	stdout_b = (f.root / 'race-b.stdout').open('w')
	stderr_b = (f.root / 'race-b.stderr').open('w')

	def spawn_gated(stdout_fp, stderr_fp):
		pid = os.fork()
		if pid == 0:
			try:
				os.setsid()
				os.close(w_go)
				os.close(r_ready)
				os.dup2(stdout_fp.fileno(), 1)
				os.dup2(stderr_fp.fileno(), 2)
				os.write(w_ready, b'1')
				os.close(w_ready)
				os.read(r_go, 1)
				os.close(r_go)
				os.execve(cmd[0], cmd, f.env)
			except BaseException:
				os._exit(127)
		return pid

	pid_a = pid_b = None
	try:
		pid_a = spawn_gated(stdout_a, stderr_a)
		pid_b = spawn_gated(stdout_b, stderr_b)
		os.close(w_ready)
		os.close(r_go)
		ready = b''
		while len(ready) < 2:
			chunk = os.read(r_ready, 2 - len(ready))
			if not chunk:
				break
			ready += chunk
		os.close(r_ready)

		with SnapshotWatcher(f.run) as watcher:
			# Release both children at the same instant.
			os.write(w_go, b'GG')
			os.close(w_go)
			w_go = None

			# Wait until one exits (loser) and one reaches the nft -c barrier (winner).
			loser_pid = None
			loser_rc = None
			deadline = time.monotonic() + 8.0
			while time.monotonic() < deadline:
				for p in (pid_a, pid_b):
					if loser_pid is None:
						wpid, status = os.waitpid(p, os.WNOHANG)
						if wpid == p:
							loser_pid = p
							loser_rc = os.waitstatus_to_exitcode(status)
				if loser_pid is not None and entered.exists():
					break
				time.sleep(0.01)

		winner_pid = pid_b if loser_pid == pid_a else pid_a
		check('S4 exactly one contender exits BUSY (3) while winner reaches barrier',
			loser_pid is not None and loser_rc == 3 and entered.exists(),
			f'loser={loser_pid} rc={loser_rc} entered={entered.exists()} a={pid_a} b={pid_b}')
		check('S4 daemon.pid only ever recorded winner pid, never loser pid',
			loser_pid not in watcher.pids_seen
			and winner_pid in watcher.pids_seen
			and f.read_pidfile('daemon.pid') == winner_pid,
			f'pids_seen={watcher.pids_seen} winner={winner_pid} loser={loser_pid} final={f.read_pidfile("daemon.pid")}')

		hold.unlink()
		wait_for(lambda: f.state().get('state') == 'running', timeout=10.0, label='S4 winner running')
		check('S4 single xray launch and single dnsmasq install across race',
			len(f.xray_starts()) == 1
			and sum(1 for line in f.call_lines() if line.startswith('dnsmasq ')) == 1,
			f'xray_starts={f.xray_starts()} dnsmasq_calls={[l for l in f.call_lines() if l.startswith("dnsmasq ")]}')

		os.kill(winner_pid, signal.SIGTERM)
		deadline = time.monotonic() + 10.0
		winner_rc = None
		while time.monotonic() < deadline:
			wpid, status = os.waitpid(winner_pid, os.WNOHANG)
			if wpid == winner_pid:
				winner_rc = os.waitstatus_to_exitcode(status)
				break
			time.sleep(0.01)
		check('S4 winner stops cleanly on SIGTERM',
			winner_rc == 0 and f.state().get('state') == 'stopped',
			f'winner_rc={winner_rc} state={f.state().get("state")}')
		winner_pid = None
	finally:
		if w_go is not None:
			try:
				os.close(w_go)
			except OSError:
				pass
		f.release_nft_barrier()
		for p in (pid_a, pid_b):
			if p is not None and pid_alive(p):
				try:
					os.killpg(p, signal.SIGKILL)
				except OSError:
					pass
				try:
					os.waitpid(p, 0)
				except ChildProcessError:
					pass
		for fp in (stdout_a, stderr_a, stdout_b, stderr_b):
			fp.close()
		f.cleanup_leftovers()


def scenario_normal_exit_takeover(base, binaries):
	"""Scenario 5: single-instance positive control and immediate takeover after clean exit."""
	f = Fixture(base, binaries, 'normal-takeover')
	lock_file = f.run / 'daemon.lock'
	with f.daemon('first') as first:
		wait_for(lambda: f.state().get('state') == 'running', first, label='S5 first running')
		check('S5 instance lock exists in isolated run_dir', lock_file.exists())
		first.terminate()
		rc1 = first.wait(timeout=10)
		check('S5 first stops cleanly and preserves lock file inode',
			rc1 == 0 and f.state().get('state') == 'stopped' and lock_file.exists(),
			f'rc1={rc1} state={f.state().get("state")} lock_exists={lock_file.exists()}')

	ino_before = lock_file.stat().st_ino
	with f.daemon('second') as second:
		wait_for(lambda: f.state().get('state') == 'running', second, label='S5 second running')
		check('S5 second immediately acquires same lock inode and reaches running',
			f.read_pidfile('daemon.pid') == second.pid and lock_file.stat().st_ino == ino_before,
			f'pid={f.read_pidfile("daemon.pid")} expected={second.pid}')
		second.terminate()
		rc2 = second.wait(timeout=10)
		check('S5 second stops cleanly', rc2 == 0 and f.state().get('state') == 'stopped')


def scenario_sigkill_takeover(base, binaries):
	"""Scenario 6: SIGKILLed owner with surviving children does not block lock re-acquisition."""
	f = Fixture(base, binaries, 'sigkill-takeover')
	lock_file = f.run / 'daemon.lock'
	with f.daemon('doomed') as doomed:
		wait_for(lambda: f.state().get('state') == 'running', doomed, label='S6 doomed running')
		old_xray = f.read_pidfile('xray.pid')
		check('S6 doomed daemon has running xray child', old_xray is not None and pid_alive(old_xray))
		# SIGKILL ONLY the daemon process, leaving supervised children alive.
		os.kill(doomed.pid, signal.SIGKILL)
		rc_killed = doomed.wait(timeout=5)
		check('S6 doomed daemon killed by SIGKILL while xray survives',
			rc_killed == -signal.SIGKILL and pid_alive(old_xray) and lock_file.exists(),
			f'rc={rc_killed} xray_alive={pid_alive(old_xray)} lock_exists={lock_file.exists()}')

		# Immediately launch successor while old_xray is still alive.
		# Distinguish (a) lock re-acquirable from (b) full dataplane recovery.
		with f.daemon('successor') as successor:
			wait_for(lambda: f.read_pidfile('daemon.pid') == successor.pid, successor,
				timeout=5.0, label='S6 successor acquires lock and publishes pid')
			check('S6 lock immediately re-acquired despite surviving child and leftover lock file',
				f.read_pidfile('daemon.pid') == successor.pid)

			wait_for(lambda: f.state().get('state') == 'running', successor,
				timeout=10.0, label='S6 successor dataplane recovery')
			new_xray = f.read_pidfile('xray.pid')
			check('S6 dataplane recovered with fresh xray child',
				new_xray is not None and new_xray != old_xray and pid_alive(new_xray),
				f'old_xray={old_xray} new_xray={new_xray}')
			successor.terminate()
			rc_succ = successor.wait(timeout=10)
			check('S6 successor stops cleanly', rc_succ == 0 and f.state().get('state') == 'stopped')


def scenario_lock_setup_failures(base, binaries):
	"""Scenario 7: lock setup failures refuse startup with exit 1 and diagnostic error, not BUSY (3)."""
	# 7a: daemon.lock path is a directory -> fs.open('ae') fails at open stage.
	f_open = Fixture(base, binaries, 'lock-open-fail')
	(f_open.run / 'daemon.lock').mkdir()
	res_open = f_open.run_contender('open-fail', timeout=5.0)
	events_open = f_open.events()
	check('S7a lock open failure exits 1 (not BUSY 3) with diagnostic error',
		(not res_open['timed_out'])
		and res_open['rc'] == 1
		and 'lock' in res_open['stderr'].lower()
		and not any(e.get('code') == 'BUSY' for e in events_open)
		and any(e.get('code') == 'START_FAILED' and e.get('args', {}).get('step') == 'instance_lock' for e in events_open),
		f'rc={res_open["rc"]} stderr={res_open["stderr"]!r} events={events_open}')
	check('S7a lock open failure leaves state/pid untouched and makes zero calls',
		not (f_open.run / 'state.json').exists()
		and not (f_open.run / 'daemon.pid').exists()
		and len(f_open.call_lines()) == 0,
		f'calls={f_open.call_lines()}')

	# 7b: run_dir itself is a regular file -> mkdir_p fails at directory creation stage.
	f_dir = Fixture(base, binaries, 'lock-mkdir-fail', create_run_dir=False)
	f_dir.run.parent.mkdir(parents=True, exist_ok=True)
	f_dir.run.write_text('not a directory\n')
	res_dir = f_dir.run_contender('mkdir-fail', timeout=5.0)
	check('S7b lock mkdir failure exits 1 (not BUSY 3) with diagnostic error and zero calls',
		(not res_dir['timed_out'])
		and res_dir['rc'] == 1
		and len(res_dir['stderr'].strip()) > 0
		and len(f_dir.call_lines()) == 0,
		f'rc={res_dir["rc"]} stderr={res_dir["stderr"]!r} calls={f_dir.call_lines()}')


def main():
	with tempfile.TemporaryDirectory(prefix='.instance-owner-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		for sub in ('data', 'base', 'custom'):
			(base / sub).mkdir()
		for filename in ('gfwlist', 'chnlist', 'apple'):
			(base / 'base' / f'{filename}.txt').write_text('example.com\n')
		(base / 'base' / 'chnroute4.txt').write_text('1.0.0.0/8\n')
		(base / 'base' / 'gfw_static4.txt').write_text('91.108.4.0/22\n')
		binaries = base / 'bin'
		build_stubs(binaries)

		scenarios = [
			scenario_duplicate_while_running,
			scenario_duplicate_during_startup,
			scenario_duplicate_while_error_waiting,
			scenario_interleaved_first_starts,
			scenario_normal_exit_takeover,
			scenario_sigkill_takeover,
			scenario_lock_setup_failures,
		]
		for fn in scenarios:
			try:
				fn(base, binaries)
			except Exception as exc:
				msg = f'FAIL  T16.59 {fn.__name__}: {exc}'
				print(msg, flush=True)
				FAILURES.append(msg)
	return 1 if FAILURES else 0


if __name__ == '__main__':
	sys.exit(main())
