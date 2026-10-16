'use strict';

// Subscription planning is pure; update() owns all I/O and side effects.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as identity from 'aetherproxy.identity';
import * as log from 'aetherproxy.log';
import * as net from 'aetherproxy.net';
import * as pipeline from 'aetherproxy.pipeline';
import * as sys from 'aetherproxy.sys';
import * as uri from 'aetherproxy.uri';

const NODE_PROTOCOL_FIELDS = [
	'protocol', 'address', 'port', 'uuid', 'password', 'method', 'flow', 'encryption',
	'transport', 'host', 'path', 'service_name', 'xhttp_mode', 'header_type', 'security',
	'sni', 'alpn', 'fingerprint', 'pinned_cert_sha256', 'verify_name',
	'reality_pbk', 'reality_sid', 'reality_spx'
];
const NODE_OPTION_FIELDS = [ 'label', 'source', 'match_strong', 'match_weak', ...NODE_PROTOCOL_FIELDS ];

function same_value(a, b) {
	return sprintf('%.J', a ?? null) == sprintf('%.J', b ?? null);
}

function protocol_value(field, node) {
	if (node?.[field] != null)
		return node[field];
	if (field == 'transport')
		return 'raw';
	if (field == 'security')
		return 'none';
	if (field == 'encryption' && node?.protocol == 'vless')
		return 'none';
	if (field == 'method' && node?.protocol == 'vmess')
		return 'auto';
	if (field == 'alpn')
		return [];
	return null;
}

function protocol_equal(a, b) {
	for (let field in NODE_PROTOCOL_FIELDS)
		if (!same_value(protocol_value(field, a), protocol_value(field, b)))
			return false;
	return true;
}

function node_changed(a, b) {
	return !protocol_equal(a, b) || !same_value(a?.label, b?.label);
}

function has_option_value(value) {
	return value != null && !(type(value) == 'array' && !length(value));
}

function inc(counts, key, amount) {
	counts[key] = (counts[key] ?? 0) + (amount ?? 1);
}

function add_change(changes, op, section, option, value) {
	let change = { op, section };
	if (option != null)
		change.option = option;
	if (value != null)
		change.value = value;
	push(changes, change);
}

// Pure mapping from parsed subscription nodes to ordered UCI operations.
function make_plan(old_nodes, parsed, opts) {
	old_nodes ??= {};
	opts ??= {};
	let skipped = { ...(parsed?.skipped ?? {}) };
	let seen = {}, nodes = [];
	for (let node in (parsed?.nodes ?? [])) {
		let strong = identity.keys(node).strong;
		if (seen[strong]) {
			inc(skipped, 'duplicate');
			continue;
		}
		seen[strong] = true;
		push(nodes, node);
	}

	let matched = identity.match(old_nodes, nodes, {
		referenced: id => id == opts.current,
		new_id: opts.new_id
	});
	let changes = [], added = 0, updated = 0, stale = 0;

	for (let item in matched.assign) {
		let id = item.id, old = old_nodes[id], node = item.node;
		let identity_keys = identity.keys(node);
		let desired = {
			...node,
			source: opts.sub_name,
			match_strong: identity_keys.strong,
			match_weak: identity_keys.weak,
			stale: false
		};
		if (!has_option_value(desired.label))
			delete desired.label;

		if (old == null) {
			added++;
			add_change(changes, 'add', id, null, 'node');
		}
		else if (node_changed(old, desired)) {
			updated++;
		}

		for (let field in NODE_OPTION_FIELDS) {
			let value = desired[field];
			if (field == 'alpn' && !length(value ?? []))
				value = null;

			if (value == null) {
				if (old != null && has_option_value(old[field]))
					add_change(changes, 'delete_option', id, field);
				continue;
			}

			if (old == null || !same_value(old[field], value))
				add_change(changes, 'set', id, field, value);
		}

		if (old?.stale == true)
			add_change(changes, 'delete_option', id, 'stale');
	}

	for (let id in matched.stale) {
		let old = old_nodes[id];
		if (old?.stale != true) {
			stale++;
			add_change(changes, 'set', id, 'stale', '1');
		}
	}

	for (let id in matched.removed)
		add_change(changes, 'delete_section', id);

	let current_changed = false;
	if (opts.current != null && old_nodes[opts.current] != null)
		for (let item in matched.assign)
			if (item.id == opts.current && !protocol_equal(old_nodes[opts.current], item.node))
				current_changed = true;

	let skipped_sorted = {};
	for (let key in sort(keys(skipped)))
		skipped_sorted[key] = skipped[key];

	return {
		changes,
		counts: {
			added,
			updated,
			stale,
			revived: length(matched.revived),
			removed: length(matched.removed),
			skipped: skipped_sorted
		},
		current_changed,
		matched
	};
};

