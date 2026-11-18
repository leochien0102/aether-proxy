'use strict';
// T16.17: independent TCP hysteresis, fault latching and runtime selection guards.
import * as config from 'aetherproxy.config';
import * as monitor from 'aetherproxy.monitor';
import * as failover from 'aetherproxy.node_failover';

const ID = 'n_11111111111111111111111111111111';
const OTHER = 'n_22222222222222222222222222222222';

export const cases = [
	{ name: 'T16.17 node file order preserved and subscription inheritance limited to three fields', kind: 'order', expect: true },
	{ name: 'T16.17 changed live IP resets the consecutive failure sequence', kind: 'ip-change', expect: true },
	{ name: 'T16.21 absent global defaults off and absent list is empty', kind: 'defaults', expect: true },
	{ name: 'T16.21 list is deduplicated, bounded and ordered', kind: 'normalize', expect: true },
	{ name: 'T16.21 participation requires global on, membership and an enabled existing node', kind: 'participation', expect: true },
	{ name: 'T16.21 selection depends on membership only; empty is none', kind: 'selection', expect: true },
	{ name: 'T16.21 invalid global and disabled bool rejected by check normalization', kind: 'invalid', expect: true },
	{ name: 'T16.17 global off never arms despite three TCP failures', kind: 'off', expect: true },
	{ name: 'T16.21 unlisted current node never triggers', kind: 'opt-out', expect: true },
	{ name: 'T16.21 disabled current node never triggers', kind: 'disabled', expect: true },
	{ name: 'T16.17 exactly three live TCP failures arm once', kind: 'trigger', expect: true },
	{ name: 'T16.17 HTTP failures without TCP failures never arm', kind: 'http', expect: true },
	{ name: 'T16.17 TCP success resets consecutive failures', kind: 'reset', expect: true },
	{ name: 'T16.17 same fault remains latched after ten minutes', kind: 'latch', expect: true },
	{ name: 'T16.17 recovery rearms a new fault after cooldown', kind: 'rearm', expect: true },
	{ name: 'T16.17 success cooldown blocks until exact ten-minute boundary', kind: 'cooldown', expect: true },
	{ name: 'T16.17 manual reload protects different node for ten minutes', kind: 'manual', expect: true },
	{ name: 'T16.17 failed manual reload does not impose manual protection', kind: 'manual-failed', expect: true }
];

function raw_node(value) {
	return { protocol: 'socks', address: '127.0.0.1', port: '443', ...value };
};

