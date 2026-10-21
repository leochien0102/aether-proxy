'use strict';

// Node parse/import and committed node selection (docs/10 "node parse" and "切换节点").
// Selection only changes main.node; session/global UCI deltas must never be committed here.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as schema from 'aetherproxy.schema';
import * as state from 'aetherproxy.state';
import * as sys from 'aetherproxy.sys';

import * as node from 'aetherproxy.node';
import * as pipeline from 'aetherproxy.pipeline';

const USAGE = 'Usage: aether-proxy node parse <uri> | node import <uri> | node use <id> [--json] [--confdir <dir>]';
// Match the node_import RPC boundary (docs/10); these are input limits, not system paths.
const URI_MAX_BYTES = 4096;
const URI_SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//;
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

function use_failure(opts, code, detail, op) {
	let value = { ok: false, code, detail };
	if (op != null)
		value.op = op;
	return pipeline.finish(opts, value, code == 'USAGE' ? 2 : 1, `${code}: ${detail}`);
}

function use_node(opts, id) {
	if (match(id, schema.NODE_NAME_RE) == null)
		return use_failure(opts, 'USAGE', 'invalid node ID');

	let root = replace(opts.sys_root ?? '', /\/$/, '');
	let confdir = fs.realpath(opts.confdir ?? (root + C.CONFIG_DIR));
	if (confdir == null)
		return use_failure(opts, 'FS_FAILED', fs.error() ?? 'cannot locate configuration', 'uci-commit');

	let cursor = uci.cursor(confdir);
	// libuci absolute-path loads disable delta replay (has_delta=false). Merely
	// passing a private savedir would STILL replay /tmp/.uci from delta_path.
	// Commit the loaded package by name: libuci retains its original file path.
	if (!cursor.load(confdir + '/' + C.UCI_PACKAGE))
		return use_failure(opts, 'FS_FAILED', cursor.error() ?? 'cannot load configuration', 'uci-commit');
	if (cursor.get(C.UCI_PACKAGE, id) != 'node')
		return use_failure(opts, 'USAGE', `unknown node ID '${id}'`);

	let previous = cursor.get(C.UCI_PACKAGE, 'main', 'node');
	if (previous == id)
		return pipeline.finish(opts, { ok: true, node: id, previous, reload: false }, 0, `already using ${id}`);

	let current = state.read(opts.run_dir ?? (root + C.RUN_DIR));
	// Refuse before committing: guessing "stopped" could silently skip a required reload (docs/10).
	if (current == null)
		return use_failure(opts, 'FS_FAILED', state.error(), 'read');
	if (!cursor.set(C.UCI_PACKAGE, 'main', 'node', id) || !cursor.commit(C.UCI_PACKAGE))
		return use_failure(opts, 'FS_FAILED', cursor.error() ?? 'cannot commit main.node', 'uci-commit');

	let reload = index([ 'starting', 'running', 'degraded', 'failsafe' ], current.state) >= 0;
	if (reload) {
		let init = root + C.PROG_INIT;
		let res = sys.run([ init, 'reload' ], { timeout: C.NODE_USE_TIMEOUT_SECS, quiet: true });
		if (res.code != 0)
			return use_failure(opts, 'CMD_FAILED', `${init} reload: exit ${res.code}: ${trim(res.stderr)}`);
	}
	return pipeline.finish(opts, { ok: true, node: id, previous, reload }, 0, `selected ${id}`);
}

function parse_node(opts, line) {
	// The rpcd boundary's limits, checked on the CLI too; `node import` keeps its
	// existing CLI contract (docs/10 "node parse").
	if (length(line) > URI_MAX_BYTES || match(line, URI_SCHEME_RE) == null)
		return pipeline.finish(opts,
			{ ok: false, code: 'USAGE', detail: `uri must be a node share URI (at most ${URI_MAX_BYTES} bytes)` },
			2, USAGE);
	let value = node.parse_node(line);
	return pipeline.finish(opts, value, value.ok ? 0 : 2,
		value.ok ? sprintf('%.J', value) : `${value.code}: ${value.detail}`);
}

export function run(args) {
	let parsed = parse_args(args);
	if (parsed.error)
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			{ ok: false, code: 'USAGE', detail: parsed.error }, 2,
			`${parsed.error}\n${USAGE}`);

	if (parsed.positional[0] == 'parse' && length(parsed.positional) == 2)
		return parse_node(parsed.opts, parsed.positional[1]);

	if (parsed.positional[0] == 'use' && length(parsed.positional) == 2)
		return use_node(parsed.opts, parsed.positional[1]);

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
