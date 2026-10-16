'use strict';
'require baseclass';

/*
 * Pure view model for the overview page (docs/10 「页面卡的写法」「概览页」).
 *
 * build() turns the raw rpc results into everything the view renders: texts are
 * already translated through _() (every msgid used here must have an entry in
 * po/zh_Hans/aether-proxy.po), button availability is decided per state, and
 * nothing here issues requests or touches the DOM. The view only renders the
 * returned object and never looks at the rpc results' business fields.
 */

/* Replaces each %s with the corresponding extra argument, in order. */
function fmt(s) {
	for (let i = 1; i < arguments.length; i++)
		s = s.replace('%s', arguments[i]);

	return s;
}

/* docs/10 「概览页」: the state wording, with 「等待网络」 while --boot waits. */
const STATE_TEXT = {
	stopped: _('Stopped'),
	starting: _('Starting'),
	running: _('Running'),
	degraded: _('Degraded'),
	failsafe: _('Failsafe'),
	error: _('Start failed')
};

function state_text(state, waiting_network) {
	if (state == 'starting' && waiting_network)
		return _('Waiting for network');

	return STATE_TEXT[state] ?? state;
}

/* Relative time with one bucket per magnitude (docs/10: 「x 分钟前」之类). */
function rel_time(now, ts) {
	const d = Math.max(0, Math.floor(now - ts));

	if (d < 60)
		return fmt(_('%s seconds ago'), d);
	if (d < 3600)
		return fmt(_('%s minutes ago'), Math.floor(d / 60));
	if (d < 86400)
		return fmt(_('%s hours ago'), Math.floor(d / 3600));

	return fmt(_('%s days ago'), Math.floor(d / 86400));
}

/* docs/10 「概览页」: only start is usable in stopped/error; in every other
   documented state start is disabled and restart/stop are usable. */
function buttons_for(ok, state) {
	if (!ok)
		return { start: false, restart: false, stop: false };

	const active = (state == 'starting' || state == 'running' || state == 'degraded' || state == 'failsafe');

	return {
		start: (state == 'stopped' || state == 'error'),
		restart: active,
		stop: active
	};
}

function notice_args(n) {
	return (n && typeof n.args == 'object' && n.args != null) ? n.args : {};
}

/* One line per notice, args filled in; an unknown code still produces a line
   naming the event code instead of throwing (docs/tasks/m8.md T8.4 scenario 8). */
function notice_text(n) {
	if (!n || typeof n.code != 'string')
		return fmt(_('Unhandled notice: %s.'), JSON.stringify(n ?? {}));

	const args = notice_args(n);

	switch (n.code) {
		case 'COMPONENT_MISSING':
			return fmt(_('The component %s is missing; install it before starting the service.'), args.component ?? '?');

		case 'UPDATE_AVAILABLE':
			return fmt(_('An update for %s is available (%s).'), args.package ?? '?', args.available ?? '?');

		case 'IPV6_PRESENT':
			/* docs/03 「IPv4-only 的泄漏处理」 wording. */
			return fmt(_('A global IPv6 address is present on %s: clients may still connect directly over IPv6, consider disabling the LAN IPv6 assignment.'), args.iface ?? '?');

		case 'DNSMASQ_EXTRA_SERVERS': {
			/* concatenated by hand to keep the ucode join() guard (docs/12 syntax
			   limit 4, enforced on all added code) quiet */
			const servers = Array.isArray(args.servers) ? args.servers : [];
			let list = '';

			for (const s of servers)
				list += (list == '' ? '' : '; ') + s;

			return fmt(_('dnsmasq configuration contains additional server= lines outside aether-proxy: %s.'), list);
		}

		default:
			return fmt(_('Unhandled notice: %s.'), n.code + ' ' + JSON.stringify(args));
	}
}

return baseclass.extend({
	/* status: the object resolved by ap.call('status'), version: the object
	   resolved by ap.call('version'), labels: node section name -> label from
	   UCI, now: current unix time in seconds. Returns the view model. */
	build: function(status, version, labels, now) {
		labels = (labels && typeof labels == 'object') ? labels : {};
		now = (typeof now == 'number') ? now : Math.floor(Date.now() / 1000);

		const own_version = (version && version.ok && typeof version.version == 'string') ? version.version : null;

		/* docs/10: a failed status read shows the error and disables every button. */
		if (!status || status.ok === false) {
			const code = (status && typeof status.code == 'string') ? status.code : 'RPC_FAILED';
			const detail = (status && typeof status.detail == 'string' && status.detail != '') ? status.detail : null;

			return {
				ok: false,
				error: fmt(_('Reading the status failed: %s.'), detail ? code + ': ' + detail : code),
				state_text: null,
				dns_failsafe: false,
				state_since_text: null,
				dns_tier_text: null,
				node_text: null,
				node_ip: null,
				probe_text: null,
				probe_since_text: null,
				components: [],
				own_version,
				notices: [],
				buttons: { start: false, restart: false, stop: false }
			};
		}

		const state = status.state ?? 'unknown';
		const node_id = (status.node_id == null) ? null : String(status.node_id);

		let probe_text = null, probe_since_text = null;
		const probe = (typeof status.last_probe == 'object' && status.last_probe != null) ? status.last_probe : null;

		if (probe) {
			probe_text = probe.ok ? fmt(_('Healthy, %s ms.'), probe.latency_ms ?? '?') : _('Probe failed.');

			if (typeof probe.at == 'number')
				probe_since_text = rel_time(now, probe.at);
		}
		else {
			probe_text = _('Not probed yet.');
		}

		const components = [];
		const raw_components = (typeof status.components == 'object' && status.components != null) ? status.components : {};

		for (const name of Object.keys(raw_components).sort()) {
			const c = raw_components[name];

			components.push({
				name,
				version: (c && typeof c == 'object' && c.version != null) ? String(c.version) : null,
				path: (c && typeof c == 'object' && c.path != null) ? String(c.path) : null
			});
		}

		return {
			ok: true,
			error: null,
			state_text: state_text(state, status.waiting_network === true),
			dns_failsafe: status.dns_failsafe === true,
			state_since_text: (typeof status.since == 'number') ? rel_time(now, status.since) : null,
			dns_tier_text: (status.dns_tier == null) ? null : String(status.dns_tier),
			node_text: (node_id == null) ? null : (labels[node_id] || node_id),
			node_ip: (status.node_ip == null) ? null : String(status.node_ip),
			probe_text,
			probe_since_text,
			components,
			own_version,
			notices: (Array.isArray(status.notices) ? status.notices : []).map(notice_text),
			buttons: buttons_for(true, state)
		};
	}
});
