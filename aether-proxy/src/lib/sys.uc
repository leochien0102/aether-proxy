'use strict';

// The only module allowed to spawn processes (docs/12 rule 2) or write files (rule 3).

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';

let last_error = null;
let last_lock_retryable = false;

// fs.open() and fs.popen() failures do not always set fs.error() in ucode 2025.07.18
// (verified on the pinned build), so never print it bare.
function fs_err() {
	return fs.error() ?? 'unknown error';
}

// Runs inside `sh -c`. Needs a wrapper because ucode has no way to capture stdout and
// stderr separately: all per-invocation files (stdout, stderr, wrapper diagnostics,
// and timer handshake files) live inside a 0700 private directory created by run()
// before spawning `sh`. argv arrives as "$@", so nothing from the caller is ever
// interpolated into the script text.
const WRAPPER = join(' ', [
	'd=$1; timeout=$2; shift 2;',
	'exec >"$d/stdout" || exit 125;',
	'e=$d/stderr; : >"$e" || exit 125;',
	'helper=$d/wrapper; : >"$helper" || exit 125; exec 2>>"$helper";',
	'is_pid() { case "$1" in ""|0|*[!0-9]*) return 1 ;; *) return 0 ;; esac; };',
	// BusyBox ash does not set SA_RESTART on SIGCHLD for open(); avoid special builtins
	// (`:` / `exec <file>`) after spawning children and retry regular redirections on EINTR.
	'wr() { printf "%s" "$2" >"$1" || printf "%s" "$2" >"$1" || printf "%s" "$2" >"$1"; };',
	'wrl() { printf "%s\\n" "$2" >"$1" || printf "%s\\n" "$2" >"$1" || printf "%s\\n" "$2" >"$1"; };',
	'rd() { IFS= read -r pub <"$1" || IFS= read -r pub <"$1" || IFS= read -r pub <"$1"; };',
	'if [ "$timeout" = "-" ]; then',
	'  "$@" </dev/null 2>"$e"; rc=$?; timed=false;',
	'else',
	'  done=$d/done; timed_file=$d/timeout; sleeper=$d/sleep; grace=$d/grace;',
	'  rcfile=$d/rc; gkill=$d/gkill; rdone=$d/rdone;',
	'  wr "$sleeper" ""; wr "$grace" "";',
	'  exec 3>&1 || exit 125;',
	'  {',
	'    ( exec "$@" </dev/null >&3 3>&- 2>>"$e" ) & runner=$!;',
	'    printf "P %s\\n" "$runner";',
	// Cancel the sleeps with KILL, not the timer shell with TERM: rc.common may have
	// passed an ignored TERM disposition that no child shell can reset (docs/12 rule 2).
	// Each sleep stage publishes its own PID ($$) to both the pidfile and the control
	// pipe BEFORE exec'ing `sleep`, so no `sleep` can ever run without its PID already
	// queued ahead of any timer exit event `D <status>`.
	'    (',
	'      ( sh -c \'',
	'          if ! { printf "%s\\n" "$$" >"$1" || printf "%s\\n" "$$" >"$1" || printf "%s\\n" "$$" >"$1"; }; then',
	'            printf "F sleep\\n"; exit 125;',
	'          fi;',
	'          if ! printf "S %s\\n" "$$"; then exit 125; fi;',
	'          if [ -f "$3" ]; then exit 0; fi;',
	'          exec sleep "$2" >/dev/null;',
	'        \' sh "$sleeper" "$timeout" "$done" 3>&- & t=$!;',
	'        wait "$t"; sw=$?;',
	'        if [ -f "$done" ]; then',
	'          if ! wrl "$grace" "-" || ! printf "G -\\n"; then',
	'            printf "F grace\\n"; exit 125;',
	'          fi;',
	'          exit 0;',
	'        fi;',
	'        if [ "$sw" -ne 0 ]; then printf "F sleep-exit\\n"; exit 125; fi;',
	'        wr "$timed_file" "" || { printf "F timeout-mark\\n"; exit 125; };',
	'        kill -TERM "$runner";',
	'        if [ -f "$done" ]; then',
	'          if ! wrl "$grace" "-" || ! printf "G -\\n"; then',
	'            printf "F grace\\n"; exit 125;',
	'          fi;',
	'          exit 0;',
	'        fi;',
	'        sh -c \'',
	'          if ! { printf "%s\\n" "$$" >"$1" || printf "%s\\n" "$$" >"$1" || printf "%s\\n" "$$" >"$1"; }; then',
	'            printf "F grace\\n"; exit 125;',
	'          fi;',
	'          if ! printf "G %s\\n" "$$"; then exit 125; fi;',
	'          if [ -f "$2" ]; then exit 0; fi;',
	'          exec sleep 1 >/dev/null;',
	'        \' sh "$grace" "$done" 3>&- & t=$!;',
	'        wait "$t"; gw=$?;',
	'        if [ -f "$done" ]; then exit 0; fi;',
	'        if [ "$gw" -ne 0 ]; then printf "F grace-exit\\n"; exit 125; fi;',
	'        kill -KILL "$runner";',
	'      ) 3>&- & timer=$!;',
	'      printf "T %s\\n" "$timer";',
	'      wait "$timer"; trc=$?;',
	'      printf "D %s\\n" "$trc";',
	'    ) 3>&- & timer_sup=$!;',
	'    wait "$runner"; rrc=$?;',
	'    printf "R %s\\n" "$rrc";',
	'    wait "$timer_sup";',
	'  } | {',
	'    exec 3>&-;',
	'    runner=""; timer=""; runner_done=0; timer_done=0; trc=0;',
	'    rc=-1; timed=false; s1=""; s2=""; handshake_err="";',
	'    while IFS=" " read -r ev_kind ev_arg; do',
	'      case "$ev_kind" in',
	'        P) if is_pid "$ev_arg"; then runner=$ev_arg; else handshake_err="runner handshake failed"; break; fi ;;',
	'        T) if is_pid "$ev_arg"; then timer=$ev_arg; else handshake_err="timer pid invalid"; break; fi ;;',
	'        S)',
	'          if is_pid "$ev_arg"; then s1=$ev_arg; fi;',
	'          if is_pid "$s1" && [ -f "$sleeper" ] && rd "$sleeper" && [ "$pub" = "$s1" ]; then',
	'            if [ "$runner_done" -eq 1 ]; then kill -KILL "$s1"; fi;',
	'          else',
	'            handshake_err="timer failed to publish sleep pid"; break;',
	'          fi ;;',
	'        G)',
	'          if [ "$ev_arg" = "-" ]; then',
	'            if [ -f "$grace" ] && rd "$grace" && [ "$pub" = "-" ]; then',
	'              s2="-";',
	'            else',
	'              handshake_err="timer failed to publish grace pid"; break;',
	'            fi;',
	'          else',
	'            if is_pid "$ev_arg"; then s2=$ev_arg; fi;',
	'            if is_pid "$s2" && [ -f "$grace" ] && rd "$grace" && [ "$pub" = "$s2" ]; then',
	'              if [ "$runner_done" -eq 1 ]; then kill -KILL "$s2"; fi;',
	'            else',
	'              handshake_err="timer failed to publish grace pid"; break;',
	'            fi;',
	'          fi ;;',
	'        R)',
	'          runner_done=1; rc=$ev_arg; wr "$done" "";',
	'          if is_pid "$s1"; then kill -KILL "$s1"; fi;',
	'          if is_pid "$s2"; then kill -KILL "$s2"; fi;',
	'          if [ "$timer_done" -eq 1 ]; then break; fi ;;',
	'        F)',
	'          handshake_err="timer handshake failed: $ev_arg"; break ;;',
	'        D)',
	'          timer_done=1; trc=$ev_arg;',
	'          if [ "$trc" -ne 0 ]; then',
	'            handshake_err="timer exited early (status $trc)"; break;',
	'          elif [ -z "$s1" ]; then',
	'            handshake_err="timer exited without publishing sleep pid"; break;',
	'          elif [ -z "$s2" ]; then',
	'            handshake_err="timer exited without publishing grace pid"; break;',
	'          elif [ "$runner_done" -eq 1 ]; then',
	'            break;',
	'          elif [ ! -f "$timed_file" ]; then',
	'            handshake_err="timer exited before command completed"; break;',
	'          fi ;;',
	'      esac;',
	'    done;',
	'    if [ -z "$handshake_err" ] && [ "$timer_done" -eq 0 ]; then',
	'      handshake_err="timer event stream ended early";',
	'    fi;',
	'    if [ -n "$handshake_err" ]; then',
	'      wr "$done" "";',
	'      if is_pid "$s1"; then kill -KILL "$s1"; fi;',
	'      if is_pid "$s2"; then kill -KILL "$s2"; fi;',
	'      if is_pid "$timer" && kill -0 "$timer"; then kill -KILL "$timer"; fi;',
	'      if [ "$runner_done" -eq 0 ] && is_pid "$runner" && kill -0 "$runner"; then',
	'        kill -TERM "$runner";',
	'        ( sleep 1 >/dev/null & g=$!; wrl "$gkill" "$g"; wait "$g";',
	'          if [ ! -f "$rdone" ]; then kill -KILL "$runner"; fi;',
	'        ) </dev/null & gsup=$!;',
	'        while IFS=" " read -r ev_kind ev_arg; do',
	'          case "$ev_kind" in',
	'            S|G) if is_pid "$ev_arg"; then kill -KILL "$ev_arg"; fi ;;',
	'            R)',
	'              runner_done=1; wr "$rdone" "";',
	'              if rd "$gkill" && is_pid "$pub"; then kill -KILL "$pub"; fi;',
	'              break ;;',
	'          esac;',
	'        done;',
	'        if [ "$runner_done" -eq 0 ]; then kill -KILL "$runner"; fi;',
	'        if rd "$gkill" && is_pid "$pub"; then kill -KILL "$pub"; fi;',
	'        wait "$gsup";',
	'      fi;',
	'      while IFS=" " read -r ev_kind ev_arg; do',
	'        case "$ev_kind" in',
	'          S|G) if is_pid "$ev_arg"; then kill -KILL "$ev_arg"; fi ;;',
	'        esac;',
	'      done;',
	'      wrl "$rcfile" "-1 false";',
	'      printf "%s\\n" "$handshake_err" >>"$e";',
	'    else',
	'      if [ -f "$timed_file" ]; then wrl "$rcfile" "124 true"; else wrl "$rcfile" "$rc false"; fi;',
	'    fi;',
	'  };',
	'  exec 3>&-;',
	'  rc=-1; timed=false;',
	'  if IFS=" " read -r rc timed <"$rcfile"; then :; fi;',
	'  rm -f "$done" "$timed_file" "$sleeper" "$grace" "$rcfile" "$gkill" "$rdone" 2>>"$e";',
	'fi;',
	// Cancellation races a naturally completed sleep; keep command stderr separate so
	// filtering those harmless wrapper-only job/kill diagnostics cannot hide its errors.
	'while IFS= read -r line; do case "$line" in',
	'  ""|Terminated|Killed|*"can\'t kill pid"*|*"No such process"*|*"Interrupted system call"*) ;;',
	'  *) printf "%s\\n" "$line" >>"$e" ;; esac; done <"$helper";',
	'rm -f "$helper" 2>>"$e";',
	'printf "\\n@@AP-RC@@ %s %s\\n" "$rc" "$timed"'
]);
const MARKER = "\n@@AP-RC@@ ";
const RUN_FILES = [ 'stdout', 'stderr', 'wrapper', 'done', 'timeout', 'sleep', 'grace', 'rc', 'gkill', 'rdone' ];

