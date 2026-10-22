'use strict';

// Manual node import and read-only parsing (docs/10 "`log`、`node import`、`custom`").
//
// node_options(), parse_node(), plan_changes() and strong_keys() are pure (docs/12
// rule 1): parsing and planning never touch configuration. import_node() owns all I/O and
// reuses the subscription write path from sub.uc: stage under a renamed package, then
// replace the original only when it is unchanged in the meantime (docs/06 "原子应用"
// steps 3 and 5). Unlike a subscription update it never reloads: a new node is never the
// current node (docs/10).

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as identity from 'aetherproxy.identity';
import * as log from 'aetherproxy.log';
import * as sub from 'aetherproxy.sub';
import * as sys from 'aetherproxy.sys';
import * as uri from 'aetherproxy.uri';

// Section options written for a manual node (docs/05 "config node"), in output order.
const NODE_OPTION_FIELDS = [
	'label', 'source', 'match_strong', 'match_weak', 'protocol', 'address', 'port',
	'uuid', 'password', 'method', 'flow', 'encryption', 'transport', 'host', 'path',
	'service_name', 'xhttp_mode', 'header_type', 'security', 'sni', 'alpn',
	'fingerprint', 'pinned_cert_sha256', 'verify_name',
	'reality_pbk', 'reality_sid', 'reality_spx', 'reality_pqv', 'ech_config_list',
	'grpc_multi_mode', 'ws_heartbeat', 'xhttp_extra', 'mux', 'mux_concurrency',
	'mux_xudp_concurrency', 'mux_xudp_udp443', 'tcp_fast_open', 'tcp_mptcp'
];

function fs_error() {
	return fs.error() ?? 'unknown error';
}

// Pure: share exactly the UCI value conversion between parse and import (docs/10).
// Metadata belongs to the writer, never to the form populated by `node parse`.
export function node_options(node) {
	let desired = { ...node, label: node.label ?? `${node.address}:${node.port}` };
	let options = {};
	for (let field in NODE_OPTION_FIELDS) {
		if (index([ 'source', 'match_strong', 'match_weak' ], field) >= 0)
			continue;
		let value = desired[field];
		if (value == null || (field == 'alpn' && type(value) == 'array' && !length(value)))
			continue;
		// UCI stores strings; parsed ports arrive as numbers. Lists stay arrays.
		options[field] = type(value) == 'array' ? [ ...value ] : `${value}`;
	}
	return options;
};

// Pure: warnings are intentionally discarded here, not recorded as events (docs/10).
export function parse_node(line) {
	let parsed = uri.parse_line(line ?? '');
	if (parsed?.node == null)
		return { ok: false, code: 'CONFIG_INVALID', detail: parsed?.skip ?? 'malformed' };
	return { ok: true, node: node_options(parsed.node) };
};

// Pure: retain the import operation order while adding writer-only metadata.
export function plan_changes(node, id) {
	let keys = identity.keys(node);
	let desired = {
		...node_options(node), source: 'manual', match_strong: keys.strong, match_weak: keys.weak
	};
	let changes = [ { op: 'add', section: id, value: 'node' } ];
	for (let field in NODE_OPTION_FIELDS)
		if (desired[field] != null)
			push(changes, { op: 'set', section: id, option: field, value: desired[field] });
	return { id, changes, keys };
};

// Pure: fresh strong key of every configured node (never a stored match_strong: a
// hand-written node may not carry one; docs/10).
export function strong_keys(snapshot) {
	let out = {};
	for (let id, node in snapshot.nodes)
		out[id] = identity.keys(node).strong;
	return out;
};

// The result shape every exit path of import_node() produces.
function result(ok, code, node_id, duplicate, detail) {
	return {
		ok,
		code: ok ? null : code,
		node: node_id ?? null,
		duplicate: duplicate == true,
		detail: detail ?? null
	};
}

// Runs the test-only race hook (docs/tasks/m8.md T8.2 scenario 6): a hook command is
// executed between staging and the final replace so a test can modify the configuration
// concurrently. Like the other AETHER_PROXY_TEST_* variables it is never set in production;
// a failing hook is logged (sys.run records CMD_FAILED) and does not stop the import.
function run_race_hook() {
	let hook = getenv('AETHER_PROXY_TEST_NODE_IMPORT_RACE');
	if (hook == null || hook == '')
		return;
	sys.run([ hook ], { timeout: 10 });
}

function log_warnings(warnings, node_id) {
	for (let warning in warnings ?? [])
		log.event(null, warning.code, { node: node_id, label: warning.args?.label ?? '-' });
}

