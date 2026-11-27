'use strict';

// T16.84: bounded timer handshake for sys.run — no unbounded wait, no busy-wait,
// no process residue, sibling sentinels preserved.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const PREFIX = ROOT + '/tests/host/prefix';
const UCODE_BIN = PREFIX + '/bin/ucode';
const UCODE_LIB = PREFIX + '/lib';
const LIB_DIR = ROOT + '/aether-proxy/src/lib';
const REAL_SH = '/bin/sh';
const REAL_SLEEP = '/bin/sleep';

export const cases = [
	{ name: 'partial child S frame preserves success', expect: 'PASS', kind: 'partial_frame_s_0' },
	{ name: 'partial child S frame preserves nonzero exit', expect: 'PASS', kind: 'partial_frame_s_7' },
	{ name: 'partial child G frame preserves success', expect: 'PASS', kind: 'partial_frame_g_0' },
	{ name: 'partial child G frame preserves nonzero exit', expect: 'PASS', kind: 'partial_frame_g_7' },
	{ name: 'partial child S PID preserves success', expect: 'PASS', kind: 'partial_frame_s_0', cut: 'half' },
	{ name: 'partial child S PID preserves nonzero exit', expect: 'PASS', kind: 'partial_frame_s_7', cut: 'half' },
	{ name: 'partial child G PID preserves success', expect: 'PASS', kind: 'partial_frame_g_0', cut: 'half' },
	{ name: 'partial child G PID preserves nonzero exit', expect: 'PASS', kind: 'partial_frame_g_7', cut: 'half' },
	{ name: 'child S PID without frame suffix preserves success', expect: 'PASS', kind: 'partial_frame_s_0', cut: 'full' },
	{ name: 'child S PID without frame suffix preserves nonzero exit', expect: 'PASS', kind: 'partial_frame_s_7', cut: 'full' },
	{ name: 'child G PID without frame suffix preserves success', expect: 'PASS', kind: 'partial_frame_g_0', cut: 'full' },
	{ name: 'child G PID without frame suffix preserves nonzero exit', expect: 'PASS', kind: 'partial_frame_g_7', cut: 'full' },
	{ name: 'missing all G frames still fails handshake', expect: 'PASS', kind: 'missing_frame_g' },
	{ name: 'missing D frame still fails handshake', expect: 'PASS', kind: 'missing_frame_d' },
	{
		name: 'normal fast command returns promptly without waiting for timeout',
		expect: 'PASS',
		kind: 'normal_fast'
	},
	{
		name: 'normal command exit 124 is distinct from timeout and handshake failure',
		expect: 'PASS',
		kind: 'normal_exit_124'
	},
	{
		name: 'normal timeout delivers TERM before KILL and cancels grace sleep',
		expect: 'PASS',
		kind: 'normal_timeout_term'
	},
	{
		name: 'normal timeout escalates TERM to KILL when TERM is ignored',
		expect: 'PASS',
		kind: 'normal_timeout_kill'
	},
	{
		name: 'first PID unpublished when runner already finished',
		expect: 'PASS',
		kind: 'first_pid_runner_done'
	},
	{
		name: 'first PID unpublished while runner is still running',
		expect: 'PASS',
		kind: 'first_pid_runner_running'
	},
	{
		name: 'grace PID unpublished when runner already finished',
		expect: 'PASS',
		kind: 'grace_pid_runner_done'
	},
	{
		name: 'grace PID unpublished while runner is still running (ignoring TERM)',
		expect: 'PASS',
		kind: 'grace_pid_runner_running'
	},
	{
		name: 'timer exits early when runner already finished',
		expect: 'PASS',
		kind: 'timer_early_runner_done'
	},
	{
		name: 'timer exits early while runner is still running',
		expect: 'PASS',
		kind: 'timer_early_runner_running'
	},
	{
		name: 'stage 1 publisher blocked on FIFO when timer exits (never unlocked)',
		expect: 'PASS',
		kind: 'pre_publish_sleep_timer_exit'
	},
	{
		name: 'stage 2 grace publisher blocked on FIFO when timer exits (never unlocked)',
		expect: 'PASS',
		kind: 'pre_publish_grace_timer_exit'
	},
	{
		name: 'no grace needed: runner finishes normally while grace path is unread FIFO',
		expect: 'PASS',
		kind: 'no_grace_needed_fifo_no_reader'
	},
	{
		name: 'timer kill status never becomes a handshake failure',
		expect: 'PASS',
		kind: 'timer_kill_after_runner_success'
	}
];

function failed(detail) {
	return 'FAIL: ' + detail;
}

function random_hex(n) {
	let fp = fs.open('/dev/urandom', 'r');
	if (fp == null)
		die(`cannot open /dev/urandom: ${fs.error() ?? 'unknown error'}`);
	let bytes = fp.read(n);
	let rerr = fs.error();
	let closed = fp.close();
	if (!closed || bytes == null || length(bytes) != n)
		die(`cannot read /dev/urandom: ${rerr ?? fs.error() ?? 'unknown error'}`);
	let out = '';
	for (let i = 0; i < n; i++)
		out += sprintf('%02x', ord(bytes, i));
	return out;
}

// Exclusively create a 0700 directory without ever deleting a pre-existing path.
function with_exclusive_dir(preferred, fn) {
	let dir = null;
	for (let attempt = 0; attempt < 16; attempt++) {
		let candidate = attempt == 0 ? preferred : `${preferred}.${random_hex(6)}`;
		if (fs.mkdir(candidate, 0700)) {
			dir = candidate;
			break;
		}
		let err = fs.error() ?? 'unknown error';
		if (err != 'File exists')
			die(`cannot create sandbox ${candidate}: ${err}`);
	}
	if (dir == null)
		die(`cannot exclusively create sandbox near ${preferred}: too many collisions`);

	let res = null;
	let err = null;
	try {
		res = fn(dir);
	}
	catch (e) {
		err = e;
	}
	sys.run([ 'chmod', '-R', 'u+rwx', dir ], { quiet: true });
	sys.run([ 'rm', '-rf', dir ], { quiet: true });
	if (err != null)
		die(`${err}`);
	return res;
}