function random_hex(n) {
	let fp = fs.open(C.RANDOM_DEVICE, 'r');
	if (fp == null)
		return { ok: false, error: `open ${C.RANDOM_DEVICE}: ${fs_err()}` };
	let bytes = fp.read(n);
	let rerr = fs.error();
	let closed = fp.close();
	if (!closed || bytes == null || length(bytes) != n)
		return { ok: false, error: `read ${C.RANDOM_DEVICE}: ${rerr ?? fs_err()}` };
	let out = '';
	for (let i = 0; i < n; i++)
		out += sprintf('%02x', ord(bytes, i));
	return { ok: true, hex: out };
}

function create_run_dir() {
	for (let attempt = 0; attempt < 8; attempt++) {
		let rnd = random_hex(12);
		if (!rnd.ok)
			return rnd;
		let path = `${C.TMP_DIR}/aether-proxy-run.${rnd.hex}`;
		// Exclusive 0700 mkdir keeps capture files inaccessible to other users even under
		// a loose caller umask, without mutating the umask inherited by the target command.
		if (fs.mkdir(path, 0700))
			return { ok: true, path };
		let err = fs_err();
		if (err != 'File exists')
			return { ok: false, error: `cannot create ${path}: ${err}` };
	}
	return { ok: false, error: `cannot create private temp dir in ${C.TMP_DIR}: too many collisions` };
}

