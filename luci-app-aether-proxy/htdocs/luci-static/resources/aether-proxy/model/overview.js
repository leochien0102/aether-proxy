'use strict';
'require baseclass';
'require aether-proxy.model.logs as logs';

/*
 * Pure overview model (docs/10 「概览页」「Dashboard：概览页升级」「其余页面先出页面」「概览页第六轮修正」).
 *
 * build() turns the raw rpc results into everything the view renders: texts are
 * already translated through _() (every msgid used here must have an entry in
 * po/zh_Hans/aether-proxy.po), and button availability is decided per state.
 * T10.22 also summarizes staged session changes before disabling the service;
 * T10.23 keeps real latency independent of monitor health and switches via node_use;
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

/* Duration uses the same buckets as probe age, without implying a timestamp. */
function state_duration(now, ts) {
	const d = Math.max(0, Math.floor(now - ts));
	if (d < 60)
		return fmt(_('For %s seconds', 'aether-proxy'), d);
	if (d < 3600)
		return fmt(_('For %s minutes', 'aether-proxy'), Math.floor(d / 60));
	if (d < 86400)
		return fmt(_('For %s hours', 'aether-proxy'), Math.floor(d / 3600));
	return fmt(_('For %s days', 'aether-proxy'), Math.floor(d / 86400));
}

function state_level(state) {
	if (state == 'running')
		return 'ok';
	if (state == 'degraded' || state == 'failsafe')
		return 'warn';
	return state == 'error' ? 'error' : 'neutral';
}

function error_text(code) {
	const texts = {
		NODE_RESOLVE_FAILED: _('Node address resolution failed.', 'aether-proxy'),
		CONFIG_INVALID: _('Invalid configuration; see the logs page.', 'aether-proxy'),
		START_FAILED: _('Start failed; see the logs page.', 'aether-proxy')
	};
	return code == null ? null : (texts[code] ?? String(code));
}

