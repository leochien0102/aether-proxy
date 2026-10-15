'use strict';

import * as mon from 'aetherproxy.monitor';

const BASE = {
	state: 'running', dns_tier: 'T1', dns_failsafe: false,
	xray_down_count: 0, xray_down_reported: false,
	chinadns_down_count: 0, chinadns_down_reported: false,
	proxy_fail_count: 0, proxy_ok_count: 0, dns_fail_count: 0,
	t3_since: null, last_t2_retry: null, t2_retry_pending: false,
	last_node_refresh: 1000, node_ip: '203.0.113.9', last_probe: null, since: 900
};
const CFG = {
	main: { fail_open: true },
	probe: { fail_threshold: 3, recover_threshold: 2 },
	dns: { allow_china_fallback: true }
};

function test(name, state, obs, cfg, actions, codes, fields) {
	return { name, expect: 'PASS', state, obs, cfg, actions, codes, fields };
};

export const cases = [
	{ name: 'monitor cadence follows running state', expect: 'PASS', kind: 'interval' },
	test('one missing-table sample is debounced', {},
		{ now: 1000, table_present: false, xray_listening: true, chinadns_listening: true }, CFG,
		[], [], { state: 'running', table_missing_count: 1 }),
	test('two missing-table rounds schedule one reload', { table_missing_count: 1 },
		{ now: 1010, table_present: false, xray_listening: true, chinadns_listening: true }, CFG,
		[ 'nft_reload' ], [ 'NFT_TABLE_RESTORED' ], { state: 'running', table_missing_count: 2 }),
	test('a present middle sample clears table debounce', { table_missing_count: 1 },
		{ now: 1010, table_present: true, xray_listening: true, chinadns_listening: true }, CFG,
		[], [], { state: 'running', table_missing_count: 0 }),
	test('first xray-down round is tolerated', { xray_down_count: 0 },
		{ now: 1010, table_present: true, xray_listening: false, chinadns_listening: true }, CFG,
		[], [], { xray_down_count: 1, state: 'running' }),
	test('second xray-down round fails open and lowers DNS', { xray_down_count: 1 },
		{ now: 1020, table_present: true, xray_listening: false, chinadns_listening: true }, CFG,
		[ 'nft_flush_prerouting', 'set_tier:T2' ], [ 'DNS_TIER_CHANGED', 'XRAY_DOWN_FAILOPEN' ],
		{ xray_down_count: 2, state: 'failsafe', dns_tier: 'T2' }),
	test('fail_open false keeps interception but lowers DNS', { xray_down_count: 1 },
		{ now: 1020, table_present: true, xray_listening: false, chinadns_listening: true },
		{ ...CFG, main: { fail_open: false } }, [ 'set_tier:T2' ], [ 'DNS_TIER_CHANGED', 'XRAY_DOWN' ],
		{ state: 'degraded', dns_tier: 'T2' }),
	test('xray recovery reloads the table after fail-open', { state: 'failsafe', xray_down_count: 2, xray_down_reported: true },
		{ now: 1040, table_present: true, xray_listening: true, chinadns_listening: true }, CFG,
		[ 'nft_reload' ], [ 'XRAY_RECOVERED' ], { state: 'degraded', xray_down_count: 0, xray_down_reported: false }),
	test('first chinadns-down round is tolerated', { chinadns_down_count: 0 },
		{ now: 1010, table_present: true, xray_listening: true, chinadns_listening: false }, CFG,
		[], [], { chinadns_down_count: 1, dns_failsafe: false }),
	test('second chinadns-down round removes dnsmasq fragment', { chinadns_down_count: 1 },
		{ now: 1020, table_present: true, xray_listening: true, chinadns_listening: false }, CFG,
		[ 'dnsmasq_remove' ], [ 'DNS_DOWN_FAILSAFE' ], { chinadns_down_count: 2, dns_failsafe: true }),
	test('chinadns recovery reinstalls dnsmasq fragment', { dns_failsafe: true, chinadns_down_count: 2, chinadns_down_reported: true },
		{ now: 1030, table_present: true, xray_listening: true, chinadns_listening: true }, CFG,
		[ 'dnsmasq_install' ], [ 'DNS_RECOVERED' ], { dns_failsafe: false, chinadns_down_count: 0 }),
	test('proxy failures below threshold do not switch state', { proxy_fail_count: 1 },
		{ now: 1010, table_present: true, xray_listening: true, chinadns_listening: true, proxy_ok: false }, CFG,
		[], [], { proxy_fail_count: 2, state: 'running' }),
	test('proxy failure at threshold becomes degraded and uses T2', { proxy_fail_count: 2 },
		{ now: 1020, table_present: true, xray_listening: true, chinadns_listening: true, proxy_ok: false, proxy_latency_ms: 19 }, CFG,
		[ 'set_tier:T2' ], [ 'DNS_TIER_CHANGED', 'PROXY_UNHEALTHY' ], { proxy_fail_count: 3, state: 'degraded', dns_tier: 'T2' }),
	test('proxy recovery below threshold remains degraded', { state: 'degraded', dns_tier: 'T2', proxy_ok_count: 0 },
		{ now: 1030, table_present: true, xray_listening: true, chinadns_listening: true, proxy_ok: true }, CFG,
		[], [], { proxy_ok_count: 1, state: 'degraded' }),
	test('proxy recovery at threshold becomes running and uses T1', { state: 'degraded', dns_tier: 'T2', proxy_ok_count: 1 },
		{ now: 1040, table_present: true, xray_listening: true, chinadns_listening: true, proxy_ok: true, proxy_latency_ms: 12 }, CFG,
		[ 'set_tier:T1' ], [ 'DNS_TIER_CHANGED', 'PROXY_HEALTHY' ], { proxy_ok_count: 2, state: 'running', dns_tier: 'T1' }),
	test('one T2 DNS failure does not enter T3', { state: 'degraded', dns_tier: 'T2' },
		{ now: 1010, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: false }, CFG,
		[], [], { dns_fail_count: 1, dns_tier: 'T2' }),
	test('two T2 DNS failures enter T3 when allowed', { state: 'degraded', dns_tier: 'T2', dns_fail_count: 1 },
		{ now: 1020, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: false }, CFG,
		[ 'set_tier:T3' ], [ 'DNS_TIER_CHANGED' ], { dns_tier: 'T3', dns_fail_count: 0, t3_since: 1020, last_t2_retry: 1020 }),
	test('two T2 DNS failures stay T2 without fallback permission', { state: 'degraded', dns_tier: 'T2', dns_fail_count: 1 },
		{ now: 1020, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: false },
		{ ...CFG, dns: { allow_china_fallback: false } }, [], [], { dns_tier: 'T2', dns_fail_count: 2 }),
	test('T3 does not retry before five minutes', { state: 'degraded', dns_tier: 'T3', t3_since: 1000, last_t2_retry: 1000 },
		{ now: 1299, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: true }, CFG,
		[], [], { dns_tier: 'T3' }),
	test('T3 retries T2 at five minutes', { state: 'degraded', dns_tier: 'T3', t3_since: 1000, last_t2_retry: 1000 },
		{ now: 1300, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: true }, CFG,
		[ 'set_tier:T2' ], [ 'DNS_TIER_CHANGED' ], { dns_tier: 'T2', last_t2_retry: 1300, t2_retry_pending: true }),
	test('failed T2 retry immediately returns to T3', { state: 'degraded', dns_tier: 'T2', t3_since: 1000, last_t2_retry: 1300, t2_retry_pending: true },
		{ now: 1310, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: false }, CFG,
		[ 'set_tier:T3' ], [ 'DNS_TIER_CHANGED' ], { dns_tier: 'T3', t2_retry_pending: false, t3_since: 1310 }),
	test('successful T2 retry clears pending state', { state: 'degraded', dns_tier: 'T2', t3_since: 1000, last_t2_retry: 1300, t2_retry_pending: true },
		{ now: 1310, table_present: true, xray_listening: true, chinadns_listening: true, dns_ok: true }, CFG,
		[], [], { dns_tier: 'T2', t2_retry_pending: false, dns_fail_count: 0 }),
	test('node refresh runs just before its ten-minute boundary only when due', { last_node_refresh: 1000 },
		{ now: 1599, table_present: true, xray_listening: true, chinadns_listening: true }, CFG,
		[], [], { last_node_refresh: 1000 }),
	test('node refresh runs at ten minutes', { last_node_refresh: 1000 },
		{ now: 1600, table_present: true, xray_listening: true, chinadns_listening: true }, CFG,
		[ 'refresh_node_ip' ], [], { last_node_refresh: 1600 }),
	test('combined restore and fail-open actions preserve monitor order', { state: 'running', dns_tier: 'T1', xray_down_count: 1, table_missing_count: 1 },
		{ now: 1020, table_present: false, xray_listening: false, chinadns_listening: true }, CFG,
		[ 'nft_reload', 'nft_flush_prerouting', 'set_tier:T2' ],
		[ 'NFT_TABLE_RESTORED', 'DNS_TIER_CHANGED', 'XRAY_DOWN_FAILOPEN' ], { state: 'failsafe', dns_tier: 'T2' })
];

export function run(c) {
	if (c.kind == 'interval')
		return mon.interval_ms({ state: 'running' }) == 30000 && mon.interval_ms({ state: 'degraded' }) == 10000
			? 'PASS' : 'FAIL: cadence mismatch';
	let result = mon.next({ ...BASE, ...(c.state ?? {}) }, c.obs, c.cfg);
	if (sprintf('%.J', result.actions) != sprintf('%.J', c.actions))
		return `FAIL: ${c.name} actions ${sprintf('%.J', result.actions)}`;
	let codes = map(result.events, e => e.code);
	if (sprintf('%.J', codes) != sprintf('%.J', c.codes))
		return `FAIL: ${c.name} events ${sprintf('%.J', codes)}`;
	for (let key, value in c.fields)
		if (sprintf('%.J', result.state[key]) != sprintf('%.J', value))
			return `FAIL: ${c.name} ${key} expected ${sprintf('%.J', value)} got ${sprintf('%.J', result.state[key])}`;
	return 'PASS';
};
