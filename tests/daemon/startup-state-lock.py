#!/usr/bin/env python3
"""T16.67 regression: explicit operation-lock release on initial_state write failure."""

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
UCODE_BIN = ROOT / 'tests/host/prefix/bin/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'

FAILURES = []


def check(name, condition, detail=''):
	if not condition:
		msg = f'FAIL  T16.67 {name}'
		if detail:
			msg += f': {detail}'
		print(msg, flush=True)
		FAILURES.append(msg)
		return False
	print(f'PASS  T16.67 {name}', flush=True)
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


def try_flock_exclusive(path):
	"""Attempt a non-blocking exclusive flock as an independent holder, then unlock/close."""
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


def build_instrumented_modules(base):
	"""Copy production lib/ and wrap only sys.lock() to trace explicit unlock/close calls."""
	modules = base / 'modules/aetherproxy'
	shutil.copytree(ROOT / 'aether-proxy/src/lib', modules)
	sys_uc = modules / 'sys.uc'
	source = sys_uc.read_text()
	needle = '\tlast_error = null;\n\treturn fp;\n}\n'
	assert source.count(needle) == 1, 'sys.uc lock() return anchor changed'
	replacement = '''\tlast_error = null;
\tlet trace_path = getenv('AETHER_PROXY_TEST_LOCK_TRACE');
\tif (trace_path == null || trace_path == '')
\t\treturn fp;
\tfunction trace_op(op, extra) {
\t\tlet tf = fs.open(trace_path, 'a');
\t\tif (tf != null) {
\t\t\ttf.write(sprintf('%J\\n', { op, path, ...(extra ?? {}) }));
\t\t\ttf.close();
\t\t}
\t};
\ttrace_op('acquire');
\treturn {
\t\tlock: (mode) => {
\t\t\tlet ok = fp.lock(mode);
\t\t\ttrace_op('lock', { mode, ok: !!ok });
\t\t\treturn ok;
\t\t},
\t\tclose: () => {
\t\t\tlet ok = fp.close();
\t\t\ttrace_op('close', { ok: !!ok });
\t\t\treturn ok;
\t\t}
\t};
}
'''
	sys_uc.write_text(source.replace(needle, replacement, 1))
	return base / 'modules'


