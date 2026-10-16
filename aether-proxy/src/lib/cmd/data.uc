'use strict';

// Read-only rule inventory; docs/10 "规则与 DNS 页" and docs/08 local hashes.
// Status failures are returned, never logged: opening this page must not add events.
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as update from 'aetherproxy.update';
import * as pipeline from 'aetherproxy.pipeline';

function read_updates(path) {
	let text = fs.readfile(path);
	if (text == null)
		return {};
	try {
		let value = json(text);
		return type(value) == 'object' ? value : {};
	}
	catch (e) {
		return {}; // Corrupt cache explicitly means not checked (docs/10).
	}
}

function inventory(root, run_dir) {
	let records = read_updates(`${run_dir}/${C.UPDATE_FILE}`);
	let items = {};
	for (let name in C.DATA_STATUS_NAMES) {
		let filename = C.DATA_DOMAIN_FILES[name] ?? C.DATA_IP_FILES[name];
		let path = `${root}${C.DATA_DIR}/${filename}`;
		let stat = fs.stat(path);
		let downloaded = stat != null;
		if (!downloaded) {
			path = `${root}${C.BASELINE_DATA_DIR}/${filename}`;
			stat = fs.stat(path);
		}
		let text = fs.readfile(path);
		let hash = update.local_data_hash(root, name, filename, true);
		// TODO(design): missing/unreadable data has no specified status representation.
		// Return an explicit failure rather than fabricate an empty, healthy inventory.
		if (text == null || stat == null || !hash.ok)
			return { ok: false, code: 'FS_FAILED', detail: `cannot inspect data ${name}` };
		let lines = 0;
		for (let line in split(text, '\n')) {
			line = trim(line);
			if (length(line) && substr(line, 0, 1) != '#')
				lines++;
		}
		let changed = records.data?.[name]?.changed;
		items[name] = {
			source: downloaded ? 'downloaded' : 'baseline', version: substr(hash.hash, 0, 12), lines,
			updated_at: downloaded ? stat.mtime : null,
			changed: type(changed) == 'bool' ? changed : null
		};
	}
	return { ok: true, checked: records.checked ?? null, items };
}

export function run(args) {
	let opts = {}, positional = [];
	let json_output = index(args, '--json') >= 0;
	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json') {
			opts.json = true;
			continue;
		}
		if ((arg == '--sys-root' || arg == '--run-dir') && i + 1 < length(args)) {
			opts[arg == '--sys-root' ? 'root' : 'run_dir'] = args[++i];
			continue;
		}
		push(positional, arg);
	}
	if (length(positional) != 1 || positional[0] != 'status')
		return pipeline.finish({ json: json_output }, {
			ok: false, code: 'USAGE', detail: 'expected data status [--json] [--sys-root <dir>] [--run-dir <dir>]'
		}, 2, 'Usage: data status');
	let root = replace(opts.root ?? '', /\/$/, '');
	let value = inventory(root, opts.run_dir ?? `${root}${C.RUN_DIR}`);
	return pipeline.finish(opts, value, value.ok ? 0 : 1, sprintf('%.J', value));
};
