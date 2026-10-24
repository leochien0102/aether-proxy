'use strict';
'require baseclass';
'require aether-proxy.model.conflicts as conflicts';

/* Pure log-page presentation, per docs/10 「日志页」 and docs/09 event catalog.
 * T10.39 optionally resolves IDs using { nodes, subscriptions } name maps.
 * T10.50 follows docs/10 "r14 修正：事件文字" for conditional text and mode names.
 * T10.52 gives PRECHECK_FAILED conflict entries shared product names while raw
 * args remain unchanged for hover. Templates use only catalog parameters.
 */
const TEMPLATES = {
	SERVICE_STARTED: _('Service started in {elapsed_ms} ms', 'aether-proxy'),
	RELOAD_APPLIED: _('Reloaded from node {from_node} to {to_node} in {elapsed_ms} ms', 'aether-proxy'),
	SERVICE_STOPPED: _('Service stopped (mode {mode}, node {node})', 'aether-proxy'),
	BUSY: _('Operation locked by {holder}', 'aether-proxy'),
	CONFIG_INVALID: _('Invalid configuration: {field}, {reason}', 'aether-proxy'),
	PRECHECK_FAILED: _('Precheck failed: {missing}', 'aether-proxy'),
	RENDER_INVALID: _('Invalid artifact {artifact}: {detail}', 'aether-proxy'),
	START_FAILED: _('Start failed at {step}: {detail}', 'aether-proxy'),
	JOB_LOST: _('Job {job} ({kind}) lost its worker', 'aether-proxy'),
	START_RETRY: _('Start retry {attempt} in {in_secs} seconds', 'aether-proxy'),
	NET_WAIT_TIMEOUT: _('Network wait timed out after {waited} seconds', 'aether-proxy'),
	COMPONENT_MISSING: _('Component missing: {component}', 'aether-proxy'),
	COMPONENT_TOO_OLD: _('Component {component} version {version} requires {min}', 'aether-proxy'),
	NODE_RESOLVE_FALLBACK: _('Node {node}: using {lkg_ip} for {domain}', 'aether-proxy'),
	NODE_RESOLVE_FAILED: _('Node {node}: could not resolve {domain}', 'aether-proxy'),
	NODE_IP_CHANGED: _('Node {node} IP changed from {old} to {new}', 'aether-proxy'),
	NODE_STALE: _('Node {node} is stale', 'aether-proxy'),
	NODE_STALE_IN_USE: _('Current node {node} is stale', 'aether-proxy'),
	NODE_INSECURE_IGNORED: _('Ignored insecure setting for node {node}', 'aether-proxy'),
	PROXY_HEALTHY: _('Proxy healthy: {latency_ms} ms', 'aether-proxy'),
	PROXY_UNHEALTHY: _('Proxy unhealthy: {fails} failures', 'aether-proxy'),
	DNS_TIER_CHANGED: _('DNS changed from {from} to {to} (reason: {reason})', 'aether-proxy'),
	XRAY_DOWN_FAILOPEN: _('Xray down on port {port}; traffic goes directly', 'aether-proxy'),
	XRAY_DOWN: _('Xray down on port {port}', 'aether-proxy'),
	XRAY_RECOVERED: _('Xray recovered on port {port}', 'aether-proxy'),
	CHILD_CRASHED: _('Child {name} (PID {pid}) exited with {code}; restart in {restart_in} seconds', 'aether-proxy'),
	DNS_DOWN_FAILSAFE: _('DNS down; original upstream configuration restored', 'aether-proxy'),
	DNS_RECOVERED: _('DNS recovered', 'aether-proxy'),
	NFT_TABLE_RESTORED: _('Missing nftables table restored', 'aether-proxy'),
	DNSMASQ_CONFDIR_NOT_FOUND: _('dnsmasq configuration directory not found', 'aether-proxy'),
	DNSMASQ_EXTRA_SERVERS: _('Additional dnsmasq servers: {servers}', 'aether-proxy'),
	IPV6_PRESENT: _('Global IPv6 address present on {iface}', 'aether-proxy'),
	SUB_UPDATED:
		_('Subscription {sub}: added {added}, updated {updated}, stale {stale}, removed {removed}, skipped {skipped}', 'aether-proxy'),
	SUB_FETCH_FAILED: _('Subscription {sub} fetch failed: {detail}', 'aether-proxy'),
	SUB_DECODE_FAILED: _('Subscription {sub} decode failed: {detail}', 'aether-proxy'),
	SUB_FORMAT_UNSUPPORTED: _('Subscription {sub} format unsupported: {detail}', 'aether-proxy'),
	SUB_APPLY_INVALID: _('Subscription {sub} apply invalid: {detail}', 'aether-proxy'),
	SUB_PROXY_UNAVAILABLE: _('Subscription {sub} proxy unavailable: {detail}', 'aether-proxy'),
	SUB_SHRANK: _('Subscription {sub} shrank from {old} to {new}', 'aether-proxy'),
	SUB_NO_VALID_NODES: _('Subscription {sub} has no valid nodes; skipped {skipped}', 'aether-proxy'),
	UPDATE_AVAILABLE: _('Update available for {package}: {current} to {latest}', 'aether-proxy'),
	UPDATE_INSTALLED: _('Installed {package} version {version}', 'aether-proxy'),
	UPDATE_VERIFY_FAILED: _('Update verification failed for {package}: {version}', 'aether-proxy'),
	UPDATE_ROLLED_BACK: _('Rolled back {package} to {version}', 'aether-proxy'),
	DATA_UPDATED: _('Updated rule data: {items}', 'aether-proxy'),
	MANIFEST_BAD_SIGNATURE: _('Invalid manifest signature: {url}', 'aether-proxy'),
	UPDATE_FETCH_FAILED: _('Could not fetch update channels: {urls}', 'aether-proxy'),
	NO_SPACE: _('Insufficient space: need {need}, free {free}', 'aether-proxy'),
	ARCH_UNSUPPORTED: _('Unsupported architecture: {arch}', 'aether-proxy'),
	CMD_FAILED: _('Command {cmd} exited with {rc}: {stderr}', 'aether-proxy'),
	FS_FAILED: _('File operation {op} failed for {path}: {detail}', 'aether-proxy')
};
/* Callers without name maps retain their exact pre-T10.39 output. */
const LEGACY_TEMPLATES = {
	NODE_STALE: _('Node {node} ({label}) is stale', 'aether-proxy'),
	NODE_STALE_IN_USE: _('Current node {node} ({label}) is stale', 'aether-proxy'),
	NODE_INSECURE_IGNORED: _('Ignored insecure setting for node {node} ({label})', 'aether-proxy')
};
const MODES = {
	gfw: _('GFW only', 'aether-proxy'),
	bypass_cn: _('Bypass China', 'aether-proxy'),
	global: _('Global (all traffic through proxy)', 'aether-proxy'),
	direct: _('Direct', 'aether-proxy'),
	proxy: _('Global (all traffic through proxy)', 'aether-proxy')
};
const RANK = { error: 0, warn: 1, notice: 2 };
const LEVELS = { error: _('Error', 'aether-proxy'), warn: _('Warning', 'aether-proxy'), notice: _('Notice', 'aether-proxy') };
const CLASSES = { error: 'label danger', warn: 'label warning', notice: 'label notice' };

