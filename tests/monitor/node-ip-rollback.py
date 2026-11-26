#!/usr/bin/env python3
"""T16.69 (H4): isolated same-node IP refresh rollback and TERM-in-flight tests.

Runs the real daemon/monitor/xray_ready code inside a temporary sysroot with
wrapper stubs that record actual loaded nft bytes and actual Xray startup
config bytes (never touching host network or real devices).
"""

import contextlib
import fcntl
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/xray-ready'))
from proc_fixture import seed_elf  # noqa: E402

passed = 0
failed = 0
failures = []


def check(condition, label):
	global passed, failed
	if condition:
		passed += 1
		print('PASS ', label, flush=True)
	else:
		failed += 1
		failures.append(label)
		print('FAIL ', label, flush=True)


def wait_for(predicate, timeout=10, desc='condition'):
	end = time.monotonic() + timeout
	while time.monotonic() < end:
		if predicate():
			return True
		time.sleep(0.02)
	return False


def lock_is_free(lock_path):
	if not lock_path.exists():
		return True
	with lock_path.open('a+') as f:
		try:
			fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
		except BlockingIOError:
			return False
		fcntl.flock(f.fileno(), fcntl.LOCK_UN)
		return True


class Fixture:
	def __init__(self, base, name, old_ip, new_ip, port):
		self.base = base / name
		self.root = self.base / 'root'
		self.run = self.root / 'var/run/aether-proxy'
		self.current = self.run / 'current'
		self.bin = self.base / 'bin'
		self.old_ip = old_ip
		self.new_ip = new_ip
		self.port = port

		shutil.copytree(ROOT / 'tests/stubs/daemon-bin', self.bin)
		self._install_wrappers()

		for d in ('etc/config', 'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
		          'sys/class/net/br-lan', 'var/lock', 'var/run/aether-proxy',
		          'etc/aether-proxy/state'):
			(self.root / d).mkdir(parents=True, exist_ok=True)
		for d in ('data', 'baseline', 'custom'):
			(self.base / d).mkdir(parents=True, exist_ok=True)
		for f in ('gfwlist', 'chnlist', 'apple'):
			(self.base / 'baseline' / f'{f}.txt').write_text('example.com\n')
		(self.base / 'baseline/chnroute4.txt').write_text('1.0.0.0/8\n')
		(self.base / 'baseline/gfw_static4.txt').write_text('91.108.4.0/22\n')
		(self.root / 'var/etc/dnsmasq.conf.test').write_text(
			'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
		dnsmasq = self.root / 'etc/init.d/dnsmasq'
		dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
		dnsmasq.chmod(0o755)
		seed_elf(self.root)
		(self.root / 'proc/net/tcp').write_text(
			' 0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00000000 00000000 0 0 0\n')
		for f in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log',
		          'nft-loads.log', 'xray-starts.log'):
			(self.root / f).touch()

		sample = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
		sample = sample.replace("option port '443'", f"option port '{port}'", 1)
		sample += "\nconfig dns 'dns'\n\tlist trust_dns 'tcp://8.8.8.8'\n"
		(self.root / 'etc/config/aetherproxy').write_text(sample)
		(self.root / 'resolve-ip').write_text(f'{old_ip}\n')

		# Copy production modules to a disposable directory:
		# 1. monitor.uc gets only the refresh-now trigger (same pattern as tests/xray-ready/lifecycle.py).
		# 2. sys.uc gets an opt-in one-shot write_atomic fault injector for candidate/publish write failures.
		self.modules = self.base / 'modules/aetherproxy'
		shutil.copytree(ROOT / 'aether-proxy/src/lib', self.modules)
		mon_path = self.modules / 'monitor.uc'
		mon_src = mon_path.read_text()
		needle = '\tlet obs = observe(daemon);'
		assert mon_src.count(needle) == 1
		mon_path.write_text(mon_src.replace(needle, '''
	if (fs.stat(system_path(daemon.ctx, '/refresh-now')) != null) {
		if (!fs.unlink(system_path(daemon.ctx, '/refresh-now'))) die('refresh marker unlink failed');
		daemon.machine.last_node_refresh = 0;
		daemon.machine.last_node_refresh_attempt = null;
	}
''' + needle))

		sys_path = self.modules / 'sys.uc'
		sys_src = sys_path.read_text()
		needle = 'function write_atomic(path, content, metadata) {'
		assert sys_src.count(needle) == 1
		sys_path.write_text(sys_src.replace(needle, needle + r'''
	let fault_file = (getenv('SYSROOT') ?? '') + '/fail-write-path';
	let fault_target = fs.readfile(fault_file);
	if (fault_target != null && trim(fault_target) == path) {
		fs.unlink(fault_file);
		last_error = 'injected write_atomic failure for ' + path;
		return false;
	}
'''))

		self.env = dict(
			os.environ,
			SYSROOT=str(self.root),
			STUB_LOG=str(self.root / 'calls.log'),
			STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
			PATH=str(self.bin) + ':' + os.environ['PATH'],
			AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
			AETHER_PROXY_TEST_RAW_LOG_COLLECTOR=str(ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'),
			LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
		)

	def _install_wrappers(self):
		(self.bin / 'nft').rename(self.bin / 'nft-original')
		(self.bin / 'nft').write_text('''#!/bin/sh
case " $* " in
	*" -c -f "*)
		exec "$(dirname "$0")/nft-original" "$@"
		;;
	*" -f "*)
		if [ -f "$SYSROOT/nft-load-fail-once" ]; then
			rm -f "$SYSROOT/nft-load-fail-once"
			printf 'nft %s\\n' "$*" >> "$STUB_LOG"
			echo 'injected one-shot nft load failure' >&2
			exit 1
		fi
		if [ -f "$SYSROOT/nft-load-fail-seq" ]; then
			read -r left < "$SYSROOT/nft-load-fail-seq"
			left=$((left - 1))
			if [ "$left" -le 0 ]; then
				rm -f "$SYSROOT/nft-load-fail-seq"
				printf 'nft %s\\n' "$*" >> "$STUB_LOG"
				echo 'injected sequenced nft load failure' >&2
				exit 1
			fi
			printf '%s\\n' "$left" > "$SYSROOT/nft-load-fail-seq"
		fi
		"$(dirname "$0")/nft-original" "$@"
		rc=$?
		if [ "$rc" -eq 0 ]; then
			for arg do file="$arg"; done
			cp "$file" "$SYSROOT/loaded-nft.conf"
			printf '%s\\n' "$file" >> "$SYSROOT/nft-loads.log"
		fi
		exit "$rc"
		;;
esac
exec "$(dirname "$0")/nft-original" "$@"
''')
		(self.bin / 'nft').chmod(0o755)

		(self.bin / 'xray').rename(self.bin / 'xray-original')
		# Inject an opt-in stop barrier into the disposable xray-original copy so
		# term-during-stop can deterministically deliver SIGTERM while old.stop() waits.
		orig_xray = (self.bin / 'xray-original').read_text()
		stop_needle = '\tcleanup() {\n'
		assert orig_xray.count(stop_needle) == 1
		(self.bin / 'xray-original').write_text(orig_xray.replace(stop_needle, stop_needle + '''\t\tif [ -f "$SYSROOT/xray-slow-stop-hold" ]; then
\t\t\ttouch "$SYSROOT/xray-stopping-entered"
\t\t\twhile [ -f "$SYSROOT/xray-slow-stop-hold" ]; do sleep 0.02; done
\t\tfi
'''))
		(self.bin / 'xray-original').chmod(0o755)
		(self.bin / 'xray').write_text('''#!/bin/sh
if [ "$1" = run ] && [ "$2" = -test ]; then
	if [ -f "$SYSROOT/xray-test-fail-once" ]; then
		rm -f "$SYSROOT/xray-test-fail-once"
		printf 'xray %s\\n' "$*" >> "$STUB_LOG"
		echo 'injected xray -test failure' >&2
		exit 1
	fi
	exec "$(dirname "$0")/xray-original" "$@"
fi
if [ "$1" = run ] && [ "$2" = -c ]; then
	root=${3%/var/run/aether-proxy/current/*}
	printf '%s\\n' "$$" >> "$root/xray-starts.log"
	if [ -f "$root/xray-crash-once" ]; then
		rm -f "$root/xray-crash-once"
		printf 'xray %s\\n' "$*" >> "$root/calls.log"
		echo 'injected xray immediate exit' >&2
		exit 1
	fi
	cp "$3" "$root/xray-active-config.json"
	if [ -f "$root/xray-missing-once" ]; then
		port=$(cat "$root/xray-missing-once")
		rm -f "$root/xray-missing-once"
		printf '%s\\n' "$port" > "$root/xray-dns-missing-port"
		# Remove marker after child publishes so rollback child succeeds unless re-armed.
		(sleep 0.4; rm -f "$root/xray-dns-missing-port") &
	fi
fi
exec "$(dirname "$0")/xray-original" "$@"
''')
		(self.bin / 'xray').chmod(0o755)

	def state(self):
		p = self.run / 'state.json'
		return json.loads(p.read_text()) if p.exists() else {}

	def lkg(self):
		p = self.root / 'etc/aether-proxy/state/node-ip.json'
		return json.loads(p.read_text()) if p.exists() else {}

	def events(self, code=None):
		p = self.run / 'events.jsonl'
		if not p.exists():
			return []
		items = [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
		return items if code is None else [e for e in items if e.get('code') == code]

	def probes_log(self):
		p = self.run / 'node-probe.log'
		if not p.exists():
			return []
		return [json.loads(line) for line in p.read_text().splitlines() if line.strip()]

	def nft_bytes(self):
		return (self.current / 'aether-proxy.nft').read_bytes()

	def xray_bytes(self):
		return (self.current / 'xray.json').read_bytes()

	def loaded_nft_bytes(self):
		return (self.root / 'loaded-nft.conf').read_bytes()

	def active_xray_bytes(self):
		return (self.root / 'xray-active-config.json').read_bytes()

	def xray_starts(self):
		return len([l for l in (self.root / 'xray-starts.log').read_text().splitlines() if l.strip()])

	def nft_loads(self):
		return len([l for l in (self.root / 'nft-loads.log').read_text().splitlines() if l.strip()])

	def xray_pid(self):
		p = self.run / 'xray.pid'
		return p.read_text().strip() if p.exists() else None

	def trigger_refresh(self, child, target_ip):
		(self.root / 'resolve-ip').write_text(f'{target_ip}\n')
		(self.root / 'refresh-now').touch()
		child.send_signal(signal.SIGUSR1)

	def wait_running(self):
		ok = wait_for(
			lambda: self.state().get('state') == 'running'
			and self.state().get('node_ip') == self.old_ip
			and lock_is_free(self.root / 'var/lock/aether-proxy.lock'),
			timeout=10,
		)
		assert ok, f'daemon did not reach running: state={self.state()}'
		# Yield briefly past finish_tick's unlock -> daemon.busy=false assignment.
		time.sleep(0.03)

	@contextlib.contextmanager
	def daemon(self):
		cmd = [
			str(ROOT / 'tests/host/prefix/bin/ucode'),
			'-L', str(self.base / 'modules/*.uc'),
			'-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
			'--', 'daemon',
			'--sys-root', str(self.root),
			'--bin-dir', str(self.bin),
			'--confdir', str(self.root / 'etc/config'),
			'--data-dir', str(self.base / 'data'),
			'--baseline-dir', str(self.base / 'baseline'),
			'--custom-dir', str(self.base / 'custom'),
		]
		with (self.base / 'stdout').open('w') as out, (self.base / 'stderr').open('w') as err:
			proc = subprocess.Popen(cmd, env=self.env, stdout=out, stderr=err, start_new_session=True)
			try:
				yield proc
			finally:
				if proc.poll() is None:
					proc.terminate()
				try:
					proc.wait(timeout=10)
				except subprocess.TimeoutExpired:
					os.killpg(proc.pid, signal.SIGKILL)
					proc.wait()
				stderr = (self.base / 'stderr').read_text()
				check(proc.returncode == 0 and not stderr,
				      f'{self.base.name}: daemon exits cleanly (rc={proc.returncode}, stderr={stderr!r})')


def nft_set_contains(nft_text, set_name, ip):
	"""Check whether a specific nft set block contains the given IPv4 element."""
	marker = f'set {set_name} {{'
	start = nft_text.find(marker)
	if start < 0:
		return False
	end = nft_text.find('\n\t}', start)
	block = nft_text[start:end if end >= 0 else len(nft_text)]
	return ip in block


def assert_restored(f, label, old_nft, old_xray, old_loaded_nft, old_active_xray,
                    expect_nft_loads=None, expect_xray_starts=None, dynamic_gfw4_ip=None):
	check(f.nft_bytes() == old_nft, f'{label}: current/aether-proxy.nft bytes match old')
	check(f.xray_bytes() == old_xray, f'{label}: current/xray.json bytes match old')
	loaded_nft = f.loaded_nft_bytes()
	loaded_text = loaded_nft.decode()
	if dynamic_gfw4_ip is not None:
		check(nft_set_contains(loaded_text, 'node_ip4', f.old_ip)
		      and f.new_ip.encode() not in loaded_nft,
		      f'{label}: runtime loaded nft restores old node_ip4 without new IP')
		check(nft_set_contains(loaded_text, 'gfw4', dynamic_gfw4_ip),
		      f'{label}: runtime loaded nft preserves pre-refresh gfw4 dynamic set ({dynamic_gfw4_ip})')
	else:
		check(loaded_nft == old_loaded_nft and f.old_ip.encode() in loaded_nft
		      and f.new_ip.encode() not in loaded_nft,
		      f'{label}: actual loaded nft matches old IP')
	check(f.active_xray_bytes() == old_active_xray and f.old_ip.encode() in f.active_xray_bytes()
	      and f.new_ip.encode() not in f.active_xray_bytes(),
	      f'{label}: actual running Xray config matches old IP')
	check(f.state().get('node_ip') == f.old_ip, f'{label}: state.json node_ip remains old IP')
	check(f.lkg().get('nodes', {}).get('node.example.com') == f.old_ip, f'{label}: LKG remains old IP')
	check(len(f.events('NODE_IP_CHANGED')) == 0, f'{label}: zero NODE_IP_CHANGED events')
	check(len(f.events('BUSY')) == 0, f'{label}: zero BUSY events (no double lock)')
	check(lock_is_free(f.root / 'var/lock/aether-proxy.lock'), f'{label}: C.LOCK_FILE released')
	if expect_nft_loads is not None:
		check(f.nft_loads() == expect_nft_loads,
		      f'{label}: nft load count == {expect_nft_loads} (got {f.nft_loads()})')
	if expect_xray_starts is not None:
		check(f.xray_starts() == expect_xray_starts,
		      f'{label}: xray start count == {expect_xray_starts} (got {f.xray_starts()})')


def verify_followup_success(f, child, label):
	"""After a recoverable failure, a clean refresh to new_ip must succeed."""
	probes_before = len(f.probes_log())
	f.trigger_refresh(child, f.new_ip)
	ok = wait_for(
		lambda: len(f.events('NODE_IP_CHANGED')) == 1 and f.state().get('node_ip') == f.new_ip,
		timeout=10,
	)
	check(ok, f'{label}: subsequent refresh succeeds and publishes new IP')
	check(f.new_ip.encode() in f.nft_bytes() and f.old_ip.encode() not in f.nft_bytes(),
	      f'{label}: followup current/aether-proxy.nft has new IP')
	check(f.new_ip.encode() in f.xray_bytes() and f.old_ip.encode() not in f.xray_bytes(),
	      f'{label}: followup current/xray.json has new IP')
	check(f.new_ip.encode() in f.loaded_nft_bytes(),
	      f'{label}: followup loaded nft has new IP')
	check(f.new_ip.encode() in f.active_xray_bytes(),
	      f'{label}: followup running Xray config has new IP')
	check(f.lkg().get('nodes', {}).get('node.example.com') == f.new_ip,
	      f'{label}: followup LKG updated to new IP')
	check(len(f.events('NODE_IP_CHANGED')) == 1,
	      f'{label}: exactly one NODE_IP_CHANGED emitted')
	check(len(f.probes_log()) > probes_before and f.probes_log()[-1].get('action') == 'switch',
	      f'{label}: node-probe.log records switch')
	# finish_tick publishes state.json before it unlocks; publication is not a release barrier.
	check(wait_for(lambda: lock_is_free(f.root / 'var/lock/aether-proxy.lock'), timeout=10),
	      f'{label}: C.LOCK_FILE released after followup')


def main():
	# Bind two distinct non-127.0.0.1 loopback addresses (127.0.0.1 is used by xray's
	# DNS/HTTP listen directives) so both old_ip and new_ip are real reachable TCP endpoints.
	old_ip = '127.0.0.10'
	new_ip = '127.0.0.20'
	with socket.socket() as listener:
		listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
		listener.bind(('0.0.0.0', 0))
		listener.listen(64)
		port = listener.getsockname()[1]

		def drain_accepts():
			while True:
				try:
					conn, _ = listener.accept()
				except OSError:
					break
				conn.close()

		threading.Thread(target=drain_accepts, daemon=True).start()

		with tempfile.TemporaryDirectory(prefix='.t1669-', dir=ROOT / 'tests/monitor') as tmp:
			base = pathlib.Path(tmp)

			# 0. Positive control: clean refresh to new IP
			f = Fixture(base, 'positive-control', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				verify_followup_success(f, child, 'positive-control')
				check(len(f.events('START_FAILED')) == 0, 'positive-control: zero START_FAILED events')
				check(len(f.events('BUSY')) == 0, 'positive-control: zero BUSY events (no double lock)')

			# 1a. Second staging candidate file write failure (staging/xray.json fails after staging/aether-proxy.nft)
			f = Fixture(base, 'stage-second-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'fail-write-path').write_text(str(f.run / 'staging/xray.json') + '\n')
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'))
				assert_restored(f, 'stage-second-fail', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0, expect_xray_starts=starts0)
				check(not (f.run / 'staging').exists(), 'stage-second-fail: staging directory cleaned up')
				check(len(f.events('START_FAILED')) >= 1, 'stage-second-fail: START_FAILED emitted')
				verify_followup_success(f, child, 'stage-second-fail')

			# 1b. Second publish file write failure (current/xray.json fails after current/aether-proxy.nft)
			f = Fixture(base, 'write-second-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'fail-write-path').write_text(str(f.current / 'xray.json') + '\n')
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'))
				assert_restored(f, 'write-second-fail', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0, expect_xray_starts=starts0)
				check(len(f.events('START_FAILED')) >= 1, 'write-second-fail: START_FAILED emitted')
				verify_followup_success(f, child, 'write-second-fail')

			# 2. Xray config validation failure (xray run -test fails)
			f = Fixture(base, 'xray-test-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'xray-test-fail-once').touch()
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'))
				assert_restored(f, 'xray-test-fail', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0, expect_xray_starts=starts0)
				check(any('xray run -test' in str(e.get('args', {}).get('detail', ''))
				          for e in f.events('START_FAILED')),
				      'xray-test-fail: START_FAILED mentions xray run -test')
				verify_followup_success(f, child, 'xray-test-fail')

			# 3. nft -f load failure
			f = Fixture(base, 'nft-load-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'nft-load-fail-once').touch()
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'))
				assert_restored(f, 'nft-load-fail', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0, expect_xray_starts=starts0)
				check(any('nft -f' in str(e.get('args', {}).get('detail', ''))
				          for e in f.events('START_FAILED')),
				      'nft-load-fail: START_FAILED mentions nft -f')
				verify_followup_success(f, child, 'nft-load-fail')

			# 4. Xray child immediate exit (start/readiness failure after nft load)
			f = Fixture(base, 'xray-crash-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'xray-crash-once').touch()
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				         timeout=12)
				# nft was loaded once for forward and once for rollback (+2); xray started for forward and rollback (+2).
				assert_restored(f, 'xray-crash-fail', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0 + 2, expect_xray_starts=starts0 + 2)
				check(len(f.events('START_FAILED')) >= 1, 'xray-crash-fail: START_FAILED emitted')
				verify_followup_success(f, child, 'xray-crash-fail')

			# 5. Xray readiness failure (missing referenced DNS socket)
			f = Fixture(base, 'xray-ready-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'xray-missing-once').write_text('31082\n')
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				         timeout=15)
				assert_restored(f, 'xray-ready-fail', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0 + 2, expect_xray_starts=starts0 + 2)
				check(any('not ready' in str(e.get('args', {}).get('detail', ''))
				          for e in f.events('START_FAILED')),
				      'xray-ready-fail: START_FAILED mentions readiness timeout')
				verify_followup_success(f, child, 'xray-ready-fail')

			# 5b. Xray readiness failure with live runtime gfw4 dynamic set not in old current/aether-proxy.nft
			f = Fixture(base, 'xray-ready-dynamic-sets', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				dyn_ip = '198.51.100.77'
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded, old_active = f.loaded_nft_bytes(), f.active_xray_bytes()
				check(dyn_ip.encode() not in old_nft,
				      'xray-ready-dynamic-sets: precondition old current/aether-proxy.nft does not contain dynamic IP')
				# Simulate live gfw4 dynamic element learned at runtime before refresh.
				(f.root / 'gfw4-elem').write_text(json.dumps([dyn_ip]) + '\n')
				loads0, starts0 = f.nft_loads(), f.xray_starts()
				(f.root / 'xray-missing-once').write_text('31082\n')
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				         timeout=15)
				assert_restored(f, 'xray-ready-dynamic-sets', old_nft, old_xray, old_loaded, old_active,
				                expect_nft_loads=loads0 + 2, expect_xray_starts=starts0 + 2,
				                dynamic_gfw4_ip=dyn_ip)
				check(not (f.run / 'staging').exists(),
				      'xray-ready-dynamic-sets: staging cleaned up after dynamic-set rollback')
				check(any('not ready' in str(e.get('args', {}).get('detail', ''))
				          for e in f.events('START_FAILED')),
				      'xray-ready-dynamic-sets: START_FAILED mentions readiness timeout')
				verify_followup_success(f, child, 'xray-ready-dynamic-sets')
				check(nft_set_contains(f.loaded_nft_bytes().decode(), 'gfw4', dyn_ip),
				      'xray-ready-dynamic-sets: followup refresh also retains gfw4 dynamic IP')

			# 6. Rollback failure (forward Xray crash + rollback nft load fails)
			f = Fixture(base, 'rollback-nft-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				(f.root / 'xray-crash-once').touch()
				# 1st nft -f (forward) succeeds; 2nd nft -f (rollback) fails.
				(f.root / 'nft-load-fail-seq').write_text('2\n')
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				         timeout=12)
				action_errs = [e for e in f.events('START_FAILED')
				               if e.get('args', {}).get('step') == 'monitor:actions']
				rb_errs = [e for e in f.events('START_FAILED')
				           if e.get('args', {}).get('step') == 'monitor:rollback_nft']
				check(len(rb_errs) >= 1, 'rollback-nft-fail: separate monitor:rollback_nft START_FAILED emitted')
				check(any('rollback_nft' in str(e.get('args', {}).get('detail', ''))
				          and 'exited' in str(e.get('args', {}).get('detail', ''))
				          for e in action_errs),
				      'rollback-nft-fail: monitor:actions detail distinguishes original error and rollback_nft error')
				check(f.nft_bytes() == old_nft and f.xray_bytes() == old_xray,
				      'rollback-nft-fail: current/ files restored to old bytes')
				check(f.state().get('node_ip') == old_ip and f.lkg().get('nodes', {}).get('node.example.com') == old_ip,
				      'rollback-nft-fail: state.json and LKG not updated to new IP')
				check(len(f.events('NODE_IP_CHANGED')) == 0,
				      'rollback-nft-fail: zero NODE_IP_CHANGED on rollback failure')
				check(lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				      'rollback-nft-fail: C.LOCK_FILE released after rollback failure')

			# 6b. Rollback failure (forward Xray crash + rollback Xray readiness fails)
			f = Fixture(base, 'rollback-xray-fail', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				old_nft, old_xray = f.nft_bytes(), f.xray_bytes()
				old_loaded = f.loaded_nft_bytes()
				(f.root / 'xray-crash-once').touch()
				(f.root / 'xray-dns-missing-port').write_text('31082\n')
				f.trigger_refresh(child, new_ip)
				wait_for(lambda: len(f.probes_log()) >= 1 and lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				         timeout=15)
				action_errs = [e for e in f.events('START_FAILED')
				               if e.get('args', {}).get('step') == 'monitor:actions']
				rb_errs = [e for e in f.events('START_FAILED')
				           if e.get('args', {}).get('step') == 'monitor:rollback_xray']
				check(len(rb_errs) >= 1, 'rollback-xray-fail: separate monitor:rollback_xray START_FAILED emitted')
				check(any('rollback_xray' in str(e.get('args', {}).get('detail', ''))
				          and 'exited' in str(e.get('args', {}).get('detail', ''))
				          for e in action_errs),
				      'rollback-xray-fail: monitor:actions detail distinguishes original error and rollback_xray error')
				check(f.nft_bytes() == old_nft and f.xray_bytes() == old_xray,
				      'rollback-xray-fail: current/ files restored to old bytes')
				check(f.loaded_nft_bytes() == old_loaded,
				      'rollback-xray-fail: loaded nft restored to old bytes')
				check(f.state().get('node_ip') == old_ip and f.lkg().get('nodes', {}).get('node.example.com') == old_ip,
				      'rollback-xray-fail: state.json and LKG not updated to new IP')
				check(len(f.events('NODE_IP_CHANGED')) == 0,
				      'rollback-xray-fail: zero NODE_IP_CHANGED on rollback failure')
				check(lock_is_free(f.root / 'var/lock/aether-proxy.lock'),
				      'rollback-xray-fail: C.LOCK_FILE released after rollback failure')

			# 7. TERM in-flight during old.stop() must NOT spawn a new Xray child
			f = Fixture(base, 'term-during-stop', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				(f.root / 'xray-slow-stop-hold').touch()
				starts_before = f.xray_starts()
				f.trigger_refresh(child, new_ip)
				entered = wait_for(lambda: (f.root / 'xray-stopping-entered').exists(), timeout=8)
				check(entered, 'term-during-stop: old Xray entered stopping barrier')
				child.terminate()
				time.sleep(0.15)
				(f.root / 'xray-slow-stop-hold').unlink()
				child.wait(timeout=8)
				check(f.xray_starts() == starts_before,
				      f'term-during-stop: no new Xray spawned after TERM (before={starts_before}, after={f.xray_starts()})')
				check(f.state().get('state') == 'stopped', 'term-during-stop: state.json is stopped')
				check(len(f.events('NODE_IP_CHANGED')) == 0, 'term-during-stop: zero NODE_IP_CHANGED')
				check(lock_is_free(f.root / 'var/lock/aether-proxy.lock'), 'term-during-stop: C.LOCK_FILE released')

			# 8. TERM in-flight during new Xray readiness must NOT revive old Xray child
			f = Fixture(base, 'term-during-ready', old_ip, new_ip, port)
			with f.daemon() as child:
				f.wait_running()
				(f.root / 'xray-dns-missing-port').write_text('31082\n')
				starts_before = f.xray_starts()
				f.trigger_refresh(child, new_ip)
				spawned = wait_for(lambda: f.xray_starts() == starts_before + 1, timeout=8)
				check(spawned, 'term-during-ready: new Xray spawned and waiting for readiness')
				time.sleep(0.15)
				child.terminate()
				child.wait(timeout=8)
				check(f.xray_starts() == starts_before + 1,
				      f'term-during-ready: TERM cancels without reviving rollback Xray (starts={f.xray_starts()})')
				check(f.state().get('state') == 'stopped', 'term-during-ready: state.json is stopped')
				check(len(f.events('NODE_IP_CHANGED')) == 0, 'term-during-ready: zero NODE_IP_CHANGED')
				check(lock_is_free(f.root / 'var/lock/aether-proxy.lock'), 'term-during-ready: C.LOCK_FILE released')

	print(f'T16.69 node-ip-rollback: {passed} passed, {failed} failed', flush=True)
	if failed:
		sys.exit(1)


if __name__ == '__main__':
	main()