/* DNS tiers are backend codes, not user-facing explanations (docs/03). */
function dns_text(state, tier) {
	if (!['starting', 'running', 'degraded', 'failsafe'].includes(state) || tier == null)
		return null;
	const texts = {
		T1: _('Resolved through the node (normal).', 'aether-proxy'),
		T2: _('Direct to overseas DNS (starting, or proxy unhealthy).', 'aether-proxy'),
		T3: _('Domestic DNS only (overseas DNS unreachable; results may be poisoned).', 'aether-proxy')
	};
	return texts[tier] ?? String(tier);
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
			return fmt(_('The component %s is missing; install it before starting the service.', 'aether-proxy'),
				args.component ?? '?') + (args.component == 'chinadns-ng' ? ' ' +
				_('Or download the chinadns-ng package from the release page and install it manually.',
					'aether-proxy') : '');

		case 'UPDATE_AVAILABLE':
			return fmt(_('An update for %s is available (%s).', 'aether-proxy'), args.package ?? '?', args.available ?? '?');

		case 'IPV6_PRESENT':
			/* docs/03 「IPv4-only 的泄漏处理」 wording. */
			return fmt(_('A global IPv6 address is present on %s: clients may still connect directly over IPv6, consider disabling the LAN IPv6 assignment.', 'aether-proxy'), args.iface ?? '?');

		case 'DNSMASQ_EXTRA_SERVERS':
			return fmt(
				_('dnsmasq configuration contains server= lines that this service did not write: %s.', 'aether-proxy'),
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

/* Undefined is the pending inventory; null is a failed call, not an unknown version. */
function components_failed(inventory) {
	return inventory !== undefined && inventory?.ok !== true;
}

/* Keep diagnostics out of path cells; the view shows one retryable explanation. */
function component_error(inventory) {
	if (!components_failed(inventory))
		return null;
	return {
		text: fmt(_('Reading component information failed (%s)', 'aether-proxy'), inventory?.code ?? 'RPC_FAILED'),
		detail: inventory?.detail || null
	};
}

/* Own version comes from a separate RPC, even when reading status failed. */
function component_rows(version, inventory) {
	const components = [{
		name: 'aether-proxy',
		version: version === undefined ? _('Reading…', 'aether-proxy')
			: ((version && version.ok && typeof version.version == 'string') ? version.version : null),
		path: '/usr/bin/aether-proxy'
	}];
	/* Inventory is independent of runtime status, including failed status reads. */
	for (const name of [ 'xray', 'chinadns-ng' ]) {
		if (inventory === undefined) {
			components.push({ name, version: _('Reading…', 'aether-proxy'), path: _('Reading…', 'aether-proxy') });
			continue;
		}
		if (components_failed(inventory)) {
			components.push({ name, version: _('Reading failed', 'aether-proxy'), path: '' });
			continue;
		}
		const c = inventory.components?.[name];
		components.push({
			name,
			version: c?.found === true && c.version != null ? String(c.version) : null,
			path: c?.found === false ? _('Not found', 'aether-proxy')
				: (c?.found === true && c.path != null ? String(c.path) : null)
		});
	}
	return components;
}

function probe_fields(probe, now) {
	if (typeof probe != 'object' || probe == null)
		return { probe_text: _('Not probed yet', 'aether-proxy'), probe_since_text: null, probe_level: 'neutral' };
	return {
		probe_text: probe.ok
			? fmt(_('Healthy, %s ms', 'aether-proxy'), probe.latency_ms ?? '?') : _('Probe failed', 'aether-proxy'),
		probe_since_text: typeof probe.at == 'number' ? rel_time(now, probe.at) : null,
		probe_level: probe.ok ? 'ok' : 'error'
	};
}

function node_options(labels, current) {
	return Object.keys(labels ?? {}).sort().map((id) => ({
		value: id,
		text: id === current
			? fmt(_('%s (current)', 'aether-proxy'), labels[id] || id) : (labels[id] || id)
	}));
}

/* Reload failures leave runtime status unchanged. Compare against UCI instead
   of last_error, which describes startup rather than the attempted switch. */
function switch_pending(status, configured_node) {
	const active = ['starting', 'running', 'degraded', 'failsafe'].includes(status?.state);
	if (status?.ok === false || !active)
		return false;
	return !!configured_node && !!status.node_id && configured_node !== status.node_id;
}

function switch_reason(reply) {
	if (!reply || reply.ok === false)
		return null;
	const codes = [ 'NODE_RESOLVE_FAILED', 'CONFIG_INVALID', 'PRECHECK_FAILED', 'RENDER_INVALID' ];
	let latest = null;
	for (const event of reply.events ?? []) {
		const reload_failure = event.code === 'START_FAILED'
			&& typeof event.args?.step === 'string' && event.args.step.startsWith('reload:');
		if (!codes.includes(event.code) && !reload_failure)
			continue;
		if (!latest || event.ts >= latest.ts)
			latest = event;
	}
	return latest;
}

function switch_notice(status, configured_node, labels, reply, now) {
	if (!switch_pending(status, configured_node))
		return null;
	const configured = labels[configured_node] || configured_node;
	const reason = switch_reason(reply);
	if (!reason)
		return fmt(_('Switching to “%s”…', 'aether-proxy'), configured);
	return fmt(_('Switching to “%s” did not take effect; the service is still using “%s”. '
		+ 'Reason: %s (%s). Click Restart to start with the configured node '
		+ '(this briefly interrupts proxy traffic), or see the logs page for details.', 'aether-proxy'),
		configured, labels[status.node_id] || status.node_id, logs.message(reason), rel_time(now, reason.ts));
}

return baseclass.extend({
	switch_pending: switch_pending,
	component_rows: component_rows,
	components_failed: components_failed,
	component_error: component_error,

	/* docs/10 T10.22: apply commits the entire session, not just this switch.
	   Only an option set/removal is superseded; section edits still matter. */
	staged_confirmation: function(changes) {
		let count = 0;
		const configs = [];
		for (const [config, records] of Object.entries(changes)) {
			const others = records.filter((record) => {
				const enabled_option = config === 'aetherproxy'
					&& record[1] === 'main' && record[2] === 'enabled';
				const replaced = (record[0] === 'set' && record.length === 4)
					|| (record[0] === 'remove' && record.length === 3);
				return !enabled_option || !replaced;
			});
			if (others.length) {
				count += others.length;
				configs.push(config);
			}
		}
		if (!count)
			return null;
		return {
			title: _('Unapplied changes remain', 'aether-proxy'),
			text: fmt(_('%s unapplied changes remain (%s) and will be applied together with this operation.',
				'aether-proxy'), count, configs.join('、')),
			ok: _('Apply together', 'aether-proxy'),
			destructive: false
		};
	},
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
		const result = {
			proxy: {}, direct: {}, total: {},
			total_label: _('Total (WAN)', 'aether-proxy'),
			total_title: current?.wan?.dev
				? fmt(_('All traffic on WAN interface %s, including the router itself.', 'aether-proxy'),
					current.wan.dev)
				: _('All traffic on the WAN interface, including the router itself.', 'aether-proxy')
		};
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

	probe_sites: function(reply) {
		const sites = reply?.ok === true && Array.isArray(reply.sites) ? reply.sites : [];
		const valid = sites.length && sites.every(site =>
			typeof site?.name === 'string' && site.name && typeof site.label === 'string' && site.label);
		if (valid)
			return { options: sites.map(site => ({ value: site.name, text: site.label })), error: null };
		/* An empty or malformed list counts as a failed read: probing stays disabled and no
		   site is guessed (docs/10 「检测真实延迟与切换节点」, settled 2026-10-21). */
		return { options: [], error: fmt(_('Reading the site list failed (%s)', 'aether-proxy'),
			reply?.ok === false ? (reply.code ?? 'RPC_FAILED') : 'RPC_FAILED') };
	},

	probe_result: function(reply, label) {
		if (reply?.ok === true)
			return fmt(_('%s %s ms', 'aether-proxy'), label, reply.latency_ms);
		if (reply?.code === 'PROBE_TIMEOUT')
			return fmt(_('%s timed out', 'aether-proxy'), label);
		if (reply?.code === 'PROBE_FAILED')
			return reply.http_code != null
				? fmt(_('%s returned HTTP %s', 'aether-proxy'), label, reply.http_code)
				: fmt(_('%s connection failed', 'aether-proxy'), label);
		if (reply?.code === 'NOT_RUNNING')
			return _('The service is not running.', 'aether-proxy');
		return failure_text(reply);
	},

	node_use_message: function(reply, status) {
		if (reply?.ok !== true)
			return fmt(_('Switching nodes failed (%s)', 'aether-proxy'), reply?.code ?? 'RPC_FAILED')
				+ (reply?.detail ? ': ' + reply.detail : '');
		if (reply.reload === false && status?.ok !== false
			&& ['stopped', 'error'].includes(status?.state))
			return _('Set as the current node; it will be used on the next start.', 'aether-proxy');
		return null;
	},

	node_options: node_options,

	can_switch: function(selected, current) {
		return !!selected && selected !== current;
	},

	/* status/version: undefined while pending, null or ok:false on failure,
	   otherwise the objects resolved by ap.call. labels: node section name -> label from
	   UCI, now: current unix time in seconds. configured_node is read at load;
	   inventory is undefined while pending, null/ok:false on failure, and is
	   fetched after rendering or on explicit retry (docs/10 「概览页第五轮修正」). events contains
	   recent errors only while a node switch is pending (docs/10 T10.11). */
	build: function(status, version, labels, now, enabled, configured_node, inventory, events) {
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
		const disable_confirmation = _('Turning this off stops the service immediately, sends all traffic directly, '
			+ 'and disables automatic startup at boot. Turn it off?', 'aether-proxy');
		const disabled_notice = is_enabled ? null : _('The service is not enabled: turn on the Enable switch '
			+ 'and it will start automatically.', 'aether-proxy');
		const stop_confirmation = _('Stopping the service leaves all traffic going out directly. '
			+ 'This is only temporary: restarting the router or saving the settings of this '
			+ 'service again starts it; to disable it for good, turn off Enable above.', 'aether-proxy');

		const components = component_rows(version, inventory);
		const state = (status?.ok === false ? null : status?.state) ?? 'unknown';
		const active = ['starting', 'running', 'degraded', 'failsafe'].includes(state);
		/* WAN counters also include other services; missing proxy counters cannot imply direct traffic. */
		const traffic_note = active || status === undefined ? null
			: _('The service is not running; proxy and direct traffic cannot be distinguished.', 'aether-proxy');
		/* Inactive state files can retain an old node_id; only runtime wins. */
		const current_node = (active && status.node_id) || configured_node || null;
		const nodes = {
			switch_notice: switch_notice(status, configured_node, labels, events, now),
			current_node,
			node_options: node_options(labels, current_node),
			node_text: Object.keys(labels).length ? null
				: _('There are no nodes yet. Add or import nodes on the Nodes page.', 'aether-proxy')
		};

		/* docs/10: a failed status read shows the error and disables every button. */
		if (!status || status.ok === false) {
			/* Undefined is the initial read, not an RPC failure. Keep UCI-only
			   controls usable without inventing any runtime state (docs/10 T10.17). */
			const pending = status === undefined;
			const code = (status && typeof status.code == 'string') ? status.code : 'RPC_FAILED';
			const detail = (status && typeof status.detail == 'string' && status.detail != '') ? status.detail : null;

			return {
				ok: false,
				error: pending ? null
					: fmt(_('Reading the status failed (%s); will retry automatically later', 'aether-proxy'), code),
				error_detail: pending ? null : detail,
				state_text: pending ? _('Reading…', 'aether-proxy') : null,
				probe_disabled: true,
				traffic_note,
				dns_failsafe: false,
				state_level: 'neutral',
				state_duration_text: null,
				error_text: null,
				dns_text: null,
				...nodes,
				node_ip: null,
				node_address_text: null,
				probe_text: null,
				probe_since_text: null,
				probe_level: 'neutral',
				components,
				notices: [],
				enabled: is_enabled,
				enabled_note,
				disable_confirmation,
				disabled_notice,
				stop_confirmation,
				buttons: { start: false, restart: false, stop: false }
			};
		}

		return {
			ok: true,
			error: null,
			error_detail: null,
			probe_disabled: !['running', 'degraded'].includes(state),
			state_text: state_text(state, status.waiting_network === true),
			traffic_note,
			dns_failsafe: status.dns_failsafe === true,
			state_level: state_level(state),
			state_duration_text: (typeof status.since == 'number') ? state_duration(now, status.since) : null,
			error_text: error_text(status.last_error),
			dns_text: dns_text(state, status.dns_tier),
			...nodes,
			node_ip: (active && status.node_ip) ? String(status.node_ip) : null,
			node_address_text: (active && status.node_ip)
				? fmt(_('Node address %s', 'aether-proxy'), status.node_ip) : null,
			...probe_fields(status.last_probe, now),
			components,
			notices: (Array.isArray(status.notices) ? status.notices : []).map(notice_text),
			enabled: is_enabled,
			enabled_note,
			disable_confirmation,
			disabled_notice,
			stop_confirmation,
			buttons: buttons_for(true, state, is_enabled)
		};
	}
});