export function run(c) {
	if (c.kind == 'order') {
		let r = config.normalize({ sub: { failover: '1', fetch_via: 'proxy' },
			nodes: { [OTHER]: raw_node({}), [ID]: raw_node({}) },
			subscriptions: { s_22222222: { url: 'https://two.example' },
				s_11111111: { url: 'https://one.example' } } });
		return r.ok && keys(r.snapshot.nodes)[0] == OTHER &&
			keys(r.snapshot.subscriptions)[0] == 's_11111111' &&
			r.snapshot.subscriptions.s_11111111.failover == null &&
			r.snapshot.subscriptions.s_11111111.fetch_via == 'proxy';
	}
	if (c.kind == 'defaults') {
		let r = config.normalize({ nodes: { [ID]: raw_node({}) } });
		return r.ok && r.snapshot.sub.failover === false && r.snapshot.main.failover_nodes == null &&
			r.snapshot.nodes[ID].disabled == null;
	}
	if (c.kind == 'normalize') {
		let input = [ OTHER, '', null, OTHER, ' ', ID ];
		let wanted = [ OTHER, ID ];
		for (let i = 0; i < 70; i++) {
			let id = sprintf('n_%032x', i);
			push(input, id);
			if (i < 62)
				push(wanted, id);
		}
		let r = config.normalize({ main: { failover_nodes: input } });
		return r.ok && join(',', r.snapshot.main.failover_nodes) == join(',', wanted) &&
			join(',', failover.normalize(ID)) == ID;
	}
	if (c.kind == 'participation') {
		let r = config.normalize({ sub: { failover: '1' }, main: { failover_nodes: [ ID, OTHER, 'missing' ] },
			nodes: { [ID]: raw_node({ disabled: '0' }), [OTHER]: raw_node({ disabled: '1' }) } });
		if (!r.ok) return false;
		let cfg = r.snapshot;
		return failover.participates(cfg, ID) && !failover.participates(cfg, OTHER) &&
			!failover.participates(cfg, 'missing') &&
			!failover.participates({ ...cfg, sub: { failover: false } }, ID) &&
			!failover.participates({ ...cfg, main: {} }, ID);
	}
	if (c.kind == 'selection') {
		return failover.subscription_state([], [ ID ]) == 'none' &&
			failover.subscription_state([ ID, OTHER ], [ 'missing' ]) == 'none' &&
			failover.subscription_state([ ID, OTHER ], [ ID ]) == 'some' &&
			failover.subscription_state([ ID, OTHER ], [ OTHER, ID ]) == 'all';
	}
	if (c.kind == 'invalid') {
		let r = config.normalize({ sub: { failover: 'yes' }, nodes: { [ID]: raw_node({ disabled: '2' }) } });
		return !r.ok && length(r.errors) == 2 && r.errors[0].field == 'sub.failover' &&
			r.errors[1].field == `node.${ID}.disabled`;
	}
	let cfg = { main: { node: ID, mode: 'global', degrade_gfw: false,
			failover_nodes: c.kind == 'opt-out' ? [ OTHER ] : [ ID, OTHER ] },
		dns: { direct_dns_enabled: false, allow_china_fallback: false }, probe: { fail_threshold: 3 },
		sub: { failover: c.kind != 'off' }, nodes: { [ID]: { disabled: c.kind == 'disabled' } } };
	let state = monitor.initial_state({ state: 'running', dns_tier: 'T1', node_id: ID }, 1000);
	let now = 1000, attempts = 0;
	function round(tcp, stamp, id, reload) {
		now = stamp ?? now + 10;
		let r = monitor.next(state, { now, node_id: id ?? ID, node_reload: reload,
			node_tcp_ok: tcp, proxy_ok: false, xray_listening: true, table_present: true,
			chinadns_listening: true }, cfg);
		state = r.state;
		if (index(r.actions, 'failover') >= 0)
			attempts++;
	};
	if (c.kind == 'cooldown')
		state.failover_until = 1600;
	if (c.kind == 'manual' || c.kind == 'manual-failed') {
		cfg.nodes[OTHER] = {};
		let reload = { at: 1000, ok: c.kind == 'manual', target_node: OTHER };
		for (let i = 0; i < 3; i++) round(false, 1010 + i * 10, OTHER, reload);
		if (c.kind == 'manual-failed') return attempts == 1;
		if (attempts != 0 || state.failover_until != 1600) return false;
		round(false, 1599, OTHER, reload);
		if (attempts != 0) return false;
		round(false, 1600, OTHER, reload);
		return attempts == 1;
	}
	for (let i = 0; i < 2; i++) round(c.kind == 'http' ? true : false);
	if (attempts != 0) return false;
	if (c.kind == 'reset') round(true);
	if (c.kind == 'ip-change') {
		let r = monitor.next(state, { now: 1030, node_id: ID, node_tcp_ip: '127.0.0.2',
			node_tcp_ok: false }, cfg);
		return r.state.failover_failures == 1 && index(r.actions, 'failover') < 0;
	}
	round(c.kind == 'http' ? true : false);
	if (index([ 'off', 'opt-out', 'disabled', 'http', 'reset' ], c.kind) >= 0)
		return attempts == 0;
	if (c.kind == 'cooldown') {
		round(false, 1599);
		if (attempts != 0) return false;
		round(false, 1600);
		return attempts == 1;
	}
	if (attempts != 1) return false;
	if (c.kind == 'trigger') return state.failover_latched && state.failover_failures == 3;
	round(false, 1700);
	if (attempts != 1) return false;
	if (c.kind == 'latch') return true;
	round(true, 1710);
	for (let i = 0; i < 3; i++) round(false);
	return attempts == 2;
};
