#!/usr/bin/env python3
"""T9.25: real cleanup CLI with cross-process flock contention (docs/04 and docs/10)."""

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
COMMAND = [str(ROOT / 'tests/host/ucode'), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--']


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS  T9.25 cleanup: ' + name, flush=True)


# The child signals readiness only after flock succeeds; the CLI cannot race lock acquisition.
HOLDER = '''
import fcntl, sys, time
with open(sys.argv[1], 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    print('locked', flush=True)
    if sys.argv[2] == 'forever':
        sys.stdin.readline()
    else:
        time.sleep(float(sys.argv[2]))
'''


@contextmanager
def hold_lock(path, duration='forever'):
	with subprocess.Popen([sys.executable, '-c', HOLDER, str(path), str(duration)],
			stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as child:
		try:
			assert child.stdout.readline() == 'locked\n'
			yield child
		finally:
			if child.poll() is None:
				child.terminate()
			child.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix='.cleanup-wait-', dir=ROOT / 'tests/cli') as temp:
	base = Path(temp)
	root = base / 'sysroot'
	run = root / 'var/run/aether-proxy'
	config = root / 'etc/config'
	for name in ('var/lock', 'var/etc', 'tmp/dnsmasq.d', 'etc/init.d', 'etc/config',
			'var/run/aether-proxy'):
		(root / name).mkdir(parents=True, exist_ok=True)
	shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', config / 'aetherproxy')
	(root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
	dnsmasq = root / 'etc/init.d/dnsmasq'
	dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
	dnsmasq.chmod(0o755)
	calls = base / 'calls.log'
	lock = root / 'var/lock/aether-proxy.lock'
	events = run / 'events.jsonl'
	state = run / 'state.json'
	fragment = root / 'tmp/dnsmasq.d/aether-proxy.conf'
	binaries = ROOT / 'tests/stubs/daemon-bin'
	env = dict(os.environ, SYSROOT=str(root), STUB_LOG=str(calls))
	options = ['--sys-root', str(root), '--bin-dir', str(binaries), '--confdir', str(config)]

	def seed():
		calls.write_text('')
		events.write_text('')
		state.write_text('{"state":"running"}\n')
		(root / 'nft-table').touch()
		(root / 'ip-rules').write_text('900: from all fwmark 0x80000/0x80000 lookup 233\n')
		(root / 'ip-routes').write_text('local default dev lo table 233\n')
		fragment.write_text('server=127.0.0.1#31053\n')

	def untouched():
		return (calls.read_text() == '' and json.loads(state.read_text())['state'] == 'running'
			and (root / 'nft-table').exists() and fragment.exists()
			and (root / 'ip-rules').stat().st_size > 0 and (root / 'ip-routes').stat().st_size > 0)

	def busy_events():
		return [json.loads(line) for line in events.read_text().splitlines()
			if json.loads(line)['code'] == 'BUSY']

	def cleaned():
		return (json.loads(state.read_text())['state'] == 'stopped'
			and not (root / 'nft-table').exists() and not fragment.exists()
			and (root / 'ip-rules').read_text() == '' and (root / 'ip-routes').read_text() == ''
			and 'dnsmasq restart' in calls.read_text())

	def invoke(*args, command='cleanup'):
		started = time.monotonic()
		result = subprocess.run(COMMAND + [command, *options, *args], env=env,
			capture_output=True, text=True, timeout=12)
		return result, time.monotonic() - started

	seed()
	with hold_lock(lock, 2) as holder:
		started = time.monotonic()
		with subprocess.Popen(COMMAND + ['cleanup', *options, '--wait', '5'], env=env,
				stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pending:
			time.sleep(1.3)
			check('waiting retries emit no BUSY and leave runtime untouched',
				pending.poll() is None and busy_events() == [] and untouched())
			stdout, stderr = pending.communicate(timeout=12)
			elapsed = time.monotonic() - started
			holder.wait(timeout=5)
			check('--wait 5 succeeds about 2s after start when holder releases, without BUSY',
				pending.returncode == 0 and stdout == 'cleanup: ok\n' and stderr == ''
				and 1.8 <= elapsed < 4.5 and busy_events() == [] and cleaned())
			print(f'INFO  T9.25 cleanup: release-after-2s elapsed {elapsed:.2f}s', flush=True)

	seed()
	with hold_lock(lock, 0.2):
		result, elapsed = invoke('--wait', '5')
		check('released lock is retried at the next one-second tick',
			result.returncode == 0 and 0.9 <= elapsed < 1.9 and busy_events() == [] and cleaned())

	seed()
	with hold_lock(lock):
		started = time.monotonic()
		with subprocess.Popen(COMMAND + ['cleanup', *options, '--wait', '2'], env=env,
				stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pending:
			time.sleep(1.3)
			check('timeout retries stay silent before final failure',
				pending.poll() is None and events.read_text() == '' and untouched())
			stdout, stderr = pending.communicate(timeout=12)
			elapsed = time.monotonic() - started
			recorded = busy_events()
			check('--wait 2 times out about 2s with one original BUSY event and exit 3',
				pending.returncode == 3 and stdout == '' and stderr.startswith('cleanup failed: BUSY: ')
				and 1.8 <= elapsed < 4.5 and len(recorded) == 1
				and recorded[0]['level'] == 'warn' and recorded[0]['args'] == {'holder': 'daemon'}
				and untouched())
			print(f'INFO  T9.25 cleanup: timeout elapsed {elapsed:.2f}s', flush=True)

		for args, label in [((), 'no --wait'), (('--wait', '0'), '--wait 0')]:
			seed()
			result, elapsed = invoke(*args)
			check(label + ' returns BUSY immediately with one event and no cleanup',
				result.returncode == 3 and result.stdout == '' and result.stderr == stderr
				and elapsed < 0.9 and len(busy_events()) == 1 and untouched())

		for args in [('--wait', value) for value in ('-1', '121', 'abc', '1.5', '1e1', '')] + [('--wait',)]:
			seed()
			result, elapsed = invoke(*args)
			check(repr(args) + ' is USAGE without waiting, events or cleanup',
				result.returncode == 2 and result.stdout == '' and 'Usage: aether-proxy cleanup' in result.stderr
				and elapsed < 0.9 and events.read_text() == '' and untouched())

	for args, label in [((), 'no --wait'), (('--wait', '0'), '--wait 0'),
			(('--wait', '5'), '--wait 5'), (('--wait', '120'), '--wait 120')]:
		seed()
		result, elapsed = invoke(*args)
		check(label + ' cleans immediately when unlocked',
			result.returncode == 0 and result.stdout == 'cleanup: ok\n' and result.stderr == ''
			and elapsed < 1.5 and busy_events() == [] and cleaned())

	# T9.27: simulate the real /proc identity without holding the global lock.
	@contextmanager
	def daemon_process(*identity):
		code = "import sys; print('ready', flush=True); sys.stdin.readline()"
		with subprocess.Popen([sys.executable, '-c', code, *identity], stdin=subprocess.PIPE,
				stdout=subprocess.PIPE, text=True) as child:
			try:
				assert child.stdout.readline() == 'ready\n'
				(run / 'daemon.pid').write_text(str(child.pid) + '\n')
				yield child
			finally:
				if child.poll() is None:
					child.terminate()
				child.wait(timeout=5)

	for identity in [('aether-proxy', 'daemon'), ('/usr/bin/aether-proxy', '--', 'daemon')]:
		seed()
		with daemon_process(*identity) as daemon:
			with subprocess.Popen(COMMAND + ['cleanup', *options, '--wait', '5'], env=env,
					stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pending:
				time.sleep(1.3)
				check('T9.27 unlocked live daemon blocks cleanup: ' + repr(identity),
					pending.poll() is None and untouched() and busy_events() == [])
				# Waiting must release a lock it could acquire, or daemon exit could deadlock.
				with hold_lock(lock, 0.1):
					check('T9.27 daemon wait leaves the global lock available', untouched())
				daemon.terminate()
				daemon.wait(timeout=5)
				stdout, stderr = pending.communicate(timeout=10)
				check('T9.27 cleanup runs after daemon exit and preserves exported sets',
					pending.returncode == 0 and stdout == 'cleanup: ok\n' and stderr == ''
					and busy_events() == [] and cleaned() and (run / 'sets.save').exists())

	seed()
	with daemon_process('/usr/bin/aether-proxy', 'daemon'):
		result, elapsed = invoke('--wait', '2')
		check('T9.27 live daemon timeout is BUSY without cleanup',
			result.returncode == 3 and 1.8 <= elapsed < 4.5
			and len(busy_events()) == 1 and untouched())
		seed()
		result, elapsed = invoke('--wait', '0')
		check('T9.27 explicit wait zero checks daemon once and returns BUSY immediately',
			result.returncode == 3 and elapsed < 0.9 and len(busy_events()) == 1 and untouched())
		seed()
		result, elapsed = invoke()
		check('T9.27 no wait retains immediate lock-only cleanup with a live daemon',
			result.returncode == 0 and elapsed < 1.5 and cleaned())

	for identity in [('unrelated',), ('not-aether-proxy', 'daemon'), ('aether-proxy', 'status')]:
		seed()
		with daemon_process(*identity) as unrelated:
			result, elapsed = invoke('--wait', '5')
			check('T9.27 reused pid with different cmdline cleans immediately: ' + repr(identity),
				result.returncode == 0 and elapsed < 1.5 and cleaned() and unrelated.poll() is None)

	seed()
	result, elapsed = invoke('--wait', '5')
	check('T9.27 stale pid whose process has gone does not block cleanup',
		result.returncode == 0 and elapsed < 1.5 and cleaned())
	(run / 'daemon.pid').write_text('not-a-pid\n')
	seed()
	result, elapsed = invoke('--wait', '1')
	check('T9.27 corrupt pid conservatively returns BUSY without cleanup',
		result.returncode == 3 and 0.9 <= elapsed < 2.5 and untouched())
	(run / 'daemon.pid').unlink()

	# sys.lock currently maps open failures to BUSY too; pin the conservative fallback.
	seed()
	lock.unlink()
	lock.mkdir()
	result, elapsed = invoke('--wait', '1')
	check('lock I/O failure keeps bounded retries and original BUSY semantics',
		result.returncode == 3 and result.stderr.startswith('cleanup failed: BUSY: open lock ')
		and 0.9 <= elapsed < 2.5 and len(busy_events()) == 1 and untouched())
	lock.rmdir()

	seed()
	result, elapsed = invoke('--wait', '0', command='daemon')
	check('daemon rejects cleanup-only --wait before changing runtime',
		result.returncode == 2 and 'unknown option --wait' in result.stderr
		and events.read_text() == '' and untouched())
