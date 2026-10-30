'use strict';

// Node parse/import and shared node/mode selection (docs/10 "切换节点" / "切换默认模式").
// Selection only changes the requested main options; session/global UCI deltas must stay staged.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as schema from 'aetherproxy.schema';
import * as state from 'aetherproxy.state';
import * as sys from 'aetherproxy.sys';

import * as node from 'aetherproxy.node';
import * as pipeline from 'aetherproxy.pipeline';
import * as config from 'aetherproxy.config';
import * as xray from 'aetherproxy.render.xray';
import * as check from 'aetherproxy.cmd.check';
import * as components from 'aetherproxy.cmd.components';

const USAGE = 'Usage: aether-proxy node parse <uri> | node import <uri> | node use <id> [--mode <mode>]';
const MODE_USAGE = 'Usage: aether-proxy mode use <gfw|bypass_cn|global>';
const MODES = filter(schema.SCHEMA.main, field => field.name == 'mode')[0].enum;
// Match the node_import RPC boundary (docs/10); these are input limits, not system paths.
const URI_MAX_BYTES = 4096;
const URI_SCHEME_RE = /^[A-Za-z][A-Za-z0-9+.-]*:\/\//;
const CONTEXT_OPTIONS = { '--confdir': 'confdir', '--run-dir': 'run_dir', '--sys-root': 'sys_root' };

