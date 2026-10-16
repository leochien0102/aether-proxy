'use strict';

import * as pipeline from 'aetherproxy.pipeline';
import * as update from 'aetherproxy.update';

const VALUE_OPTIONS = {
	'--confdir': 'confdir', '--run-dir': 'run_dir', '--sys-root': 'sys_root', '--bin-dir': 'bin_dir'
};

function parse_args(args) {
	let opts = {}, positional = [];
	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json') {
			opts.json = true;
			continue;
		}
		let key = VALUE_OPTIONS[arg];
		if (key != null) {
			if (i + 1 >= length(args))
				return { error: `option ${arg} needs a value` };
			opts[key] = args[++i];
			continue;
		}
		if (substr(arg, 0, 1) == '-')
			return { error: `unknown option ${arg}` };
		push(positional, arg);
	}
	return { opts, positional };
}

function usage(opts, detail) {
	return pipeline.finish(opts, { ok: false, code: 'USAGE', detail }, 2,
		`${detail}\nUsage: aether-proxy update check [options]\n       aether-proxy update data [options]\n       aether-proxy update package (not implemented yet)`);
}

export function run(args) {
	let parsed = parse_args(args);
	if (parsed.error)
		return usage({ json: index(args, '--json') >= 0 }, parsed.error);
	if (length(parsed.positional) != 1 || index([ 'check', 'data' ], parsed.positional[0]) < 0)
		return usage(parsed.opts, parsed.positional[0] == 'package' ? '尚未实现' : 'expected `update check` or `update data`');
	let result = parsed.positional[0] == 'data' ? update.data_update(parsed.opts) : update.check(parsed.opts);
	if (!result.ok)
		return pipeline.finish(parsed.opts, parsed.positional[0] == 'data'
			? { ok: false, code: result.code, updated: result.updated, unchanged: result.unchanged, failed: result.failed }
			: { ok: false, code: result.code, detail: result.detail }, result.exit,
			parsed.positional[0] == 'data' && result.code == null ? 'update data completed with failures' : `${result.code}: ${result.detail}`);
	if (parsed.positional[0] == 'data')
		return pipeline.finish(parsed.opts, { ok: true, updated: result.updated, unchanged: result.unchanged, failed: result.failed }, 0, 'update data completed');
	return pipeline.finish(parsed.opts, result.value, 0, 'update check completed');
};
