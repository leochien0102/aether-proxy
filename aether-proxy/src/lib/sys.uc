'use strict';

// The only module allowed to spawn processes (docs/12 rule 2) or write files (rule 3).

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';

let last_error = null;
let run_seq = 0;

// fs.open() and fs.popen() failures do not always set fs.error() in ucode 2025.07.18
// (verified on the pinned build), so never print it bare.
function fs_err() {
	return fs.error() ?? 'unknown error';
}

// POSIX single-quote escaping: ' becomes '\'' so the result is one shell word.
function q(arg) {
	return "'" + replace(`${arg}`, "'", "'\\''") + "'";
}

// Runs inside `sh -c`. Needs a wrapper because ucode has no way to capture stdout and
// stderr separately: stderr goes to a mktemp file, and the exit code, timeout flag, and
// that file's path are appended to stdout after a marker line. argv arrives as "$@", so
// nothing from the caller is ever interpolated into the script text.
const WRAPPER = join(' ', [
	'e=$(mktemp ' + C.TMP_DIR + '/aether-proxy-sys.XXXXXX) ||',
	'{ printf "\\n@@AP-RC@@ 125 - false -\\n"; exit 125; };',
	'helper=$e.wrapper; : >"$helper"; exec 2>>"$helper";',
	'timeout=$1; shift; timer=-;',
	'if [ "$timeout" = "-" ]; then',
	'  "$@" </dev/null 2>"$e"; rc=$?; timed=false;',
	'else',
	'  done=$e.done; child=$e.pid; timed_file=$e.timeout; finished=$e.finished;',
	'  ( exec "$@" </dev/null 2>>"$e" ) 2>>"$helper" & runner=$!;',
	'  printf "%s\\n" "$runner" >"$child";',
	'  ( t=;',
	"    trap 'if [ -n \"$t\" ]; then kill \"$t\" 2>>\"$helper\"; wait \"$t\" 2>>\"$helper\"; fi; : >\"$finished\"; exit 0' TERM;",
	'    sleep "$timeout" & t=$!; wait "$t"; t=;',
	'    if [ ! -f "$done" ]; then',
	'      : >"$timed_file"; IFS= read -r c <"$child"; kill -TERM "$c" 2>>"$helper";',
	'      sleep 1 & t=$!; wait "$t"; t=;',
	'      if [ ! -f "$done" ]; then kill -KILL "$c" 2>>"$helper"; fi;',
	'    fi;',
	'    : >"$finished" ) 2>>"$helper" & timer=$!;',
	'  wait "$runner"; rc=$?; : >"$done";',
	'  if [ ! -f "$finished" ]; then kill -TERM "$timer" 2>>"$helper"; fi;',
	'  wait "$timer" 2>>"$helper";',
	'  if [ -f "$timed_file" ]; then rc=124; timed=true; else timed=false; fi;',
	'  rm -f "$done" "$child" "$timed_file" "$finished" 2>>"$e";',
	'fi;',
	'while IFS= read -r line; do if [ "$line" != "Terminated" ]; then printf "%s\\n" "$line" >>"$e"; fi; done <"$helper";',
	'rm -f "$helper" 2>>"$e";',
	'printf "\\n@@AP-RC@@ %s %s %s\\n" "$rc" "$e" "$timed"'
]);
const MARKER = "\n@@AP-RC@@ ";

// ash may print "Terminated" when a background child is signalled; discard that shell
// job notification while preserving every other wrapper diagnostic and command stderr.
function first_line(s, max) {
	let line = split(trim(s ?? ''), '\n')[0];

	return length(line) > max ? substr(line, 0, max) : line;
}

