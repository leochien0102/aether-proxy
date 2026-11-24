#!/usr/bin/env python3
"""T16.68 regression: external SIGHUP reload and standalone cleanup share C.LOCK_FILE."""

from contextlib import contextmanager
import fcntl
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
PROC_FIXTURE = ROOT / 'tests/xray-ready/proc_fixture.py'
LOGFILTER = ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'

FAILURES = []


def check(name, condition, detail=''):
	if not condition:
		msg = f'FAIL  T16.68 {name}'
		if detail:
			msg += f': {detail}'
		print(msg, flush=True)
		FAILURES.append(msg)
		return False
	print(f'PASS  T16.68 {name}', flush=True)
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


def read_pid(path):
	if not path.exists():
		return None
	text = path.read_text().strip()
	return int(text) if text.isdigit() else None


def kill_pid_bounded(pid):
	if not pid_alive(pid):
		return
	try:
		os.kill(pid, signal.SIGTERM)
	except ProcessLookupError:
		return
	deadline = time.monotonic() + 2.0
	while time.monotonic() < deadline:
		if not pid_alive(pid):
			return
		time.sleep(0.01)
	try:
		os.kill(pid, signal.SIGKILL)
	except ProcessLookupError:
		pass


def try_flock_exclusive(path):
	"""Return True if an independent holder can immediately acquire flock(LOCK_EX|LOCK_NB)."""
	fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
	try:
		try:
			fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
		except BlockingIOError:
			return False
		fcntl.flock(fd, fcntl.LOCK_UN)
		return True
	finally:
		os.close(fd)


@contextmanager
def hold_flock_exclusive(path):
	"""Hold a real kernel exclusive flock on path from this independent process."""
	fd = os.open(str(path), os.O_CREAT | os.O_RDWR, 0o600)
	try:
		fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
		yield fd
	finally:
		try:
			fcntl.flock(fd, fcntl.LOCK_UN)
		finally:
			os.close(fd)


def wait_for(predicate, child=None, timeout=15.0, label='condition', detail_fn=None):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		value = predicate()
		if value:
			return value
		if child is not None and child.poll() is not None:
			extra = f' ({detail_fn()})' if detail_fn is not None else ''
			raise AssertionError(
				f'daemon exited early ({child.returncode}) while waiting for {label}{extra}'
			)
		time.sleep(0.01)
	extra = f' ({detail_fn()})' if detail_fn is not None else ''
	raise AssertionError(f'timed out ({timeout}s) waiting for {label}{extra}')


def read_jsonl(path):
	if not path.exists():
		return []
	items = []
	for line in path.read_text().splitlines():
		line = line.strip()
		if not line:
			continue
		try:
			items.append(json.loads(line))
		except json.JSONDecodeError:
			pass
	return items