function with_sandbox(tag, fn) {
	let pid = fs.readlink('/proc/self') ?? 'x';
	let preferred = `/tmp/aether-proxy-t1684-${tag}-${pid}`;
	return with_exclusive_dir(preferred, base => {
		let tmp_root = `${base}/tmp`;
		let bin_dir = `${base}/bin`;
		if (!fs.mkdir(tmp_root, 0700) || !fs.mkdir(bin_dir, 0700))
			die(`cannot create sandbox subdirs in ${base}: ${fs.error() ?? 'unknown error'}`);
		return fn({ base, tmp_root, bin_dir });
	});
}

function build_modules(base, tmp_dir) {
	let mod_root = `${base}/modules`;
	let pkg_dir = `${mod_root}/aetherproxy`;
	if (!fs.mkdir(mod_root, 0700) || !fs.mkdir(pkg_dir, 0700))
		die(`cannot create module dir ${pkg_dir}: ${fs.error() ?? 'unknown error'}`);

	for (let entry in fs.lsdir(LIB_DIR) ?? []) {
		if (entry == 'const.uc')
			continue;
		let src = `${LIB_DIR}/${entry}`;
		let dst = `${pkg_dir}/${entry}`;
		if (!fs.symlink(src, dst))
			die(`cannot symlink ${src} -> ${dst}: ${fs.error() ?? 'unknown error'}`);
	}

	let const_src = fs.readfile(`${LIB_DIR}/const.uc`);
	if (const_src == null)
		die('cannot read const.uc');
	let patched = replace(const_src, /export const TMP_DIR = '[^']+';/, `export const TMP_DIR = '${tmp_dir}';`);
	if (patched == const_src)
		die('failed to patch TMP_DIR in const.uc');
	if (fs.writefile(`${pkg_dir}/const.uc`, patched) == null)
		die('cannot write patched const.uc');

	return mod_root;
}

function plant_file_sentinels(tmp_root) {
	let sentinels = {
		'sentinel.txt': 'keep-plain\n',
		'aether-proxy-run.sentinel': 'keep-run\n',
		'aether-proxy-run.999999.1': 'keep-legacy\n'
	};
	for (let name in keys(sentinels)) {
		if (fs.writefile(`${tmp_root}/${name}`, sentinels[name]) == null)
			die(`cannot write sentinel ${name}`);
	}
	let other_dir = `${tmp_root}/aether-proxy-run.otherdir`;
	if (!fs.mkdir(other_dir, 0700) || fs.writefile(`${other_dir}/keep.txt`, 'keep-nested\n') == null)
		die('cannot create nested sentinel');
	return sentinels;
}

function check_file_sentinels(tmp_root, sentinels) {
	let expected = sort([ ...keys(sentinels), 'aether-proxy-run.otherdir' ]);
	let actual = sort(fs.lsdir(tmp_root) ?? []);
	if (sprintf('%.J', actual) != sprintf('%.J', expected))
		return `tmp_root entries mismatch: expected ${sprintf('%.J', expected)}, got ${sprintf('%.J', actual)}`;
	for (let name in keys(sentinels)) {
		let got = fs.readfile(`${tmp_root}/${name}`);
		if (got != sentinels[name])
			return `sentinel ${name} modified: ${sprintf('%.J', got)}`;
	}
	let nested = fs.readfile(`${tmp_root}/aether-proxy-run.otherdir/keep.txt`);
	if (nested != 'keep-nested\n')
		return `nested sentinel modified: ${sprintf('%.J', nested)}`;
	return null;
}

function write_exec(path, body) {
	if (fs.writefile(path, body) == null)
		die(`cannot write ${path}`);
	if (!fs.chmod(path, 0700))
		die(`cannot chmod ${path}`);
}

function kill_session_residue(sid) {
	if (sid == null || sid <= 0)
		return;
	for (let entry in fs.lsdir('/proc') ?? []) {
		if (!match(entry, /^[0-9]+$/))
			continue;
		let stat = fs.readfile(`/proc/${entry}/stat`);
		if (stat == null)
			continue;
		let rp = rindex(stat, ')');
		if (rp < 0)
			continue;
		let rest = split(trim(substr(stat, rp + 1)), / +/);
		if (+rest[3] == sid)
			sys.run([ 'kill', '-KILL', entry ], { quiet: true });
	}
}