export function plan(old_nodes, parsed, opts) {
	let result = make_plan(old_nodes, parsed, opts);
	return { changes: result.changes, counts: result.counts, current_changed: result.current_changed };
};

function fs_error() {
	return fs.error() ?? 'unknown error';
}

export function system_path(root, path) {  // T8.2: reused by node import and custom
	return root == '' ? path : replace(root, /\/$/, '') + path;
};

export function absolute_options(opts) {  // T8.2: reused by node import
	let root = opts.sys_root ?? '';
	return {
		...opts,
		confdir: opts.confdir ?? system_path(root, C.CONFIG_DIR),
		run_dir: opts.run_dir ?? system_path(root, C.RUN_DIR),
		data_dir: system_path(root, C.DATA_DIR),
		baseline_dir: system_path(root, C.BASELINE_DATA_DIR),
		custom_dir: system_path(root, C.CUSTOM_DIR)
	};
};

function uci_error(cursor) {
	return cursor.error() ?? 'unknown UCI error';
}

function temp_dirs(ctx) {
	let base = `${ctx.opts.run_dir}/${C.SUB_WORK_SUBDIR}`;
	let delta = `${base}/${C.SUB_DELTA_SUBDIR}`;
	let render = `${base}/${C.SUB_RENDER_SUBDIR}`;
	return { base, delta, render, render_delta: `${render}/${C.SUB_DELTA_SUBDIR}` };
}

function strip_section(section) {
	let out = {};
	for (let key in keys(section))
		if (substr(key, 0, 1) != '.')
			out[key] = section[key];
	return out;
}

export function load_committed_config(ctx, text) {  // T8.2: reused by node import
	let dirs = temp_dirs(ctx);
	let dir = `${dirs.base}/${C.SUB_SNAPSHOT_SUBDIR}`;
	let delta = `${dir}/${C.SUB_DELTA_SUBDIR}`;
	if (!sys.mkdir_p(dir) || !sys.mkdir_p(delta))
		return { ok: false, errors: [ { code: 'io', detail: sys.error() } ] };
	let path = `${dir}/${C.SUB_SNAPSHOT_PACKAGE}`;
	if (!sys.write_atomic(path, text))
		return { ok: false, errors: [ { code: 'io', detail: sys.error() } ] };
	let cursor = uci.cursor(dir, delta);
	if (!cursor.load(C.SUB_SNAPSHOT_PACKAGE))
		return { ok: false, errors: [ { code: 'uci', detail: uci_error(cursor) } ] };

	let raw = { hosts: [], subscriptions: {}, nodes: {} };
	for (let section in [ 'main', 'dns', 'update', 'probe' ]) {
		let value = cursor.get_all(C.SUB_SNAPSHOT_PACKAGE, section);
		raw[section] = value ? strip_section(value) : null;
	}
	cursor.foreach(C.SUB_SNAPSHOT_PACKAGE, 'host', section => { push(raw.hosts, strip_section(section)); });
	cursor.foreach(C.SUB_SNAPSHOT_PACKAGE, 'subscription', section => {
		raw.subscriptions[section['.name']] = strip_section(section);
	});
	cursor.foreach(C.SUB_SNAPSHOT_PACKAGE, 'node', section => {
		raw.nodes[section['.name']] = strip_section(section);
	});

	let loaded = config.normalize(raw);
	if (loaded.ok)
		for (let warning in (loaded.warnings ?? []))
			log.event(null, warning.code, warning.args);
	return loaded;
};