// run(argv, opts) -> { code, stdout, stderr }
// opts.timeout: seconds. opts.quiet: do not log CMD_FAILED. timed_out distinguishes a
// timeout from a command that independently exits with code 124.
// code is -1 if the wrapper's result could not be read, or 124 on a timeout.
function run(argv, opts) {
	if (type(argv) != 'array' || !length(argv))
		die('sys.run: argv must be a non-empty array');

	opts ??= {};

	let args = map(argv, a => `${a}`);

	let timeout = opts.timeout == null ? '-' : `${opts.timeout}`;
	let res = { code: -1, stdout: '', stderr: '', timed_out: false };
	// The wrapper writes to a file, not a pipe: uloop's SIGCHLD handler has no SA_RESTART,
	// so a supervised child exiting mid-read cut popen() reads short (EINTR) and the
	// result was lost. system() retries waitpid() on EINTR and leaves SIGCHLD alone.
	run_seq++;
	let out_path = `${C.TMP_DIR}/aether-proxy-run.${fs.readlink('/proc/self') ?? 'x'}.${run_seq}`;
	let wrc = system([ 'sh', '-c', 'exec >"$1" || exit 125; shift; ' + WRAPPER, 'sh', out_path, timeout, ...args ]);
	let text = fs.readfile(out_path);

	if (text != null && !fs.unlink(out_path))
		res.stderr = `(cannot remove ${out_path}: ${fs_err()})`;

	if (text == null) {
		res.stderr = `wrapper produced no result (sh exit ${wrc})`;
	}
	else {
		// The leading newline sidesteps rindex() failing to report a match at offset 0
		// (seen on the pinned ucode build) when the command printed nothing.
		let out = '\n' + text;
		let pos = rindex(out, MARKER);

		if (pos < 0) {
			res.stdout = substr(out, 1);
			res.stderr = `wrapper produced no result (sh exit ${wrc})`;
		}
		else {
			let m = match(substr(out, pos + length(MARKER)), /^([0-9]+) ([^ ]+) (true|false)\n$/);

			res.stdout = substr(out, 1, pos - 1);

			if (m) {
				res.code = +m[1];
				res.timed_out = m[3] == 'true';

				if (m[2] == '-') {
					res.stderr = 'mktemp failed';
				}
				else {
					res.stderr = fs.readfile(m[2]) ?? `cannot read ${m[2]}: ${fs_err()}`;

					if (!fs.unlink(m[2]))
						res.stderr += `\n(cannot remove ${m[2]}: ${fs_err()})`;
				}
			}
			else {
				res.stderr = 'wrapper result unparsable';
			}
		}
	}

	if (res.code != 0 && !opts.quiet) {
		let args = {
			cmd: join(' ', argv),
			rc: res.code,
			stderr: first_line(res.stderr, 200)
		};

		if (res.timed_out)
			args.timed_out = true;

		log.event('error', 'CMD_FAILED', args);
	}

	return res;
}

// Writes to a temp file next to the target and renames over it, so readers never see
// a partial file. Returns true, or null on failure (reason in error()).
// TODO(design): 09 has no event code for filesystem errors, so this does not log;
// callers must record the failure with a code that fits their context.
function write_atomic(path, content) {
	let pid = fs.readlink('/proc/self');
	let tmp = `${path}.tmp.${pid ?? 'x'}`;
	let fp = fs.open(tmp, 'w');

	if (!fp) {
		last_error = `open ${tmp}: ${fs_err()}`;
		return null;
	}

	let ok = fp.write(content);
	let werr = fs.error();

	// close() flushes; a failure here (e.g. ENOSPC) must also abort the rename.
	let cok = fp.close();

	if (ok == null || !cok) {
		last_error = `write ${tmp}: ${werr ?? fs_err()}`;
		fs.unlink(tmp);
		return null;
	}

	if (!fs.rename(tmp, path)) {
		last_error = `rename ${tmp} -> ${path}: ${fs_err()}`;
		fs.unlink(tmp);
		return null;
	}

	last_error = null;
	return true;
}

// mkdir -p. Returns true, or null on failure (reason in error()).
function mkdir_p(path) {
	let cur = substr(path, 0, 1) == '/' ? '' : '.';

	for (let part in split(path, '/')) {
		if (part == '')
			continue;

		cur += '/' + part;

		let st = fs.stat(cur);

		if (st != null) {
			if (st.type == 'directory')
				continue;

			last_error = `${cur} exists and is not a directory`;
			return null;
		}

		if (!fs.mkdir(cur)) {
			last_error = `mkdir ${cur}: ${fs_err()}`;
			return null;
		}
	}

	last_error = null;
	return true;
}

// Opens and holds a non-blocking exclusive flock. Closing the returned handle releases it.
function lock(path) {
	let parent = substr(path, 0, rindex(path, '/'));
	if (parent != '' && !mkdir_p(parent))
		return null;

	// 'e' = O_CLOEXEC: children spawned while the lock is held (chinadns-ng during startup)
	// must not inherit it, or an orphan keeps the lock after a SIGKILLed daemon.
	let fp = fs.open(path, 'ae');
	if (fp == null) {
		last_error = `open lock ${path}: ${fs_err()}`;
		return null;
	}

	if (!fp.lock('xn')) {
		last_error = `lock ${path}: ${fs_err()}`;
		fp.close();
		return null;
	}

	last_error = null;
	return fp;
}

function error() {
	return last_error;
}

export { q, run, write_atomic, mkdir_p, lock, error };