// Run one sys.run inside an isolated ucode process in its own session (setsid -w),
// alongside a live sibling sentinel process. Observation of session residue, sibling
// sentinel liveness, and private dir reclamation all happen BEFORE any fixture cleanup.
// The outer `timeout` is strictly a safety guard for the test runner (e.g. before-fix hangs),
// never the production convergence mechanism.
function run_isolated_case(sb, cfg) {
	let sentinels = plant_file_sentinels(sb.tmp_root);
	let mod_root = build_modules(sb.base, sb.tmp_root);
	let sid_file = `${sb.base}/session.sid`;
	let res_file = `${sb.base}/obs.json`;
	let sentinel_pid_file = `${sb.base}/sentinel.pid`;

	let start_sentinel = sys.run([
		'sh', '-c',
		`exec ${REAL_SLEEP} 300 >/dev/null 2>&1 & printf "%s" "$!" >"$1"`,
		'sh', sentinel_pid_file
	], { quiet: true });
	if (start_sentinel.code != 0)
		die(`cannot start sibling sentinel: ${sprintf('%.J', start_sentinel)}`);
	let sentinel_pid = trim(fs.readfile(sentinel_pid_file) ?? '');
	if (!match(sentinel_pid, /^[0-9]+$/))
		die(`invalid sibling sentinel pid: ${sprintf('%.J', sentinel_pid)}`);

	let worker_uc = join('\n', [
		"import * as sys from 'aetherproxy.sys';",
		"import * as fs from 'fs';",
		`let self_pid = +fs.readlink('/proc/self');`,
		`fs.writefile(${sprintf('%.J', sid_file)}, '' + self_pid);`,
		'function scan_session(sid, self_pid) {',
		'  let entries = [];',
		'  let in_sid = {};',
		'  in_sid[self_pid] = true;',
		"  for (let entry in fs.lsdir('/proc') ?? []) {",
		'    if (!match(entry, /^[0-9]+$/)) continue;',
		'    let p = +entry;',
		'    if (p == self_pid) continue;',
		'    let stat = fs.readfile(`/proc/${entry}/stat`);',
		'    if (stat == null) continue;',
		"    let rp = rindex(stat, ')');",
		'    if (rp < 0) continue;',
		"    let lp = index(stat, '(');",
		'    let comm = lp >= 0 ? substr(stat, lp + 1, rp - lp - 1) : "";',
		'    let rest = split(trim(substr(stat, rp + 1)), / +/);',
		'    if (+rest[3] == sid) {',
		'      in_sid[p] = true;',
		'      push(entries, { pid: p, ppid: +rest[1], comm, state: rest[0] });',
		'    }',
		'  }',
		'  // A dead zombie reparented outside our session (to init/subreaper after external',
		'  // SIGKILL of timer) cannot be reaped by sys.run; any live proc or in-session',
		'  // zombie is real residue.',
		'  return filter(entries, e => e.state != "Z" || in_sid[e.ppid]);',
		'}',
		'let t0 = clock(true);',
		`let r = sys.run(${sprintf('%.J', cfg.argv)}, ${sprintf('%.J', cfg.opts)});`,
		'let t1 = clock(true);',
		'let elapsed = t1[0] - t0[0] + (t1[1] - t0[1]) / 1000000000.0;',
		'let residue = scan_session(self_pid, self_pid);',
		`let sentinel_stat = fs.readfile('/proc/${sentinel_pid}/stat');`,
		'let sentinel_alive = sentinel_stat != null && index(sentinel_stat, ") Z ") < 0;',
		`let tmp_entries = sort(fs.lsdir(${sprintf('%.J', sb.tmp_root)}) ?? []);`,
		`fs.writefile(${sprintf('%.J', res_file)}, sprintf('%.J', {`,
		'  sid: self_pid, elapsed, result: r, residue, sentinel_alive, tmp_entries',
		'}));'
	]);
	let worker_path = `${sb.base}/worker.uc`;
	fs.writefile(worker_path, worker_uc);

	let guard_s = cfg.guard_s ?? 6;
	let path_prefix = cfg.use_bin ? `${sb.bin_dir}:` : '';
	let inner_cmd = cfg.ignore_term
		? `${REAL_SH} -c 'trap "" TERM; exec "$@"' sh `
		: '';
	let launch_sh = join('\n', [
		`LD_LIBRARY_PATH=${sprintf("'%s'", UCODE_LIB)}`,
		'export LD_LIBRARY_PATH',
		`PATH=${sprintf("'%s'", path_prefix)}"$PATH"`,
		'export PATH',
		`exec timeout -k 1 ${guard_s} setsid -w ${inner_cmd}${sprintf("'%s'", UCODE_BIN)} -L ${sprintf("'%s/*.uc'", mod_root)} -L ${sprintf("'%s/*/*.uc'", mod_root)} -L ${sprintf("'%s/ucode/*.so'", UCODE_LIB)} ${sprintf("'%s'", worker_path)}`
	]);

	let outer = sys.run([ REAL_SH, '-c', launch_sh ], { quiet: true, timeout: guard_s + 5 });
	let obs_raw = fs.readfile(res_file);
	let obs = obs_raw != null ? json(obs_raw) : null;
	let file_err = check_file_sentinels(sb.tmp_root, sentinels);

	// Fallback cleanup runs strictly AFTER all pre-cleanup observations above are captured.
	let sid_raw = trim(fs.readfile(sid_file) ?? '');
	if (match(sid_raw, /^[0-9]+$/))
		kill_session_residue(+sid_raw);
	sys.run([ 'kill', '-KILL', sentinel_pid ], { quiet: true });

	if (outer.code == 124 || outer.code == 137)
		return { error: `hit outer test guard (${guard_s}s): production code did not converge (outer exit ${outer.code})` };
	if (outer.code != 0 || obs == null)
		return { error: `isolated runner failed: outer=${sprintf('%.J', outer)}, obs=${sprintf('%.J', obs_raw)}` };

	obs.file_err = file_err;
	return obs;
}

function check_common_invariants(label, obs) {
	if (obs.error)
		return failed(obs.error);
	let r = obs.result;
	printf('INFO  %s: %.3fs, code %d, timed_out %J, residue %d, sentinel %J\n',
		label, obs.elapsed, r.code, r.timed_out, length(obs.residue), obs.sentinel_alive);
	if (length(obs.residue) != 0)
		return failed(`process residue before cleanup: ${sprintf('%.J', obs.residue)}`);
	if (!obs.sentinel_alive)
		return failed('sibling sentinel process died');
	if (obs.file_err != null)
		return failed(obs.file_err);
	return null;
}

