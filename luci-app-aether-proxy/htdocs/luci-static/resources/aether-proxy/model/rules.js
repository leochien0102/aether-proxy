'use strict';
'require baseclass';

/* Pure rules/DNS presentation and format preflight (docs/10 "规则与 DNS 页").
 * Match config.uc upstream and net.uc literally, including underscores in domains.
 * The CLI remains authoritative after LuCI applies its session configuration.
 * DNS presets, trust transports and WAN hints follow docs/10 "DNS 常用地址与协议".
 * Direct DNS test fields follow docs/03 "直连境外 DNS（可选）" and docs/10 r13. */
function fmt(s) {
	for (let i = 1; i < arguments.length; i++)
		s = s.replace('%s', arguments[i]);
	return s;
}
function ipv4(s) {
	return typeof s == 'string' && s.split('.').length == 4 && s.split('.').every(
		o => /^(0|[1-9][0-9]{0,2})$/.test(o) && +o <= 255);
}
function domain(s) {
	return typeof s == 'string' && s.length >= 1 && s.length <= 253 && s.split('.').every(
		l => l.length <= 63 && /^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$/.test(l));
}
function upstream(s) {
	if (typeof s != 'string')
		return false;
	let rest = s, i = rest.indexOf('://');
	if (i >= 0) {
		if (![ 'udp', 'tcp', 'tls' ].includes(rest.slice(0, i)))
			return false;
		rest = rest.slice(i + 3);
	}
	i = rest.indexOf('#');
	if (i >= 0) {
		const port = rest.slice(i + 1);
		if (!/^[0-9]{1,5}$/.test(port) || +port < 1 || +port > 65535)
			return false;
		rest = rest.slice(0, i);
	}
	i = rest.indexOf('@');
	if (i >= 0) {
		if (!domain(rest.slice(0, i)))
			return false;
		rest = rest.slice(i + 1);
	}
	return ipv4(rest);
}
/* Keep values separate from translated labels so adding a provider changes only this table. */
const PRESETS = {
	china_dns: [
		{ value: 'wan', name: _('ISP-provided DNS', 'aether-proxy') },
		{ value: '223.5.5.5', name: _('AliDNS', 'aether-proxy') },
		{ value: '223.6.6.6', name: _('AliDNS', 'aether-proxy') },
		{ value: '114.114.114.114', name: _('114 DNS', 'aether-proxy') },
		{ value: '114.114.115.115', name: _('114 DNS', 'aether-proxy') },
		{ value: '180.76.76.76', name: _('Baidu', 'aether-proxy') }
	],
	trust_dns: [
		{ value: '8.8.8.8', name: _('Google', 'aether-proxy') },
		{ value: '8.8.4.4', name: _('Google', 'aether-proxy') },
		{ value: '1.1.1.1', name: _('Cloudflare', 'aether-proxy') },
		{ value: '1.0.0.1', name: _('Cloudflare', 'aether-proxy') },
		{ value: '9.9.9.9', name: _('Quad9', 'aether-proxy') },
		{ value: '208.67.222.222', name: _('OpenDNS', 'aether-proxy') }
	],
	direct_dns: [
		{ value: 'tcp://9.9.9.9', name: _('Quad9', 'aether-proxy') },
		{ value: 'tcp://8.8.8.8', name: _('Google', 'aether-proxy') },
		{ value: 'tcp://1.1.1.1', name: _('Cloudflare', 'aether-proxy') }
	]
};
function presets(field) {
	return PRESETS[field].map(item => [ item.value, item.value == 'wan' ? item.name :
		fmt(_('%s (%s)', 'aether-proxy'), item.name, item.value) ]);
}
function trust_address(value) {
	return typeof value == 'string' && ipv4(value.replace(/^(tcp|udp):\/\//, ''));
}
function trust_input(value, optional) {
	return (optional && value == '') || ipv4(value) ? true : _('Invalid IPv4 address.', 'aether-proxy');
}
function trust_rows(value) {
	const values = Array.isArray(value) ? value : value == null ? [] : [ value ];
	return [0, 1].map(i => ({
		address: (values[i] ?? '').replace(/^(tcp|udp):\/\//, ''),
		protocol: values[i]?.startsWith('udp://') ? 'udp' : 'tcp'
	}));
}
function trust_values(rows) {
	/* Do not filter the first empty row: validation must reject it even if row 2 is filled. */
	return rows.map(row => row.address && row.protocol == 'udp' ? 'udp://' + row.address : row.address)
		.slice(0, rows[1].address == '' ? 1 : 2);
}
function wan_dns_text(status) {
	const active = ['starting', 'running', 'degraded', 'failsafe'].includes(status?.state);
	/* A successful status is state.json itself and carries no ok field. */
	if (!status || status.ok === false || !active || !Array.isArray(status.wan_dns))
		return null;
	return status.wan_dns.length ?
		fmt(_('ISP-provided DNS is currently %s', 'aether-proxy'),
			status.wan_dns.join(_(',', 'aether-proxy'))) :
		_('ISP-provided DNS is not available yet; temporarily using 223.5.5.5.', 'aether-proxy');
}
function validate(field, value) {
	if (field == 'dns_probe_domain')
		return domain(value) ? true : _('Invalid DNS probe domain.', 'aether-proxy');
	if (field == 'direct_dns_enabled')
		return value == '0' || value == '1' ? true : _('Invalid direct DNS flag.', 'aether-proxy');
	if (field == 'allow_china_fallback')
		return value == '0' || value == '1' ? true : _('Invalid fallback flag.', 'aether-proxy');
	const values = Array.isArray(value) ? value : value == null ? [] : [ value ];
	if (field == 'trust_dns') {
		if (values.length < 1 || values.length > 2)
			return _('Trust DNS requires one or two IPv4 addresses.', 'aether-proxy');
		return values.every(trust_address) ? true : _('Invalid IPv4 address.', 'aether-proxy');
	}
	return values.every(v => (field == 'china_dns' && v == 'wan') || upstream(v)) ?
		true : _('Invalid DNS upstream.', 'aether-proxy');
}
const NAMES = {
	gfwlist: _('Blocked domains', 'aether-proxy'), chnlist: _('China domains', 'aether-proxy'), apple: _('Apple China domains', 'aether-proxy'),
	chnroute4: _('China IPv4 routes', 'aether-proxy'), gfw_static4: _('Static proxy IPv4 routes', 'aether-proxy')
};
function relative(now, ts) {
	if (ts == null)
		return _('Never', 'aether-proxy');
	const delta = Math.max(0, Math.floor(now - ts));
	if (delta < 60)
		return fmt(_('%s seconds ago', 'aether-proxy'), delta);
	if (delta < 3600)
		return fmt(_('%s minutes ago', 'aether-proxy'), Math.floor(delta / 60));
	if (delta < 86400)
		return fmt(_('%s hours ago', 'aether-proxy'), Math.floor(delta / 3600));
	return fmt(_('%s days ago', 'aether-proxy'), Math.floor(delta / 86400));
}
function failure(r) {
	return (r?.code ?? 'RPC_FAILED') + ': ' + (r?.detail ?? '');
}
function save_result(r) {
	if (r?.ok)
		return { text: r.reload == 'failed' ? _('Saved, but reload failed.', 'aether-proxy') :
			(r.changed ? _('Saved.', 'aether-proxy') : _('Content unchanged.', 'aether-proxy')), errors: [] };
	return {
		text: failure(r),
		errors: (r?.errors ?? []).map(e => fmt(_('Line %s: %s', 'aether-proxy'), e.line, e.text))
	};
}
const loading_text = _('Reading…', 'aether-proxy');
/* Undefined means pending; a failed read must not expose a writable empty list. */
function list_state(r) {
	return {
		disabled: !r?.ok,
		content: r?.ok ? (r.content ?? '') : '',
		placeholder: r === undefined ? loading_text : '',
		error: r === undefined || r?.ok ? null : save_result(r)
	};
}
function table(r, now) {
	return {
		error: r?.ok ? null : failure(r), checked: relative(now, r?.checked),
		rows: Object.keys(NAMES).map(name => {
			const item = r?.items?.[name] ?? {};
			return [ NAMES[name], item.source == 'downloaded' ? _('Downloaded', 'aether-proxy') : _('Packaged', 'aether-proxy'),
				item.version ?? '—', item.lines ?? '—', relative(now, item.updated_at),
				item.changed === true ? _('Update available', 'aether-proxy') :
					item.changed === false ? _('Latest', 'aether-proxy') : _('Not checked', 'aether-proxy') ];
		})
	};
}
function job_result(job) {
	const r = job?.result ?? job;
	const names = list => (list ?? []).map(n => NAMES[n] ?? n).join(', ');
	const failures = Object.keys(r?.failed ?? {}).map(n => (NAMES[n] ?? n) + ': ' + r.failed[n]);
	/* docs/10 "名单改为标签页": omit empty categories, not their headings alone. */
	const lines = [];
	if (r?.updated?.length)
		lines.push(fmt(_('Updated: %s', 'aether-proxy'), names(r.updated)));
	if (r?.unchanged?.length)
		lines.push(fmt(_('Unchanged: %s', 'aether-proxy'), names(r.unchanged)));
	if (failures.length)
		lines.push(fmt(_('Failed: %s', 'aether-proxy'), failures.join('; ')));
	if (job?.ok === false || job?.error)
		lines.push(failure(job));
	return lines;
}
function dns_test_count(result, blocked) {
	if (result.ok == 0)
		return blocked ? _('Blocked domains cannot be resolved directly (normal).', 'aether-proxy') :
			fmt(_('All %s attempts failed', 'aether-proxy'), result.total);
	let text = blocked ? fmt(_('Blocked domain: out of %s attempts, %s succeeded', 'aether-proxy'),
		result.total, result.ok) : fmt(_('Out of %s attempts, %s succeeded', 'aether-proxy'), result.total, result.ok);
	if (result.latency_ms != null)
		text += fmt(_(', about %s ms', 'aether-proxy'), result.latency_ms);
	return text;
}
function dns_test_result(job) {
	const result = job?.result ?? job;
	if (job?.ok === false || job?.state == 'failed' || result?.ok === false) {
		const code = result?.code ?? job?.code ?? job?.error ?? 'CMD_FAILED';
		const detail = result?.detail ?? job?.detail;
		return [ fmt(_('Direct DNS test failed: %s', 'aether-proxy'), code + (detail ? ': ' + detail : '')) ];
	}
	if (!Array.isArray(result?.results)) {
		/* TODO(design): unspecified missing job results must not look like a
		 * successful empty test; report failure without changing configuration. */
		return [ _('Direct DNS test returned no results.', 'aether-proxy') ];
	}
	return result.results.map(item => {
		if (item.unsupported)
			return item.upstream + ': ' + _('This upstream format is not supported for testing.', 'aether-proxy');
		return item.upstream + ': ' + item.unblocked.domain + ' ' + dns_test_count(item.unblocked, false) +
			'; ' + item.blocked.domain + ' ' + dns_test_count(item.blocked, true);
	});
}
return baseclass.extend({ validate, save_result, table, job_result, dns_test_result, relative, loading_text, list_state,
	presets, trust_rows, trust_values, trust_input, wan_dns_text,
	modes: function() {
		return [ [ 'bypass_cn', _('Bypass China — proxy destinations outside China.', 'aether-proxy') ],
			[ 'gfw', _('Blocked sites — proxy only blocked domains.', 'aether-proxy') ],
			[ 'global', _('Global — proxy all follow-policy traffic.', 'aether-proxy') ] ];
	}
});
