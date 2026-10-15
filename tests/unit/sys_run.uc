'use strict';

import * as sys from 'aetherproxy.sys';
import * as fs from 'fs';
import * as uloop from 'uloop';

export const cases = [
	{
		name: 'printf arguments without timeout',
		expect: 'PASS',
		kind: 'result',
		argv: [ 'printf', '%s|', 'rule', 'help' ],
		stdout: 'rule|help|'
	},
	{
		name: 'printf arguments with timeout',
		expect: 'PASS',
		kind: 'result',
		argv: [ 'printf', '%s|', 'rule', 'help' ],
		opts: { timeout: 5 },
		stdout: 'rule|help|'
	},
	{
		name: 'shell metacharacters remain literal',
		expect: 'PASS',
		kind: 'result',
		argv: [ 'printf', '%s|', 'has space', "it's", '$(not-a-command)', 'line1\nline2' ],
		opts: { timeout: 5 },
		stdout: "has space|it's|$(not-a-command)|line1\nline2|"
	},
	{
		name: 'separate stdout stderr and exit status',
		expect: 'PASS',
		kind: 'exit',
		argv: [ 'sh', '-c', 'echo out; echo err >&2; exit 3' ],
		stdout: 'out\n',
		stderr: 'err\n',
		code: 3
	},
	{
		name: 'timeout kills command and reports timeout',
		expect: 'PASS',
		kind: 'timeout',
		argv: [ 'sleep', '5' ],
		opts: { timeout: 1 }
	},
	{
		name: 'command exit 124 is not a timeout',
		expect: 'PASS',
		kind: 'exit',
		argv: [ 'sh', '-c', 'exit 124' ],
		opts: { timeout: 5 },
		code: 124,
		stdout: '',
		stderr: ''
	},
	{
		name: 'quick command stops timer without leaving sleep',
		expect: 'PASS',
		kind: 'quick',
		argv: [ 'printf', 'done' ],
		opts: { timeout: 30 }
	},
	{
		name: 'a child exiting mid-run (SIGCHLD) does not lose the result',
		expect: 'PASS',
		kind: 'sigchld'
	},
	{
		name: 'lock fd is not inherited by spawned children',
		expect: 'PASS',
		kind: 'lock_cloexec'
	},
	{
		name: 'timeout implementation uses integer sleep only',
		expect: 'PASS',
		kind: 'source'
	}
];

function clock_seconds() {
	let r = sys.run([ 'date', '+%s.%N' ], { quiet: true });
	return r.code == 0 ? +r.stdout : null;
}

function sleep_30_count() {
	let r = sys.run([ 'ps', '-C', 'sleep', '-o', 'args=' ], { quiet: true });
	let count = 0;

	for (let line in split(trim(r.stdout ?? ''), '\n'))
		if (trim(line) == 'sleep 30')
			count++;

	return count;
}

function failed(detail) {
	return 'FAIL: ' + detail;
}

export function run(c) {
	if (c.kind == 'result') {
		let r = sys.run(c.argv, c.opts);

		if (r.code != 0 || r.stdout != c.stdout || r.stderr != '' || r.timed_out)
			return failed(sprintf('unexpected result %.J', r));

		return 'PASS';
	}

	if (c.kind == 'exit') {
		let r = sys.run(c.argv, c.opts);

		if (r.code != c.code || r.stdout != c.stdout || r.stderr != c.stderr || r.timed_out)
			return failed(sprintf('unexpected result %.J', r));

		return 'PASS';
	}

	if (c.kind == 'timeout') {
		let start = clock_seconds();
		let r = sys.run(c.argv, c.opts);
		let elapsed = clock_seconds() - start;

		if (r.code != 124 || !r.timed_out || elapsed >= 3)
			return failed(sprintf('result %.J, elapsed %.3f seconds', r, elapsed));

		return 'PASS';
	}

	if (c.kind == 'quick') {
		let before = sleep_30_count();
		let start = clock_seconds();
		let r = sys.run(c.argv, c.opts);
		let elapsed = clock_seconds() - start;
		let after = sleep_30_count();

		if (r.code != 0 || r.stdout != 'done' || r.timed_out || elapsed >= 1 || before != after)
			return failed(sprintf('result %.J, elapsed %.3f seconds, sleep count %d -> %d', r, elapsed, before, after));

		return 'PASS';
	}

	if (c.kind == 'sigchld') {
		uloop.init();
		for (let i = 0; i < 3; i++) {
			uloop.process('/bin/sleep', [ '0.1' ], {}, () => {});
			let r = sys.run([ 'sh', '-c', 'sleep 0.4; echo ok' ], { quiet: true });

			if (r.code != 0 || r.stdout != 'ok\n')
				return failed(sprintf('round %d: %.J', i, r));
			uloop.run(200);
		}

		return 'PASS';
	}

	if (c.kind == 'lock_cloexec') {
		let path = `/tmp/aether-proxy-test-lock.${fs.readlink('/proc/self')}`;
		let lock = sys.lock(path);

		if (lock == null)
			return failed(`cannot take ${path}: ${sys.error()}`);
		uloop.init();
		let child = uloop.process('/bin/sleep', [ '2' ], {}, () => {});
		uloop.run(200);	// let the child get past exec(); before exec it still holds the fd
		lock.close();
		let again = sys.lock(path);
		child.delete();
		fs.unlink(path);
		if (again == null)
			return failed('lock still held after close: the child inherited the fd');
		again.close();

		return 'PASS';
	}

	if (c.kind == 'source') {
		let source = fs.readfile('aether-proxy/src/lib/sys.uc');

		if (source == null)
			return failed('cannot read sys.uc source');
		if (match(source, /sleep +[0-9]*\./))
			return failed('fractional sleep duration found in sys.uc');

		return 'PASS';
	}

	return failed('unknown test kind');
};
