'use strict';

import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';
import * as state from 'aetherproxy.state';

function usage(args, detail) {
	let json = index(args, '--json') >= 0;
	let result = { ok: false, code: 'USAGE', detail, errors: [] };
	return pipeline.finish({ json }, result, 2, detail);
};

function human_status(value) {
	let lines = [ `state: ${value.state ?? 'unknown'}` ];

	for (let field in [ 'dns_tier', 'dns_failsafe', 'node_id', 'node_ip', 'since', 'last_probe', 'last_error', 'components', 'render_hash' ])
		if (value[field] != null)
			push(lines, `${field}: ${sprintf('%J', value[field])}`);

	return join('\n', lines);
}

export function run(args) {
	let parsed = pipeline.parse_args(args);
	if (parsed.error)
		return usage(args, parsed.error);

	if (length(parsed.positional))
		return usage(args, 'status takes no arguments');

	for (let key in keys(parsed.opts))
		if (key != 'json' && key != 'run_dir')
			return usage(args, `option --${replace(key, /_/g, '-')} is not supported by status`);

	let run_dir = pipeline.run_dir(parsed.opts);
	let current = state.read(run_dir);
	if (current == null) {
		let detail = state.error() ?? 'unknown state read error';
		log.event('error', 'FS_FAILED', { op: 'read', path: run_dir + '/' + C.STATE_FILE, detail });
		return pipeline.finish(parsed.opts,
			{ ok: false, code: 'FS_FAILED', detail }, 1, `cannot read status: ${detail}`);
	}

	return pipeline.finish(parsed.opts, current, 0, human_status(current));
};
