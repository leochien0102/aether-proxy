'use strict';

// `aether-proxy status`: prints state.json plus the probe summary, the update summary and
// the pending notices for the LuCI overview page (docs/10 「概览页」). The notices are
// detected live on every call: read-only, and unlike apply they never log events — the
// page polls this every few seconds, so the event log must stay untouched.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';
import * as config from 'aetherproxy.config';
import * as state from 'aetherproxy.state';
import * as check from 'aetherproxy.cmd.check';
import * as apply from 'aetherproxy.apply';
import * as updates_cache from 'aetherproxy.updates_cache';

function usage(args, detail) {
	let json = index(args, '--json') >= 0;
	let result = { ok: false, code: 'USAGE', detail, errors: [] };
	return pipeline.finish({ json }, result, 2, detail);
};

function human_status(value) {
	let lines = [ `state: ${value.state ?? 'unknown'}` ];

	for (let field in [ 'dns_tier', 'dns_failsafe', 'node_id', 'node_ip', 'since', 'last_probe', 'last_error', 'probe', 'updates_available', 'components', 'render_hash', 'notices' ])
		if (value[field] != null)
			push(lines, `${field}: ${sprintf('%J', value[field])}`);

	return join('\n', lines);
}

// probe.json summary for status (10): null when there is no usable probe result yet.
function probe_summary(run_dir) {
	let text = fs.readfile(`${run_dir}/${C.PROBE_FILE}`);
	if (text == null)
		return null;
	let data = null;
	try {
		data = json(text);
	}
	catch (e) {
		return null;	// a half-written or damaged file is not worth failing status for
	}
	if (type(data) != 'object' || type(data.nodes) != 'object')
		return null;
	let total = 0, reachable = 0;
	for (let id, node in data.nodes) {
		total++;
		if (type(node) == 'object' && (node.ok ?? 0) > 0)
			reachable++;
	}
	return { at: data.at ?? null, total, reachable };
}

// --sys-root prefix for absolute system paths (docs/10 「仅供测试的选项」).
function root_prefix(opts) {
	let root = opts.sys_root ?? '';
	return root == '' ? '' : replace(root, /\/$/, '');
}

// COMPONENT_MISSING notices for the components the lookup of docs/01
// 「组件二进制的查找顺序」 cannot find — the same function `check` uses.
function component_notices(snapshot, opts) {
	let notices = [];
	let lookup = { bin_dir: opts.bin_dir };

	for (let name, key in { [C.XRAY_COMPONENT]: 'xray_bin', [C.CHINADNS_COMPONENT]: 'chinadns_bin' })
		if (check.find_component(name, snapshot.main[key], lookup) == null)
			push(notices, { code: 'COMPONENT_MISSING', args: { component: name } });

	return notices;
}

// UPDATE_AVAILABLE notices from the already-read updates.json; the xray-core entry is
// muted while update.xray_auto is 'off' (docs/10 「概览页」).
function update_notices(snapshot, updates) {
	let notices = [];

	if (type(updates) != 'object' || type(updates.packages) != 'object')
		return notices;

	let mute_xray = snapshot.update?.xray_auto == 'off';

	for (let name in C.UPDATE_PACKAGES) {
		let entry = updates.packages[name];

		if (type(entry) != 'object' || entry.newer !== true)
			continue;
		if (name == C.XRAY_CORE_PACKAGE && mute_xray)
			continue;

		push(notices, { code: 'UPDATE_AVAILABLE', args: { package: name, available: entry.available } });
	}

	return notices;
}

// IPV6_PRESENT notice: the first LAN interface (in lan_ifaces order) that has a global
// address (scope 00) in /proc/net/if_inet6, docs/03 「IPv4-only 的泄漏处理」. No file and
// no matching interface mean nothing to report; reading is silent by design.
function ipv6_notice(opts, lan_ifaces) {
	let text = fs.readfile(root_prefix(opts) + C.IF_INET6_PATH);
	if (text == null)
		return null;

	for (let iface in (lan_ifaces ?? [])) {
		for (let line in split(text, '\n')) {
			let fields = split(trim(line), /[ \t]+/);

			if (length(fields) >= 6 && fields[3] == C.IPV6_SCOPE_GLOBAL && fields[5] == iface)
				return { code: 'IPV6_PRESENT', args: { iface } };
		}
	}

	return null;
}

// DNSMASQ_EXTRA_SERVERS notice: `server=` lines outside our own fragment, via the same
// event-free detection apply runs at start (docs/10 「概览页」). A failed scan (for example
// no dnsmasq conf-dir) means nothing to report.
function dnsmasq_notice(snapshot, opts) {
	let prefix = root_prefix(opts);
	let scan = apply.scan_extra_servers({
		root: prefix,
		lan_ifaces: snapshot.main.lan_ifaces,
		dnsmasq_instance: snapshot.dns?.dnsmasq_instance ?? null
	});

	if (!scan.ok || !length(scan.servers))
		return null;

	return { code: 'DNSMASQ_EXTRA_SERVERS', args: { servers: scan.servers } };
}

function collect_notices(snapshot, opts, updates) {
	let notices = component_notices(snapshot, opts);

	for (let n in update_notices(snapshot, updates))
		push(notices, n);

	let v6 = ipv6_notice(opts, snapshot.main.lan_ifaces);
	if (v6 != null)
		push(notices, v6);

	let extra = dnsmasq_notice(snapshot, opts);
	if (extra != null)
		push(notices, extra);

	return notices;
}

export function run(args) {
	let parsed = pipeline.parse_args(args);
	if (parsed.error)
		return usage(args, parsed.error);

	if (length(parsed.positional))
		return usage(args, 'status takes no arguments');

	for (let key in keys(parsed.opts))
		if (key != 'json' && key != 'run_dir' && key != 'confdir' && key != 'sys_root' && key != 'bin_dir')
			return usage(args, `option --${replace(key, /_/g, '-')} is not supported by status`);

	let run_dir = pipeline.run_dir(parsed.opts);
	let current = state.read(run_dir);
	if (current == null) {
		let detail = state.error() ?? 'unknown state read error';
		log.event('error', 'FS_FAILED', { op: 'read', path: run_dir + '/' + C.STATE_FILE, detail });
		return pipeline.finish(parsed.opts,
			{ ok: false, code: 'FS_FAILED', detail }, 1, `cannot read status: ${detail}`);
	}

	// docs/10 「概览页」: status reads the configuration for the notices. A configuration
	// that fails to load or validate fails the whole call like in `check`; status is
	// polled every few seconds, so no event is logged for it (the JSON response carries
	// the errors instead).
	// TODO(design): docs/10 does not define status behavior for an invalid configuration,
	// and nothing says whether config.load warnings should surface here; status is polled
	// every few seconds, so they are neither logged nor returned for now.
	let cfg = config.load(uci.cursor(parsed.opts.confdir));
	if (!cfg.ok)
		return pipeline.finish(parsed.opts,
			{ ok: false, code: 'CONFIG_INVALID', detail: `${length(cfg.errors)} configuration error(s)`, errors: cfg.errors },
			2, pipeline.describe_errors({ code: 'CONFIG_INVALID', detail: 'configuration invalid', errors: cfg.errors }));

	current.probe = probe_summary(run_dir);
	let updates = updates_cache.read(run_dir, parsed.opts.sys_root);
	current.updates_available = updates.stale ? null : updates.value;
	current.notices = collect_notices(cfg.snapshot, parsed.opts, current.updates_available);

	return pipeline.finish(parsed.opts, current, 0, human_status(current));
};
