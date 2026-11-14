'use strict';

// Installed package versions from the native package databases (M4-19).
// The component banner is what the binary reports; the package manager is what the
// device actually installed. The page shows both and flags a mismatch (docs/04).
import * as fs from 'fs';
import * as C from 'aetherproxy.const';

// opkg status: blocks of "Package: x" / "Version: y", separated by blank lines.
export function parse_opkg(text) {
	let result = {};
	if (type(text) != 'string')
		return result;
	let current = null;
	for (let raw in split(text, '\n')) {
		let line = trim(raw);
		if (line == '') {
			current = null;
			continue;
		}
		let matched = match(line, /^Package:[ \t]*(\S+)$/);
		if (matched != null) {
			current = matched[1];
			continue;
		}
		matched = match(line, /^Version:[ \t]*(\S+)$/);
		if (matched != null && current != null)
			result[current] = matched[1];
	}
	return result;
};

// apk installed: blocks of "P:name" / "V:version"; other "K:" fields are irrelevant.
export function parse_apk(text) {
	let result = {};
	if (type(text) != 'string')
		return result;
	let current = null;
	for (let raw in split(text, '\n')) {
		let line = trim(raw);
		if (line == '') {
			current = null;
			continue;
		}
		let matched = match(line, /^P:(.+)$/);
		if (matched != null) {
			current = matched[1];
			continue;
		}
		matched = match(line, /^V:(.+)$/);
		if (matched != null && current != null)
			result[current] = matched[1];
	}
	return result;
};

// Read both databases; a missing database is normal (only one manager is installed).
export function read(paths) {
	let result = {};
	for (let path in paths ?? [ C.OPKG_STATUS_PATH, C.APK_INSTALLED_PATH ]) {
		let text = fs.readfile(path);
		if (type(text) != 'string')
			continue;
		let parsed = index(path, 'status') >= 0 ? parse_opkg(text) : parse_apk(text);
		for (let name, version in parsed)
			if (result[name] == null)
				result[name] = version;
	}
	return result;
};