function normal_fast_case() {
	return with_sandbox('norm-fast', sb => {
		let obs = run_isolated_case(sb, {
			argv: [ 'printf', 'fast-ok' ],
			opts: { timeout: 30, quiet: true },
			guard_s: 6
		});
		let err = check_common_invariants('normal_fast', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != 0 || r.timed_out || r.stdout != 'fast-ok' || r.stderr != '' || obs.elapsed >= 1.5)
			return failed(`unexpected fast result: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function normal_exit_124_case() {
	return with_sandbox('norm-124', sb => {
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', 'printf out124; printf err124 >&2; exit 124' ],
			opts: { timeout: 15, quiet: true },
			guard_s: 6
		});
		let err = check_common_invariants('normal_exit_124', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != 124 || r.timed_out || r.stdout != 'out124' || r.stderr != 'err124' || obs.elapsed >= 1.5)
			return failed(`unexpected exit 124 result: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function normal_timeout_term_case() {
	return with_sandbox('norm-term', sb => {
		let mark = `${sb.base}/got-term`;
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', 'trap \'printf TERM >"$1"; exit 0\' TERM; while :; do :; done', 'sh', mark ],
			opts: { timeout: 1, quiet: true },
			guard_s: 6
		});
		let err = check_common_invariants('normal_timeout_term', obs);
		if (err)
			return err;
		let r = obs.result;
		let got = fs.readfile(mark);
		if (r.code != 124 || !r.timed_out || got != 'TERM' || obs.elapsed >= 1.7)
			return failed(`unexpected TERM-first timeout: ${sprintf('%.J', obs)}, mark=${sprintf('%.J', got)}`);
		return 'PASS';
	});
}

function normal_timeout_kill_case() {
	return with_sandbox('norm-kill', sb => {
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', `trap '' TERM; exec ${REAL_SLEEP} 30` ],
			opts: { timeout: 1, quiet: true },
			guard_s: 6
		});
		let err = check_common_invariants('normal_timeout_kill', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != 124 || !r.timed_out || obs.elapsed < 1.5 || obs.elapsed >= 3.5)
			return failed(`unexpected TERM->KILL timeout: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

// Lock $d/sleep to 0400 before timer publishes its first sleep PID:
// - Pre-creating $d/sleep as 0400 lets non-fatal `wr "$sleeper" ""` proceed so runner
//   starts while timer's `wrl "$sleeper" "$t"` deterministically fails with EACCES.
// - On baseline (which uses fatal `: >"$sleeper"`), runner also clears & locks $d/sleep
//   if writable, proving baseline fails/hangs on the same fault.
function install_first_pid_fault_shims(sb) {
	write_exec(`${sb.bin_dir}/sh`, join('\n', [
		`#!${REAL_SH}`,
		'if [ "$1" = "-c" ] && [ "$3" = "sh" ] && [ -d "$4" ]; then',
		'  case "$4" in',
		`    ${sb.tmp_root}/aether-proxy-run.*) : >"$4/sleep"; chmod 0400 "$4/sleep" ;;`,
		'  esac',
		'fi',
		`exec ${REAL_SH} "$@"`
	]) + '\n');
}