function value_text(value) {
	if (value == null)
		return '?';
	if (Array.isArray(value))
		return value.map(value_text).join('、');
	if (typeof value == 'object')
		return Object.keys(value).map(k => k + ' ' + value_text(value[k])).join('、');
	return String(value);
}

function precheck_missing(value) {
	if (!Array.isArray(value))
		return value_text(value);
	return value.map(item => conflicts.format_log_item(item) ?? value_text(item)).join('、');
}

function name_text(args, key, names) {
	// A missing reference keeps the page-wide “?” (design lead, 2026-10-22).
	if (args[key] == null || args[key] === '')
		return value_text(null);
	// Only node events carry label (docs/09), and it names that node.
	if (key === 'node' && args.label != null && args.label !== '')
		return value_text(args.label);
	const table = (key === 'sub' ? names.subscriptions : names.nodes) || {};
	if (Object.prototype.hasOwnProperty.call(table, args[key]) && table[args[key]])
		return value_text(table[args[key]]);
	return key === 'sub' ? _('Deleted subscription', 'aether-proxy') : _('Deleted node', 'aether-proxy');
}

function event_template(code, args, names) {
	if (code === 'SUB_UPDATED' && !Object.values(args.skipped || {}).some(count => count > 0))
		return _('Subscription {sub}: added {added}, updated {updated}, stale {stale}, removed {removed}',
			'aether-proxy');
	// Compare IDs, not display names: different nodes can have the same label.
	// Missing endpoints must keep the usual "?", not claim that a node is unchanged.
	if (code === 'RELOAD_APPLIED' && args.from_node != null && args.from_node !== '' &&
		args.from_node === args.to_node)
		return _('Configuration reloaded (node unchanged: {to_node}) in {elapsed_ms} ms', 'aether-proxy');
	return !names && Object.prototype.hasOwnProperty.call(LEGACY_TEMPLATES, code)
		? LEGACY_TEMPLATES[code] : TEMPLATES[code];
}

