#!/usr/bin/env python3
"""T9.46: private exports and a deterministic clock test stop/5-second boundaries (docs/04)."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='.stopping-unit-', dir=ROOT / 'tests/daemon') as temp:
	base = Path(temp)
	modules = base / 'modules/aetherproxy'
	shutil.copytree(ROOT / 'aether-proxy/src/lib', modules)
	path = modules / 'daemon.uc'
	path.write_text(path.read_text() + '\nexport { write_stopping };\n')
	path = modules / 'monitor.uc'
	source = path.read_text().replace("'use strict';", "'use strict';\nlet test_clock = null, test_ready = null;", 1)
	# Only time, listener observation and sleeping are substituted. The production
	# readiness loop, comparison operators and final port check remain unchanged.
	for old, new in (
		('function monotonic_ms() {', 'function monotonic_ms() {\n\tif (test_clock != null) return test_clock;'),
		('function port_listening(daemon, port) {',
		 'function port_listening(daemon, port) {\n\tif (test_clock != null) return test_clock >= test_ready;'),
		('uloop.run(C.DAEMON_POLL_MS);',
		 'if (test_clock != null) test_clock = min(test_clock + C.DAEMON_POLL_MS, test_ready);\n'
		 '\t\telse uloop.run(C.DAEMON_POLL_MS);'),
	):
		assert source.count(old) == 1, old
		source = source.replace(old, new)
	# Land exactly on sub-poll readiness times, but never move the clock backwards.
	source = source.replace('min(test_clock + C.DAEMON_POLL_MS, test_ready)',
		'test_clock + min(C.DAEMON_POLL_MS, max(test_ready - test_clock, 1))')
	path.write_text(source + '''
export function test_readiness(ready, stopped) {
	test_clock = 0;
	test_ready = ready;
	let result = wait_xray_port({}, () => stopped);
	let elapsed = test_clock;
	test_clock = null;
	return { result, elapsed };
};
export { persist_state, finish_tick, run_actions };
''')
	driver = base / 'driver.uc'
	driver.write_text('''\
'use strict';
// Private harness: do not add testing exports or clock controls to installed modules.
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as daemon from 'aetherproxy.daemon';
import * as monitor from 'aetherproxy.monitor';
import * as state from 'aetherproxy.state';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as C from 'aetherproxy.const';

function check(name, value) {
	if (!value) die('FAIL  T9.46 ' + name + '\\n');
	print('PASS  T9.46 ' + name + '\\n');
};
uloop.init();
let root = ARGV[0];
for (let variant in [ 'missing', 'null', 'idle', 'busy' ]) {
	let ctx = { root: root + '/' + variant, run_dir: C.RUN_DIR };
	if (variant != 'missing') ctx.monitor = variant == 'null' ? null : { busy: variant == 'busy' };
	let dir = ctx.root + C.RUN_DIR;
	check(variant + ': setup', sys.mkdir_p(dir));
	log.set_run_dir(dir);
	let original = { state: 'running', since: 12, future_field: { keep: [ 1, 2 ] }, node_ip: '203.0.113.1' };
	state.write(dir, original);
	let before = time();
	let stopping = daemon.write_stopping(ctx);
	check(variant + ': intent and preserved snapshot published immediately',
		ctx.stopping_requested && stopping.state == 'stopping' && stopping.since >= before &&
		stopping.future_field.keep[1] == 2 && stopping.node_ip == original.node_ip);
	let bytes = fs.readfile(dir + '/' + C.STATE_FILE);
	check(variant + ': repeated stop preserves original timestamp and bytes',
		daemon.write_stopping(ctx) == stopping && fs.readfile(dir + '/' + C.STATE_FILE) == bytes);
	check(variant + ': reload completion cannot replace any stopping fields',
		state.write(dir, { state: 'running', since: 999, node_ip: '203.0.113.2' }) &&
		fs.readfile(dir + '/' + C.STATE_FILE) == bytes);
	let d = monitor.create_daemon({ ctx, state: original });
	// A forbidden tick would try to acquire a lock and observe a missing snapshot.
	d.busy = variant == 'busy';
	monitor.tick(d);
	check(variant + ': monitor tick starts no observation after intent', d.busy == (variant == 'busy'));
	for (let error in [ null, 'in-flight action failed' ]) {
		d.busy = true;
		let closed = false, unlocked = false, rescheduled = false;
		d.interval = { set: () => { rescheduled = true; } };
		let lock = { lock: () => { unlocked = true; return true; }, close: () => { closed = true; } };
		monitor.finish_tick(d, { state: 'running', node_ip: 'changed' },
			{ events: [], actions: [ 'set_tier:T2' ] }, lock, 0, error);
		let outcome = error == null ? 'success' : 'failure';
		check(variant + ': completion ' + outcome + ' preserves stop and releases busy/lock',
			!d.busy && unlocked && closed && !rescheduled && d.immediate == null &&
			fs.readfile(dir + '/' + C.STATE_FILE) == bytes);
	}
	check(variant + ': persist_state cannot change stopping',
		monitor.persist_state(d, { state: 'running' }) && fs.readfile(dir + '/' + C.STATE_FILE) == bytes);
	let completed = false;
	monitor.run_actions(d, {}, [ 'forbidden-new-action' ], 0, error => { completed = error == null; });
	check(variant + ': queued monitor action does not start', completed);
	let events = fs.readfile(dir + '/' + C.EVENTS_FILE) ?? '';
	check(variant + ': no START_FAILED during action completion', index(events, 'START_FAILED') < 0);
	check(variant + ': in-flight failure remains observable as CMD_FAILED', index(events, 'CMD_FAILED') >= 0);
	check(variant + ': final stopped remains writable', state.write(dir, { state: 'stopped' }) &&
		state.read(dir).state == 'stopped');
}
for (let ready in [ -1, 0, 1, 4999, 5000, 5001, 5100 ]) {
	let observed = monitor.test_readiness(ready, false);
	check('readiness at ' + ready + 'ms: correct side of 5s deadline', observed.result == (ready <= 5000));
	let stopped = monitor.test_readiness(ready, true);
	check('readiness at ' + ready + 'ms: stop checked before listener', !stopped.result && stopped.elapsed == 0);
}
uloop.done();
''')
	# The event filename is the documented constant; fail loudly if the harness is stale.
	library_path = str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', '')
	env = dict(os.environ, LD_LIBRARY_PATH=library_path)
	subprocess.run([str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(base / 'modules/*.uc'),
		str(driver), '--', str(base / 'roots')], env=env, check=True)
