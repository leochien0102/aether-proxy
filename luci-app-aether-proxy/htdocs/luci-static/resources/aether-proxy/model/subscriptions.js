'use strict';
'require baseclass';
// Pure subscription presentation, ID generation and deletion plans for the LuCI view.
// Design: docs/10「订阅页（2026-10-16 定，T8.6）」; keep URLs masked and the current node retained.

function fmt(text, ...args) {
	for (const arg of args) text = text.replace('%s', String(arg));
	return text;
}
const errors = {
	SUB_FETCH_FAILED: _('Download failed', 'aether-proxy'),
	SUB_DECODE_FAILED: _('Decode failed', 'aether-proxy'),
	SUB_FORMAT_UNSUPPORTED: _('Unsupported format', 'aether-proxy'),
	SUB_NO_VALID_NODES: _('No valid nodes', 'aether-proxy'),
	SUB_APPLY_INVALID: _('Invalid configuration after update', 'aether-proxy'),
	SUB_PROXY_UNAVAILABLE: _('Proxy unavailable', 'aether-proxy'),
	SUB_SHRANK: _('Node count dropped sharply', 'aether-proxy')
};
const reasons = {
	malformed: _('Malformed', 'aether-proxy'), unsupported_scheme: _('Unsupported protocol', 'aether-proxy'),
	unsupported_transport: _('Unsupported transport', 'aether-proxy'), unsupported_security: _('Unsupported security', 'aether-proxy'),
	ss_plugin: _('SS with plugin', 'aether-proxy'), vmess_alterid: _('VMess alterId is not zero', 'aether-proxy')
};
function relative(now, at) {
	if (at == null) return '–';
	const seconds = Math.max(0, Math.floor(now - at));
	if (seconds < 60) return fmt(_('%s seconds ago', 'aether-proxy'), seconds);
	if (seconds < 3600) return fmt(_('%s minutes ago', 'aether-proxy'), Math.floor(seconds / 60));
	if (seconds < 86400) return fmt(_('%s hours ago', 'aether-proxy'), Math.floor(seconds / 3600));
	return fmt(_('%s days ago', 'aether-proxy'), Math.floor(seconds / 86400));
}
function mask(url) {
	// Accept only an unambiguous HTTP(S) authority; never echo path/userinfo.
	const match = /^(https?):\/\/([^\s/?#]+)(?:[/?#]|$)/i.exec(url || '');
	if (!match) return '…';
	const host = match[2].split('@').pop();
	if (!/^(?:[a-z0-9.-]+|\[[0-9a-f:]+\])(?::[0-9]+)?$/i.test(host)) return '…';
	return match[1].toLowerCase() + '://' + host + '/…';
}
function result(record, now) {
	if (!record) return { text: _('Not updated yet', 'aether-proxy'), time: '–', skipped: '' };
	const counts = record.skipped || {};
	const entries = Object.keys(counts).map(key => (reasons[key] || key) + ' ' + counts[key]);
	return {
		text: record.error ? (errors[record.error] || record.error) : fmt(_('Success, %s nodes', 'aether-proxy'), record.nodes),
		time: relative(now, record.last_attempt),
		skipped: entries.length ? fmt(_('Skipped %s: %s', 'aether-proxy'), Object.values(counts).reduce((a, b) => a + b, 0), entries.join('、')) : ''
	};
}
return baseclass.extend({
	build: function(subscriptions, status, now, busy) {
		return {
			error: status && status.ok === false ? status.code + ': ' + (status.detail || '') : '',
			rows: subscriptions.map(s => ({
				id: s['.name'], name: s.name || s['.name'], address: mask(s.url),
				enabled: s.enabled === '0' ? _('Disabled', 'aether-proxy') : _('Enabled', 'aether-proxy'),
				interval: Number(s.interval_hours ?? 24) === 0 ? _('Manual only', 'aether-proxy') : fmt(_('%s hours', 'aether-proxy'), s.interval_hours || 24),
				via: s.fetch_via || 'auto', result: result(status?.subs?.[s['.name']], now),
				can_update: !busy
			})), can_update: !busy
		};
	},
	job_result: function(job, names) {
		if (job.ok === false) return [job.code + ': ' + (job.detail || '')];
		return Object.entries(job.result?.subs || {}).map(([id, s]) =>
			(names[id] || id) + ': ' + (s.ok === false ? s.code :
				fmt(_('Added %s / Updated %s / Stale %s / Revived %s / Removed %s', 'aether-proxy'), s.added ?? 0, s.updated ?? 0, s.stale ?? 0, s.revived ?? 0, s.removed ?? 0)));
	},
	new_id: function(existing, bytes) {
		let id;
		do { id = 's_' + Array.from(bytes(), b => b.toString(16).padStart(2, '0')).join(''); }
		while (existing.includes(id));
		return id;
	},
	delete_plan: function(id, nodes, current) {
		const owned = nodes.filter(n => n.source === id);
		const remove = owned.filter(n => n['.name'] !== current).map(n => n['.name']);
		const manual = owned.filter(n => n['.name'] === current).map(n => n['.name']);
		return { remove, manual, confirm: fmt(_('Delete this subscription and %s nodes? %s current node(s) will be kept as manual.', 'aether-proxy'), remove.length, manual.length) };
	}
});