function first_pid_runner_done_case() {
	return with_sandbox('first-done', sb => {
		install_first_pid_fault_shims(sb);
		let started = `${sb.base}/runner.started`;
		let runner_sh = join('\n', [
			"trap '' TERM",
			`: >${sprintf("'%s'", started)}`,
			'd=$(dirname "$(readlink -f /proc/$$/fd/1)")',
			'if [ -w "$d/sleep" ]; then : >"$d/sleep"; chmod 0400 "$d/sleep"; fi',
			'printf fast-before-fault'
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			ignore_term: true,
			guard_s: 6
		});
		let err = check_common_invariants('first_pid_runner_done', obs);
		if (err)
			return err;
		if (fs.lstat(started) == null)
			return failed('runner did not start');
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stdout != 'fast-before-fault' || r.stderr == '' || obs.elapsed >= 2.0)
			return failed(`expected bounded handshake error: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function first_pid_runner_running_case() {
	return with_sandbox('first-run', sb => {
		install_first_pid_fault_shims(sb);
		let started = `${sb.base}/runner.started`;
		let runner_sh = join('\n', [
			"trap '' TERM",
			`: >${sprintf("'%s'", started)}`,
			'd=$(dirname "$(readlink -f /proc/$$/fd/1)")',
			'if [ -w "$d/sleep" ]; then : >"$d/sleep"; chmod 0400 "$d/sleep"; fi',
			`exec ${REAL_SLEEP} 30`
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			ignore_term: true,
			guard_s: 6
		});
		let err = check_common_invariants('first_pid_runner_running', obs);
		if (err)
			return err;
		if (fs.lstat(started) == null)
			return failed('runner did not start');
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 3.0)
			return failed(`expected bounded handshake error: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function grace_pid_runner_done_case() {
	return with_sandbox('grace-done', sb => {
		let grace_locked = `${sb.base}/grace.locked`;
		let stage1_seen = `${sb.base}/stage1.seen`;
		write_exec(`${sb.bin_dir}/sleep`, join('\n', [
			`#!${REAL_SH}`,
			`if [ ! -f ${sprintf("'%s'", stage1_seen)} ]; then`,
			`  : >${sprintf("'%s'", stage1_seen)}`,
			'  d=$(dirname "$(readlink -f "/proc/$PPID/fd/2" 2>/dev/null)")',
			'  if [ -d "$d" ] && [ -f "$d/grace" ]; then',
			'    i=0; while [ ! -s "$d/sleep" ] && [ "$i" -lt 200 ]; do /bin/sleep 0.01; i=$((i + 1)); done',
			'    chmod 0400 "$d/grace"',
			`    : >${sprintf("'%s'", grace_locked)}`,
			'  fi',
			'  exit 0',
			'fi',
			`exec ${REAL_SLEEP} "$@"`
		]) + '\n');

		let runner_sh = join('\n', [
			`trap '${REAL_SLEEP} 0.05; printf done-after-grace-lock; exit 0' TERM`,
			`i=0; while [ ! -f ${sprintf("'%s'", grace_locked)} ] && [ "$i" -lt 300 ]; do ${REAL_SLEEP} 0.01; i=$((i + 1)); done`,
			`while :; do ${REAL_SLEEP} 0.05; done`
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 1, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let err = check_common_invariants('grace_pid_runner_done', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 3.0)
			return failed(`expected bounded grace handshake error: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function grace_pid_runner_running_case() {
	return with_sandbox('grace-run', sb => {
		let grace_locked = `${sb.base}/grace.locked`;
		let stage1_mark = `${sb.base}/stage1.seen`;
		write_exec(`${sb.bin_dir}/sleep`, join('\n', [
			`#!${REAL_SH}`,
			`if [ ! -f ${sprintf("'%s'", stage1_mark)} ]; then`,
			`  : >${sprintf("'%s'", stage1_mark)}`,
			'  d=$(dirname "$(readlink -f "/proc/$PPID/fd/2" 2>/dev/null)")',
			'  if [ -d "$d" ] && [ -f "$d/grace" ]; then',
			'    i=0; while [ ! -s "$d/sleep" ] && [ "$i" -lt 200 ]; do /bin/sleep 0.01; i=$((i + 1)); done',
			'    chmod 0400 "$d/grace"',
			`    : >${sprintf("'%s'", grace_locked)}`,
			'  fi',
			'fi',
			`exec ${REAL_SLEEP} "$@"`
		]) + '\n');

		let runner_sh = join('\n', [
			"trap '' TERM",
			`i=0; while [ ! -f ${sprintf("'%s'", grace_locked)} ] && [ "$i" -lt 300 ]; do ${REAL_SLEEP} 0.01; i=$((i + 1)); done`,
			`exec ${REAL_SLEEP} 30`
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 1, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let err = check_common_invariants('grace_pid_runner_running', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 4.0)
			return failed(`expected bounded grace handshake error while runner ignores TERM: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function timer_early_runner_done_case() {
	return with_sandbox('early-done', sb => {
		let timer_killed = `${sb.base}/timer.killed`;
		let killed_once = `${sb.base}/killed.once`;
		write_exec(`${sb.bin_dir}/sleep`, join('\n', [
			`#!${REAL_SH}`,
			`if [ ! -f ${sprintf("'%s'", killed_once)} ]; then`,
			`  : >${sprintf("'%s'", killed_once)}`,
			'  d=$(dirname "$(readlink -f "/proc/$PPID/fd/2" 2>/dev/null)")',
			'  if [ -d "$d" ] && [ -f "$d/sleep" ]; then',
			'    i=0; while [ ! -s "$d/sleep" ] && [ "$i" -lt 200 ]; do /bin/sleep 0.01; i=$((i + 1)); done',
			'    kill -KILL "$PPID" 2>/dev/null',
			`    : >${sprintf("'%s'", timer_killed)}`,
			'  fi',
			'fi',
			`exec ${REAL_SLEEP} "$@"`
		]) + '\n');

		let runner_sh = join('\n', [
			`i=0; while [ ! -f ${sprintf("'%s'", timer_killed)} ] && [ "$i" -lt 300 ]; do ${REAL_SLEEP} 0.01; i=$((i + 1)); done`,
			'printf done-after-timer-exit'
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			ignore_term: true,
			guard_s: 6
		});
		let err = check_common_invariants('timer_early_runner_done', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 3.0)
			return failed(`expected bounded timer early-exit error: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

function timer_early_runner_running_case() {
	return with_sandbox('early-run', sb => {
		let runner_started = `${sb.base}/runner.started`;
		let killed_once = `${sb.base}/killed.once`;
		write_exec(`${sb.bin_dir}/sleep`, join('\n', [
			`#!${REAL_SH}`,
			`if [ ! -f ${sprintf("'%s'", killed_once)} ]; then`,
			`  : >${sprintf("'%s'", killed_once)}`,
			'  d=$(dirname "$(readlink -f "/proc/$PPID/fd/2" 2>/dev/null)")',
			'  if [ -d "$d" ] && [ -f "$d/sleep" ]; then',
			'    i=0; while [ ! -s "$d/sleep" ] && [ "$i" -lt 200 ]; do /bin/sleep 0.01; i=$((i + 1)); done',
			`    i=0; while [ ! -f ${sprintf("'%s'", runner_started)} ] && [ "$i" -lt 200 ]; do /bin/sleep 0.01; i=$((i + 1)); done`,
			'    kill -KILL "$PPID" 2>/dev/null',
			'  fi',
			'fi',
			`exec ${REAL_SLEEP} "$@"`
		]) + '\n');

		let runner_sh = join('\n', [
			`: >${sprintf("'%s'", runner_started)}`,
			`exec ${REAL_SLEEP} 30`
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			ignore_term: true,
			guard_s: 6
		});
		let err = check_common_invariants('timer_early_runner_running', obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 3.0)
			return failed(`expected bounded timer early-exit error while runner runs: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

// Independent observer helper: waits until a process whose cmdline contains `target_path`
// is actually blocked in kernel `wait_for_partner` (open(FIFO, O_WRONLY) with no reader),
// records publisher & timer PIDs to `reached_file`, SIGKILLs timer (ppid), and exits.
// Crucially: NEVER opens the FIFO to unblock it; sys.run itself must converge and reap.
function write_observer_script(sb, name) {
	let path = `${sb.base}/${name}`;
	write_exec(path, join('\n', [
		`#!${REAL_SH}`,
		'target="$1"; reached="$2"; drain_once="$3"',
		'if [ "$drain_once" = "1" ]; then cat "$target" >/dev/null 2>&1; fi',
		'i=0',
		'while [ "$i" -lt 400 ]; do',
		'  for p in /proc/[0-9]*; do',
		'    pid=${p#/proc/}',
		'    [ "$pid" = "$$" ] && continue',
		'    wchan=$(cat "$p/wchan" 2>/dev/null || true)',
		'    [ "$wchan" = "wait_for_partner" ] || continue',
		'    cmd=$(tr "\\0" " " <"$p/cmdline" 2>/dev/null || true)',
		'    case "$cmd" in',
		'      *"$target"*)',
		'        stat=$(cat "$p/stat" 2>/dev/null || true)',
		'        rest=${stat##*) }',
		'        set -- $rest',
		'        ppid=$2',
		'        if [ -n "$ppid" ] && [ "$ppid" -gt 1 ]; then',
		'          printf "%s %s\\n" "$pid" "$ppid" >"$reached"',
		'          kill -KILL "$ppid" 2>/dev/null',
		'          exit 0',
		'        fi',
		'        ;;',
		'    esac',
		'  done',
		`  ${REAL_SLEEP} 0.01`,
		'  i=$((i + 1))',
		'done',
		'exit 1'
	]) + '\n');
	return path;
}

// Stage 1 publisher blocks forever on FIFO $d/sleep (never unlocked by fixture).
// Independent observer confirms publisher reached `wait_for_partner` and SIGKILLs timer.
function pre_publish_sleep_timer_exit_case() {
	return with_sandbox('prepub-s1', sb => {
		let reached = `${sb.base}/s1.reached`;
		let obs_sh = write_observer_script(sb, 'obs-s1.sh');
		write_exec(`${sb.bin_dir}/sh`, join('\n', [
			`#!${REAL_SH}`,
			'if [ "$1" = "-c" ] && [ "$3" = "sh" ] && [ -d "$4" ]; then',
			'  case "$4" in',
			`    ${sb.tmp_root}/aether-proxy-run.*)`,
			'      mkfifo -m 0600 "$4/sleep"',
			`      setsid ${sprintf("'%s'", obs_sh)} "$4/sleep" ${sprintf("'%s'", reached)} 1 </dev/null >/dev/null 2>&1 &`,
			'      ;;',
			'  esac',
			'fi',
			`exec ${REAL_SH} "$@"`
		]) + '\n');

		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', `exec ${REAL_SLEEP} 30` ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let err = check_common_invariants('pre_publish_sleep_timer_exit', obs);
		if (err)
			return err;
		if (fs.lstat(reached) == null)
			return failed('observer did not confirm stage 1 publisher blocked at fault point');
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 3.0)
			return failed(`expected bounded stage 1 blocked-publisher error: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

// Stage 2 grace publisher blocks forever on FIFO $d/grace (never unlocked by fixture).
// Stage 1 sleep shim plants FIFO $d/grace, launches independent observer, and exits 0;
// observer confirms stage 2 publisher reached `wait_for_partner` and SIGKILLs timer.
function pre_publish_grace_timer_exit_case() {
	return with_sandbox('prepub-s2', sb => {
		let stage1_seen = `${sb.base}/s1.seen`;
		let reached = `${sb.base}/s2.reached`;
		let obs_sh = write_observer_script(sb, 'obs-s2.sh');
		write_exec(`${sb.bin_dir}/sleep`, join('\n', [
			`#!${REAL_SH}`,
			`if [ ! -f ${sprintf("'%s'", stage1_seen)} ]; then`,
			`  : >${sprintf("'%s'", stage1_seen)}`,
			'  d=$(dirname "$(readlink -f "/proc/$PPID/fd/2" 2>/dev/null)")',
			'  if [ -d "$d" ] && [ -e "$d/grace" ]; then',
			'    rm -f "$d/grace"',
			'    mkfifo -m 0600 "$d/grace"',
			`    setsid ${sprintf("'%s'", obs_sh)} "$d/grace" ${sprintf("'%s'", reached)} 0 </dev/null >/dev/null 2>&1 &`,
			'  fi',
			'  exit 0',
			'fi',
			`exec ${REAL_SLEEP} "$@"`
		]) + '\n');

		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', `trap '' TERM; exec ${REAL_SLEEP} 30` ],
			opts: { timeout: 1, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let err = check_common_invariants('pre_publish_grace_timer_exit', obs);
		if (err)
			return err;
		if (fs.lstat(reached) == null)
			return failed('observer did not confirm stage 2 grace publisher blocked at fault point');
		let r = obs.result;
		if (r.code != -1 || r.timed_out || r.stderr == '' || obs.elapsed >= 3.5)
			return failed(`expected bounded stage 2 blocked-publisher error: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

// No grace needed: stage 1 is established, $d/grace is replaced with a FIFO that has
// no reader (fixture never opens it and never kills timer), and runner finishes normally.
// Production code must return the original command's result promptly without touching $d/grace.
function no_grace_needed_fifo_no_reader_case() {
	return with_sandbox('nograce-fifo', sb => {
		let fifo_ready = `${sb.base}/grace.fifo.ready`;
		write_exec(`${sb.bin_dir}/sleep`, join('\n', [
			`#!${REAL_SH}`,
			'd=$(dirname "$(readlink -f "/proc/$PPID/fd/2" 2>/dev/null)")',
			'if [ -d "$d" ] && [ -e "$d/grace" ]; then',
			'  i=0; while [ ! -s "$d/sleep" ] && [ "$i" -lt 200 ]; do /bin/sleep 0.01; i=$((i + 1)); done',
			'  rm -f "$d/grace"',
			'  mkfifo -m 0600 "$d/grace"',
			`  : >${sprintf("'%s'", fifo_ready)}`,
			'fi',
			`exec ${REAL_SLEEP} "$@"`
		]) + '\n');

		let runner_sh = join('\n', [
			`i=0; while [ ! -f ${sprintf("'%s'", fifo_ready)} ] && [ "$i" -lt 300 ]; do ${REAL_SLEEP} 0.01; i=$((i + 1)); done`,
			'printf orig-out; printf orig-err >&2; exit 7'
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner_sh ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let err = check_common_invariants('no_grace_needed_fifo_no_reader', obs);
		if (err)
			return err;
		if (fs.lstat(fifo_ready) == null)
			return failed('stage 1 did not establish unread grace FIFO');
		let r = obs.result;
		if (r.code != 7 || r.timed_out || r.stdout != 'orig-out' || r.stderr != 'orig-err' || obs.elapsed >= 2.0)
			return failed(`expected prompt original command result without grace write: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

// Suppress complete events, not pidfile writes: framing must not turn a genuinely
// missing ownership/completion event into a successful command result.
function missing_control_frame_case(stage) {
	return with_sandbox(`missing-${stage}`, sb => {
		let trace = `${sb.base}/control.trace`;
		write_exec(`${sb.bin_dir}/sh`, join('\n', [
			`#!${REAL_SH}`,
			'if [ "$1" = "-c" ] && [ "$3" = "sh" ]; then',
			'  script=$2; shift 2',
			'  case "$2" in',
			`    '${sb.tmp_root}'/aether-proxy-run.*)`,
			'      if [ -d "$2" ]; then',
			"        needle='} | {'; before=${script%%\"$needle\"*}; after=${script#*\"$needle\"};",
			`        script=$before'} | tee "${trace}" | {'$after;`,
			'      fi',
			`      script='printf() { case "$1" in *"${stage} "*) return 0 ;; *) command printf "$@" ;; esac; }; '"$script" ;;`,
			'  esac',
			`  exec ${REAL_SH} -c "$script" "$@"`,
			'fi',
			`exec ${REAL_SH} "$@"`
		]) + '\n');
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', 'printf missing-out; printf missing-err >&2; exit 7' ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let raw = fs.readfile(trace) ?? '';
		printf('INFO  missing_frame_%s raw control: %J\n', stage, raw);
		let err = check_common_invariants(`missing_frame_${stage}`, obs);
		if (err)
			return err;
		let r = obs.result;
		let diagnostic = stage == 'G' ? 'timer exited without publishing grace pid' : 'timer event stream ended early';
		if (r.code != -1 || r.timed_out || r.stdout != 'missing-out' || r.stderr != `missing-err${diagnostic}\n`)
			return failed(`missing ${stage} must remain a handshake error: ${sprintf('%.J', obs)}`);
		if (match(raw, stage == 'G' ? /G / : /D /))
			return failed(`fixture failed to suppress ${stage}: ${sprintf('%.J', raw)}`);
		return 'PASS';
	});
}

