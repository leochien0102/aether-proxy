'use strict';

// The only module allowed to spawn processes (docs/12 rule 2) or write files (rule 3).

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';

let last_error = null;

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
// stderr separately: stderr goes to a mktemp file, and the exit code plus that file's
// path are appended to stdout after a marker line. argv arrives as "$@", so nothing
// from the caller is ever interpolated into the script text.
const WRAPPER = join(' ', [
	'e=$(mktemp ' + C.TMP_DIR + '/aether-proxy-sys.XXXXXX) ||',
	'{ printf "\\n@@AP-RC@@ 125 -\\n"; exit 125; };',
	'"$@" </dev/null 2>"$e"; rc=$?;',
	'printf "\\n@@AP-RC@@ %s %s\\n" "$rc" "$e"'
]);
const MARKER = "\n@@AP-RC@@ ";

function first_line(s, max) {
	let line = split(trim(s ?? ''), '\n')[0];

	return length(line) > max ? substr(line, 0, max) : line;
}

// run(argv, opts) -> { code, stdout, stderr }
// opts.timeout: seconds, enforced with timeout(1). opts.quiet: do not log CMD_FAILED.
// code is -1 if the wrapper's result could not be read, and 124/143 on a timeout
// (busybox and coreutils differ).
function run(argv, opts) {
	if (type(argv) != 'array' || !length(argv))
		die('sys.run: argv must be a non-empty array');

	opts ??= {};

	let args = map(argv, a => `${a}`);

	if (opts.timeout != null) {
		// TODO(design): docs do not say how timeouts are enforced; relies on timeout(1)
		// being present (OpenWrt busybox applet, enabled by default).
		unshift(args, 'timeout', `${opts.timeout}`);
	}

	let cmdline = 'sh -c ' + q(WRAPPER) + ' sh ' + join(' ', map(args, q));
	let res = { code: -1, stdout: '', stderr: '' };
	let fp = fs.popen(cmdline, 'r');

	if (!fp) {
		res.stderr = `popen failed: ${fs_err()}`;
	}
	else {
		// The leading newline sidesteps rindex() failing to report a match at offset 0
		// (seen on the pinned ucode build) when the command printed nothing.
		let out = '\n' + (fp.read('all') ?? '');
		let wrc = fp.close();
		let pos = rindex(out, MARKER);

		if (pos < 0) {
			res.stdout = substr(out, 1);
			res.stderr = `wrapper produced no result (sh exit ${wrc})`;
		}
		else {
			let m = match(substr(out, pos + length(MARKER)), /^([0-9]+) ([^\n]*)\n$/);

			res.stdout = substr(out, 1, pos - 1);

			if (m) {
				res.code = +m[1];

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
		log.event('error', 'CMD_FAILED', {
			cmd: join(' ', argv),
			rc: res.code,
			stderr: first_line(res.stderr, 200)
		});
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

function error() {
	return last_error;
}

export { q, run, write_atomic, mkdir_p, error };
