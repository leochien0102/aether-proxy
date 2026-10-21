'use strict';
'require baseclass';

/* Pure rules/DNS presentation and format preflight (docs/10 "规则与 DNS 页").
 * Match config.uc upstream and net.uc literally, including underscores in domains.
 * The CLI remains authoritative after LuCI applies its session configuration. */
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
function validate(field, value) {
	if (field == 'dns_probe_domain')
		return domain(value) ? true : _('Invalid DNS probe domain.', 'aether-proxy');
	if (field == 'allow_china_fallback')
		return value == '0' || value == '1' ? true : _('Invalid fallback flag.', 'aether-proxy');
	const values = Array.isArray(value) ? value : value == null ? [] : [ value ];
	if (field == 'trust_dns') {
		if (values.length < 1 || values.length > 2)
			return _('Trust DNS requires one or two IPv4 addresses.', 'aether-proxy');
		return values.every(ipv4) ? true : _('Invalid IPv4 address.', 'aether-proxy');
	}
	return values.every(upstream) ? true : _('Invalid DNS upstream.', 'aether-proxy');
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
return baseclass.extend({ validate, save_result, table, job_result, relative, loading_text, list_state,
	modes: function() {
		return [ [ 'bypass_cn', _('Bypass China — proxy destinations outside China.', 'aether-proxy') ],
			[ 'gfw', _('Blocked sites — proxy only blocked domains.', 'aether-proxy') ],
			[ 'global', _('Global — proxy all follow-policy traffic.', 'aether-proxy') ] ];
	}
});
