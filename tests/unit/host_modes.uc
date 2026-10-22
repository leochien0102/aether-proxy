'use strict';

// T9.19: docs/02 device modes and docs/03 shared DNS. Test normalized inputs and exact
// rule bodies independently of the renderer, including disabled and overlapping hosts.
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';
import * as chinadns from 'aetherproxy.render.chinadns';

const CTX = { paths: {
	gfwlist: '/etc/aether-proxy/data/gfwlist.txt',
	chnlist: '/etc/aether-proxy/data/chnlist.txt', apple: '/etc/aether-proxy/data/apple.txt'
} };
const GFW = { policy: 'gfw', mac: 'AA-BB-CC-DD-EE-19' };
const BYPASS = { policy: 'bypass_cn', ip: '192.168.19.0/24' };
const BODIES = {
	gfw: '\t\tip daddr @proxy_ip4 goto proxy\n\t\tip daddr @uproxy4 goto proxy\n' +
		'\t\tip daddr @gfw4 goto proxy\n\t\tip daddr @gfw_static4 goto proxy\n',
	bypass_cn: '\t\tip daddr @proxy_ip4 goto proxy\n\t\tip daddr @uproxy4 goto proxy\n' +
		'\t\tip daddr @chnroute4 return\n\t\tgoto proxy\n'
};

function snapshot(mode, hosts) {
	let r = config.normalize({ main: { mode }, hosts: hosts ?? [] });
	if (!r.ok)
		die(sprintf('unexpected config errors: %.J', r.errors));
	return r.snapshot;
}

function chain(text, name) {
	let parts = split(text, '\tchain ' + name + ' {\n');
	return length(parts) == 2 ? split(parts[1], '\t}\n')[0] : null;
}

function contains(text, part) {
	return index(text, part) >= 0;
}

function mode_rules(c) {
	let text = nft.render(snapshot(c.mode, [ GFW, BYPASS ]), CTX);
	return chain(text, 'mode_' + c.policy) == BODIES[c.policy] &&
		chain(nft.render(snapshot(c.policy), CTX), 'by_mode') == BODIES[c.policy];
}

function disabled(c) {
	let off = { ...GFW, enabled: '0', udp: '1' };
	let off_bypass = { ...BYPASS, enabled: '0', udp: '1' };
	let base = snapshot(c.mode);
	let with_off = snapshot(c.mode, [ off, off_bypass ]);
	return nft.render(base, CTX) == nft.render(with_off, CTX) &&
		chinadns.render(base, CTX) == chinadns.render(with_off, CTX);
}

function dns_delta(c) {
	let ctx = { ...CTX, runtime: { dns_tier: c.tier } };
	let base = chinadns.render(snapshot(c.mode), ctx);
	let hosts = [ GFW, { ...GFW, mac: 'aa:bb:cc:dd:ee:20' } ];
	let actual = chinadns.render(snapshot(c.mode, hosts), ctx);
	let add = 'add-taggfw-ip inet@aetherproxy@gfw4,null\n';
	if (c.mode == 'gfw')
		return actual == base;
	if (c.mode == 'global')
		base = replace(base, 'chnlist-file ', 'gfwlist-file ' + CTX.paths.gfwlist + '\nchnlist-file ');
	return actual == replace(base, '\ngroup uproxy\n', '\n' + add + 'group uproxy\n');
}

function precedence() {
	// Reverse UCI order, overlapping networks and unlisted=direct must not change precedence.
	let s = snapshot('bypass_cn', [
		{ policy: 'follow', ip: '192.168.19.10' }, GFW, BYPASS,
		{ policy: 'proxy', ip: '192.168.0.0/16' }, { policy: 'direct', ip: '192.168.19.0/28' }
	]);
	s.main.unlisted_policy = 'direct';
	let text = nft.render(s, CTX);
	let expected = '';
	for (let p in [ 'direct', 'proxy', 'bypass_cn', 'gfw', 'follow' ]) {
		let action = p == 'direct' ? 'return' : 'goto ' +
			(p == 'proxy' ? 'proxy' : (p == 'follow' ? 'by_mode' : 'mode_' + p));
		expected += '\t\tip saddr @host_' + p + '4 ' + action + '\n';
		expected += '\t\tether saddr @host_' + p + '_mac ' + action + '\n';
	}
	return chain(text, 'host_policy') == expected &&
		contains(text, 'set host_gfw_mac { type ether_addr; elements = { aa:bb:cc:dd:ee:19 } }') &&
		contains(text, 'set host_bypass_cn4 { type ipv4_addr; flags interval; auto-merge; ' +
			'elements = { 192.168.19.0/24 } }');
}

