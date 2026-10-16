'use strict';
'require baseclass';

/* Pure log-page presentation, per docs/10 「日志页」 and docs/09 event catalog.
 * Templates use only catalog parameters; raw args remain available for hover.
 */
const TEMPLATES = {
	SERVICE_STARTED: _('Service started in {elapsed_ms} ms'),
	SERVICE_STOPPED: _('Service stopped (mode {mode}, node {node})'),
	BUSY: _('Operation locked by {holder}'),
	CONFIG_INVALID: _('Invalid configuration: {field}, {reason}'),
	PRECHECK_FAILED: _('Precheck failed: {missing}'),
	RENDER_INVALID: _('Invalid artifact {artifact}: {detail}'),
	START_FAILED: _('Start failed at {step}: {detail}'),
	JOB_LOST: _('Job {job} ({kind}) lost its worker'),
	START_RETRY: _('Start retry {attempt} in {in_secs} seconds'),
	NET_WAIT_TIMEOUT: _('Network wait timed out after {waited} seconds'),
	COMPONENT_MISSING: _('Component missing: {component}'),
	COMPONENT_TOO_OLD: _('Component {component} version {version} requires {min}'),
	NODE_RESOLVE_FALLBACK: _('Node {node}: using {lkg_ip} for {domain}'),
	NODE_RESOLVE_FAILED: _('Node {node}: could not resolve {domain}'),
	NODE_IP_CHANGED: _('Node {node} IP changed from {old} to {new}'),
	NODE_STALE: _('Node {node} ({label}) is stale'),
	NODE_STALE_IN_USE: _('Current node {node} ({label}) is stale'),
	NODE_INSECURE_IGNORED: _('Ignored insecure setting for node {node} ({label})'),
	PROXY_HEALTHY: _('Proxy healthy: {latency_ms} ms'),
	PROXY_UNHEALTHY: _('Proxy unhealthy: {fails} failures'),
	DNS_TIER_CHANGED: _('DNS changed from {from} to {to} (reason: {reason})'),
	XRAY_DOWN_FAILOPEN: _('Xray down on port {port}; traffic goes directly'),
	XRAY_DOWN: _('Xray down on port {port}'),
	XRAY_RECOVERED: _('Xray recovered on port {port}'),
	CHILD_CRASHED: _('Child {name} (PID {pid}) exited with {code}; restart in {restart_in} seconds'),
	DNS_DOWN_FAILSAFE: _('DNS down; original upstream configuration restored'),
	DNS_RECOVERED: _('DNS recovered'),
	NFT_TABLE_RESTORED: _('Missing nftables table restored'),
	DNSMASQ_CONFDIR_NOT_FOUND: _('dnsmasq configuration directory not found'),
	DNSMASQ_EXTRA_SERVERS: _('Additional dnsmasq servers: {servers}'),
	IPV6_PRESENT: _('Global IPv6 address present on {iface}'),
	SUB_UPDATED:
		_('Subscription {sub}: added {added}, updated {updated}, stale {stale}, removed {removed}, skipped {skipped}'),
	SUB_FETCH_FAILED: _('Subscription {sub} fetch failed: {detail}'),
	SUB_DECODE_FAILED: _('Subscription {sub} decode failed: {detail}'),
	SUB_FORMAT_UNSUPPORTED: _('Subscription {sub} format unsupported: {detail}'),
	SUB_APPLY_INVALID: _('Subscription {sub} apply invalid: {detail}'),
	SUB_PROXY_UNAVAILABLE: _('Subscription {sub} proxy unavailable: {detail}'),
	SUB_SHRANK: _('Subscription {sub} shrank from {old} to {new}'),
	SUB_NO_VALID_NODES: _('Subscription {sub} has no valid nodes; skipped {skipped}'),
	UPDATE_AVAILABLE: _('Update available for {package}: {current} to {latest}'),
	UPDATE_INSTALLED: _('Installed {package} version {version}'),
	UPDATE_VERIFY_FAILED: _('Update verification failed for {package}: {version}'),
	UPDATE_ROLLED_BACK: _('Rolled back {package} to {version}'),
	DATA_UPDATED: _('Updated rule data: {items}'),
	MANIFEST_BAD_SIGNATURE: _('Invalid manifest signature: {url}'),
	UPDATE_FETCH_FAILED: _('Could not fetch update channels: {urls}'),
	NO_SPACE: _('Insufficient space: need {need}, free {free}'),
	ARCH_UNSUPPORTED: _('Unsupported architecture: {arch}'),
	CMD_FAILED: _('Command {cmd} exited with {rc}: {stderr}'),
	FS_FAILED: _('File operation {op} failed for {path}: {detail}')
};
const RANK = { error: 0, warn: 1, notice: 2 };
const LEVELS = { error: _('Error'), warn: _('Warning'), notice: _('Notice') };
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

function message(event) {
	const args = event.args || {};
	if (!Object.prototype.hasOwnProperty.call(TEMPLATES, event.code))
		return event.code + ' ' + JSON.stringify(args);
	return TEMPLATES[event.code].replace(/\{(\w+)\}/g, (match, key) => value_text(args[key]));
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
	events: function(res, previous, level, code) {
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
				text: message(event), title: JSON.stringify(event.args || {})
			}));
		return {
			data, rows, codes: Array.from(new Set(events.map(e => e.code))).sort(),
			error: ok ? null : failure(res || {}),
			skipped: data.skipped > 0 ? _('Skipped {n} damaged event lines').replace('{n}', data.skipped) : null
		};
	},

	sources: function() {
		return [ [ 'all', _('All') ], [ 'aether-proxy', 'aether-proxy' ], [ 'xray', 'Xray' ], [ 'dns', 'DNS' ] ];
	},
	line_counts: function() { return [ 100, 200, 500, 1000, 2000 ]; },
	log_params: function(source, lines) { return { source: source, lines: Number(lines) }; },
	raw: function(res, log_level) {
		return {
			text: res && res.ok !== false ? (res.lines || []).map(line => line.text).join('\n') : '',
			error: res && res.ok !== false ? null : failure(res || {}),
			hint: log_level == 'debug' ?
				_('Increase the buffer in System → Log; return to notice after troubleshooting.') : null
		};
	}
});