function count_subscription_nodes(snapshot, name) {
	let count = 0;
	for (let id, node in snapshot.nodes)
		if (node.source == name)
			count++;
	return count;
}

function subscription_nodes(snapshot, name) {
	let out = {};
	for (let id, node in snapshot.nodes)
		if (node.source == name)
			out[id] = node;
	return out;
}

function proxy_running(ctx) {
	let state = fs.readfile(ctx.opts.run_dir + '/' + C.STATE_FILE);
	let obj = state == null ? null : json(state);
	if (type(obj) != 'object' || index([ 'starting', 'running', 'degraded' ], obj.state) < 0)
		return false;

	for (let path in [
		system_path(ctx.root, C.PROC_NET_TCP),
		system_path(ctx.root, C.PROC_NET_TCP6)
	])
		if (net.tcp_listening(fs.readfile(path), C.HTTP_PORT))
			return true;

	return false;
}

function unlink_if_exists(path) {
	if (fs.stat(path) == null) {
		let detail = fs_error();
		return detail == 'No such file or directory' ? { ok: true } : { ok: false, detail: `stat ${path}: ${detail}` };
	}
	return fs.unlink(path) ? { ok: true } : { ok: false, detail: `unlink ${path}: ${fs_error()}` };
}

function curl_attempt(ctx, sub, path, via_proxy) {
	let curl = ctx.opts.bin_dir ? `${ctx.opts.bin_dir}/curl` : 'curl';
	let argv = [ curl, '--fail', '--silent', '--show-error', '--max-time', '30', '--max-filesize', '5242880', '-A', sub.user_agent ];
	if (via_proxy)
		push(argv, '-x', `http://${C.HTTP_LISTEN}:${C.HTTP_PORT}`);
	push(argv, '-o', path, sub.url);
	return sys.run(argv, { timeout: 35, quiet: true });
}

function fetch_body(ctx, name, sub) {
	let dir = system_path(ctx.root, C.DOWNLOAD_DIR);
	if (!sys.mkdir_p(dir))
		return { ok: false, code: 'SUB_FETCH_FAILED', detail: `cannot create download directory: ${sys.error()}` };
	let path = `${dir}/sub-${name}`;
	let removed = unlink_if_exists(path);
	if (!removed.ok)
		return { ok: false, code: 'SUB_FETCH_FAILED', detail: removed.detail };

	let mode = sub.fetch_via ?? 'auto';
	let running = mode == 'direct' ? false : proxy_running(ctx);
	if (mode == 'proxy' && !running)
		return { ok: false, code: 'SUB_PROXY_UNAVAILABLE', detail: 'Xray is not running or its HTTP listener is unavailable' };

	let used_proxy = mode == 'proxy';
	let result = curl_attempt(ctx, sub, path, used_proxy);
	if (result.code != 0 && mode == 'auto' && running) {
		removed = unlink_if_exists(path);
		if (!removed.ok)
			return { ok: false, code: 'SUB_FETCH_FAILED', detail: removed.detail };
		used_proxy = true;
		result = curl_attempt(ctx, sub, path, true);
	}

	if (result.code != 0) {
		let via = used_proxy ? ' via proxy' : '';
		let detail = `curl${via} exited ${result.code}${result.timed_out ? ' (timeout)' : ''}: ${trim(result.stderr)}`;
		removed = unlink_if_exists(path);
		if (!removed.ok)
			detail += `; ${removed.detail}`;
		return { ok: false, code: 'SUB_FETCH_FAILED', detail };
	}

	let stat = fs.stat(path);
	if (stat == null || stat.size <= 0 || stat.size > 5242880) {
		let detail = stat == null ? `curl output missing: ${fs_error()}` : (stat.size == 0 ? 'curl returned an empty body' : 'curl body exceeds 5 MiB');
		removed = unlink_if_exists(path);
		if (!removed.ok)
			detail += `; ${removed.detail}`;
		return { ok: false, code: 'SUB_FETCH_FAILED', detail };
	}

	let body = fs.readfile(path);
	if (body == null) {
		let detail = `cannot read downloaded body: ${fs_error()}`;
		removed = unlink_if_exists(path);
		if (!removed.ok)
			detail += `; ${removed.detail}`;
		return { ok: false, code: 'SUB_FETCH_FAILED', detail };
	}

	removed = unlink_if_exists(path);
	if (!removed.ok)
		return { ok: false, code: 'SUB_FETCH_FAILED', detail: removed.detail };

	return { ok: true, body };
}