def build_stubs(bin_dir):
	"""Copy tests/stubs/daemon-bin and add opt-in deterministic barriers for nft and xray."""
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', bin_dir)

	nft = bin_dir / 'nft'
	nft_src = nft.read_text()
	load_anchor = '\t*" -f "*)\n'
	assert nft_src.count(load_anchor) == 1, 'nft stub -f anchor changed'
	load_hook = load_anchor + '''\t\tif [ -f "$SYSROOT/barrier-nft-load" ]; then
\t\t\tcount=0
\t\t\t[ -f "$SYSROOT/nft-load-hits" ] && read -r count < "$SYSROOT/nft-load-hits"
\t\t\tcount=$((count + 1))
\t\t\tprintf '%s\\n' "$count" > "$SYSROOT/nft-load-hits"
\t\t\tread -r target < "$SYSROOT/barrier-nft-load"
\t\t\tif [ "$count" -eq "$target" ]; then
\t\t\t\tprintf '%s\\n' "$count" > "$SYSROOT/in-nft-load.tmp"
\t\t\t\tmv "$SYSROOT/in-nft-load.tmp" "$SYSROOT/in-nft-load"
\t\t\t\ti=0
\t\t\t\twhile [ ! -e "$SYSROOT/release-nft-load" ] && [ "$i" -lt 800 ]; do
\t\t\t\t\ti=$((i + 1))
\t\t\t\t\tsleep 0.01
\t\t\t\tdone
\t\t\tfi
\t\tfi
'''
	nft_src = nft_src.replace(load_anchor, load_hook, 1)

	del_anchor = '\t*" delete table inet aetherproxy "*) rm -f "$SYSROOT/nft-table"; exit 0 ;;\n'
	assert nft_src.count(del_anchor) == 1, 'nft stub delete anchor changed'
	del_hook = '''\t*" delete table inet aetherproxy "*)
\t\tif [ -f "$SYSROOT/barrier-nft-delete" ]; then
\t\t\tprintf '1\\n' > "$SYSROOT/in-nft-delete.tmp"
\t\t\tmv "$SYSROOT/in-nft-delete.tmp" "$SYSROOT/in-nft-delete"
\t\t\ti=0
\t\t\twhile [ ! -e "$SYSROOT/release-nft-delete" ] && [ "$i" -lt 800 ]; do
\t\t\t\ti=$((i + 1))
\t\t\t\tsleep 0.01
\t\t\tdone
\t\tfi
\t\trm -f "$SYSROOT/nft-table"
\t\texit 0 ;;
'''
	nft_src = nft_src.replace(del_anchor, del_hook, 1)
	nft.write_text(nft_src)
	nft.chmod(0o755)

	xray = bin_dir / 'xray'
	xray_src = xray.read_text()
	xray_anchor = 'if [ "$1" = run ] && [ "$2" = -c ]; then\n\tSYSROOT=${3%/var/run/aether-proxy/current/*}\n\tSTUB_LOG="$SYSROOT/calls.log"\n\tprintf \'xray %s\\n\' "$*" >> "$STUB_LOG"\n'
	assert xray_src.count(xray_anchor) == 1, 'xray stub run -c anchor changed'
	xray_hook = xray_anchor + '''\tif [ -f "$SYSROOT/fail-xray-start-once" ]; then
\t\trm -f "$SYSROOT/fail-xray-start-once"
\t\techo 'stub armed xray start failure' >&2
\t\texit 1
\tfi
'''
	xray_src = xray_src.replace(xray_anchor, xray_hook, 1)
	xray.write_text(xray_src)
	xray.chmod(0o755)


