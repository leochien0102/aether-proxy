'use strict';

// Process timeout regressions, including rc.common's inherited SIGTERM ignore (docs/12 rule 2).
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
		name: 'timer diagnostic filtering preserves identical command stderr',
		expect: 'PASS',
		kind: 'exit',
		argv: [ 'sh', '-c', 'printf "\\nTerminated\\nKilled\\nNo such process\\n\\n" >&2; exit 7' ],
		opts: { timeout: 10 },
		stdout: '',
		stderr: '\nTerminated\nKilled\nNo such process\n\n',
		code: 7
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
		name: 'inherited ignored TERM: true returns within 5s without timer residue',
		expect: 'PASS',
		kind: 'inherited',
		argv: [ 'true' ],
		timeout: 10,
		code: 0,
		limit: 5
	},
	{
		name: 'inherited ignored TERM: timeout returns 124 within 5s without timer residue',
		expect: 'PASS',
		kind: 'inherited',
		argv: [ 'sleep', '30' ],
		timeout: 1,
		code: 124,
		limit: 5
	},
	{
		name: 'timeout delivers TERM before KILL and reaps grace timer',
		expect: 'PASS',
		kind: 'term_first'
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

// Only sleeps in one session count: suites running in parallel start sleeps of their own.
function sleeper_pids(durations, sid) {
	let r = sys.run([ 'ps', '-C', 'sleep', '-o', 'pid=,sid=,args=' ], { quiet: true });
	let pids = [];
	// ps -C returns 1 when no sleep exists; any other failure must not fake an empty table.
	if (r.code != 0 && (r.code != 1 || r.stderr != ''))
		die(sprintf('cannot inspect sleep processes: %.J', r));

	for (let line in split(trim(r.stdout ?? ''), '\n')) {
		let fields = match(trim(line), /^([0-9]+) +([0-9]+) sleep ([0-9]+)$/);
		if (fields && +fields[2] == sid && index(durations, +fields[3]) >= 0)
			push(pids, fields[1]);
	}

	return pids;
}

// Run one sys.run in another interpreter in its own session (setsid -w waits for it).
// Timer sleeps keep that session even after they are reparented, so the residue scan sees
// this call's sleeps only. ignore_term models rc.common's inherited TERM ignore; doing that
// in the test runner itself would contaminate later cases.
function session_run(argv, opts, durations, ignore_term) {
	let code = "import * as sys from 'aetherproxy.sys'; import * as fs from 'fs'; " +
		'let start = clock(true); ' +
		`let result = sys.run(${sprintf('%.J', argv)}, ${sprintf('%.J', opts)}); ` +
		'let end = clock(true); ' +
		"print(sprintf('%.J', { result, sid: +fs.readlink('/proc/self'), " +
		'elapsed: end[0] - start[0] + (end[1] - start[1]) / 1000000000.0 }));';
	let shell = ignore_term ? [ 'sh', '-c', 'trap \'\' TERM; exec "$@"', 'sh' ] : [];
	let child = sys.run([ 'setsid', '-w', ...shell, 'tests/host/ucode', '-e', code ], { quiet: true });
	if (child.code != 0)
		return { error: sprintf('child %.J', child) };
	let measured = json(child.stdout);
	measured.residue = sleeper_pids(durations, measured.sid);
	return measured;
}

function failed(detail) {
	return 'FAIL: ' + detail;
}

// The limits sit at half of what the regression costs (waiting out the 10 s timeout, or the
// 30 s sleep): a loaded host must not fail them, the regression still does.
function inherited_term_case(c) {
	let measured = session_run(c.argv, { timeout: c.timeout, quiet: true }, [ 1, 10, 30 ], true);
	if (measured.error)
		return failed(measured.error);
	let r = measured.result;
	printf('INFO  %s: %.3fs, code %d, timed_out %J\n', c.name, measured.elapsed, r.code, r.timed_out);
	if (r.code != c.code || r.timed_out != (c.code == 124) || measured.elapsed >= c.limit)
		return failed(sprintf('measured %.J', measured));
	if (r.stdout != '' || r.stderr != '')
		return failed(sprintf('unexpected inherited-command output %.J', r));
	if (length(measured.residue))
		return failed(sprintf('unreaped sleepers %.J', measured.residue));
	return 'PASS';
}

function term_first_case() {
	let path = `tests/unit/term-first.${fs.readlink('/proc/self')}`;
	let script = 'trap \'printf TERM > "$1"; exit 0\' TERM; while :; do :; done';
	let measured = session_run([ 'sh', '-c', script, 'sh', path ], { timeout: 1, quiet: true }, [ 1 ]);
	if (measured.error)
		return failed(measured.error);
	let r = measured.result, elapsed = measured.elapsed;
	let received = fs.readfile(path);
	if (received != null && !fs.unlink(path))
		return failed(`cannot remove ${path}: ${fs.error() ?? 'unknown error'}`);
	if (r.code != 124 || !r.timed_out || received != 'TERM')
		return failed(sprintf('result %.J, first signal %J', r, received));
	// The command exits on TERM, so the wrapper must cancel the 1 s grace sleep, not wait it out.
	if (elapsed >= 1.7)
		return failed(sprintf('returned after %.2fs; the grace sleep was waited out', elapsed));
	return length(measured.residue) ? failed(sprintf('unreaped grace sleepers %.J', measured.residue)) : 'PASS';
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
		let measured = session_run(c.argv, c.opts, [ 30 ]);
		if (measured.error)
			return failed(measured.error);
		let r = measured.result;

		if (r.code != 0 || r.stdout != 'done' || r.timed_out || measured.elapsed >= 1 || length(measured.residue))
			return failed(sprintf('measured %.J', measured));

		return 'PASS';
	}

	if (c.kind == 'inherited')
		return inherited_term_case(c);

	if (c.kind == 'term_first')
		return term_first_case();

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