// Only scheduling is injected: the real controller owns the child before R, then
// handles R after the child has emitted an incomplete frame. No sleeps race KILL.
// G is deliberately NOT a real timeout: omit its mark/TERM to check exit fidelity;
// normal_timeout_* above independently cover the real timeout semantics.
function partial_control_frame_case(stage, exit_code, cut) {
	return with_sandbox(`partial-${stage}-${exit_code}-${cut}`, sb => {
		let owned = `${sb.base}/owned`;
		let armed = `${sb.base}/armed`;
		let start = `${sb.base}/start`;
		let ready = `${sb.base}/ready`;
		let hold = `${sb.base}/hold`;
		let trace = `${sb.base}/control.trace`;
		let mk = sys.run([ 'mkfifo', owned, armed, start, ready, hold ], { quiet: true });
		if (mk.code != 0)
			die('cannot create partial-frame handshake FIFOs');
		let parent_printf = join('\n', [
			'printf() {',
			'  command printf "$@" || return;',
			'  case "$1" in',
			`    *"${stage} "*) if [ "$2" != "-" ]; then command printf 'owned\\n' >'${owned}'; fi ;;`,
			`    *"R "*) command printf 'start\\n' >'${start}' ;;`,
			'  esac;',
			'};'
		]);
		let child_printf = join('\n', [
			'printf() {',
			'  case "$1" in',
			`    *"${stage} "*)`,
				`      IFS= read -r token <'${owned}';`,
				`      command printf 'armed\\n' >'${armed}';`,
				`      IFS= read -r token <'${start}';`,
				'      frame=$(command printf "$@");',
				`      command printf '%s' "\${frame%%${stage}*}${stage}";`,
				...(cut == 'stage' ? [] : [
					'      pid=$2;',
					...(cut == 'half' ? [ '      n=$((${#pid} / 2)); pid=$(command printf "%s" "$pid" | cut -c "1-$n");' ] : []),
					'      command printf " %s" "$pid";'
				]),
				`      command printf 'ready\\n' >'${ready}';`,
				`      IFS= read -r token <'${hold}';`,
				'      return 125 ;;',
			'    *) command printf "$@" ;;',
			'  esac;',
			'};'
		]);
		let target = stage == 'S' ? 'sleep' : 'grace';
		write_exec(`${sb.bin_dir}/sh`, join('\n', [
			`#!${REAL_SH}`,
			'if [ "$1" = "-c" ] && [ "$3" = "sh" ]; then',
			'  script=$2; shift 2',
			'  case "$2" in',
			`    '${sb.tmp_root}'/aether-proxy-run.*/${target})`,
			`      script='${replace(child_printf, /'/g, "'\\''")}'"$script" ;;`,
			`    '${sb.tmp_root}'/aether-proxy-run.*)`,
			`      [ -d "$2" ] || exec ${REAL_SH} -c "$script" "$@"`,
			'      replace_once() {',
			'        needle=$1; replacement=$2;',
			'        case "$script" in *"$needle"*) ;; *) exit 126 ;; esac;',
			'        before=${script%%"$needle"*}; after=${script#*"$needle"};',
			'        script=$before$replacement$after;',
			'      };',
			`      replace_once 'runner_done=1; rc=$ev_arg;' 'IFS= read -r token <"${ready}"; runner_done=1; rc=$ev_arg;'`,
			`      replace_once '} | {' '} | tee "${trace}" | {'`,
			...(stage == 'G' ? [
				`      replace_once 'wr "$timed_file" ""' ':'`,
				`      replace_once 'kill -TERM "$runner";' ':;'`
			] : []),
			`      script='${replace(parent_printf, /'/g, "'\\''")}'"$script" ;;`,
			'  esac',
			`  exec ${REAL_SH} -c "$script" "$@"`,
			'fi',
			`exec ${REAL_SH} "$@"`
		]) + '\n');
		if (stage == 'G')
			write_exec(`${sb.bin_dir}/sleep`, `#!${REAL_SH}\nexit 0\n`);
		let runner = join('\n', [
			`IFS= read -r token <'${armed}'`,
			'printf frame-out; printf frame-err >&2;',
			`exit ${exit_code}`
		]);
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', runner ],
			opts: { timeout: 20, quiet: true },
			use_bin: true,
			guard_s: 6
		});
		let raw = fs.readfile(trace) ?? '';
		printf('INFO  partial_frame_%s_%d_%s raw control: %J\n', stage, exit_code, cut, raw);
		let err = check_common_invariants(`partial_frame_${stage}_${exit_code}_${cut}`, obs);
		if (err)
			return err;
		let r = obs.result;
		if (r.code != exit_code || r.timed_out || r.stdout != 'frame-out' || r.stderr != 'frame-err' || obs.elapsed >= 2.0)
			return failed(`expected exact original exit/stdout/stderr after partial ${stage}: ${sprintf('%.J', obs)}`);
		let ownership = match(raw, stage == 'S' ? /S ([0-9]+);?\n/ : /G ([0-9]+);?\n/);
		if (ownership == null)
			return failed(`missing parent ${stage} ownership: ${sprintf('%.J', raw)}`);
		let pid = ownership[1];
		let partial = stage + (cut == 'stage' ? '' : ' ' + (cut == 'half' ? substr(pid, 0, int(length(pid) / 2)) : pid));
		let framed = substr(raw, 0, 1) == '\n';
		let suffix = framed ? ';\n' : '\n';
		let prefix = framed ? '\n' : '';
		let next_event = stage == 'S' ? 'G -' : 'D 0';
		let sequence = `R ${exit_code}${suffix}${prefix}${partial}${prefix}${next_event}${suffix}`;
		if (index(raw, sequence) < 0 || index(raw, 'D 0' + suffix) < 0)
			return failed(`missing ordered runner/partial/normal timer completion: ${sprintf('%.J', raw)}`);
		return 'PASS';
	});
}