function cleanup_run_dir(dir) {
	let errors = [];
	for (let name in RUN_FILES) {
		let path = `${dir}/${name}`;
		if (fs.lstat(path) != null && !fs.unlink(path))
			push(errors, `cannot remove ${path}: ${fs_err()}`);
	}
	if (!fs.rmdir(dir))
		push(errors, `cannot remove ${dir}: ${fs_err()}`);
	return errors;
}

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
	// The wrapper writes to files inside a per-call private dir, not a pipe: uloop's
	// SIGCHLD handler has no SA_RESTART, so a supervised child exiting mid-read cut
	// popen() reads short (EINTR) and the result was lost. system() retries waitpid()
	// on EINTR and leaves SIGCHLD alone.
	let created = create_run_dir();
	if (!created.ok) {
		res.stderr = created.error;
	}
	else {
		let dir = created.path;
		let out_path = `${dir}/stdout`;
		let err_path = `${dir}/stderr`;
		let wrc = system([ 'sh', '-c', WRAPPER, 'sh', dir, timeout, ...args ]);
		let text = fs.readfile(out_path);

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
				let m = match(substr(out, pos + length(MARKER)), /^(-?[0-9]+) (true|false)\n$/);

				res.stdout = substr(out, 1, pos - 1);

				if (m) {
					res.code = +m[1];
					res.timed_out = m[2] == 'true';
					res.stderr = fs.readfile(err_path) ?? `cannot read ${err_path}: ${fs_err()}`;
				}
				else {
					res.stderr = 'wrapper result unparsable';
				}
			}
		}

		let cleanup_errors = cleanup_run_dir(dir);
		if (length(cleanup_errors)) {
			let note = `(${join('; ', cleanup_errors)})`;
			res.stderr = res.stderr == '' ? note : `${res.stderr}\n${note}`;
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
			let detail = fs_err();
			let existing = fs.stat(cur);
			if (existing != null && existing.type == 'directory')
				continue;
			last_error = `mkdir ${cur}: ${detail}`;
			return null;
		}
	}

	last_error = null;
	return true;
}

// Opens and holds a non-blocking exclusive flock. Closing the returned handle releases it.
function lock(path) {
	last_lock_retryable = false;
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
		let detail = fs_err();
		// Retry policy follows the failure stage, not errno or diagnostic text.
		// A valid handle's flock failure gets a bounded retry budget, even if
		// the underlying cause is permanent. This does not establish contention.
		last_lock_retryable = true;
		last_error = `lock ${path}: ${detail}`;
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

// Read immediately after a failed lock(); later lock calls reset this flag.
// True means the failure stage permits bounded retries, not proven contention.
function lock_retryable() {
	return last_lock_retryable;
}

export { run, write_atomic, mkdir_p, lock, lock_retryable, clean_tmp_files, error };