class Fixture:
	def __init__(self, base, name, fail_initial_state=False, instrumented_modules=None):
		self.root = base / name
		self.run = self.root / 'var/run/aether-proxy'
		self.bin = self.root / 'bin'
		self.lock_file = self.root / 'var/lock/aether-proxy.lock'
		self.instance_lock_file = self.run / 'daemon.lock'
		self.lock_trace = self.root / 'lock-trace.jsonl'
		self.snapshot_file = self.root / 'dnsmasq-install-snapshot.json'
		self.instrumented_modules = instrumented_modules

		shutil.copytree(ROOT / 'tests/stubs/daemon-bin', self.bin)
		for directory in (
			'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
			'sys/class/net/br-lan', 'var/lock', 'etc/aether-proxy/state',
			'var/run/aether-proxy', 'etc/config', 'base', 'data', 'custom',
		):
			(self.root / directory).mkdir(parents=True, exist_ok=True)
		shutil.copyfile(
			ROOT / 'tests/fixtures/sample/aetherproxy',
			self.root / 'etc/config/aetherproxy',
		)
		(self.root / 'var/etc/dnsmasq.conf.test').write_text(
			'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n'
		)
		if fail_initial_state:
			(self.root / 'fail-initial-state').write_text('1\n')

		# Hook /etc/init.d/dnsmasq:
		# - On dnsmasq_install (when fail-initial-state exists), snapshot live children
		#   and verify C.LOCK_FILE is still held, then turn state.json into a directory
		#   so only the subsequent initial_state write fails (EISDIR, works as root too).
		# - On rollback dnsmasq_remove, remove the directory obstacle so shutdown/error
		#   state persistence proceeds normally.
		dnsmasq = self.root / 'etc/init.d/dnsmasq'
		dnsmasq.write_text('''#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['SYSROOT'])
stub_log = Path(os.environ['STUB_LOG'])
with stub_log.open('a') as f:
	f.write('dnsmasq ' + ' '.join(sys.argv[1:]) + '\\n')

run_dir = root / 'var/run/aether-proxy'
state_path = run_dir / 'state.json'
trigger = root / 'fail-initial-state'
obstacle = root / 'state-obstacle-active'

def read_pid(path):
	if not path.exists():
		return None
	text = path.read_text().strip()
	return int(text) if text.isdigit() else None

def alive(pid):
	if pid is None:
		return False
	try:
		os.kill(pid, 0)
		return True
	except OSError:
		return False

def flock_free(path):
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

if trigger.exists():
	trigger.unlink()
	xray_pid = read_pid(root / 'xray.pid')
	dns_pid = read_pid(root / 'chinadns.pid')
	snap = {
		'xray_pid': xray_pid,
		'xray_alive': alive(xray_pid),
		'dns_pid': dns_pid,
		'dns_alive': alive(dns_pid),
		'op_lock_free_before_state': flock_free(root / 'var/lock/aether-proxy.lock'),
		'instance_lock_free_before_state': flock_free(run_dir / 'daemon.lock'),
	}
	(root / 'dnsmasq-install-snapshot.json').write_text(json.dumps(snap) + '\\n')
	if state_path.exists() and not state_path.is_dir():
		state_path.unlink()
	state_path.mkdir(exist_ok=True)
	obstacle.write_text('1\\n')
elif obstacle.exists():
	obstacle.unlink()
	if state_path.is_dir():
		state_path.rmdir()
''')
		dnsmasq.chmod(0o755)

		subprocess.run(
			['python3', str(ROOT / 'tests/xray-ready/proc_fixture.py'), str(self.root)],
			check=True,
		)
		(self.root / 'proc/net/tcp').write_text(
			'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00000000:00000000 00000000 0 0 0\n'
		)
		for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
			(self.root / file).touch()
		for file in ('gfwlist', 'chnlist', 'apple'):
			(self.root / 'base' / (file + '.txt')).write_text('example.com\n')
		(self.root / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
		(self.root / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

		self.calls = self.root / 'calls.log'
		self.env = dict(
			os.environ,
			SYSROOT=str(self.root),
			STUB_LOG=str(self.calls),
			STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
			PATH=str(self.bin) + ':' + os.environ['PATH'],
			AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
			AETHER_PROXY_TEST_RAW_LOG_COLLECTOR=str(ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'),
		)
		if self.instrumented_modules is not None:
			lib_path = str(ROOT / 'tests/host/prefix/lib')
			existing = os.environ.get('LD_LIBRARY_PATH', '')
			self.env['LD_LIBRARY_PATH'] = f'{lib_path}:{existing}' if existing else lib_path
			self.env['AETHER_PROXY_TEST_LOCK_TRACE'] = str(self.lock_trace)

		self.args = [
			'--sys-root', str(self.root),
			'--bin-dir', str(self.bin),
			'--confdir', str(self.root / 'etc/config'),
			'--data-dir', str(self.root / 'data'),
			'--baseline-dir', str(self.root / 'base'),
			'--custom-dir', str(self.root / 'custom'),
		]

	def daemon_command(self):
		if self.instrumented_modules is not None:
			return [
				str(UCODE_BIN),
				'-L', str(self.instrumented_modules / '*.uc'),
				'-S', str(ENTRY), '--', 'daemon', *self.args,
			]
		return [str(UCODE), '-S', str(ENTRY), '--', 'daemon', *self.args]

	def events(self):
		return read_jsonl(self.run / 'events.jsonl')

	def state(self):
		path = self.run / 'state.json'
		if not path.exists() or path.is_dir():
			return {}
		try:
			return json.loads(path.read_text())
		except json.JSONDecodeError:
			return {}

	def trace_for(self, path):
		target = str(path)
		return [entry for entry in read_jsonl(self.lock_trace) if entry.get('path') == target]

	def debug_summary(self):
		stderr = (self.root / 'stderr').read_text() if (self.root / 'stderr').exists() else ''
		return f'events={self.events()} state={self.state()} stderr={stderr!r}'

	@contextmanager
	def daemon(self):
		with (self.root / 'stdout').open('w') as stdout, (self.root / 'stderr').open('w') as stderr:
			with subprocess.Popen(
				self.daemon_command(), env=self.env, stdout=stdout, stderr=stderr,
			) as child:
				try:
					yield child
				finally:
					if child.poll() is None:
						child.terminate()
						try:
							child.wait(timeout=15)
						except subprocess.TimeoutExpired:
							child.kill()
							child.wait(timeout=5)

	def spawn_second_daemon(self):
		return subprocess.run(
			[str(UCODE), '-S', str(ENTRY), '--', 'daemon', *self.args],
			env=self.env, text=True, capture_output=True, timeout=15,
		)


def run_initial_state_failure_case(base, label, instrumented_modules=None):
	f = Fixture(
		base, label, fail_initial_state=True, instrumented_modules=instrumented_modules,
	)
	with f.daemon() as child:
		# Deterministic barrier: daemon has returned from start_sequence(), run
		# rollback shutdown, persisted error state, and entered wait_retry(30).
		wait_for(
			lambda: any(e.get('code') == 'START_RETRY' for e in f.events()),
			child=child, timeout=20.0, label=f'{label}: START_RETRY',
			detail_fn=f.debug_summary,
		)

		check(f'{label}: daemon still alive in retry wait', child.poll() is None)

		snap = json.loads(f.snapshot_file.read_text())
		check(
			f'{label}: startup reached dnsmasq_install with live children and held locks',
			snap['xray_alive'] and snap['dns_alive']
			and not snap['op_lock_free_before_state']
			and not snap['instance_lock_free_before_state'],
			str(snap),
		)

		events = f.events()
		state_failures = [
			e for e in events
			if e.get('code') == 'START_FAILED' and e.get('args', {}).get('step') == 'state'
		]
		check(f'{label}: START_FAILED recorded with step=state', len(state_failures) >= 1, str(events))
		check(
			f'{label}: SERVICE_STARTED not emitted',
			not any(e.get('code') == 'SERVICE_STARTED' for e in events),
			str(events),
		)

		st = f.state()
		check(
			f'{label}: error state records failed_step=state',
			st.get('state') == 'error' and st.get('failed_step') == 'state',
			str(st),
		)

		check(
			f'{label}: started children cleaned up by rollback',
			not pid_alive(snap['xray_pid']) and not pid_alive(snap['dns_pid'])
			and not (f.run / 'xray.pid').exists()
			and not (f.run / 'chinadns-ng.pid').exists(),
			f"xray={snap['xray_pid']}({pid_alive(snap['xray_pid'])}) "
			f"dns={snap['dns_pid']}({pid_alive(snap['dns_pid'])})",
		)

		check(
			f'{label}: independent holder acquires C.LOCK_FILE while daemon is alive',
			try_flock_exclusive(f.lock_file),
		)

		check(
			f'{label}: daemon.lock remains held while daemon is alive',
			not try_flock_exclusive(f.instance_lock_file),
		)
		second = f.spawn_second_daemon()
		check(
			f'{label}: second daemon rejected with exit 3 by daemon.lock',
			second.returncode == 3,
			f'rc={second.returncode} stderr={second.stderr!r}',
		)

		if instrumented_modules is not None:
			op_trace = f.trace_for(f.lock_file)
			inst_trace = f.trace_for(f.instance_lock_file)
			op_ops = [(e.get('op'), e.get('mode')) for e in op_trace]
			inst_ops = [(e.get('op'), e.get('mode')) for e in inst_trace]
			check(
				f'{label}: C.LOCK_FILE explicitly unlocked and closed before return',
				op_ops == [('acquire', None), ('lock', 'u'), ('close', None)],
				f'trace={op_trace}',
			)
			check(
				f'{label}: daemon.lock not unlocked or closed while daemon is alive',
				inst_ops == [('acquire', None)],
				f'trace={inst_trace}',
			)

		child.terminate()
		rc = child.wait(timeout=15)
		check(f'{label}: daemon exits 0 on SIGTERM', rc == 0, f'rc={rc}')

	check(
		f'{label}: daemon.lock released after daemon exits',
		try_flock_exclusive(f.instance_lock_file),
	)
	if instrumented_modules is not None:
		inst_ops_after = [(e.get('op'), e.get('mode')) for e in f.trace_for(f.instance_lock_file)]
		check(
			f'{label}: daemon.lock explicitly unlocked and closed on exit',
			inst_ops_after == [('acquire', None), ('lock', 'u'), ('close', None)],
			f'trace={inst_ops_after}',
		)


def run_normal_startup_control(base, label, instrumented_modules=None):
	f = Fixture(
		base, label, fail_initial_state=False, instrumented_modules=instrumented_modules,
	)
	with f.daemon() as child:
		wait_for(
			lambda: any(e.get('code') == 'SERVICE_STARTED' for e in f.events())
			and f.state().get('state') == 'running',
			child=child, timeout=20.0, label=f'{label}: SERVICE_STARTED + running',
			detail_fn=f.debug_summary,
		)
		# The daemon closes C.LOCK_FILE just after publishing `running`; on a slow
		# runner the sample can land inside that window, so wait for the release
		# instead of asserting on the first attempt (the lock must end up free).
		wait_for(
			lambda: try_flock_exclusive(f.lock_file),
			child=child, timeout=5.0,
			label=f'{label}: C.LOCK_FILE released for external holders',
			detail_fn=f.debug_summary,
		)
		check(
			f'{label}: daemon.lock remains held while running',
			not try_flock_exclusive(f.instance_lock_file),
		)
		second = f.spawn_second_daemon()
		check(
			f'{label}: second daemon rejected with exit 3 while running',
			second.returncode == 3,
			f'rc={second.returncode} stderr={second.stderr!r}',
		)
		if instrumented_modules is not None:
			op_ops = [(e.get('op'), e.get('mode')) for e in f.trace_for(f.lock_file)]
			inst_ops = [(e.get('op'), e.get('mode')) for e in f.trace_for(f.instance_lock_file)]
			check(
				f'{label}: C.LOCK_FILE explicitly unlocked and closed on normal startup',
				len(op_ops) >= 3
				and op_ops[:3] == [('acquire', None), ('lock', 'u'), ('close', None)]
				and len(op_ops) % 3 == 0
				and all(
					op_ops[i:i + 3] == [('acquire', None), ('lock', 'u'), ('close', None)]
					for i in range(0, len(op_ops), 3)
				),
				f'trace={op_ops}',
			)
			check(
				f'{label}: daemon.lock held during normal run',
				inst_ops == [('acquire', None)],
				f'trace={inst_ops}',
			)

		child.terminate()
		rc = child.wait(timeout=15)
		check(f'{label}: daemon exits 0 on SIGTERM', rc == 0, f'rc={rc}')

	check(
		f'{label}: daemon.lock released after normal stop',
		try_flock_exclusive(f.instance_lock_file),
	)


def main():
	with tempfile.TemporaryDirectory(prefix='.startup-state-lock-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		modules = build_instrumented_modules(base)
		# 1. Production entry point (uninstrumented): real lifecycle, real flock, real cleanup.
		run_initial_state_failure_case(base, 'real-initial-state-fail', instrumented_modules=None)
		# 2. Instrumented sys.lock wrapper over unmodified daemon.uc: proves explicit unlock+close.
		run_initial_state_failure_case(base, 'traced-initial-state-fail', instrumented_modules=modules)
		# 3. Normal startup & instance-lock controls (both real and traced).
		run_normal_startup_control(base, 'real-normal-control', instrumented_modules=None)
		run_normal_startup_control(base, 'traced-normal-control', instrumented_modules=modules)

	if FAILURES:
		print(f'T16.67 startup-state-lock: {len(FAILURES)} failed', file=sys.stderr)
		return 1
	return 0


if __name__ == '__main__':
	sys.exit(main())
