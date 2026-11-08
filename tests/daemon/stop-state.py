#!/usr/bin/env python3
"""T9.32 integration: `stopping` state, early dns_tier, real daemon with isolated stubs (docs/04)."""

from contextlib import contextmanager
import json
import traceback
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
LIB = Path(os.environ.get('T946_SOURCE_DIR', ROOT / 'aether-proxy/src/lib'))


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS  T9.32 stop-state: ' + name, flush=True)


def wait_for(predicate, child=None, timeout=12):
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		value = predicate()
		if value:
			return value
		if child is not None and child.poll() is not None:
			raise AssertionError(f'daemon exited early: {child.returncode}')
		time.sleep(0.02)
	raise AssertionError('timed out waiting for lifecycle transition')


def field_diff(before, after, prefix=''):
	result = {}
	for key in sorted(set(before) | set(after)):
		path = prefix + key
		if key not in before or key not in after:
			result[path] = {'before': before.get(key), 'after': after.get(key),
				'before_present': key in before, 'after_present': key in after}
		elif isinstance(before[key], dict) and isinstance(after[key], dict):
			result.update(field_diff(before[key], after[key], path + '.'))
		elif before[key] != after[key]:
			result[path] = {'before': before[key], 'after': after[key]}
	return result


def wait_state(fixture, wanted, child=None, timeout=12):
	def sample():
		value = fixture.state()
		return value if value.get('state') == wanted else None
	return wait_for(sample, child, timeout)


def stamp():
	return {'wall_ns': time.time_ns(), 'monotonic_ns': time.monotonic_ns()}


def objects(text):
	"""state.json is pretty-printed, so a concatenation is decoded object by object."""
	decoder, position, found = json.JSONDecoder(), 0, []
	while True:
		while position < len(text) and text[position].isspace():
			position += 1
		if position >= len(text):
			return found
		value, position = decoder.raw_decode(text, position)
		found.append(value)


