'use strict';
'require baseclass';

/*
 * Pure overview/Dashboard model (docs/10 「页面卡的写法」「概览页」「Dashboard：概览页升级」).
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
	stopped: _('Stopped', 'aether-proxy'),
	starting: _('Starting', 'aether-proxy'),
	running: _('Running', 'aether-proxy'),
	degraded: _('Degraded', 'aether-proxy'),
	failsafe: _('Failsafe', 'aether-proxy'),
	error: _('Start failed', 'aether-proxy')
};

function state_text(state, waiting_network) {
	if (state == 'starting' && waiting_network)
		return _('Waiting for network', 'aether-proxy');

	return STATE_TEXT[state] ?? state;
}

/* Relative time with one bucket per magnitude (docs/10: 「x 分钟前」之类). */
function rel_time(now, ts) {
	const d = Math.max(0, Math.floor(now - ts));

	if (d < 60)
		return fmt(_('%s seconds ago', 'aether-proxy'), d);
	if (d < 3600)
		return fmt(_('%s minutes ago', 'aether-proxy'), Math.floor(d / 60));
	if (d < 86400)
		return fmt(_('%s hours ago', 'aether-proxy'), Math.floor(d / 3600));

	return fmt(_('%s days ago', 'aether-proxy'), Math.floor(d / 86400));
}

/* docs/10 「概览页」「启用开关」: only start is usable in stopped/error; in every
   other documented state start is disabled and restart/stop are usable. With
   main.enabled=0 the init script refuses to start at all, so start and restart
   are disabled in every state; stop still follows the state, because the
   service may have been started before the switch was turned off. `enabled`
   defaults to true so callers that predate the switch keep the old rules. */
