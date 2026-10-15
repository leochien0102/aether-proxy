'use strict';

import * as pipeline from 'aetherproxy.pipeline';
import * as sub from 'aetherproxy.sub';

const USAGE = 'Usage: aether-proxy sub update [<subscription>] [--json] [--confdir <dir>] [--run-dir <dir>] [--sys-root <dir>] [--bin-dir <dir>]';

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
	for (let name, item in result.subs)
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

export function run(args) {
	let json = index(args, '--json') >= 0;
	let parsed = parse_args(args);
	if (parsed.error)
		return usage(parsed.error, json);
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
