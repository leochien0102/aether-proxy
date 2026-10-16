'use strict';

// `aether-proxy node import <uri>` (docs/10 "`log`、`node import`、`custom`", 2026-10-16).

import * as node from 'aetherproxy.node';
import * as pipeline from 'aetherproxy.pipeline';

const USAGE = 'Usage: aether-proxy node import <uri> [--json] [--confdir <dir>] [--run-dir <dir>] [--sys-root <dir>]';
const CONTEXT_OPTIONS = { '--confdir': 'confdir', '--run-dir': 'run_dir', '--sys-root': 'sys_root' };

function parse_args(args) {
	let opts = {}, positional = [];

	for (let i = 0; i < length(args); i++) {
		let arg = args[i];

		if (arg == '--json') {
			opts.json = true;
			continue;
		}

		let key = CONTEXT_OPTIONS[arg];
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

function human(result) {
	if (!result.ok)
		return `${result.code}: ${result.detail}`;

	return result.duplicate
		? `already present as ${result.node}`
		: `imported as ${result.node}`;
}

export function run(args) {
	let parsed = parse_args(args);
	if (parsed.error)
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			{ ok: false, code: 'USAGE', detail: parsed.error }, 2,
			`${parsed.error}\n${USAGE}`);

	if (parsed.positional[0] != 'import' || length(parsed.positional) != 2)
		return pipeline.finish(parsed.opts, { ok: false, code: 'USAGE', detail: 'expected `node import <uri>`' }, 2,
			`expected \`node import <uri>\`\n${USAGE}`);

	let result = node.import_node({ opts: parsed.opts }, parsed.positional[1]);
	// The documented reply shape (docs/10): no internal fields on the wire.
	let value = result.ok
		? { ok: true, node: result.node, duplicate: result.duplicate }
		: { ok: false, code: result.code, detail: result.detail };
	return pipeline.finish(parsed.opts, value, result.exit, human(result));
};
