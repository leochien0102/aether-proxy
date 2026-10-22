'use strict';
'require baseclass';
// Pure subscription presentation, ID generation and deletion plans for the LuCI view.
// Design: docs/10「订阅页」「订阅页修正」「订阅：通用设置、获取方式与行首开关」.
// Keep inheritance pure, URLs masked and the current node retained.

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
	ss_plugin: _('SS with plugin', 'aether-proxy'), vmess_alterid: _('VMess alterId is not zero', 'aether-proxy'),
	ipv6_address: _('IPv6 address', 'aether-proxy'), missing_field: _('Missing required field', 'aether-proxy'),
	duplicate: _('Duplicate', 'aether-proxy'), insecure_transport: _('Insecure transport', 'aether-proxy'),
	invalid_value: _('Invalid value', 'aether-proxy')
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
function status_result(status, id, now) {
	return status === undefined ? { text: _('Reading…', 'aether-proxy'), time: '', skipped: '' } :
		result(status?.subs?.[id], now);
}
function interval_text(value) {
	const labels = {
		'0': _('Do not update automatically', 'aether-proxy'),
		'12': _('12 hours', 'aether-proxy'), '24': _('1 day', 'aether-proxy'),
		'72': _('3 days', 'aether-proxy'), '168': _('7 days', 'aether-proxy')
	};
	return labels[String(value)] || fmt(_('%s hours', 'aether-proxy'), value);
}
function fetch_text(value) {
	return {
		auto: _('Automatic (direct first, then via current node on failure)', 'aether-proxy'),
		direct: _('Direct', 'aether-proxy'), proxy: _('Via current node', 'aether-proxy')
	}[value] || value;
}
function general_values(section, default_ua) {
	return {
		interval_hours: section?.interval_hours || '24',
		fetch_via: section?.fetch_via || 'auto',
		user_agent: section?.user_agent || default_ua
	};
}
function follow(value) {
	return fmt(_('Follow general settings (%s)', 'aether-proxy'), value);
}
function effective_text(raw, common, format) {
	return raw ? format(raw) : fmt(_('%s (general)', 'aether-proxy'), format(common));
}
function row(s, status, now, busy, general) {
	if (!s)
		return null;
	const common = general_values(general);
	return {
		id: s['.name'], name: s.name || s['.name'], address: mask(s.url),
		enabled: s.enabled === '0' ? _('Disabled', 'aether-proxy') : _('Enabled', 'aether-proxy'),
		interval: effective_text(s.interval_hours, common.interval_hours, interval_text),
		via: effective_text(s.fetch_via, common.fetch_via, fetch_text),
		result: status_result(status, s['.name'], now), can_update: !busy
	};
}
function job_error(failure) {
	if (failure.code === 'USAGE')
		return _('Subscription not applied yet; please save and apply first', 'aether-proxy');
	return fmt(_('Update failed: %s', 'aether-proxy'), failure.code || failure.error || 'UNKNOWN') +
		(failure.detail ? '（' + failure.detail + '）' : '');
}
return baseclass.extend({
	general_values,
	interval_text,
	fetch_text,
	follow,
	interval_choices: function(current) {
		const values = ['0', '12', '24', '72', '168'];
		if (current && !values.includes(String(current)))
			values.push(String(current));
		return values.map(value => [value, interval_text(value)]);
	},
	status_result,
	row,
	pending_ids: function(changes) {
		// Subscription IDs own the s_ namespace, including removed sections absent from UCI now.
		return new Set((changes?.aetherproxy || []).map(change => change[1])
			.filter(id => typeof id === 'string' && id.startsWith('s_')));
	},
	build: function(subscriptions, status, now, busy, general) {
		return {
			error: status && status.ok === false ? status.code + ': ' + (status.detail || '') : '',
			rows: subscriptions.map(s => row(s, status, now, busy, general)), can_update: !busy
		};
	},
	job_result: function(job, name_for_id) {
		if (job.ok === false)
			return [job_error(job)];
		const subs = job.result?.subs || {};
		const lines = Object.entries(subs).map(([id, s]) => {
			const name = typeof name_for_id === 'function' ? name_for_id(id) : name_for_id?.[id];
			return (name || id) + ': ' + (s.ok === false ? (errors[s.code] || s.code) :
				fmt(_('Added %s / Updated %s / Stale %s / Revived %s / Removed %s', 'aether-proxy'),
					s.added ?? 0, s.updated ?? 0, s.stale ?? 0, s.revived ?? 0, s.removed ?? 0));
		});
		if (!lines.length && (job.result?.ok === false || job.state === 'failed'))
			return [job_error(job.result || job)];
		return lines;
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