export function new_node_id(used) {  // T8.2: reused by node import
	let fp = fs.open(C.RANDOM_DEVICE, 'r');
	if (fp == null)
		return null;
	let bytes = fp.read(16);
	let closed = fp.close();
	if (bytes == null || length(bytes) != 16 || !closed)
		return null;

	let out = '';
	for (let i = 0; i < 16; i++) {
		let byte = ord(bytes, i);
		if (i == 6)
			byte = (byte & 0x0f) | 0x40;
		else if (i == 8)
			byte = (byte & 0x3f) | 0x80;
		out += sprintf('%02x', byte);
	}
	let id = `n_${out}`;
	if (used[id])
		return new_node_id(used);
	used[id] = true;
	return id;
};

function apply_changes(cursor, package_name, changes) {
	for (let change in changes) {
		let ok = null;
		switch (change.op) {
		case 'add':
			ok = cursor.set(package_name, change.section, change.value);
			break;
		case 'set':
			ok = cursor.set(package_name, change.section, change.option, change.value);
			break;
		case 'delete_option':
			if (cursor.get(package_name, change.section, change.option) == null)
				ok = true;
			else
				ok = cursor.delete(package_name, change.section, change.option);
			break;
		case 'delete_section':
			if (cursor.get_all(package_name, change.section) == null)
				ok = true;
			else
				ok = cursor.delete(package_name, change.section);
			break;
		default:
			return { ok: false, detail: `unknown plan operation ${change.op}` };
		}
		if (!ok)
			return { ok: false, detail: `${change.op} ${change.section}${change.option ? '.' + change.option : ''}: ${uci_error(cursor)}` };
	}
	return { ok: true };
}

function make_update_result(ok, code, counts, detail) {
	return {
		ok,
		code: ok ? null : code,
		added: counts?.added ?? 0,
		updated: counts?.updated ?? 0,
		stale: counts?.stale ?? 0,
		revived: counts?.revived ?? 0,
		removed: counts?.removed ?? 0,
		skipped: counts?.skipped ?? {},
		detail: detail ?? null
	};
}

function fail_subscription(name, code, detail, counts) {
	log.event(null, code, code == 'SUB_NO_VALID_NODES'
		? { sub: name, skipped: counts?.skipped ?? {} }
		: { sub: name, detail });
	return make_update_result(false, code, counts, detail);
}

function copy_file_atomic(source_text, path) {
	if (!sys.write_atomic(path, source_text))
		return { ok: false, detail: `write ${path}: ${sys.error()}` };
	return { ok: true };
}

export function stage_package(ctx, original_text, package_name, plan_result) {  // T8.2: reused by node import
	let dirs = temp_dirs(ctx);
	if (!sys.mkdir_p(dirs.base) || !sys.mkdir_p(dirs.delta))
		return { ok: false, detail: `cannot create subscription work directory: ${sys.error()}` };
	let synthetic_path = `${dirs.base}/${package_name}`;
	let copied = copy_file_atomic(original_text, synthetic_path);
	if (!copied.ok)
		return copied;

	let cursor = uci.cursor(dirs.base, dirs.delta);
	if (!cursor.load(package_name))
		return { ok: false, detail: `load ${package_name}: ${uci_error(cursor)}` };
	let applied = apply_changes(cursor, package_name, plan_result.changes);
	if (!applied.ok)
		return applied;
	if (!cursor.commit(package_name))
		return { ok: false, detail: `commit ${package_name}: ${uci_error(cursor)}` };

	let content = fs.readfile(synthetic_path);
	if (content == null)
		return { ok: false, detail: `read ${synthetic_path}: ${fs_error()}` };
	return { ok: true, content, dirs };
};

