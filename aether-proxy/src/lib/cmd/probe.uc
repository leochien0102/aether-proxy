'use strict';

// `aether-proxy probe nodes|results` (docs/07 「节点可达性检测」, 「实现细节」 2026-10-16).
//
// `probe nodes` runs the TCP probes and records the outcome incrementally:
// one write before probing, one per finished node and one final write with
// finished: true. Results of nodes that stay in the configuration survive a
// partial run; results of nodes that vanished from it are dropped.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';
import * as probe from 'aetherproxy.probe';
import * as schema from 'aetherproxy.schema';
import * as sys from 'aetherproxy.sys';

const USAGE = 'Usage: aether-proxy probe nodes [<node-id>...] [--json] [--confdir <dir>] [--run-dir <dir>]\n'
	+ '       aether-proxy probe results [--json] [--run-dir <dir>]';

function usage(detail, json) {
	return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail, errors: [] }, 2, `${detail}\n${USAGE}`);
};

// The default reply of `probe results` (docs/07 「实现细节」): a missing or
// damaged file is "no results yet", not an error, and must never log events --
// the LuCI nodes page polls this while a probe job is running.
export function empty_results() {
	return { ok: true, at: null, nodes: {}, done: 0, total: 0, finished: true, pending: [] };
};

// Reads probe.json for `probe results` (docs/07: the file content as-is) and for
// deciding which old results survive a new run. Returns null when the file is
// missing or unusable -- half-written files cannot occur through write_atomic,
// so damage means external tampering and counts as "no results".
export function read_results(path) {
	let text = fs.readfile(path);

	if (text == null)
		return null;

	let data;

	try {
		data = json(text);
	}
	catch (e) {
		return null;
	}

	return (type(data) == 'object' && type(data.nodes) == 'object') ? data : null;
};

// docs/07 「实现细节」: old results survive for nodes that are still configured,
// results of nodes that vanished from the configuration are dropped.
export function keep_old_nodes(old, configured_nodes) {
	let kept = {};

	if (old != null)
		for (let id, result in old.nodes)
			if (configured_nodes[id] != null)
				kept[id] = result;

	return kept;
};

// The incremental recorder (docs/07 「实现细节」): keeps the results of nodes that
// are still configured, writes once with done: 0 before probing, once per
// finished node and a final write with finished: true and the completion time.
// Exported so the tests can wrap on_node_done and snapshot the file between
// writes; run() uses exactly this path.
export function new_recorder(path, ids, kept_nodes, start_at) {
	let state = {
		at: start_at,
		nodes: { ...kept_nodes },
		done: 0,
		total: length(ids),
		finished: false,
		pending: [ ...ids ]
	};
	// TODO(design): docs/07 does not say what a failed incremental write should do
	// to the run. Conservative choice: log the first failure as FS_FAILED, stop
	// writing (readers keep the last good file), keep probing and fail the
	// command with exit 1 at the end.
	let failed = null;

	function flush() {
		if (failed != null)
			return;

		if (!sys.write_atomic(path, sprintf('%.J', state) + '\n')) {
			failed = sys.error() ?? 'unknown error';
			log.event('error', 'FS_FAILED', { op: 'write', path, detail: failed });
		}
	}

	// The initial write: start time, no completions yet, everything pending.
	flush();

	return {
		on_node_done: function(id, summary) {
			state.nodes[id] = summary;
			state.done++;
			let pos = index(state.pending, id);
			if (pos >= 0)
				splice(state.pending, pos, 1);
			flush();
		},
		finish: function() {
			state.finished = true;
			state.at = time();
			state.pending = [];
			flush();
			return { state, error: failed };
		}
	};
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

function probe_nodes_cmd(opts, parsed, json) {
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

	// --sys-root moves the default run dir like everywhere else (10, test-only options).
	let run_dir = opts.run_dir ?? (opts.sys_root ? replace(opts.sys_root, /\/$/, '') + C.RUN_DIR : C.RUN_DIR);
	let path = run_dir + '/' + C.PROBE_FILE;

	// Results of nodes that are still configured survive the new run (docs/07
	// 「实现细节」); nodes that vanished from the configuration are dropped here.
	let kept = keep_old_nodes(read_results(path), loaded.snapshot.nodes);

	let recorder = new_recorder(path, ids, kept, time());
	probe.probe_nodes(loaded.snapshot.nodes, ids,
		loaded.snapshot.probe.node_timeout, loaded.snapshot.probe.node_concurrency, opts.bin_dir,
		recorder.on_node_done);
	let final = recorder.finish();

	if (final.error != null) {
		let detail = final.error;
		return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail, errors: [] }, 1, `cannot write ${path}: ${detail}`);
	}

	// --json prints the complete content of the last write (docs/07 「实现细节」).
	return pipeline.finish(opts, final.state, 0, human_result(final.state));
};

function probe_results_cmd(opts, parsed, json) {
	if (length(parsed.positional) > 1)
		return usage('probe results takes no node IDs', json);

	// --sys-root moves the default run dir like everywhere else (10, test-only options).
	let run_dir = opts.run_dir ?? (opts.sys_root ? replace(opts.sys_root, /\/$/, '') + C.RUN_DIR : C.RUN_DIR);
	let path = run_dir + '/' + C.PROBE_FILE;
	// Same shape either way: the file content plus ok: true (the default already has it).
	let stored = read_results(path);
	let result = stored == null ? empty_results() : { ...stored, ok: true };

	// Read-only: no events, exit 0, the file content as-is (docs/07 「实现细节」).
	return pipeline.finish(opts, result, 0, human_result(result));
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

	if (!length(parsed.positional))
		return usage('expected `probe nodes` or `probe results`', json);

	if (parsed.positional[0] == 'results')
		return probe_results_cmd(opts, parsed, json);

	if (parsed.positional[0] != 'nodes')
		return usage('expected `probe nodes` or `probe results`', json);

	return probe_nodes_cmd(opts, parsed, json);
};
