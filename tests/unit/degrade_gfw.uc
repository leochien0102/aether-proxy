'use strict';

// T9.40: docs/02 temporary routing and docs/04 health hysteresis. Assert exact chains,
// unchanged policy/exception handling and the actions required before publishing state.
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as monitor from 'aetherproxy.monitor';

const GFW_BODY = '\t\tip daddr @proxy_ip4 goto proxy\n\t\tip daddr @uproxy4 goto proxy\n' +
	'\t\tip daddr @gfw4 goto proxy\n\t\tip daddr @gfw_static4 goto proxy\n';
const HOSTS = [
	{ policy: 'bypass_cn', ip: '192.168.1.10', mac: 'aa:bb:cc:dd:ee:10', udp: '1' },
	{ policy: 'proxy', ip: '192.168.1.11' },
	{ policy: 'direct', ip: '192.168.1.12' }
];
const CTX = { runtime: { degraded_mode: 'gfw', dns_tier: 'T3' }, paths: {
	gfwlist: '/gfw.txt', chnlist: '/chn.txt', apple: '/apple.txt',
	proxy_domain: '/proxy.txt', direct_domain: '/direct.txt', boot_list: '/boot.txt'
} };

function snapshot(mode, hosts, enabled) {
	let r = config.normalize({ main: { mode, degrade_gfw: enabled }, hosts: hosts ?? [] });
	if (!r.ok)
		die(sprintf('unexpected configuration errors: %.J', r.errors));
	return r.snapshot;
}

function chain(text, name) {
	let parts = split(text, '\tchain ' + name + ' {\n');
	return length(parts) == 2 ? split(parts[1], '\t}\n')[0] : null;
}

function render_case(c) {
	let s = snapshot(c.mode, HOSTS);
	// A distinct global policy is not representable in UCI (docs/05). Test the render
	// contract on an explicit snapshot, never reinterpret the persisted proxy policy.
	push(s.hosts, { enabled: true, policy: 'global', ip: [ '192.168.1.13' ], mac: [] });
	let text = nft.render(s, CTX);
	let base = nft.render(s, { ...CTX, runtime: { dns_tier: 'T3' } });
	let policy = chain(text, 'host_policy');
	return chain(text, 'by_mode') == GFW_BODY && chain(text, 'mode_gfw') == GFW_BODY &&
		index(policy, '@host_bypass_cn4 goto mode_gfw') >= 0 &&
		index(policy, '@host_global4 goto mode_gfw') >= 0 &&
		index(policy, '@host_proxy4 goto proxy') >= 0 && index(policy, '@host_direct4 return') >= 0 &&
		chain(text, 'prerouting') == chain(base, 'prerouting') &&
		chain(text, 'proxy') == chain(base, 'proxy') &&
		chain(text, 'quic_reject') == chain(base, 'quic_reject') &&
		chain(text, 'dns_hijack') == chain(base, 'dns_hijack') &&
		index(text, 'set host_udp4 { type ipv4_addr; flags interval; auto-merge; ' +
			'elements = { 192.168.1.10 } }') >= 0;
}

function dns_case(c) {
	let actual = chinadns.render(snapshot(c.mode, HOSTS), CTX);
	let expected = chinadns.render(snapshot('gfw', HOSTS), { ...CTX, runtime: { dns_tier: 'T3' } });
	return actual == expected && index(actual, 'add-taggfw-ip inet@aetherproxy@gfw4,null') >= 0;
}

function transition(c) {
	let cfg = snapshot(c.mode, c.hosts, c.enabled);
	cfg.probe.fail_threshold = 3;
	cfg.probe.recover_threshold = 2;
	let s = monitor.initial_state({ state: c.start ?? 'starting', dns_tier: 'T3' }, 1000);
	s.degraded_mode = c.applied ?? null;
	s.degraded_since = c.applied ? 900 : null;
	s.proxy_fail_count = c.fails ?? 2;
	s.proxy_ok_count = c.successes ?? 0;
	let obs = { now: 1010, proxy_ok: c.healthy ?? false, xray_listening: c.listening ?? true };
	let r = monitor.next(s, obs, cfg);
	return (index(r.actions, 'set_degraded_mode') >= 0) == c.action &&
		r.state.degraded_mode == (c.target ?? null);
}

export const cases = [];
for (let mode in [ 'bypass_cn', 'global', 'gfw' ]) {
	push(cases, { name: mode + ' degraded chains preserve forced policies exceptions game mode and QUIC',
		kind: 'render', mode, expect: true });
	push(cases, { name: mode + ' degraded DNS equals GFW at the same tier', kind: 'dns', mode, expect: true });
}
for (let mode in [ 'bypass_cn', 'global' ]) {
	push(cases, { name: mode + ' never-healthy startup degrades at failure threshold',
		kind: 'transition', mode, action: true, target: 'gfw', expect: true });
	push(cases, { name: mode + ' disabled switch does not degrade', kind: 'transition',
		mode, enabled: '0', action: false, expect: true });
}
push(cases,
	{ name: 'GFW without overrides does nothing', kind: 'transition', mode: 'gfw', action: false, expect: true },
	{ name: 'GFW with enabled bypass override still degrades', kind: 'transition', mode: 'gfw',
		hosts: HOSTS, action: true, target: 'gfw', expect: true },
	{ name: 'disabled bypass override is not a target', kind: 'transition', mode: 'gfw',
		hosts: [ { ...HOSTS[0], enabled: '0' } ], action: false, expect: true },
	{ name: 'forced proxy is not a target', kind: 'transition', mode: 'gfw',
		hosts: [ HOSTS[1] ], action: false, expect: true },
	{ name: 'below threshold does not degrade', kind: 'transition', mode: 'global',
		fails: 1, action: false, expect: true },
	{ name: 'Xray down never enters routing degradation', kind: 'transition', mode: 'global',
		listening: false, action: false, expect: true },
	{ name: 'failsafe never enters routing degradation', kind: 'transition', mode: 'global',
		start: 'failsafe', action: false, expect: true },
	{ name: 'recovery below threshold retains applied override', kind: 'transition', mode: 'global',
		start: 'degraded', applied: 'gfw', healthy: true, successes: 0,
		action: false, target: 'gfw', expect: true },
	{ name: 'recovery threshold removes applied override', kind: 'transition', mode: 'global',
		start: 'degraded', applied: 'gfw', healthy: true, successes: 1, action: true, expect: true },
	{ name: 'never-healthy first success removes override', kind: 'transition', mode: 'global',
		start: 'starting', applied: 'gfw', healthy: true, action: true, expect: true },
	{ name: 'invalid degrade switch is rejected', kind: 'validation', expect: true }
);

export function run(c) {
	if (c.kind == 'render') return render_case(c);
	if (c.kind == 'dns') return dns_case(c);
	if (c.kind == 'validation')
		return !config.normalize({ main: { degrade_gfw: 'yes' } }).ok;
	// A previously healthy degraded route must use the configured recovery threshold.
	if (c.start == 'degraded') {
		let old = monitor.initial_state({ state: 'running', degraded_mode: 'gfw' }, 1000);
		let cfg = snapshot(c.mode);
		let r = monitor.next({ ...old, state: 'degraded', proxy_ok_count: c.successes ?? 0 },
			{ now: 1010, proxy_ok: true, xray_listening: true }, cfg);
		return (index(r.actions, 'set_degraded_mode') >= 0) == c.action &&
			r.state.degraded_mode == (c.target ?? null);
	}
	return transition(c);
};