class Fixture:
	def __init__(self, base, name, bin_dir, mode='gfw', extra_uci=''):
		self.root = base / name
		self.run = self.root / 'var/run/aether-proxy'
		self.bin = bin_dir
		self.lock_file = self.root / 'var/lock/aether-proxy.lock'
		self.instance_lock_file = self.run / 'daemon.lock'
		self.calls_log = self.root / 'calls.log'
		self.events_file = self.run / 'events.jsonl'
		self.state_file = self.run / 'state.json'

		for directory in (
			'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
			'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
			'var/run/aether-proxy', 'etc/config', 'base', 'data', 'custom',
		):
			(self.root / directory).mkdir(parents=True, exist_ok=True)

		uci_text = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
		if mode != 'gfw':
			uci_text = uci_text.replace("option mode 'gfw'", f"option mode '{mode}'", 1)
		if extra_uci:
			uci_text += '\n' + extra_uci
		(self.root / 'etc/config/aetherproxy').write_text(uci_text)

		(self.root / 'var/etc/dnsmasq.conf.test').write_text(
			'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n'
		)
		dnsmasq = self.root / 'etc/init.d/dnsmasq'
		dnsmasq.write_text('#!/bin/sh\nprintf \'dnsmasq %s\\n\' "$*" >> "$STUB_LOG"\nexit 0\n')
		dnsmasq.chmod(0o755)

		for fname in ('gfwlist', 'chnlist', 'apple'):
			(self.root / 'base' / f'{fname}.txt').write_text('example.com\n')
		(self.root / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
		(self.root / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')
		(self.root / 'proc/net/tcp').write_text(
			'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n'
		)
		(self.root / 'proc/net/tcp6').write_text(
			'local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n'
		)
		self.calls_log.write_text('')
		subprocess.run(
			[sys.executable, str(PROC_FIXTURE), str(self.root)],
			check=True,
		)

	def env(self, extra=None):
		e = os.environ.copy()
		e.update({
			'SYSROOT': str(self.root),
			'STUB_LOG': str(self.calls_log),
			'AETHER_PROXY_TEST_LOGFILTER': str(LOGFILTER),
			'AETHER_PROXY_TEST_RAW_LOG_COLLECTOR': '/nonexistent/raw-log-collector',
		})
		if extra:
			e.update(extra)
		return e

	def write_uci(self, *, enabled=1, mode='gfw', port='443', extra_uci=''):
		text = (
			"config main 'main'\n"
			f"\toption enabled '{enabled}'\n"
			f"\toption mode '{mode}'\n"
			"\toption node 'n_00000000000000000000000000000001'\n\n"
			"config node 'n_00000000000000000000000000000001'\n"
			"\toption protocol 'trojan'\n"
			"\toption security 'tls'\n"
			"\toption address 'node.example.com'\n"
			f"\toption port '{port}'\n"
			"\toption password 'secret'\n"
		)
		if extra_uci:
			text += '\n' + extra_uci
		(self.root / 'etc/config/aetherproxy').write_text(text)

	def state(self):
		if not self.state_file.exists():
			return {}
		try:
			return json.loads(self.state_file.read_text())
		except json.JSONDecodeError:
			return {}

	def events(self):
		return read_jsonl(self.events_file)

	def calls(self):
		return self.calls_log.read_text().splitlines()

	def debug_summary(self):
		stderr = (self.root / 'daemon.stderr').read_text() if (self.root / 'daemon.stderr').exists() else ''
		return f'state={self.state()!r} events={self.events()[-5:]!r} stderr={stderr[-300:]!r}'

	def run_cleanup(self, wait_secs=None):
		argv = [
			str(UCODE), str(ENTRY), '--', 'cleanup',
			'--sys-root', str(self.root),
			'--confdir', str(self.root / 'etc/config'),
			'--bin-dir', str(self.bin),
		]
		if wait_secs is not None:
			argv.extend(['--wait', str(wait_secs)])
		return subprocess.run(argv, env=self.env(), capture_output=True, text=True, timeout=15)

	@contextmanager
	def daemon(self, extra_env=None):
		out_f = (self.root / 'daemon.stdout').open('w')
		err_f = (self.root / 'daemon.stderr').open('w')
		argv = [
			str(UCODE), str(ENTRY), '--', 'daemon',
			'--sys-root', str(self.root),
			'--confdir', str(self.root / 'etc/config'),
			'--data-dir', str(self.root / 'data'),
			'--baseline-dir', str(self.root / 'base'),
			'--custom-dir', str(self.root / 'custom'),
			'--bin-dir', str(self.bin),
		]
		proc = subprocess.Popen(argv, env=self.env(extra_env), stdout=out_f, stderr=err_f)
		try:
			yield proc
		finally:
			for rel in ('release-nft-load', 'release-nft-delete'):
				(self.root / rel).touch()
			if proc.poll() is None:
				proc.terminate()
				try:
					proc.wait(timeout=10)
				except subprocess.TimeoutExpired:
					proc.kill()
					proc.wait(timeout=5)
			for pidfile in (self.root / 'xray.pid', self.root / 'chinadns.pid'):
				kill_pid_bounded(read_pid(pidfile))
			out_f.close()
			err_f.close()


def test_hup_inflight_rejects_cleanup(base, bin_dir):
	"""Direction A: external HUP reload in-flight holds C.LOCK_FILE and rejects concurrent cleanup."""
	f = Fixture(base, 'dir-a-hup-inflight', bin_dir, mode='gfw')
	with f.daemon() as proc:
		wait_for(lambda: f.state().get('state') == 'running', proc, label='running', detail_fn=f.debug_summary)
		xray_pid = read_pid(f.root / 'xray.pid')
		dns_pid = read_pid(f.root / 'chinadns.pid')
		check('dir-a: lock free after startup', try_flock_exclusive(f.lock_file))

		# Arm deterministic barrier on the 1st nft -f during HUP reload.
		(f.root / 'nft-load-hits').unlink(missing_ok=True)
		(f.root / 'in-nft-load').unlink(missing_ok=True)
		(f.root / 'release-nft-load').unlink(missing_ok=True)
		(f.root / 'barrier-nft-load').write_text('1\n')

		floor = f.state().get('last_reload', {}).get('at', 0)
		f.write_uci(mode='global')
		proc.send_signal(signal.SIGHUP)
		wait_for(lambda: (f.root / 'in-nft-load').exists(), proc, label='HUP in nft_replace barrier', detail_fn=f.debug_summary)

		calls_before = len(f.calls())
		check('dir-a: C.LOCK_FILE held while HUP is in nft_replace', not try_flock_exclusive(f.lock_file))
		res = f.run_cleanup()
		check('dir-a: concurrent cleanup exits 3 (BUSY)', res.returncode == 3, f'rc={res.returncode} stderr={res.stderr!r}')
		new_calls = f.calls()[calls_before:]
		check('dir-a: cleanup made no nft delete or dnsmasq calls',
			not any('delete table' in c or c.startswith('dnsmasq ') or 'rule del' in c for c in new_calls),
			f'new_calls={new_calls!r}')
		check('dir-a: xray and chinadns still alive during race', pid_alive(xray_pid) and pid_alive(dns_pid))
		check('dir-a: nft-table still present during race', (f.root / 'nft-table').exists())
		check('dir-a: state.json not overwritten to stopped', f.state().get('state') == 'running', f'state={f.state().get("state")}')

		# Release barrier and verify HUP completes and releases lock.
		(f.root / 'release-nft-load').touch()
		wait_for(
			lambda: f.state().get('last_reload', {}).get('at', 0) > floor,
			proc, label='HUP completion', detail_fn=f.debug_summary,
		)
		st = f.state()
		check('dir-a: HUP reload applied mode=global', st.get('mode') == 'global' and st.get('last_reload', {}).get('ok') is True, f'state={st!r}')
		wait_for(lambda: try_flock_exclusive(f.lock_file), proc, timeout=3.0, label='dir-a lock release', detail_fn=f.debug_summary)
		check('dir-a: C.LOCK_FILE released after HUP completes', try_flock_exclusive(f.lock_file))

		# Follow-up HUP request must succeed after race finishes.
		(f.root / 'barrier-nft-load').unlink(missing_ok=True)
		floor2 = st['last_reload']['at']
		f.write_uci(mode='gfw')
		proc.send_signal(signal.SIGHUP)
		wait_for(
			lambda: f.state().get('last_reload', {}).get('at', 0) > floor2,
			proc, label='follow-up HUP completion', detail_fn=f.debug_summary,
		)
		st2 = f.state()
		check('dir-a: follow-up HUP succeeds after race', st2.get('mode') == 'gfw' and st2.get('last_reload', {}).get('ok') is True, f'state={st2!r}')


def test_external_lock_blocks_hup_then_retry_succeeds(base, bin_dir):
	"""Direction B: external flock holder blocks HUP with no data-plane side effects; new HUP succeeds after unlock."""
	f = Fixture(base, 'dir-b-external-lock', bin_dir, mode='gfw')
	with f.daemon() as proc:
		wait_for(lambda: f.state().get('state') == 'running', proc, label='running', detail_fn=f.debug_summary)
		xray_pid = read_pid(f.root / 'xray.pid')
		dns_pid = read_pid(f.root / 'chinadns.pid')
		current_nft_before = (f.run / 'current/aether-proxy.nft').read_text()
		floor = f.state().get('last_reload', {}).get('at', 0)
		busy_before = len([e for e in f.events() if e.get('code') == 'BUSY'])
		applied_before = len([e for e in f.events() if e.get('code') == 'RELOAD_APPLIED'])

		with hold_flock_exclusive(f.lock_file):
			calls_before = len(f.calls())
			f.write_uci(mode='global')
			proc.send_signal(signal.SIGHUP)
			wait_for(
				lambda: f.state().get('last_reload', {}).get('at', 0) > floor,
				proc, label='busy HUP last_reload feedback', detail_fn=f.debug_summary,
			)
			st = f.state()
			lr = st.get('last_reload', {})
			new_calls = f.calls()[calls_before:]
			busy_after = [e for e in f.events() if e.get('code') == 'BUSY']
			applied_after = [e for e in f.events() if e.get('code') == 'RELOAD_APPLIED']

			check('dir-b: busy HUP records last_reload.ok=False', lr.get('ok') is False, f'last_reload={lr!r}')
			check('dir-b: busy HUP leaves target_node/target_mode null',
				lr.get('target_node') is None and lr.get('target_mode') is None, f'last_reload={lr!r}')
			check('dir-b: busy HUP emits BUSY warn event',
				len(busy_after) > busy_before and any(e.get('args', {}).get('holder') == 'reload' for e in busy_after[busy_before:]),
				f'busy_events={busy_after[busy_before:]!r}')
			check('dir-b: busy HUP does not emit RELOAD_APPLIED', len(applied_after) == applied_before)
			check('dir-b: busy HUP keeps old mode=gfw', st.get('mode') == 'gfw' and st.get('state') == 'running', f'state={st!r}')
			check('dir-b: busy HUP makes zero data-plane stub calls', len(new_calls) == 0, f'new_calls={new_calls!r}')
			check('dir-b: busy HUP leaves current/aether-proxy.nft untouched',
				(f.run / 'current/aether-proxy.nft').read_text() == current_nft_before)
			check('dir-b: busy HUP keeps same xray and chinadns PIDs alive',
				read_pid(f.root / 'xray.pid') == xray_pid and read_pid(f.root / 'chinadns.pid') == dns_pid
				and pid_alive(xray_pid) and pid_alive(dns_pid))

		# External lock is now released; a new HUP must succeed.
		check('dir-b: C.LOCK_FILE free after external holder releases', try_flock_exclusive(f.lock_file))
		busy_at = f.state()['last_reload']['at']
		proc.send_signal(signal.SIGHUP)
		wait_for(
			lambda: f.state().get('last_reload', {}).get('at', 0) > busy_at,
			proc, label='post-unlock HUP completion', detail_fn=f.debug_summary,
		)
		st2 = f.state()
		check('dir-b: new HUP after unlock applies mode=global',
			st2.get('mode') == 'global' and st2.get('last_reload', {}).get('ok') is True, f'state={st2!r}')
		wait_for(lambda: try_flock_exclusive(f.lock_file), proc, timeout=3.0, label='dir-b lock release', detail_fn=f.debug_summary)
		check('dir-b: C.LOCK_FILE released after recovery HUP', try_flock_exclusive(f.lock_file))


def test_lock_held_during_rollback(base, bin_dir):
	"""HUP action failure keeps C.LOCK_FILE held through rollback_actions and releases after rollback."""
	f = Fixture(base, 'rollback-lock', bin_dir, mode='gfw')
	with f.daemon() as proc:
		wait_for(lambda: f.state().get('state') == 'running', proc, label='running', detail_fn=f.debug_summary)
		floor = f.state().get('last_reload', {}).get('at', 0)

		# Change both mode (nft_replace) and node port (restart_xray).
		# Forward nft -f (hit 1) succeeds; forward restart_xray fails once;
		# rollback restarts old xray and runs rollback nft -f (hit 2), where we pause!
		(f.root / 'nft-load-hits').unlink(missing_ok=True)
		(f.root / 'in-nft-load').unlink(missing_ok=True)
		(f.root / 'release-nft-load').unlink(missing_ok=True)
		(f.root / 'barrier-nft-load').write_text('2\n')
		(f.root / 'fail-xray-start-once').write_text('1\n')

		f.write_uci(mode='global', port='8443')
		proc.send_signal(signal.SIGHUP)
		wait_for(
			lambda: (f.root / 'in-nft-load').exists(),
			proc, label='HUP rollback nft_load barrier', detail_fn=f.debug_summary,
		)

		calls_before = len(f.calls())
		check('rollback: C.LOCK_FILE still held during rollback', not try_flock_exclusive(f.lock_file))
		res = f.run_cleanup()
		check('rollback: concurrent cleanup rejected with exit 3 during rollback',
			res.returncode == 3, f'rc={res.returncode} stderr={res.stderr!r}')
		new_calls = f.calls()[calls_before:]
		check('rollback: cleanup made no destructive stub calls during rollback',
			not any('delete table' in c or c.startswith('dnsmasq ') or 'rule del' in c for c in new_calls),
			f'new_calls={new_calls!r}')

		(f.root / 'release-nft-load').touch()
		wait_for(
			lambda: f.state().get('last_reload', {}).get('at', 0) > floor,
			proc, label='HUP rollback completion', detail_fn=f.debug_summary,
		)
		st = f.state()
		check('rollback: last_reload records failure', st.get('last_reload', {}).get('ok') is False, f'state={st!r}')
		check('rollback: mode reverted to gfw', st.get('mode') == 'gfw', f'state={st!r}')
		wait_for(lambda: try_flock_exclusive(f.lock_file), proc, timeout=3.0, label='rollback lock release', detail_fn=f.debug_summary)
		check('rollback: C.LOCK_FILE released after rollback completes', try_flock_exclusive(f.lock_file))

		# Subsequent HUP must succeed now that rollback finished and lock is released.
		(f.root / 'barrier-nft-load').unlink(missing_ok=True)
		floor2 = st['last_reload']['at']
		proc.send_signal(signal.SIGHUP)
		wait_for(
			lambda: f.state().get('last_reload', {}).get('at', 0) > floor2,
			proc, label='post-rollback HUP completion', detail_fn=f.debug_summary,
		)
		st2 = f.state()
		check('rollback: subsequent HUP succeeds after rollback',
			st2.get('mode') == 'global' and st2.get('last_reload', {}).get('ok') is True, f'state={st2!r}')


def test_hup_disable_holds_lock_through_shutdown(base, bin_dir):
	"""HUP with enabled=0 (changed.stop) holds C.LOCK_FILE through shutdown() teardown."""
	f = Fixture(base, 'hup-disable-stop', bin_dir, mode='gfw')
	with f.daemon() as proc:
		wait_for(lambda: f.state().get('state') == 'running', proc, label='running', detail_fn=f.debug_summary)
		(f.root / 'in-nft-delete').unlink(missing_ok=True)
		(f.root / 'release-nft-delete').unlink(missing_ok=True)
		(f.root / 'barrier-nft-delete').write_text('1\n')

		f.write_uci(enabled=0, mode='gfw')
		proc.send_signal(signal.SIGHUP)
		wait_for(
			lambda: (f.root / 'in-nft-delete').exists(),
			proc, label='HUP disable shutdown nft_delete barrier', detail_fn=f.debug_summary,
		)

		calls_before = len(f.calls())
		check('hup-stop: C.LOCK_FILE held during HUP disable shutdown', not try_flock_exclusive(f.lock_file))
		res = f.run_cleanup()
		check('hup-stop: concurrent cleanup rejected with exit 3 during HUP disable shutdown',
			res.returncode == 3, f'rc={res.returncode} stderr={res.stderr!r}')
		new_calls = f.calls()[calls_before:]
		check('hup-stop: rejected cleanup ran no dnsmasq or route commands',
			not any(c.startswith('dnsmasq ') or 'rule del' in c for c in new_calls),
			f'new_calls={new_calls!r}')

		(f.root / 'release-nft-delete').touch()
		rc = proc.wait(timeout=15)
		check('hup-stop: daemon exits 0 after HUP disable', rc == 0, f'rc={rc}')
		check('hup-stop: state.json is stopped', f.state().get('state') == 'stopped', f'state={f.state()!r}')
		check('hup-stop: SERVICE_STOPPED emitted', any(e.get('code') == 'SERVICE_STOPPED' for e in f.events()))
		check('hup-stop: C.LOCK_FILE released after HUP disable exits', try_flock_exclusive(f.lock_file))
		check('hup-stop: daemon.lock released after HUP disable exits', try_flock_exclusive(f.instance_lock_file))

		after = f.run_cleanup()
		check('hup-stop: standalone cleanup succeeds after daemon stops', after.returncode == 0, f'rc={after.returncode} stderr={after.stderr!r}')


def test_monitor_reload_no_self_deadlock(base, bin_dir):
	"""Positive control: monitor tick holding C.LOCK_FILE calls daemon.reload without self-deadlock."""
	extra_uci = "config probe 'probe'\n\toption fail_threshold '1'\n\toption recover_threshold '1'\n"
	f = Fixture(base, 'monitor-degrade-control', bin_dir, mode='bypass_cn', extra_uci=extra_uci)
	# Fail curl from the 1st probe so the initial monitor tick enters degraded + set_degraded_mode(gfw).
	with f.daemon(extra_env={'STUB_CURL_FAIL_FROM': '1', 'STUB_CURL_COUNT_FILE': str(f.run / 'curl-count')}) as proc:
		wait_for(
			lambda: f.state().get('state') == 'degraded'
			and f.state().get('degraded_mode') == 'gfw'
			and try_flock_exclusive(f.lock_file),
			proc, label='monitor set_degraded_mode(gfw) and unlock', detail_fn=f.debug_summary,
		)
		st = f.state()
		busy_events = [e for e in f.events() if e.get('code') == 'BUSY']
		check('monitor-control: degraded_mode=gfw applied via monitor reload',
			st.get('state') == 'degraded' and st.get('degraded_mode') == 'gfw', f'state={st!r}')
		check('monitor-control: last_reload.ok=True (no self-deadlock)',
			st.get('last_reload', {}).get('ok') is True, f'last_reload={st.get("last_reload")!r}')
		check('monitor-control: zero BUSY events emitted', len(busy_events) == 0, f'busy={busy_events!r}')
		check('monitor-control: C.LOCK_FILE released after monitor tick', try_flock_exclusive(f.lock_file))


def main():
	with tempfile.TemporaryDirectory(prefix='aether-t16.68-') as tmp:
		base = Path(tmp)
		bin_dir = base / 'bin'
		build_stubs(bin_dir)

		for fn in (
			test_hup_inflight_rejects_cleanup,
			test_external_lock_blocks_hup_then_retry_succeeds,
			test_lock_held_during_rollback,
			test_hup_disable_holds_lock_through_shutdown,
			test_monitor_reload_no_self_deadlock,
		):
			try:
				fn(base, bin_dir)
			except Exception as exc:
				msg = f'FAIL  T16.68 {fn.__name__}: {exc}'
				print(msg, flush=True)
				FAILURES.append(msg)

	if FAILURES:
		print(f'T16.68 hup-cleanup-lock: {len(FAILURES)} failed', flush=True)
		sys.exit(1)
	print('T16.68 hup-cleanup-lock: all passed', flush=True)


if __name__ == '__main__':
	main()