function render_current_node(ctx, content) {
	let dirs = temp_dirs(ctx);
	if (!sys.mkdir_p(dirs.render) || !sys.mkdir_p(dirs.render_delta))
		return { ok: false, detail: `cannot create render validation directory: ${sys.error()}` };
	let copied = copy_file_atomic(content, `${dirs.render}/${C.UCI_PACKAGE}`);
	if (!copied.ok)
		return copied;

	// Validate the isolated package using a separate confdir; the live config is never committed.
	let validate_opts = { ...ctx.opts, confdir: dirs.render };
	let rendered = pipeline.build(validate_opts);
	if (!rendered.ok)
		return { ok: false, detail: `render current node failed (${rendered.code}): ${rendered.detail}` };

	let xray = ctx.opts.bin_dir ? `${ctx.opts.bin_dir}/xray` : (rendered.snapshot.main.xray_bin ?? C.XRAY_COMPONENT);
	if (!fs.access(xray, 'x'))
		return { ok: false, detail: `xray run -test unavailable: ${xray} is not executable` };

	let config_path = `${dirs.render}/${C.ARTIFACT_FILES.xray}`;
	if (!sys.write_atomic(config_path, rendered.artifacts.xray))
		return { ok: false, detail: `write ${config_path}: ${sys.error()}` };
	let checked = sys.run([ xray, 'run', '-test', '-c', config_path ], { timeout: 10, quiet: true });
	if (checked.code != 0)
		return { ok: false, detail: `xray run -test exited ${checked.code}: ${trim(checked.stderr)}` };
	return { ok: true, snapshot: rendered.snapshot };
}

function error_for_parse(parsed) {
	if (parsed.error == 'SUB_NO_VALID_NODES')
		return { code: parsed.error, detail: 'subscription contains no valid nodes' };
	if (parsed.error == 'SUB_FORMAT_UNSUPPORTED')
		return { code: parsed.error, detail: 'Clash YAML subscriptions are not supported' };
	if (parsed.error == 'SUB_DECODE_FAILED')
		return { code: parsed.error, detail: 'subscription body could not be decoded' };
	return null;
}

