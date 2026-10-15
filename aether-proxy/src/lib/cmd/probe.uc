'use strict';

import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';
import * as probe from 'aetherproxy.probe';
import * as schema from 'aetherproxy.schema';
import * as sys from 'aetherproxy.sys';

const USAGE = 'Usage: aether-proxy probe nodes [<node-id>...] [--json] [--confdir <dir>] [--run-dir <dir>]';

function usage(detail, json) {
	return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail, errors: [] }, 2, `${detail}\n${USAGE}`);
};

function human_result(result) {
	let lines = [ `Probe completed at ${result.at}` ];

	for (let id in sort(keys(result.nodes))) {
		let node = result.nodes[id];
		let latency = node.median_ms == null ? 'n/a' : `${node.median_ms} ms`;
		push(lines, `${id}: ${node.ok}/3 connected, ip=${node.ip ?? 'n/a'}, median=${latency}, error=${node.error ?? 'none'}`);
	}

	return join('\n', lines);
};

export function run(args) {
	let parsed = pipeline.parse_args(args);
	let json = !!(parsed.opts?.json || index(args, '--json') >= 0);
	if (parsed.error)
		return usage(parsed.error, json);

	let opts = parsed.opts;
	let allowed_options = [ 'json', 'confdir', 'run_dir', 'sys_root', 'bin_dir' ];
	for (let key in keys(opts))
		if (index(allowed_options, key) < 0)
			return usage(`option --${replace(key, /_/g, '-')} is not supported by probe`, json);

	if (!length(parsed.positional) || parsed.positional[0] != 'nodes')
		return usage('expected `probe nodes`', json);

	let requested = slice(parsed.positional, 1);
	let loaded = config.load(uci.cursor(opts.confdir));
	if (!loaded.ok) {
		log.event(null, 'CONFIG_INVALID', { detail: `${length(loaded.errors)} configuration error(s)` });
		return pipeline.finish(opts,
			{ ok: false, code: 'CONFIG_INVALID', detail: `${length(loaded.errors)} configuration error(s)`, errors: loaded.errors },
			2, pipeline.describe_errors({ code: 'CONFIG_INVALID', detail: `${length(loaded.errors)} configuration error(s)`, errors: loaded.errors }));
	}

	let ids = length(requested) ? requested : sort(keys(loaded.snapshot.nodes));
	let unique_ids = {};
	let selected_ids = [];
	for (let id in ids)
		if (!unique_ids[id]) {
			unique_ids[id] = true;
			push(selected_ids, id);
		}
	ids = sort(selected_ids);

	for (let id in ids)
		if (match(id, schema.NODE_NAME_RE) == null || loaded.snapshot.nodes[id] == null) {
			// TODO(design): docs/07 does not specify how unknown requested IDs should be represented.
			return usage(`unknown node ID '${id}'`, json);
		}

	let result = probe.probe_nodes(loaded.snapshot.nodes, ids,
		loaded.snapshot.probe.node_timeout, loaded.snapshot.probe.node_concurrency, opts.bin_dir);
	// --sys-root moves the default run dir like everywhere else (10, test-only options).
	let run_dir = opts.run_dir ?? (opts.sys_root ? replace(opts.sys_root, /\/$/, '') + C.RUN_DIR : C.RUN_DIR);
	let path = run_dir + '/' + C.PROBE_FILE;

	if (!sys.write_atomic(path, sprintf('%.J', result) + '\n')) {
		let detail = sys.error() ?? 'unknown error';
		log.event('error', 'FS_FAILED', { op: 'write', path, detail });
		return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail }, 1, `cannot write ${path}: ${detail}`);
	}

	return pipeline.finish(opts, result, 0, human_result(result));
};
