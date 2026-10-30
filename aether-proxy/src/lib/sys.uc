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
	'  done=$e.done; timed_file=$e.timeout; sleeper=$e.sleep; grace=$e.grace;',
	'  : >"$sleeper"; : >"$grace";',
	'  ( exec "$@" </dev/null 2>>"$e" ) 2>>"$helper" & runner=$!;',
	// Cancel the sleeps with KILL, not the timer shell with TERM: rc.common may have
	// passed an ignored TERM disposition that no child shell can reset (docs/12 rule 2).
	// The timer owns and reaps both sleeps. Each PID is published even if the command
	// exits during timer startup or between TERM and the grace sleep; '-' means no grace.
	'  ( sleep "$timeout" & t=$!; printf "%s\\n" "$t" >"$sleeper"; wait "$t";',
	'    if [ ! -f "$done" ]; then',
	'      : >"$timed_file"; kill -TERM "$runner" 2>>"$helper";',
	'      sleep 1 & t=$!; printf "%s\\n" "$t" >"$grace"; wait "$t";',
	'      if [ ! -f "$done" ]; then kill -KILL "$runner" 2>>"$helper"; fi;',
	'    else printf "%s\\n" - >"$grace"; fi;',
	'  ) 2>>"$helper" & timer=$!;',
	'  wait "$runner"; rc=$?; : >"$done";',
	// Only wait for PID publication, never for the deadline. Kill both stages so the
	// TERM-handler-exits case does not leave a grace sleep (or block for another second).
	'  for pidfile in "$sleeper" "$grace"; do',
	'    while ! IFS= read -r t <"$pidfile"; do :; done;',
	'    if [ "$t" != "-" ] && kill -0 "$t" 2>>"$helper"; then kill -KILL "$t" 2>>"$helper"; fi;',
	'  done;',
	'  wait "$timer" 2>>"$helper";',
	'  if [ -f "$timed_file" ]; then rc=124; timed=true; else timed=false; fi;',
	'  rm -f "$done" "$timed_file" "$sleeper" "$grace" 2>>"$e";',
	'fi;',
	// Cancellation races a naturally completed sleep; keep command stderr separate so
	// filtering those harmless wrapper-only job/kill diagnostics cannot hide its errors.
	'while IFS= read -r line; do case "$line" in',
	'  ""|Terminated|Killed|*"can\'t kill pid"*|*"No such process"*) ;;',
	'  *) printf "%s\\n" "$line" >>"$e" ;; esac; done <"$helper";',
	'rm -f "$helper" 2>>"$e";',
	'printf "\\n@@AP-RC@@ %s %s %s\\n" "$rc" "$e" "$timed"'
]);
const MARKER = "\n@@AP-RC@@ ";

// Keep logged stderr bounded without losing the original command's captured stderr.
function first_line(s, max) {
	let line = split(trim(s ?? ''), '\n')[0];

	return length(line) > max ? substr(line, 0, max) : line;
}

// Redact URL credentials before formatting either command diagnostics or stderr.
// Match embedded URLs too (e.g. --url=https://...), and remove fragments as they may
// carry the same secrets as queries. Execution arguments and captured output stay intact.
function redact_urls(text) {
	return replace(text, /[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^[:space:]"'<>]+/g, url => {
		let clean = split(url, /[?#]/)[0];
		return replace(clean, /(:\/\/)[^/]*@/, '$1');
	});
}

function monotonic_ms() {
	let now = clock(true);
	return now == null ? null : now[0] * 1000 + now[1] / 1000000;
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
	let started = monotonic_ms();

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

	let ended = monotonic_ms();
	// TODO(design): no clock-failure policy is specified; keep command semantics and
	// report zero rather than fall back to wall time (which can jump backwards).
	let ms = started == null || ended == null ? 0 : max(0, ended - started);
	let cmd = join(' ', map(args, redact_urls));
	log.event('debug', 'CMD_RUN', { cmd, rc: res.code, ms });

	if (res.code != 0 && !opts.quiet) {
		let args = {
			cmd,
			rc: res.code,
			stderr: first_line(redact_urls(res.stderr), 200)
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
function write_atomic(path, content, metadata) {
	let pid = fs.readlink('/proc/self');
	let tmp = `${path}.tmp.${pid ?? 'x'}`;
	// Exclusive creation never follows a residue symlink left by a killed writer.
	let fp = fs.open(tmp, 'wxe', 0600);

	if (!fp) {
		last_error = `open ${tmp}: ${fs_err()}`;
		return null;
	}

	let ok = fp.write(content);
	let werr = fs.error();

	// close() flushes; a failure here (e.g. ENOSPC) must also abort the rename.
	let cok = fp.close();

	if (ok != length(content) || !cok) {
		last_error = `write ${tmp}: ${werr ?? fs_err()}`;
		if (!fs.unlink(tmp))
			last_error += `; unlink ${tmp}: ${fs_err()}`;
		return null;
	}

	// Apply ownership before permissions (chown may clear set-id bits), before publication.
	if (metadata != null) {
		let st = fs.stat(tmp);
		let owner_ok = st != null;
		if (owner_ok && (st.uid != metadata.uid || st.gid != metadata.gid))
			owner_ok = fs.chown(tmp, metadata.uid, metadata.gid);
		if (!owner_ok || !fs.chmod(tmp, metadata.mode)) {
			last_error = `metadata ${tmp}: ${fs_err()}`;
			if (!fs.unlink(tmp))
				last_error += `; unlink ${tmp}: ${fs_err()}`;
			return null;
		}
	}

	if (!fs.rename(tmp, path)) {
		last_error = `rename ${tmp} -> ${path}: ${fs_err()}`;
		if (!fs.unlink(tmp))
			last_error += `; unlink ${tmp}: ${fs_err()}`;
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

// Only call for application-owned scratch directories, under config lock.
function clean_tmp_files(dir, recursive, pattern) {
	let directory = fs.stat(dir);
	if (directory == null) {
		let detail = fs_err();
		if (detail == 'No such file or directory')
			return true;
		last_error = `stat ${dir}: ${detail}`;
		return null;
	}
	let paths = fs.glob(dir + '/' + (pattern ?? '*'));
	if (paths == null) {
		last_error = `list ${dir}: ${fs_err()}`;
		return null;
	}
	for (let path in paths) {
		let st = fs.lstat(path);
		if (st?.type == 'directory' && recursive) {
			if (!clean_tmp_files(path, true))
				return null;
		}
		else if (match(path, /\.tmp\.[^/]+$/) && !fs.unlink(path)) {
			last_error = `unlink ${path}: ${fs_err()}`;
			return null;
		}
	}
	return true;
}

function error() {
	return last_error;
}

export { run, write_atomic, mkdir_p, lock, clean_tmp_files, error };