function update_one(ctx, name, sub, snapshot, original_text, all_ids) {
	let fetched = fetch_body(ctx, name, sub);
	if (!fetched.ok)
		return { result: fail_subscription(name, fetched.code, fetched.detail), attempted: true, nodes: count_subscription_nodes(snapshot, name) };

	let parsed = uri.parse_body(fetched.body);
	let parse_error = error_for_parse(parsed);
	if (parse_error != null)
		return {
			result: fail_subscription(name, parse_error.code, parse_error.detail, { skipped: parsed.skipped }),
			attempted: true,
			nodes: count_subscription_nodes(snapshot, name),
			skipped: parsed.skipped
		};

	let old_nodes = subscription_nodes(snapshot, name);
	let used = { ...all_ids };
	let generation_error = false;
	let planned = make_plan(old_nodes, parsed, {
		sub_name: name,
		current: snapshot.main.node,
		new_id: () => {
			let id = new_node_id(used);
			if (id == null) {
				generation_error = true;
				return 'n_00000000000040008000000000000000';
			}
			return id;
		}
	});
	if (generation_error)
		return {
			result: fail_subscription(name, 'SUB_APPLY_INVALID', `cannot read 16 bytes from ${C.RANDOM_DEVICE}`),
			attempted: true, nodes: count_subscription_nodes(snapshot, name), skipped: planned.counts.skipped
		};

	let warned_nodes = {};
	for (let warning in (parsed.warnings ?? [])) {
		let node_id = '-';
		for (let item in planned.matched.assign)
			if (!warned_nodes[item.id] && item.node.label == warning.args?.label) {
				node_id = item.id;
				warned_nodes[item.id] = true;
				break;
			}
		log.event(null, warning.code, { node: node_id, label: warning.args?.label ?? '-' });
	}

	let new_count = length(planned.matched.assign);
	let shrank = length(keys(old_nodes)) >= 4 && new_count * 2 < length(keys(old_nodes));

	let original_path = `${ctx.opts.confdir}/${C.UCI_PACKAGE}`;
	let staged = stage_package(ctx, original_text, C.SUB_TEMP_PACKAGE, planned);
	if (!staged.ok)
		return {
			result: fail_subscription(name, 'SUB_APPLY_INVALID', staged.detail, planned.counts),
			attempted: true, nodes: count_subscription_nodes(snapshot, name), skipped: planned.counts.skipped
		};

	if (planned.current_changed) {
		let validation = render_current_node(ctx, staged.content);
		if (!validation.ok)
			return {
				result: fail_subscription(name, 'SUB_APPLY_INVALID', validation.detail, planned.counts),
				attempted: true, nodes: count_subscription_nodes(snapshot, name), skipped: planned.counts.skipped
			};
	}

	let current_text = fs.readfile(original_path);
	if (current_text == null || current_text != original_text) {
		let detail = current_text == null
			? `concurrent modification check could not read ${original_path}: ${fs_error()}`
			: `concurrent modification of ${original_path}; retry the subscription update`;
		return {
			result: fail_subscription(name, 'SUB_APPLY_INVALID', detail, planned.counts),
			attempted: true, nodes: count_subscription_nodes(snapshot, name), skipped: planned.counts.skipped
		};
	}

	if (staged.content != original_text && !sys.write_atomic(original_path, staged.content)) {
		return {
			result: fail_subscription(name, 'SUB_APPLY_INVALID', `replace ${original_path}: ${sys.error()}`, planned.counts),
			attempted: true, nodes: count_subscription_nodes(snapshot, name), skipped: planned.counts.skipped
		};
	}
	return {
		result: make_update_result(true, null, planned.counts),
		applied: true,
		attempted: true,
		nodes: new_count + length(planned.matched.stale),
		skipped: planned.counts.skipped,
		current_changed: planned.current_changed && staged.content != original_text,
		counts: planned.counts,
		stale_nodes: filter(planned.matched.stale, id => old_nodes[id]?.stale != true),
		shrank,
		old_count: length(keys(old_nodes)),
		new_count
	};
}

function read_subscription_state(path) {
	let text = fs.readfile(path);
	if (text == null) {
		let detail = fs_error();
		if (detail == 'No such file or directory')
			return { ok: true, text: null, value: {} };
		return { ok: false, detail: `read ${path}: ${detail}` };
	}
	// sub.json is only a status record (06 step 7): a corrupt one is logged and replaced
	// on the next write instead of blocking every update. json() throws on bad input.
	let value = null;
	try {
		value = json(text);
	}
	catch (e) {
		value = null;
	}
	if (type(value) != 'object') {
		log.event('error', 'FS_FAILED', { op: 'read', path, detail: 'not a JSON object; starting a fresh status record' });
		return { ok: true, text, value: {} };
	}
	return { ok: true, text, value };
}