function message(event, names) {
	const args = event.args || {};
	if (!Object.prototype.hasOwnProperty.call(TEMPLATES, event.code))
		return event.code + ' ' + JSON.stringify(args);
	return event_template(event.code, args, names).replace(/\{(\w+)\}/g, (match, key) => {
		if (event.code === 'PRECHECK_FAILED' && key === 'missing')
			return precheck_missing(args[key]);
		if (key === 'mode' && Object.prototype.hasOwnProperty.call(MODES, args[key]))
			return MODES[args[key]];
		if (names && ['node', 'from_node', 'to_node', 'sub'].includes(key))
			return name_text(args, key, names);
		return value_text(args[key]);
	});
}

function timestamp(ts) {
	const d = new Date(ts * 1000);
	const pad = n => String(n).padStart(2, '0');
	return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
		pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

function failure(res) {
	return (res.code || 'RPC_FAILED') + (res.detail ? ': ' + res.detail : '');
}

return baseclass.extend({
	templates: TEMPLATES,
	value_text: value_text,
	message: message,
	/* Keep the last successful payload, not filtered rows: filters still work
	 * after a failed refresh, and code options never depend on the filter.
	 */
	events: function(res, previous, level, code, names) {
		const pending = res === undefined;
		const ok = res && res.ok !== false;
		const data = ok ? res : (previous || { events: [], skipped: 0 });
		const events = data.events || [];
		const rows = events.map((event, index) => ({ event, index }))
			.filter(item => (!level || RANK[item.event.level] <= RANK[level]) &&
				(!code || item.event.code == code))
			.sort((a, b) => b.event.ts - a.event.ts || b.index - a.index)
			.map(({ event }) => ({
				time: timestamp(event.ts), level: LEVELS[event.level] || event.level,
				class_name: CLASSES[event.level] || 'label', code: event.code,
				text: message(event, names), title: JSON.stringify(event.args || {})
			}));
		return {
			data, rows, codes: Array.from(new Set(events.map(e => e.code))).sort(),
			loading: pending ? _('Reading…', 'aether-proxy') : null,
			filters_disabled: pending,
			error: pending || ok ? null : failure(res || {}),
			skipped: data.skipped > 0 ? _('Skipped {n} damaged event lines', 'aether-proxy').replace('{n}', data.skipped) : null
		};
	},

	sources: function() {
		return [ [ 'all', _('All', 'aether-proxy') ], [ 'aether-proxy', 'aether-proxy' ], [ 'xray', 'Xray' ], [ 'dns', 'DNS' ] ];
	},
	line_counts: function() { return [ 100, 200, 500, 1000, 2000 ]; },
	log_params: function(source, lines) { return { source: source, lines: Number(lines) }; },
	raw: function(res, log_level) {
		return {
			text: res && res.ok !== false ? (res.lines || []).map(line => line.text).join('\n') : '',
			error: res && res.ok !== false ? null : failure(res || {}),
			hint: log_level == 'debug' ?
				_('Increase the buffer in System → Log; return to notice after troubleshooting.', 'aether-proxy') : null
		};
	}
});