function buttons_for(ok, state, enabled) {
	if (!ok)
		return { start: false, restart: false, stop: false };

	const on = (enabled !== false);
	const active = (state == 'starting' || state == 'running' || state == 'degraded' || state == 'failsafe');

	return {
		start: on && (state == 'stopped' || state == 'error'),
		restart: on && active,
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
		return fmt(_('Unhandled notice: %s.', 'aether-proxy'), JSON.stringify(n ?? {}));

	const args = notice_args(n);

	switch (n.code) {
		case 'COMPONENT_MISSING':
			return fmt(_('The component %s is missing; install it before starting the service.', 'aether-proxy'), args.component ?? '?');

		case 'UPDATE_AVAILABLE':
			return fmt(_('An update for %s is available (%s).', 'aether-proxy'), args.package ?? '?', args.available ?? '?');

		case 'IPV6_PRESENT':
			/* docs/03 「IPv4-only 的泄漏处理」 wording. */
			return fmt(_('A global IPv6 address is present on %s: clients may still connect directly over IPv6, consider disabling the LAN IPv6 assignment.', 'aether-proxy'), args.iface ?? '?');

		case 'DNSMASQ_EXTRA_SERVERS':
			return fmt(_('dnsmasq configuration contains additional server= lines outside aether-proxy: %s.', 'aether-proxy'),
				(Array.isArray(args.servers) ? args.servers : []).join('; '));

		default:
			return fmt(_('Unhandled notice: %s.', 'aether-proxy'), n.code + ' ' + JSON.stringify(args));
	}
}

/* Counter resets invalidate only the affected direction; a WAN device change
   invalidates WAN rates, not the independent nft proxy counters. */
function byte_rate(previous, current, direction, elapsed) {
	if (!previous || !current || !Number.isFinite(elapsed) || elapsed <= 0)
		return null;
	const before = previous[direction + '_bytes'];
	const after = current[direction + '_bytes'];
	if (!Number.isFinite(before) || !Number.isFinite(after) || after < before)
		return null;
	return (after - before) * 1000 / elapsed;
}

function failure_text(reply) {
	return (reply?.code ?? 'RPC_FAILED') + (reply?.detail ? ': ' + reply.detail : '');
}

function rate_text(rate) {
	if (rate == null)
		return '–';
	const units = [ 'B/s', 'KB/s', 'MB/s' ];
	let unit = 0;
	while (rate >= 1024 && unit < units.length - 1) {
		rate /= 1024;
		unit++;
	}
	return rate.toFixed(1) + ' ' + units[unit];
}

return baseclass.extend({
	refresh_options: function() {
		return [
			{ value: '2', text: _('2 seconds', 'aether-proxy') },
			{ value: '5', text: _('5 seconds (default)', 'aether-proxy') },
			{ value: '10', text: _('10 seconds', 'aether-proxy') },
			{ value: '30', text: _('30 seconds', 'aether-proxy') },
			{ value: '0', text: _('Off', 'aether-proxy') }
		];
	},

	refresh_interval: function(value) {
		return [ '2', '5', '10', '30', '0' ].includes(value) ? Number(value) * 1000 : 5000;
	},

	traffic: function(previous, current) {
		const elapsed = previous && current ? current.at_ms - previous.at_ms : 0;
		const result = { proxy: {}, direct: {}, total: {} };
		for (const direction of [ 'tx', 'rx' ]) {
			const proxy = byte_rate(previous?.proxy, current?.proxy, direction, elapsed);
			const same_device = previous?.wan?.dev === current?.wan?.dev;
			const total = same_device ? byte_rate(previous?.wan, current?.wan, direction, elapsed) : null;
			const direct = proxy == null || total == null ? null : Math.max(0, total - proxy);
			result.proxy[direction] = rate_text(proxy);
			result.total[direction] = rate_text(total);
			result.direct[direction] = rate_text(direct);
		}
		result.connections = {
			proxy: current?.connections?.proxy == null ? '–' : String(current.connections.proxy),
			total: current?.connections?.total == null ? '–' : String(current.connections.total)
		};
		return result;
	},

	probe_result: function(reply) {
		if (reply?.code == 'TIMEOUT')
			return _('The probe did not finish within 15 seconds.', 'aether-proxy');
		if (reply?.code == 'NOT_RUNNING')
			return _('The service is not running.', 'aether-proxy');
		if (!reply || reply.code)
			return failure_text(reply);
		return reply.ok ? fmt(_('Healthy, %s ms.', 'aether-proxy'), reply.latency_ms ?? '?') : _('Probe failed.', 'aether-proxy');
	},

	/* Keep completion detection here: the view must not interpret last_probe. */
	probe_completion: function(reply, requested_at) {
		if (reply?.ok === false)
			return { done: true, text: this.probe_result(reply) };
		const probe = reply?.last_probe;
		if (!probe || probe.at < requested_at || typeof probe.at != 'number')
			return { done: false };
		return { done: true, text: probe.ok
			? fmt(_('Healthy, %s ms.', 'aether-proxy'), probe.latency_ms ?? '?') : _('Probe failed.', 'aether-proxy') };
	},

	subscription_result: function(job, labels) {
		const subs = job?.result?.subs;
		if (!subs)
			return { text: failure_text({ code: job?.code ?? job?.result?.code,
				detail: job?.detail ?? job?.result?.detail }), failures: [] };
		let success = 0;
		const failures = [];
		for (const [id, sub] of Object.entries(subs)) {
			if (sub.ok)
				success++;
			else
				failures.push((labels?.[id] || id) + ': ' + (sub.code ?? '?'));
		}
		return { text: fmt(_('Subscription update finished: %s succeeded, %s failed.', 'aether-proxy'), success, failures.length),
			failures: failures };
	},

	/* status: the object resolved by ap.call('status'), version: the object
	   resolved by ap.call('version'), labels: node section name -> label from
	   UCI, now: current unix time in seconds. Returns the view model. */
	build: function(status, version, labels, now, enabled) {
		labels = (labels && typeof labels == 'object') ? labels : {};
		now = (typeof now == 'number') ? now : Math.floor(Date.now() / 1000);

		/* docs/10 「启用开关」: the page reads main.enabled once and passes it in;
		   an undefined argument keeps the pre-switch behaviour (enabled) so the
		   model stays usable without the switch. */
		const is_enabled = (enabled === undefined || enabled === null)
			? true
			: (enabled === true || enabled === '1' || enabled === 1);
		const enabled_note = _('Once enabled the service starts at boot; turning it off stops the service '
			+ 'immediately and all traffic goes out directly.', 'aether-proxy');
		const disabled_notice = is_enabled ? null : _('The service is not enabled: turn on the switch above '
			+ 'and it will start automatically.', 'aether-proxy');
		const stop_confirmation = _('Stopping aether-proxy leaves all traffic going out directly. '
			+ 'This is only temporary: restarting the router or saving the settings of this '
			+ 'service again starts it; to disable it for good, turn off Enable above.', 'aether-proxy');

		const own_version = (version && version.ok && typeof version.version == 'string') ? version.version : null;

		/* docs/10: a failed status read shows the error and disables every button. */
		if (!status || status.ok === false) {
			const code = (status && typeof status.code == 'string') ? status.code : 'RPC_FAILED';
			const detail = (status && typeof status.detail == 'string' && status.detail != '') ? status.detail : null;

			return {
				ok: false,
				error: fmt(_('Reading the status failed: %s.', 'aether-proxy'), detail ? code + ': ' + detail : code),
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
				enabled: is_enabled,
				enabled_note,
				disabled_notice,
				stop_confirmation,
				buttons: { start: false, restart: false, stop: false }
			};
		}

		const state = status.state ?? 'unknown';
		const node_id = (status.node_id == null) ? null : String(status.node_id);

		let probe_text = null, probe_since_text = null;
		const probe = (typeof status.last_probe == 'object' && status.last_probe != null) ? status.last_probe : null;

		if (probe) {
			probe_text = probe.ok ? fmt(_('Healthy, %s ms.', 'aether-proxy'), probe.latency_ms ?? '?') : _('Probe failed.', 'aether-proxy');

			if (typeof probe.at == 'number')
				probe_since_text = rel_time(now, probe.at);
		}
		else {
			probe_text = _('Not probed yet.', 'aether-proxy');
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
			enabled: is_enabled,
			enabled_note,
			disabled_notice,
			stop_confirmation,
			buttons: buttons_for(true, state, is_enabled)
		};
	}
});