// T16.118: the timer's final `kill -KILL "$runner"` must not decide the exit status of an
// already completed command. Reproduce deterministically: the runner ignores TERM and exits 0
// shortly after the timeout fires, and the grace child removes the completion marker before the
// timer's own grace check, so the timer reaches its final kill with a reaped runner.
// A command that ignores TERM and then completes with 0 while the timer is already in its
// timeout branch: the timer's final `kill -KILL "$runner"` targets a reaped process and fails.
// That bookkeeping status must not turn a finished command into a failure.
function timer_kill_after_runner_success_case() {
	return with_sandbox('kill-status', sb => {
		let obs = run_isolated_case(sb, {
			argv: [ REAL_SH, '-c', `trap '' TERM; ${REAL_SLEEP} 1.2; printf slow-ok` ],
			opts: { timeout: 1, quiet: true },
			guard_s: 12
		});
		let err = check_common_invariants('timer_kill_after_runner_success', obs);
		if (err)
			return err;
		let r = obs.result;
		// The command ran past its timeout and ignored TERM, so 124 stays honest; what must not
		// happen is the timer's own bookkeeping status (a failed final kill) turning it into the
		// -1 handshake failure that aborted publish on the device.
		if (r.code == -1 || index(r.stderr, 'timer exited early') >= 0 || r.stdout != 'slow-ok')
			return failed(`completed command reported as timer failure: ${sprintf('%.J', obs)}`);
		return 'PASS';
	});
}

