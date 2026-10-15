'use strict';

// Runtime state is volatile and preserves fields added by newer daemon versions.

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';

let last_error = null;

function fs_err() {
	return fs.error() ?? 'unknown error';
}

// Returns the state object, the stopped default when absent, or null on an I/O/format error.
// TODO(design): docs/04 defines the missing-file default but not corrupt/unreadable state handling;
// report the error rather than silently treating it as stopped.
function read(run_dir) {
	let path = run_dir + '/' + C.STATE_FILE;
	let stat = fs.stat(path);

	if (stat == null) {
		let detail = fs_err();
		if (detail == 'No such file or directory') {
			last_error = null;
			return { state: 'stopped' };
		}

		last_error = `stat ${path}: ${detail}`;
		return null;
	}

	let text = fs.readfile(path);
	if (text == null) {
		last_error = `read ${path}: ${fs_err()}`;
		return null;
	}

	let obj = null;
	try {
		obj = json(text);	// throws on bad input
	}
	catch (e) {
		obj = null;
	}
	if (type(obj) != 'object') {
		last_error = `parse ${path}: expected a JSON object`;
		return null;
	}

	last_error = null;
	return obj;
}

function write(run_dir, obj) {
	if (type(obj) != 'object') {
		last_error = 'state.write: obj must be an object';
		return null;
	}

	let path = run_dir + '/' + C.STATE_FILE;
	// TODO(design): docs/04 does not say whether state.write should create a missing run directory.
	let result = sys.write_atomic(path, sprintf('%.J', obj) + '\n');
	last_error = result ? null : sys.error();
	return result;
}

function error() {
	return last_error;
}

export { read, write, error };