function parse_args(args, allow_mode) {
	let opts = {}, positional = [];

	for (let i = 0; i < length(args); i++) {
		let arg = args[i];

		if (arg == '--json') {
			opts.json = true;
			continue;
		}

		let key = arg == '--mode' && allow_mode ? 'mode' : CONTEXT_OPTIONS[arg];
		if (key != null) {
			if (i + 1 >= length(args) || (key == 'mode' && substr(args[i + 1], 0, 1) == '-'))
				return { error: `option ${arg} needs a value` };
			// docs/10: a repeated --mode is ambiguous, so reject it before any write.
			if (key == 'mode' && opts.mode != null)
				return { error: 'option --mode may only be given once' };
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

// Preflight the committed package plus the requested selection, never rpcd's
// staged deltas or daemon-owned artifacts (docs/10 "切换节点", review Q5).
function preflight_selection(cursor, opts, root, id, mode) {
	let binary = check.find_component(C.XRAY_COMPONENT, cursor.get(C.UCI_PACKAGE, 'main', 'xray_bin'), opts);
	if (binary == null || components.read_component_version(binary.path, 'version', C.COMPONENTS_TIMEOUT_SECS) == null)
		return null;
	let raw = config.read_raw(cursor, C.UCI_PACKAGE);
	raw.main ??= {};
	raw.main.node = id;
	if (mode != null)
		raw.main.mode = mode;
	let validated = config.normalize(raw);
	if (!validated.ok)
		return { code: 'CONFIG_INVALID', detail: sprintf('%.J', validated.errors) };
	let dir = opts.run_dir ?? (root + C.RUN_DIR);
	if (!sys.mkdir_p(dir) && fs.stat(dir)?.type != 'directory')
		return { code: 'FS_FAILED', detail: sys.error() };
	let pid = fs.readlink(C.PROC_DIR + '/self');
	if (pid == null)
		return { code: 'FS_FAILED', detail: fs.error() ?? 'cannot read process id' };
	let scratch = `${dir}/${C.NODE_USE_DIR_PREFIX}${pid}`;
	// Exclusive mkdir prevents following a stale symlink or reusing another request's files.
	if (!fs.mkdir(scratch, 0700))
		return { code: 'FS_FAILED', detail: fs.error() ?? 'cannot create preflight directory' };
	let path = scratch + '/' + C.ARTIFACT_FILES.xray;
	let failure = null;
	try {
		if (!sys.write_atomic(path, xray.render(validated.snapshot, {})))
			failure = { code: 'FS_FAILED', detail: sys.error() };
		else {
			let result = sys.run([ binary.path, 'run', '-test', '-c', path ],
				{ timeout: C.NODE_USE_TEST_TIMEOUT_SECS, quiet: true });
			if (result.code != 0) {
				let detail = trim(result.stderr) || trim(result.stdout) || 'Xray configuration test failed';
				failure = { code: 'CONFIG_INVALID', detail: `xray run -test: exit ${result.code}: `
					+ substr(detail, -C.NODE_USE_ERROR_BYTES) };
			}
		}
	}
	catch (e) {
		failure = { code: 'CONFIG_INVALID', detail: `cannot preflight Xray configuration: ${e.message ?? e}` };
	}
	if (fs.lstat(path) != null && !fs.unlink(path))
		failure = { code: 'FS_FAILED', detail: fs.error() ?? 'cannot remove preflight configuration' };
	if (!fs.rmdir(scratch))
		failure = { code: 'FS_FAILED', detail: fs.error() ?? 'cannot remove preflight directory' };
	return failure;
}

// Both entry points use this transaction and reload path. Validate all requested
// values before touching UCI, so an invalid mode can never partially select a node.
function use_selection(opts, id, mode) {
	if (id != null && match(id, schema.NODE_NAME_RE) == null)
		return use_failure(opts, 'USAGE', 'invalid node ID');
	if (mode != null && index(MODES, mode) < 0)
		return use_failure(opts, 'USAGE', `mode must be one of ${join('|', MODES)}`);

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
	if (id != null && cursor.get(C.UCI_PACKAGE, id) != 'node')
		return use_failure(opts, 'USAGE', `unknown node ID '${id}'`);

	let previous_node = cursor.get(C.UCI_PACKAGE, 'main', 'node');
	let previous_mode = cursor.get(C.UCI_PACKAGE, 'main', 'mode');
	let node_changed = id != null && previous_node != id;
	let mode_changed = mode != null && previous_mode != mode;
	// Keep the legacy node-only wire shape and human output exactly unchanged.
	let value = id != null
		? { ok: true, node: id, previous: previous_node, reload: false }
		: { ok: true, mode, previous: previous_mode, reload: false };
	if (id != null && mode != null) {
		value.mode = mode;
		value.previous_mode = previous_mode;
	}
	let selection = id ?? mode;
	if (!node_changed && !mode_changed)
		return pipeline.finish(opts, value, 0, `already using ${selection}`);

	let current = state.read(opts.run_dir ?? (root + C.RUN_DIR));
	// Refuse before committing: guessing "stopped" could silently skip a required reload (docs/10).
	if (current == null)
		return use_failure(opts, 'FS_FAILED', state.error(), 'read');
	if (node_changed) {
		let failure = preflight_selection(cursor, opts, root, id, mode);
		if (failure != null)
			return use_failure(opts, failure.code, failure.detail);
	}
	if (node_changed && !cursor.set(C.UCI_PACKAGE, 'main', 'node', id))
		return use_failure(opts, 'FS_FAILED', cursor.error() ?? 'cannot commit main.node', 'uci-commit');
	if (mode_changed && !cursor.set(C.UCI_PACKAGE, 'main', 'mode', mode))
		return use_failure(opts, 'FS_FAILED', cursor.error() ?? 'cannot set main.mode', 'uci-commit');
	// One commit publishes both values; neither set() writes the configuration file.
	if (!cursor.commit(C.UCI_PACKAGE)) {
		let fallback = mode == null ? 'cannot commit main.node' : 'cannot commit selection';
		return use_failure(opts, 'FS_FAILED', cursor.error() ?? fallback, 'uci-commit');
	}

	let reload = index([ 'starting', 'running', 'degraded', 'failsafe' ], current.state) >= 0;
	if (reload) {
		let init = root + C.PROG_INIT;
		let res = sys.run([ init, 'reload' ], { timeout: C.NODE_USE_TIMEOUT_SECS, quiet: true });
		if (res.code != 0)
			return use_failure(opts, 'CMD_FAILED', `${init} reload: exit ${res.code}: ${trim(res.stderr)}`);
	}
	value.reload = reload;
	return pipeline.finish(opts, value, 0, `selected ${selection}`);
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

export function run_mode(args) {
	let parsed = parse_args(args, false);
	let opts = parsed.opts ?? { json: index(args, '--json') >= 0 };
	if (parsed.error || parsed.positional[0] != 'use' || length(parsed.positional) != 2)
		return pipeline.finish(opts,
			{ ok: false, code: 'USAGE', detail: parsed.error ?? 'expected `mode use <mode>`' }, 2, MODE_USAGE);
	return use_selection(opts, null, parsed.positional[1]);
};

export function run(args) {
	let parsed = parse_args(args, true);
	if (parsed.error)
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			{ ok: false, code: 'USAGE', detail: parsed.error }, 2,
			`${parsed.error}\n${USAGE}`);

	if (parsed.opts.mode != null && parsed.positional[0] != 'use')
		return use_failure(parsed.opts, 'USAGE', '--mode is only valid with node use');

	if (parsed.positional[0] == 'parse' && length(parsed.positional) == 2)
		return parse_node(parsed.opts, parsed.positional[1]);

	if (parsed.positional[0] == 'use' && length(parsed.positional) == 2)
		return use_selection(parsed.opts, parsed.positional[1], parsed.opts.mode);

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