with tempfile.TemporaryDirectory(prefix='.stop-state-', dir=ROOT / 'tests/daemon') as temp:
	base = Path(temp)
	binaries = base / 'bin'
	shutil.copytree(ROOT / 'tests/stubs/daemon-bin', binaries)
	# `ip rule show` is the first command of the stop sequence after the table work; while the
	# capture flag exists it records state.json, i.e. what a page would read mid-stop.
	(binaries / 'ip').rename(binaries / 'ip-original')
	(binaries / 'ip').write_text('''#!/bin/sh
if [ -e "$SYSROOT/capture" ] && [ "$1 $2" = "rule show" ]; then
	cat "$SYSROOT/var/run/aether-proxy/state.json" >> "$SYSROOT/state-during-stop.jsonl" || exit 1
	sleep 0.5
fi
exec "$(dirname "$0")/ip-original" "$@"
''')
	(binaries / 'ip').chmod(0o755)
	# Local-only controls hold real supervisor callbacks and synchronous probes open.
	xray = binaries / 'xray'
	source = xray.read_text().replace('cleanup() {', '''cleanup() {
		if [ -e "$SYSROOT/hold-callback" ]; then
			touch "$SYSROOT/callback-held"
			while [ -e "$SYSROOT/hold-callback" ]; do sleep 0.02; done
		fi''', 1)
	xray.write_text(source)
	xray.rename(binaries / 'xray-original')
	xray.write_text('''#!/bin/sh
if [ "$1 $2" = "run -c" ]; then
	SYSROOT=${3%/var/run/aether-proxy/current/*}
	if [ -e "$SYSROOT/hold-listener" ]; then
		touch "$SYSROOT/listener-held"
		while [ -e "$SYSROOT/hold-listener" ]; do sleep 0.02; done
	fi
fi
exec "$(dirname "$0")/xray-original" "$@"
''')
	xray.chmod(0o755)
	(binaries / 'curl').rename(binaries / 'curl-original')
	(binaries / 'curl').write_text('''#!/bin/sh
if [ -e "$SYSROOT/hold-probe" ]; then
	touch "$SYSROOT/probe-held"
	while [ -e "$SYSROOT/hold-probe" ]; do sleep 0.02; done
fi
exec "$(dirname "$0")/curl-original" "$@"
''')
	(binaries / 'curl').chmod(0o755)
	(binaries / 'aether-proxy').write_text('''#!/bin/sh
printf 'scheduled %s\\n' "$*" >> "$STUB_LOG"
exit 0
''')
	(binaries / 'aether-proxy').chmod(0o755)
	for directory in ('data', 'base', 'custom'):
		(base / directory).mkdir()
	for name in ('gfwlist', 'chnlist', 'apple'):
		(base / 'base' / (name + '.txt')).write_text('example.com\n')
	(base / 'base/chnroute4.txt').write_text('1.0.0.0/8\n')
	(base / 'base/gfw_static4.txt').write_text('91.108.4.0/22\n')

	# Instrument a module copy only: record state.json when validation starts (first health
	# check is later still), as T9.27 does.
	modules = base / 'modules/aetherproxy'
	shutil.copytree(LIB, modules)
	source = (modules / 'config.uc').read_text()
	source = source.replace("'use strict';", "'use strict';\nimport * as trace_fs from 'fs';", 1)
	hook = '''export function load(cursor) {
	let trace = getenv('LIFECYCLE_TRACE');
	if (trace != null) {
		let fp = trace_fs.open(trace, 'a');
		fp.write(trace_fs.readfile(getenv('SYSROOT') + '/var/run/aether-proxy/state.json') + '\\n');
		fp.close();
	}
'''
	assert source.count('export function load(cursor) {') == 1
	(modules / 'config.uc').write_text(source.replace('export function load(cursor) {', hook, 1))

	# Observation only: record the actual TERM handler entry, not the earlier
	# controller send or an arbitrary poll of state.json. No uloop dispatch here.
	daemon_path = modules / 'daemon.uc'
	source = daemon_path.read_text()
	needle = 'function write_stopping(ctx) {'
	assert source.count(needle) == 1
	helper = '''function trace_term(ctx, kind, name) {
	let fp = fs.open(run_dir(ctx) + '/term-handled.jsonl', 'a');
	if (fp == null) die('cannot open TERM trace');
	let text = sprintf('%J\\n', { kind, name, monotonic: clock(true), wall: clock(),
		already_stopping: ctx.stopping_requested ?? false,
		published: fs.readfile(run_dir(ctx) + '/state.json') });
	let written = fp.write(text), closed = fp.close();
	if (written != length(text) || !closed) die('cannot write TERM trace');
};

'''
	source = source.replace(needle, helper + needle, 1)
	handler = "\t\t\tif (kind == 'stop') {"
	assert source.count(handler) == 1
	source = source.replace(handler, handler + "\n\t\t\t\ttrace_term(ctx, 'received', name);", 1)
	publish = '\t\t\t\twrite_stopping(ctx);'
	assert source.count(publish) == 1
	source = source.replace(publish, publish + "\n\t\t\t\ttrace_term(ctx, 'published', name);", 1)
	daemon_path.write_text(source)

	# Force the production node-refresh action without waiting ten minutes. No control-flow
	# replacement: supervision, callbacks, readiness waiting and persistence are real.
	monitor_path = modules / 'monitor.uc'
	source = monitor_path.read_text()
	needle = '\tlet obs = observe(daemon);'
	assert source.count(needle) == 1
	monitor_path.write_text(source.replace(needle, '''	let refresh = system_path(daemon.ctx, '/refresh-now');
	if (fs.stat(refresh) != null) {
		if (!fs.unlink(refresh)) die('cannot consume refresh control');
		daemon.machine.last_node_refresh = 0;
		daemon.machine.node_ip = '203.0.113.99';
	}
''' + needle))
	state_path = modules / 'state.uc'
	source = state_path.read_text()
	needle = "\tlet result = sys.write_atomic(path, sprintf('%.J', obj) + '\\n');"
	assert source.count(needle) == 1
	replacement = "\tlet result = obj.state == 'stopping' && getenv('STOP_WRITE_FAIL') == '1'\n" + \
		"\t\t? false : sys.write_atomic(path, sprintf('%.J', obj) + '\\n');"
	trace_helper = '''let trace_published = null;
function trace_state(kind, run_dir, obj, result) {
	let value = json(sprintf('%J', obj));
	let entry = { kind, monotonic: clock(true), wall: clock(), value, result,
		published: trace_published };
	let fp = fs.open(run_dir + '/state-events.jsonl', 'a');
	if (fp == null) die('cannot open full state trace');
	let text = sprintf('%J\\n', entry), written = fp.write(text);
	let closed = fp.close();
	if (written != length(text) || !closed) die('cannot write full state trace');
	if (kind == 'write_completed' && result)
		trace_published = value;
};

'''
	source = source.replace('function write_value(run_dir, obj) {',
		trace_helper + "function write_value(run_dir, obj) {\n\ttrace_state('write_enter', run_dir, obj, null);", 1)
	source = source.replace('function write(run_dir, obj) {',
		"function write(run_dir, obj) {\n\ttrace_state('write_request', run_dir, obj, null);", 1)
	source = source.replace('function hold_stopping(run_dir, obj) {',
		"function hold_stopping(run_dir, obj) {\n\ttrace_state('hold_entry', run_dir, obj, null);", 1)
	state_path.write_text(source.replace(needle, replacement + '''
	trace_state('write_completed', run_dir, obj, result);
	let trace = fs.open(run_dir + '/writes.jsonl', 'a');
	if (trace == null) die('cannot open state trace');
	trace.write(sprintf('%.J', obj) + '\\n');
	trace.close();'''))

	class Fixture:
		def __init__(self, name, dns_section=None):
			self.root = base / name
			self.run = self.root / 'var/run/aether-proxy'
			self.conf = self.root / 'etc/config'
			for directory in ('etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net', 'sys/class/net/br-lan',
					'var/lock', 'etc/aether-proxy/state', 'var/run/aether-proxy', 'etc/config'):
				(self.root / directory).mkdir(parents=True, exist_ok=True)
			shutil.copyfile(ROOT / 'tests/fixtures/sample/aetherproxy', self.conf / 'aetherproxy')
			if dns_section is not None:
				with (self.conf / 'aetherproxy').open('a') as fp:
					fp.write(dns_section)
			(self.root / 'var/etc/dnsmasq.conf.test').write_text('interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
			dnsmasq = self.root / 'etc/init.d/dnsmasq'
			dnsmasq.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
			dnsmasq.chmod(0o755)
			subprocess.run(['python3', str(ROOT / 'tests/xray-ready/proc_fixture.py'),
				str(self.root)], check=True)
			(self.root / 'proc/net/tcp').write_text(
				'  0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
			for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
				(self.root / file).touch()
			self.calls = self.root / 'calls.log'
			self.trace = self.root / 'validation.jsonl'
			self.observations = {}
			self.env = dict(os.environ, SYSROOT=str(self.root), STUB_LOG=str(self.calls),
				LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
				STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'), PATH=str(binaries) + ':' + os.environ['PATH'],
				AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
				LIFECYCLE_TRACE=str(self.trace))
			self.args = ['--sys-root', str(self.root), '--bin-dir', str(binaries), '--confdir', str(self.conf),
				'--data-dir', str(base / 'data'), '--baseline-dir', str(base / 'base'),
				'--custom-dir', str(base / 'custom')]

		def state(self):
			path = self.run / 'state.json'
			return json.loads(path.read_text()) if path.exists() and path.is_file() else {}

		def events(self):
			path = self.run / 'events.jsonl'
			return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

		def save_evidence(self, error=None):
			kind = 'failure' if error is not None else 'success'
			out = ROOT / 'tests/bootstrap-startup/.logs' / f't946-{kind}-{time.time_ns()}-{self.root.name}'
			out.mkdir(parents=True)
			data = dict(self.observations, error=error, captured=stamp(), final_state=self.state())
			data['field_diff'] = field_diff(data.get('before', {}), data.get('stopping', {}))
			data['controller_field_diff'] = field_diff(data.get('controller_before', {}), data.get('stopping', {}))
			(out / 'observation.json').write_text(json.dumps(data, indent=2) + '\n')
			for path in (self.root / 'stdout', self.root / 'stderr', self.calls,
				self.run / 'state-events.jsonl', self.run / 'writes.jsonl', self.run / 'term-handled.jsonl'):
				if path.exists():
					shutil.copyfile(path, out / path.name)
			print('T9.46 ' + kind + ' evidence:', out, flush=True)
			return out

		@contextmanager
		def daemon(self):
			with (self.root / 'stdout').open('w') as stdout, (self.root / 'stderr').open('w') as stderr:
				command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(base / 'modules/*.uc'),
					'-S', str(ENTRY), '--', 'daemon', *self.args]
				with subprocess.Popen(command, env=self.env, stdout=stdout, stderr=stderr,
						start_new_session=True) as child:
					failure = None
					try:
						yield child
					except BaseException:
						failure = traceback.format_exc()
						raise
					finally:
						if child.poll() is None:
							child.terminate()
						try:
							child.wait(timeout=12)
						except subprocess.TimeoutExpired:
							# A regression inside nested uloop must fail boundedly, not hang
							# Popen.__exit__ or leave supervised substitutes alive.
							os.killpg(child.pid, signal.SIGKILL)
							child.wait()
							raise
						finally:
							if failure is not None:
								self.save_evidence(failure)

		def captured(self):
			path = self.root / 'state-during-stop.jsonl'
			return objects(path.read_text()) if path.exists() else []

	# Scenario 2: early starting state carries dns_tier from the raw UCI value.
	for name, section, expected in (
			('tier-unset', None, 'T1'),
			('tier-direct', "\nconfig dns 'dns'\n\toption direct_dns_enabled '1'\n", 'T2')):
		fixture = Fixture(name, section)
		with fixture.daemon() as child:
			wait_for(lambda: fixture.state().get('state') == 'running', child)
			early = objects(fixture.trace.read_text())[0]
			check(f'early state before validation is starting with dns_tier {expected}: {name}',
				early['state'] == 'starting' and early['dns_tier'] == expected)
			child.terminate()
			child.wait(timeout=12)

	# Scenario 1: stopping is published first, other fields kept, stopped last.
	fixture = Fixture('stop-flow')
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('state') == 'running', child)
		before = fixture.state()
		(fixture.root / 'capture').touch()
		stop_started = int(time.time())
		child.terminate()
		child.wait(timeout=12)
		seen = fixture.captured()
		check('state.json is stopping while cleanup runs, with node_id and mode kept',
			len(seen) >= 1 and seen[0]['state'] == 'stopping' and seen[0]['node_id'] == before['node_id']
			and seen[0]['mode'] == before['mode'] and seen[0]['since'] >= stop_started - 1)
		check('final state is stopped after a clean exit',
			child.returncode == 0 and fixture.state()['state'] == 'stopped')

	# T9.46: TERM must be visible before an asynchronous busy action completes.
	for scenario, phase in (('callback', 'callback'), ('listener', 'listener'),
			('probe', 'probe'), ('listener-timeout', 'listener')):
		if os.environ.get('T946_SCENARIO', scenario) != scenario:
			continue
		fixture = Fixture('busy-' + scenario, """
config subscription 's_00000001'
	option url 'https://example.com/sub'
	option interval_hours '1'
""")
		sub_status = fixture.root / 'etc/aether-proxy/state/sub.json'
		sub_status.write_text(json.dumps({'s_00000001': {'last_attempt': int(time.time()) + 3600}}))
		fixture.env['AETHER_PROXY_TEST_SCHEDULE_INTERVAL_MS'] = '10'
		with fixture.daemon() as child:
			wait_for(lambda: fixture.state().get('state') == 'running', child)
			before = fixture.state()
			hold = fixture.root / ('hold-' + phase)
			hold.touch()
			if phase != 'probe':
				(fixture.root / 'refresh-now').touch()
			child.send_signal(signal.SIGUSR1)
			wait_for(lambda: (fixture.root / (phase + '-held')).exists(), child)
			# Starting is followed by an immediate monitor sample. Compare stopping
			# with the state immediately before TERM, not a pre-sample startup read.
			before = fixture.state()
			if phase == 'probe' and os.environ.get('T946_FORCE_WALL_BOUNDARY') == '1':
				# Diagnostic counterexample: keep the same synchronous probe held
				# across a wall second. This never relaxes the stop deadline.
				wait_for(lambda: int(time.time()) > before['last_probe']['at'], child)
			trace = fixture.run / 'writes.jsonl'
			trace.write_text('')
			(fixture.root / 'capture').touch()
			term_at = int(time.time())
			fixture.observations.update(before=before, controller_before=before,
				controller_before_sampled=stamp(), term_at=term_at, term_sent=stamp())
			child.terminate()
			fixture.observations['term_send_returned'] = stamp()
			exit_deadline = None
			try:
				if phase == 'probe':
					# TERM has been sent while the synchronous probe is held. Release
					# the barrier, rather than guessing delivery with a sleep.
					hold.unlink()
				stopping = wait_state(fixture, 'stopping', child, timeout=1)
				sampled = stamp()
				fixture.observations.update(stopping=stopping, matched_stopping=stopping,
					stopping_sampled=sampled, matched_stopping_sampled=sampled)
				if phase == 'probe' and os.environ.get('T946_DELAY_STOP_SAMPLE') == '1':
					# A deterministic descheduled-consumer counterexample: the live
					# file may already be stopped, but keep the matched observation.
					# Share, rather than add to, the original 12-second exit budget.
					exit_deadline = time.monotonic() + 12
					wait_state(fixture, 'stopped', timeout=max(0, exit_deadline - time.monotonic()))
					check('probe: matched stopping sample survives delayed consumer',
						stopping['state'] == 'stopping' and fixture.state()['state'] == 'stopped')
				term_events = [json.loads(line) for line in
					(fixture.run / 'term-handled.jsonl').read_text().splitlines()]
				handled = next(item for item in term_events if item['kind'] == 'received')
				before = json.loads(handled['published'])
				fixture.observations.update(before=before, term_handled=handled,
					controller_to_handler_diff=field_diff(fixture.observations['controller_before'], before))
				check(f'{scenario}: stopping published before busy completion',
					phase == 'probe' or hold.exists())
				check(f'{scenario}: stopping preserves every other field and TERM timestamp',
					{key: value for key, value in stopping.items() if key not in ('state', 'since')}
					== {key: value for key, value in before.items() if key not in ('state', 'since')}
					and term_at <= stopping['since'] <= term_at + 1)
				# Make the real scheduler due only after stop intent. During listener waiting
				# it still has an active timer and the readiness loop keeps dispatching it.
				if phase != 'probe':
					sub_status.write_text('{"s_00000001":{"last_attempt":1}}')
					calls_before = fixture.calls.read_text()
					for sig in (signal.SIGHUP, signal.SIGUSR1, signal.SIGUSR2):
						child.send_signal(sig)
						time.sleep(0.05)
					# T15.5 cancels readiness immediately, so shutdown may now issue
					# cleanup commands before the held listener is released. Only new
					# work/probes are forbidden, not prompt cleanup of existing work.
					def success_work(text):
						return [line for line in text.splitlines() if line.startswith(
							('scheduled ', 'curl ', 'xray run ', 'chinadns-ng '))]
					check(f'{scenario}: stopping blocks due subscription, reload and new probes',
						success_work(fixture.calls.read_text()) == success_work(calls_before))
				if scenario == 'listener-timeout':
					# Observe beyond the original five-second budget: cancellation must
					# not later publish a stale readiness success over stopping/stopped.
					time.sleep(5.2)
			finally:
				if hold.exists():
					hold.unlink()
			child.wait(timeout=12 if exit_deadline is None else max(0, exit_deadline - time.monotonic()))
			writes = objects(trace.read_text())
			state_events = [json.loads(line) for line in (fixture.run / 'state-events.jsonl').read_text().splitlines()]
			prior = [entry for entry in state_events if entry['kind'] == 'write_completed' and entry['result']
				and tuple(entry['monotonic']) < tuple(handled['monotonic'])]
			check(f'{scenario}: TERM snapshot matches independent last committed state',
				bool(prior) and prior[-1]['value'] == before)
			# The controller's pre-send sample is not a transaction boundary. A
			# completed monitor observation before TERM handling may precede stop.
			# The write barrier protects every field from the first stopping write.
			stop_index = next(i for i, value in enumerate(writes) if value['state'] == 'stopping')
			check(f'{scenario}: completion never overwrites stopping or its fields',
				writes[stop_index]['state'] == 'stopping' and all(
					value == stopping for value in writes[stop_index:] if value['state'] != 'stopped'))
			check(f'{scenario}: stopped with no runtime residue',
				child.returncode == 0 and fixture.state()['state'] == 'stopped'
				and not any((fixture.run / name).exists() for name in ('daemon.pid', 'xray.pid', 'chinadns-ng.pid'))
				and not (fixture.root / 'nft-table').exists()
				and (fixture.root / 'ip-rules').read_text() == '')
			if os.environ.get('T946_SAVE_SUCCESS') == '1':
				fixture.save_evidence()

	# A one-shot fault leaves the old file in place, then permits final stopped to succeed.
	fixture = Fixture('stop-write-transient')
	fixture.env['STOP_WRITE_FAIL'] = '1'
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('state') == 'running', child)
		(fixture.run / 'events.jsonl').write_text('')
		child.terminate()
		child.wait(timeout=12)
		codes = [event['code'] for event in fixture.events()]
		check('transient stopping write failure: only FS_FAILED and final stopped',
			codes.count('FS_FAILED') == 1 and 'START_FAILED' not in codes
			and fixture.state()['state'] == 'stopped' and child.returncode == 0)

	# Scenario 1 (cont.): a failing stopping write only logs FS_FAILED; the other steps go on.
	fixture = Fixture('stop-write-fails')
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('state') == 'running', child)
		# A directory in place of state.json makes every atomic rename onto it fail.
		(fixture.run / 'state.json').unlink()
		(fixture.run / 'state.json').mkdir()
		(fixture.run / 'events.jsonl').write_text('')
		child.terminate()
		child.wait(timeout=12)
		codes = [(e['code'], e['args'].get('op')) for e in fixture.events()]
		calls = fixture.calls.read_text()
		check('failed stopping write is logged as FS_FAILED', ('FS_FAILED', 'write') in codes)
		check('failed stopping write never emits START_FAILED',
			all(code != 'START_FAILED' for code, _ in codes))
		check('persistent stop write failure reports only FS_FAILED errors',
			all(event['code'] == 'FS_FAILED' for event in fixture.events() if event['level'] == 'error'))
		check('failed stopping write does not abort the stop sequence',
			not (fixture.root / 'nft-table').exists() and (fixture.root / 'ip-rules').read_text() == ''
			and 'dnsmasq restart' in calls and not (fixture.run / 'daemon.pid').exists()
			and any(c == 'SERVICE_STOPPED' for c, _ in codes))

	# Scenario 1 (cont.): SIGTERM during the start sequence (waiting for the network) also
	# writes stopping first. The network wait is held open by an unreachable gateway.
	fixture = Fixture('stop-while-starting')
	conf = fixture.conf / 'aetherproxy'
	conf.write_text(conf.read_text().replace("config main 'main'\n", "config main 'main'\n\toption boot_wait_timeout '30'\n", 1))
	fixture.args.append('--boot')
	# `ip -4 route show default` empty would make the network wait block; reuse the stub's
	# hook by swapping in a variant for this fixture only.
	local_bin = base / 'bin-nonet'
	shutil.copytree(binaries, local_bin)
	original = (local_bin / 'ip-original').read_text()
	(local_bin / 'ip-original').write_text(original.replace(
		"*\" -4 route show default \"*) echo 'default dev lo'; exit 0 ;;", "*\" -4 route show default \"*) exit 0 ;;"))
	fixture.env['PATH'] = str(local_bin) + ':' + os.environ['PATH']
	idx = fixture.args.index('--bin-dir')
	fixture.args[idx + 1] = str(local_bin)
	with fixture.daemon() as child:
		wait_for(lambda: fixture.state().get('waiting_network') is True, child)
		check('network wait publishes starting and keeps the T1 dns_tier of the unset option',
			fixture.state()['state'] == 'starting' and fixture.state()['dns_tier'] == 'T1')
		(fixture.root / 'capture').touch()
		child.terminate()
		child.wait(timeout=12)
		seen = fixture.captured()
		check('SIGTERM during start writes stopping before cleanup',
			len(seen) >= 1 and seen[0]['state'] == 'stopping' and seen[0]['mode'] == 'gfw')
		check('SIGTERM during start still ends in stopped', fixture.state()['state'] == 'stopped')