function write_subscription_state(ctx, prior, updates) {
	if (!length(keys(updates)))
		return { ok: true, value: prior.value };
	let value = { ...prior.value };
	for (let name, update in updates) {
		let previous = value[name] ?? {};
		value[name] = {
			last_attempt: update.at,
			last_ok: update.result.ok ? update.at : (previous.last_ok ?? null),
			nodes: update.nodes,
			skipped: update.skipped ?? {},
			error: update.result.ok ? null : update.result.code
		};
	}
	let text = sprintf('%.J', value) + '\n';
	if (prior.text == text)
		return { ok: true, value };
	let path = `${system_path(ctx.root, C.STATE_DIR)}/${C.SUB_STATE_FILE}`;
	if (!sys.mkdir_p(system_path(ctx.root, C.STATE_DIR)))
		return { ok: false, detail: `cannot create subscription state directory: ${sys.error()}` };
	if (!sys.write_atomic(path, text))
		return { ok: false, detail: `write ${path}: ${sys.error()}` };
	return { ok: true, value };
}

function test_init_reload(ctx) {
	let init = system_path(ctx.root, C.PROG_INIT);
	let result = sys.run([ init, 'reload' ], { timeout: 35, quiet: true });
	if (result.code != 0) {
		log.event('error', 'CMD_FAILED', {
			cmd: `${init} reload`, rc: result.code,
			stderr: trim(result.stderr), timed_out: result.timed_out
		});
		return { ok: false, detail: `${init} reload exited ${result.code}: ${trim(result.stderr)}` };
	}
	return { ok: true };
}