// import_node(ctx, line) -> { ok, code?, node, duplicate, detail?, exit }
// ctx is { opts } with the test options from docs/10; opts.confdir/run_dir are resolved
// here the same way sub.update() does it.
export function import_node(ctx, line) {
	ctx.root = ctx.sys_root ?? ctx.opts?.sys_root ?? ctx.root ?? '';
	ctx.opts = sub.absolute_options(ctx.opts ?? {});
	log.set_run_dir(ctx.opts.run_dir);

	let parsed = uri.parse_line(line ?? '');
	if (parsed?.node == null)
		return { ...result(false, 'CONFIG_INVALID', null, false, parsed?.skip ?? 'malformed'), exit: 2 };

	// Shared with subscription updates: both atomically replace the same configuration
	// file (docs/10 "node import"). Contention: BUSY, exit 3, nothing written.
	let lock = sys.lock(sub.system_path(ctx.root, C.SUB_LOCK_FILE));
	if (lock == null) {
		log.event('warn', 'BUSY', { holder: 'node import' });
		return { ...result(false, 'BUSY', null, false, sys.error()), exit: 3 };
	}

	let config_path = `${ctx.opts.confdir}/${C.UCI_PACKAGE}`;
	let original_text = fs.readfile(config_path);
	if (original_text == null) {
		let detail = `read ${config_path}: ${fs_error()}`;
		lock.close();
		log.event('error', 'CONFIG_INVALID', { field: C.UCI_PACKAGE, reason: detail });
		return { ...result(false, 'CONFIG_INVALID', null, false, detail), exit: 2 };
	}

	let loaded = sub.load_committed_config(ctx, original_text);
	if (!loaded.ok) {
		lock.close();
		let first = loaded.errors?.[0] ?? {};
		log.event('error', 'CONFIG_INVALID', { field: first.field ?? '-', reason: first.code ?? first.detail ?? 'invalid configuration' });
		return { ...result(false, 'CONFIG_INVALID', null, false,
			`${length(loaded.errors)} configuration error(s)`), exit: 2 };
	}

	// Duplicate check: fresh strong keys on both sides (docs/10).
	let strong = identity.keys(parsed.node).strong;
	let strong_map = strong_keys(loaded.snapshot);
	let existing = sort(keys(strong_map));
	for (let i = 0; i < length(existing); i++) {
		if (strong_map[existing[i]] != strong)
			continue;
		lock.close();
		log_warnings(parsed.warnings, existing[i]);
		return { ...result(true, null, existing[i], true), exit: 0 };
	}

	let all_ids = {};
	for (let i = 0; i < length(existing); i++)
		all_ids[existing[i]] = true;
	let id = sub.new_node_id(all_ids);
	if (id == null) {
		let detail = `cannot read 16 bytes from ${C.RANDOM_DEVICE}`;
		lock.close();
		log.event('error', 'FS_FAILED', { op: 'read', path: C.RANDOM_DEVICE, detail });
		return { ...result(false, 'FS_FAILED', null, false, detail), exit: 1 };
	}

	log_warnings(parsed.warnings, id);

	let planned = plan_changes(parsed.node, id);
	let staged = sub.stage_package(ctx, original_text, C.SUB_TEMP_PACKAGE, { changes: planned.changes });
	if (!staged.ok) {
		let detail = staged.detail;
		lock.close();
		log.event('error', 'FS_FAILED', { op: 'write', path: config_path, detail });
		return { ...result(false, 'FS_FAILED', null, false, detail), exit: 1 };
	}

	// Docs/10: the original file must be unchanged between the first read and the replace.
	run_race_hook();

	let current_text = fs.readfile(config_path);
	if (current_text == null || current_text != original_text) {
		let detail = current_text == null
			? `concurrent modification check could not read ${config_path}: ${fs_error()}`
			: 'the configuration was modified concurrently, please retry';
		lock.close();
		log.event('error', 'CONFIG_INVALID', { field: C.UCI_PACKAGE, reason: detail });
		return { ...result(false, 'CONFIG_INVALID', null, false, detail), exit: 2 };
	}

	if (staged.content != original_text && !sys.write_atomic(config_path, staged.content)) {
		let detail = `replace ${config_path}: ${sys.error()}`;
		lock.close();
		log.event('error', 'FS_FAILED', { op: 'write', path: config_path, detail });
		return { ...result(false, 'FS_FAILED', null, false, detail), exit: 1 };
	}

	lock.close();
	return { ...result(true, null, id, false), exit: 0 };
};