export function run(c) {
	if (match(c.kind, /^partial_frame_[sg]_[07]$/))
		return partial_control_frame_case(index(c.kind, '_s_') >= 0 ? 'S' : 'G', +substr(c.kind, -1), c.cut ?? 'stage');
	if (c.kind == 'missing_frame_g' || c.kind == 'missing_frame_d')
		return missing_control_frame_case(c.kind == 'missing_frame_g' ? 'G' : 'D');
	if (c.kind == 'normal_fast')
		return normal_fast_case();
	if (c.kind == 'normal_exit_124')
		return normal_exit_124_case();
	if (c.kind == 'normal_timeout_term')
		return normal_timeout_term_case();
	if (c.kind == 'normal_timeout_kill')
		return normal_timeout_kill_case();
	if (c.kind == 'first_pid_runner_done')
		return first_pid_runner_done_case();
	if (c.kind == 'first_pid_runner_running')
		return first_pid_runner_running_case();
	if (c.kind == 'grace_pid_runner_done')
		return grace_pid_runner_done_case();
	if (c.kind == 'grace_pid_runner_running')
		return grace_pid_runner_running_case();
	if (c.kind == 'timer_early_runner_done')
		return timer_early_runner_done_case();
	if (c.kind == 'timer_early_runner_running')
		return timer_early_runner_running_case();
	if (c.kind == 'pre_publish_sleep_timer_exit')
		return pre_publish_sleep_timer_exit_case();
	if (c.kind == 'pre_publish_grace_timer_exit')
		return pre_publish_grace_timer_exit_case();
	if (c.kind == 'no_grace_needed_fifo_no_reader')
		return no_grace_needed_fifo_no_reader_case();
	if (c.kind == 'timer_kill_after_runner_success')
		return timer_kill_after_runner_success_case();
	return failed('unknown test kind');
};