// update(ctx, sub_name|null) -> { ok, subs, exit?, code?, detail? }.
export function update(ctx, sub_name) {
	ctx ??= {};
	ctx.root = ctx.sys_root ?? ctx.opts?.sys_root ?? ctx.root ?? '';
	ctx.opts = absolute_options(ctx.opts ?? {});
	log.set_run_dir(ctx.opts.run_dir);

	let lock = sys.lock(system_path(ctx.root, C.SUB_LOCK_FILE));
	if (lock == null) {
		log.event('warn', 'BUSY', { holder: 'sub' });
		return { ok: false, code: 'BUSY', exit: 3, detail: sys.error(), subs: {} };
	}

	let config_path = `${ctx.opts.confdir}/${C.UCI_PACKAGE}`;
	let original_text = fs.readfile(config_path);
	if (original_text == null) {
		let detail = `read ${config_path}: ${fs_error()}`;
		lock.close();
		return { ok: false, code: 'CONFIG_INVALID', exit: 2, detail, subs: {} };
	}
	let loaded = load_committed_config(ctx, original_text);
	if (!loaded.ok) {
		lock.close();
		let first = loaded.errors?.[0] ?? {};
		log.event('error', 'CONFIG_INVALID', { field: first.field ?? '-', reason: first.code ?? first.detail ?? 'invalid configuration' });
		return { ok: false, code: 'CONFIG_INVALID', exit: 2,
			detail: `${length(loaded.errors)} configuration error(s)`, subs: {} };
	}
	let snapshot = loaded.snapshot;
	if (sub_name != null && snapshot.subscriptions[sub_name] == null) {
		lock.close();
		return { ok: false, code: 'USAGE', exit: 2, detail: `unknown subscription '${sub_name}'`, subs: {} };
	}
	let status_path = `${system_path(ctx.root, C.STATE_DIR)}/${C.SUB_STATE_FILE}`;
	let prior_state = read_subscription_state(status_path);
	if (!prior_state.ok) {
		lock.close();
		log.event('error', 'FS_FAILED', { op: 'read', path: status_path, detail: prior_state.detail });
		// An unreadable (not merely corrupt) status file is an I/O fault: FS_FAILED, no update (06 step 7).
		return { ok: false, code: 'FS_FAILED', exit: 1, detail: prior_state.detail, subs: {} };
	}

	let names = sub_name == null ? sort(keys(snapshot.subscriptions)) : [ sub_name ];
	let all_ids = {};
	for (let id in keys(snapshot.nodes))
		all_ids[id] = true;
	let results = {}, status_updates = {};
	let reload_needed = false;
	let overall_ok = true;
	let any_attempt = false;

	for (let name in names) {
		let sub = snapshot.subscriptions[name];
		if (sub.enabled != true) {
			// 06: disabled subscriptions are not processed and, unless named, not reported.
			if (sub_name != null)
				results[name] = { ...make_update_result(true, null, null), disabled: true };
			continue;
		}
		any_attempt = true;
		let attempted_at = time();
		let outcome = update_one(ctx, name, sub, snapshot, original_text, all_ids);
		results[name] = outcome.result;
		status_updates[name] = { ...outcome, result: outcome.result, at: attempted_at };
		if (!outcome.result.ok)
			overall_ok = false;
		if (outcome.current_changed)
			reload_needed = true;

		// Successful subscriptions are committed one at a time; refresh the baseline for the next
		// subscription without allowing a failed one to roll back an earlier success.
		if (outcome.result.ok) {
			let new_text = fs.readfile(config_path);
			if (new_text == null) {
				let detail = `read ${config_path} after replacement: ${fs_error()}`;
				log.event('error', 'FS_FAILED', { op: 'read', path: config_path, detail });
				results[name].ok = false;
				results[name].code = 'FS_FAILED';
				results[name].detail = detail;
				status_updates[name].result = results[name];
				overall_ok = false;
				break;
			}
			let refreshed = load_committed_config(ctx, new_text);
			if (!refreshed.ok) {
				let detail = `configuration became invalid after applying ${name}: ${length(refreshed.errors)} error(s)`;
				log.event('error', 'FS_FAILED', { op: 'reload-config', path: config_path, detail });
				results[name].ok = false;
				results[name].code = 'FS_FAILED';
				results[name].detail = detail;
				status_updates[name].result = results[name];
				overall_ok = false;
				break;
			}
			snapshot = refreshed.snapshot;
			original_text = new_text;
			for (let id in keys(snapshot.nodes))
				all_ids[id] = true;
		}
	}

	lock.close();

	let service_state = fs.readfile(ctx.opts.run_dir + '/' + C.STATE_FILE);
	let state_obj = null;
	if (service_state != null) {
		try {
			state_obj = json(service_state);
		}
		catch (e) {
			state_obj = null;	// unreadable state counts as "not running": no reload
		}
	}
	let service_active = type(state_obj) == 'object' && index([ 'starting', 'running', 'degraded' ], state_obj.state) >= 0;
	if (reload_needed && service_active) {
		let reloaded = test_init_reload(ctx);
		if (!reloaded.ok) {
			overall_ok = false;
			// No rollback (06 step 6): the new file already passed xray -test; a failed reload is
			// reported and the daemon keeps running the previous render until the next reload.
			for (let name, outcome in status_updates)
				if (outcome.current_changed) {
					results[name].ok = false;
					results[name].code = 'CMD_FAILED';
					results[name].detail = reloaded.detail;
				}
		}
	}

	for (let name, outcome in status_updates) {
		if (!outcome.applied)
			continue;
		for (let id in outcome.stale_nodes)
			log.event('warn', 'NODE_STALE', { node: id, label: snapshot.nodes[id]?.label ?? '-' });
		if (outcome.shrank)
			log.event('warn', 'SUB_SHRANK', { sub: name, old: outcome.old_count, new: outcome.new_count });
		log.event('notice', 'SUB_UPDATED', {
			sub: name,
			added: outcome.counts.added,
			updated: outcome.counts.updated,
			stale: outcome.counts.stale,
			removed: outcome.counts.removed,
			skipped: outcome.counts.skipped
		});
	}

	let saved_state = write_subscription_state(ctx, prior_state, status_updates);
	if (!saved_state.ok) {
		log.event('error', 'FS_FAILED', { op: 'write', path: status_path, detail: saved_state.detail });
		// The config is already replaced and stays; only the status record is missing (06 step 7).
		overall_ok = false;
	}
	if (!any_attempt)
		return { ok: overall_ok, subs: results };

	return { ok: overall_ok, subs: results, exit: overall_ok ? 0 : 1,
		code: overall_ok ? null : 'SUB_UPDATE_FAILED', detail: overall_ok ? null : 'one or more subscriptions failed' };
};
