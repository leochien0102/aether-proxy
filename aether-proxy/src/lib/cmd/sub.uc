'use strict';
// Expose subscription updates and read-only records through the CLI's result contract.
// Design: docs/06「原子应用」 and docs/10「订阅页（2026-10-16 定，T8.6）」.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';
import * as sub from 'aetherproxy.sub';

const USAGE = 'Usage: aether-proxy sub status [--json] [--confdir <dir>] [--sys-root <dir>]\n       aether-proxy sub update [<subscription>] [--json] [--confdir <dir>] [--run-dir <dir>] [--sys-root <dir>] [--bin-dir <dir>]';

function usage(detail, json) {
	return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail }, 2, `${detail}\n${USAGE}`);
}

function parse_args(args) {
	let opts = {}, positional = [];
	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json') {
			opts.json = true;
			continue;
		}
		let option = {
			'--confdir': 'confdir', '--run-dir': 'run_dir',
			'--sys-root': 'sys_root', '--bin-dir': 'bin_dir'
		}[arg];
		if (option != null) {
			if (i + 1 >= length(args))
				return { error: `option ${arg} needs a value` };
			opts[option] = args[++i];
			continue;
		}
		if (substr(arg, 0, 1) == '-')
			return { error: `unknown option ${arg}` };
		push(positional, arg);
	}
	return { opts, positional };
}

function public_results(result) {
	let subs = {};
	for (let name, item in result.subs) {
		if (item.disabled) {
			subs[name] = { ok: true, disabled: true };
			continue;
		}
		subs[name] = {
			ok: item.ok,
			code: item.code,
			added: item.added,
			updated: item.updated,
			stale: item.stale,
			revived: item.revived,
			removed: item.removed,
			skipped: item.skipped
		};
	}
	return { ok: result.ok, subs };
}

function human_result(result) {
	let lines = [];
	for (let name in sort(keys(result.subs))) {
		let item = result.subs[name];
		push(lines, `${name}: ${item.ok ? 'ok' : item.code}, added=${item.added}, updated=${item.updated}, stale=${item.stale}, revived=${item.revived}, removed=${item.removed}`);
		if (item.detail)
			push(lines, `  ${item.detail}`);
	}
	if (!length(lines))
		push(lines, 'no enabled subscriptions to update');
	return join('\n', lines);
}

// Unlike the updater's reader, this read path must not log corrupt records.
function status_records(path) {
	let text = fs.readfile(path);
	if (text == null)
		return {};
	try {
		let value = json(text);
		return type(value) == 'object' ? value : {};
	}
	catch (e) {
		return {}; // Corrupt status explicitly means no records (docs/10).
	}
}

export function run(args) {
	let json = index(args, '--json') >= 0;
	let parsed = parse_args(args);
	if (parsed.error)
		return usage(parsed.error, json);
	if (parsed.positional[0] == 'status') {
		if (length(parsed.positional) != 1)
			return usage('expected `sub status`', json);
		let opts = parsed.opts;
		let cursor = uci.cursor(opts.confdir ?? C.CONFIG_DIR);
		// docs/10「订阅页」 (`sub status`): without configuration we cannot identify
		// surviving subscriptions, so fail with CONFIG_INVALID instead of exposing orphan records.
		if (!cursor.load(C.UCI_PACKAGE))
			return pipeline.finish(opts, { ok: false, code: 'CONFIG_INVALID', detail: 'cannot load configuration' }, 2, 'cannot load configuration');
		let records = status_records(`${sub.system_path(opts.sys_root ?? '', C.STATE_DIR)}/${C.SUB_STATE_FILE}`);
		let subs = {};
		cursor.foreach(C.UCI_PACKAGE, 'subscription', section => {
			let id = section['.name'];
			if (id in records)
				subs[id] = records[id];
		});
		return pipeline.finish(opts, { ok: true, subs }, 0, sprintf('%.J', subs));
	}
	if (parsed.positional[0] != 'update' || length(parsed.positional) > 2)
		return usage('expected `sub update [<subscription>]`', !!parsed.opts.json);

	let name = parsed.positional[1] ?? null;
	let result = sub.update({ opts: parsed.opts }, name);
	if (result.exit == 2 || result.exit == 3 || result.code == 'FS_FAILED') {
		let value = { ok: false, code: result.code, detail: result.detail };
		return pipeline.finish(parsed.opts, value, result.exit, `${result.code}: ${result.detail}`);
	}

	let value = public_results(result);
	let exit = result.ok ? 0 : 1;
	return pipeline.finish(parsed.opts, value, exit, human_result(result));
};
