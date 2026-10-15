'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as sup from 'aetherproxy.supervise';
import * as sys from 'aetherproxy.sys';
import * as C from 'aetherproxy.const';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const CHILD = ROOT + '/tests/stubs/child/child.sh';

export const cases = [
	{ name: 'start stop and pid file lifecycle', expect: 'PASS', kind: 'lifecycle' },
	{ name: 'crash backoff is cancelled by stop', expect: 'PASS', kind: 'cancel-restart' },
	{ name: 'TERM escalates to KILL after grace', expect: 'PASS', kind: 'kill' },
	{ name: 'kill_stale verifies the command line', expect: 'PASS', kind: 'stale' },
	{ name: 'stable runtime resets backoff index', expect: 'PASS', kind: 'stable' }
];

function fail(msg) {
	return `FAIL: ${msg}`;
};

function run_loop(setup) {
	let dir = `/tmp/aether-proxy-supervise-test-${fs.readlink('/proc/self')}-${time()}`;
	if (!sys.mkdir_p(dir))
		return fail(`mkdir: ${sys.error()}`);
	if (!uloop.init())
		return fail('uloop.init failed');

	let result = null;
	let watchdog = uloop.timer(25000, () => {
		result = fail('hard timeout');
		uloop.end();
	});
	setup(dir, v => {
		result = v;
		watchdog.cancel();
		uloop.end();
	});
	uloop.run();
	uloop.done();

	return result ?? fail('event loop returned without result');
};

function make(dir, mode, on_event, backoff, stable_secs) {
	return sup.create({
		name: 'child',
		argv: [ '/bin/sh', CHILD, mode ],
		run_dir: dir,
		backoff: backoff ?? [ 0.2, 0.4 ],
		stable_secs: stable_secs ?? 10,
		on_event
	});
};

export function run(c) {
	if (c.kind == 'lifecycle') {
		return run_loop((dir, done) => {
			let s = make(dir, 'hold', null);
		s.start();
		let pid = s.pid();
		if (!pid || fs.readfile(`${dir}/child.pid`) != `${pid}\n`)
			return done(fail('pid file was not written'));
		uloop.timer(100, () => s.stop(() => {
			if (fs.stat(`${dir}/child.pid`) != null || s.running())
				done(fail('pid file or process remained after stop'));
			else
				done('PASS');
		}));
	});
	}

	if (c.kind == 'cancel-restart') {
		return run_loop((dir, done) => {
			let crashes = 0, restarts = 0, s;
			s = make(dir, 'crash', (kind) => {
				if (kind == 'crashed') {
					crashes++;
					s.stop(() => uloop.timer(350, () => done(restarts == 0 && crashes == 1 ? 'PASS' : fail('restart was not cancelled'))));
				}
				if (kind == 'restarting')
					restarts++;
			});
			s.start();
		});
	}

	if (c.kind == 'kill') {
		return run_loop((dir, done) => {
			let s = make(dir, 'ignore-term', null);
			s.start();
			uloop.timer(100, () => s.stop(() => done(!s.running() ? 'PASS' : fail('process survived KILL'))));
		});
	}

	if (c.kind == 'stale') {
		return run_loop((dir, done) => {
			let proc = uloop.process('/bin/sh', [ CHILD, 'ignore-term' ], null, () => {});
			let pid = proc.pid();
			if (!sys.write_atomic(`${dir}/child.pid`, `${pid}\n`))
				return done(fail(`pid file write: ${sys.error()}`));
			uloop.timer(100, () => {
				let wrong = sup.kill_stale(dir, 'child', 'does-not-match');
				if (wrong.ok || !fs.stat(`${C.PROC_DIR}/${pid}`)) {
					sys.run([ 'kill', '-KILL', `${pid}` ], { quiet: true });
					done(fail('mismatch was not safely rejected'));
					return;
				}
				let killed = sup.kill_stale(dir, 'child', 'sleep');
				uloop.timer(100, () => done(killed.ok && !fs.stat(`${C.PROC_DIR}/${pid}`) ? 'PASS' : fail(`matching process not stopped: ${killed.detail}`)));
			});
		});
	}

	if (c.kind == 'stable') {
		return run_loop((dir, done) => {
			let crash_delays = [], crashes = 0, s;
			s = sup.create({ name: 'child', argv: [ '/bin/sh', CHILD, 'crash' ], run_dir: dir,
				backoff: [ 0.05, 0.2 ], stable_secs: 0.04, on_event: (kind, info) => {
				if (kind == 'crashed') {
					push(crash_delays, info.restart_in);
					crashes++;
					if (crashes == 3)
						s.stop(() => done(crash_delays[0] == 0.05 && crash_delays[1] == 0.05 && crash_delays[2] == 0.05 ? 'PASS' : fail(`stable reset delays ${sprintf('%.J', crash_delays)}`)));
				}
			} });
			s.start();
		});
	}

	return fail('unknown test case');
};
