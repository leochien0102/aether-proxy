'use strict';

// Read-only rule inventory; docs/10 "规则与 DNS 页" and docs/08 local hashes.
// Status failures are returned, never logged: opening this page must not add events.
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
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

function count_lines(paths) {
	// One native scan avoids splitting the large chnlist into ucode strings (docs/10, T10.7).
	// grep exits 1 when every count is zero; quiet keeps this read-only command event-free.
	let result = sys.run([ 'grep', '-H', '-c', '-v', '-E', '^[ \t\r]*(#|$)', ...values(paths) ],
		{ timeout: 5, quiet: true });
	let failure = { ok: false, code: 'CMD_FAILED', detail: `grep exit ${result.code}` };
	if (result.code != 0 && result.code != 1)
		return failure;

	let counts = {};
	for (let line in split(rtrim(result.stdout, '\n'), '\n')) {
		// Match the final colon: a test root (or a filename) may itself contain colons.
		let row = match(line, /^(.*):([0-9]+)$/);
		if (row == null || index(values(paths), row[1]) < 0)
			return failure;
		if (counts[row[1]] != null)
			return failure;
		counts[row[1]] = +row[2];
	}
	for (let name, path in paths)
		if (counts[path] == null)
			return failure;
	return { ok: true, counts };
}

function inventory(root, run_dir) {
	let records = read_updates(`${run_dir}/${C.UPDATE_FILE}`);
	let items = {}, paths = {};
	for (let name in C.DATA_STATUS_NAMES) {
		let filename = C.DATA_DOMAIN_FILES[name] ?? C.DATA_IP_FILES[name];
		let path = `${root}${C.DATA_DIR}/${filename}`;
		let stat = fs.stat(path);
		let downloaded = stat != null;
		if (!downloaded) {
			path = `${root}${C.BASELINE_DATA_DIR}/${filename}`;
			stat = fs.stat(path);
		}
		let hash = update.local_data_hash(root, name, filename, true);
		// TODO(design): missing data or unavailable hashes have no specified status representation.
		// Return an explicit failure rather than fabricate an empty, healthy inventory.
		if (stat == null || !hash.ok)
			return { ok: false, code: 'FS_FAILED', detail: `cannot inspect data ${name}` };
		paths[name] = path;
		let changed = records.data?.[name]?.changed;
		items[name] = {
			source: downloaded ? 'downloaded' : 'baseline', version: substr(hash.hash, 0, 12), lines: null,
			updated_at: downloaded ? stat.mtime : null,
			changed: type(changed) == 'bool' ? changed : null
		};
	}
	let counted = count_lines(paths);
	if (!counted.ok)
		return counted;
	for (let name, path in paths)
		items[name].lines = counted.counts[path];
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
