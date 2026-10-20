'use strict';

// Read update discovery results and detect package database changes (docs/08 "缓存过期").
// Keep this dependency chain light: status is polled every five seconds and must not
// load update.uc or invoke a package manager just to decide whether its cache is usable.
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';

function read_object(path) {
	let text = fs.readfile(path);
	if (text == null) {
		let detail = fs.error() ?? 'unknown error';
		if (detail != 'No such file or directory')
			log.event('error', 'FS_FAILED', { op: 'read', path, detail });
		return null;
	}
	try {
		let value = json(text);
		if (type(value) == 'object')
			return value;
		log.event('error', 'FS_FAILED', { op: 'parse', path, detail: 'expected a JSON object' });
		return null;
	}
	catch (e) {
		log.event('error', 'FS_FAILED', { op: 'parse', path, detail: e.message ?? `${e}` });
		return null;
	}
}

export function read(run_dir, sys_root) {
	let value = read_object(`${run_dir}/${C.UPDATE_FILE}`);
	let result = { value, stale: false };
	if (type(value?.checked) != 'int' && type(value?.checked) != 'double')
		return result;
	let path = value.pm == 'opkg' ? C.OPKG_STATUS_PATH : value.pm == 'apk' ? C.APK_INSTALLED_PATH : null;
	if (path == null)
		return result;
	let root = replace(sys_root ?? '', /\/$/, '');
	let info = fs.stat(root + path);
	// Unknown database state is explicitly not stale; probing it must not emit events.
	if (type(info?.mtime) == 'int' || type(info?.mtime) == 'double')
		result.stale = info.mtime > value.checked;
	return result;
};