function udp(c) {
	let h = c.policy == 'gfw' ? GFW : BYPASS;
	let base = nft.render(snapshot('global'), CTX);
	let text = nft.render(snapshot('global', [ { ...h, udp: '1' } ]), CTX);
	let element = c.policy == 'gfw' ? 'aa:bb:cc:dd:ee:19' : '192.168.19.0/24';
	let set_prefix = c.policy == 'gfw' ? 'set host_udp_mac { type ether_addr; ' :
		'set host_udp4 { type ipv4_addr; flags interval; auto-merge; ';
	return chain(text, 'proxy') == chain(base, 'proxy') &&
		contains(text, set_prefix + 'elements = { ' + element + ' } }');
}

function only_used(c) {
	let h = c.policy == 'gfw' ? GFW : BYPASS;
	let other = c.policy == 'gfw' ? 'bypass_cn' : 'gfw';
	let text = nft.render(snapshot(c.mode, [ h ]), CTX);
	let dns_unchanged = c.policy != 'bypass_cn' ||
		chinadns.render(snapshot(c.mode, [ h ]), CTX) == chinadns.render(snapshot(c.mode), CTX);
	return chain(text, 'mode_' + c.policy) == BODIES[c.policy] && dns_unchanged &&
		!contains(text, 'host_' + other) && !contains(text, 'mode_' + other);
}

function validation(c) {
	let r = config.normalize({ hosts: c.hosts });
	return join(',', map(r.errors ?? [], e => e.field + ':' + e.code)) == c.errors;
}

export const cases = [
	{ name: 'host policy precedence direct proxy bypass_cn gfw follow', fn: 'precedence', expect: true },
	{ name: 'direct plus UDP remains a conflict', fn: 'validation',
		hosts: [ { policy: 'direct', ip: '192.168.1.1', udp: '1' } ],
		errors: 'host[0].udp:conflict', expect: true },
	{ name: 'override duplicate IP and /32 remain a conflict', fn: 'validation',
		hosts: [ { ...BYPASS, ip: '192.168.1.1' }, { ...GFW, ip: '192.168.1.1/32' } ],
		errors: 'host[1].ip:duplicate', expect: true },
	{ name: 'override duplicate MAC remains a conflict even when disabled', fn: 'validation',
		hosts: [ GFW, { ...BYPASS, mac: 'aa:bb:cc:dd:ee:19', enabled: '0' } ],
		errors: 'host[1].mac:duplicate', expect: true },
	{ name: 'override duplicate CIDR remains a conflict', fn: 'validation',
		hosts: [ BYPASS, { ...GFW, ip: BYPASS.ip } ],
		errors: 'host[1].ip:duplicate', expect: true },
	{ name: 'override with no address remains invalid', fn: 'validation',
		hosts: [ { policy: 'gfw' } ], errors: 'host[0].ip:required', expect: true },
	{ name: 'unknown host mode remains invalid', fn: 'validation',
		hosts: [ { ...BYPASS, policy: 'global' } ], errors: 'host[0].policy:invalid_enum', expect: true }
];

for (let mode in [ 'bypass_cn', 'global', 'gfw' ]) {
	push(cases, { name: mode + ' disabled overrides are byte-identical to no hosts',
		fn: 'disabled', mode, expect: true });
	for (let tier in [ 'T1', 'T2', 'T3' ])
		push(cases, { name: mode + ' ' + tier + ' GFW device DNS exact delta',
			fn: 'dns_delta', mode, tier, expect: true });
	for (let policy in [ 'bypass_cn', 'gfw' ]) {
		push(cases, { name: mode + ' mode_' + policy + ' matches exact default rules',
			fn: 'mode_rules', mode, policy, expect: true });
		push(cases, { name: mode + ' only used ' + policy + ' mode is emitted',
			fn: 'only_used', mode, policy, expect: true });
	}
}
for (let policy in [ 'bypass_cn', 'gfw' ])
	push(cases, { name: policy + ' game mode populates UDP set and leaves proxy chain unchanged',
		fn: 'udp', policy, expect: true });

export function run(c) {
	switch (c.fn) {
	case 'precedence': return precedence();
	case 'validation': return validation(c);
	case 'disabled': return disabled(c);
	case 'dns_delta': return dns_delta(c);
	case 'mode_rules': return mode_rules(c);
	case 'only_used': return only_used(c);
	case 'udp': return udp(c);
	}
	return false;
};
