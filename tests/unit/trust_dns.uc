'use strict';

// T9.22: docs/05 trust_dns grammar and docs/03 node-to-DNS protocol selection.
// Pure normalization covers the full grammar; pipeline.read covers CONFIG_INVALID
// using read-only fixtures, so no UCI write can leak into the host's default savedir.
import * as config from 'aetherproxy.config';
import * as pipeline from 'aetherproxy.pipeline';
import * as xray from 'aetherproxy.render.xray';
import * as chinadns from 'aetherproxy.render.chinadns';
import { trust_dns_parts } from 'aetherproxy.net';

const FIXTURES = sourcepath(0, true) + '/../fixtures/';
const DEFAULT = [ '8.8.8.8', '1.1.1.1' ];
const MIXED = [ 'udp://8.8.8.8', '1.1.1.1' ];

function snapshot(entries) {
	let r = config.normalize({ dns: { trust_dns: entries } });
	if (!r.ok)
		die(sprintf('unexpected trust_dns errors: %.J', r.errors));
	return r.snapshot;
}

function dns_lines(text) {
	return filter(split(text, '\n'), line => index(line, 'trust-dns ') == 0 ||
		index(line, 'group-upstream ') == 0);
}

function tunnels(entries) {
	let s = snapshot(entries);
	let obj = xray.build(s, {});
	let ins = slice(obj.inbounds, 1, 3);
	let addresses = map(entries, entry => replace(entry, /^(tcp|udp):\/\//, ''));
	if (length(ins) != 2)
		return false;
	let local_ports = ins[0].listen == '127.0.0.1' && ins[0].port == 31082 &&
		ins[1].listen == '127.0.0.1' && ins[1].port == 31083;
	let targets = ins[0].settings.address == addresses[0] &&
		ins[1].settings.address == (addresses[1] ?? addresses[0]);
	let dual_network = length(filter(ins, inbound => inbound.settings.network == 'tcp,udp' &&
		inbound.settings.port == 53 && inbound.protocol == 'tunnel')) == 2;
	let proxy_routing = index(obj.routing.rules[0].inboundTag, ins[0].tag) >= 0 &&
		index(obj.routing.rules[0].inboundTag, ins[1].tag) >= 0 &&
		obj.routing.rules[0].outboundTag == 'proxy';
	return local_ports && targets && dual_network && proxy_routing;
}

function explicit_tcp(tier, single) {
	let ctx = { runtime: { dns_tier: tier } };
	let entries = single ? [ '1.1.1.1' ] : DEFAULT;
	let bare = snapshot(entries);
	let explicit = snapshot(map(entries, entry => 'tcp://' + entry));
	return xray.render(bare, ctx) == xray.render(explicit, ctx) &&
		chinadns.render(bare, ctx) == chinadns.render(explicit, ctx);
}

function upstreams(c) {
	let ctx = { runtime: { dns_tier: 'T1' } };
	let lines = dns_lines(chinadns.render(snapshot(c.entries), ctx));
	return lines[0] == 'trust-dns ' + c.upstream &&
		lines[1] == 'group-upstream ' + c.upstream &&
		lines[2] == 'group-upstream 223.5.5.5,114.114.114.114' &&
		lines[3] == 'group-upstream tcp://9.9.9.9,tcp://8.8.8.8';
}

function fallback(tier) {
	let ctx = { runtime: { dns_tier: tier } };
	let bare = chinadns.render(snapshot(DEFAULT), ctx);
	let mixed = chinadns.render(snapshot(MIXED), ctx);
	let expected = tier == 'T2' ? 'tcp://9.9.9.9,tcp://8.8.8.8' : '223.5.5.5,114.114.114.114';
	return bare == mixed && dns_lines(mixed)[0] == 'trust-dns ' + expected &&
		dns_lines(mixed)[1] == 'group-upstream ' + expected;
}

function invalid(c) {
	let r = config.normalize({ dns: { trust_dns: [ c.entry ] } });
	return !r.ok && length(r.errors) == 1 && r.errors[0].field == 'dns.trust_dns' &&
		r.errors[0].code == 'invalid_ipv4';
}

function invalid_pipeline(c) {
	let r = pipeline.read({ confdir: FIXTURES + c.fixture });
	let failure = !r.ok && r.exit == 2 && r.code == 'CONFIG_INVALID';
	return failure && length(r.errors) == 1 && r.errors[0].field == 'dns.trust_dns';
}

export const cases = [
	{ name: 'bare IPv4 preserves legacy snapshot', fn: 'snapshot', expect: DEFAULT },
	{ name: 'bare IPv4 DNS tunnels are dual-network and stay routed through proxy',
		fn: 'tunnels', entries: DEFAULT, expect: true },
	{ name: 'mixed UDP TCP DNS tunnels have pure IPv4 targets and proxy routing',
		fn: 'tunnels', entries: MIXED, expect: true },
	{ name: 'single UDP target preserves second tunnel mirror',
		fn: 'tunnels', entries: [ 'udp://8.8.8.8' ], expect: true },
	{ name: 'bare IPv4 T1 trust and uproxy stay TCP; china and boot unchanged', fn: 'upstreams',
		entries: DEFAULT, upstream: 'tcp://127.0.0.1#31082,tcp://127.0.0.1#31083', expect: true },
	{ name: 'mixed UDP TCP T1 trust and uproxy select per-item protocol', fn: 'upstreams',
		entries: MIXED, upstream: 'udp://127.0.0.1#31082,tcp://127.0.0.1#31083', expect: true },
	{ name: 'reversed TCP UDP T1 uses corresponding ports', fn: 'upstreams',
		entries: [ 'tcp://1.1.1.1', 'udp://8.8.8.8' ],
		upstream: 'tcp://127.0.0.1#31082,udp://127.0.0.1#31083', expect: true },
	{ name: 'two UDP T1 entries both use local Xray', fn: 'upstreams',
		entries: [ 'udp://8.8.8.8', 'udp://1.1.1.1' ],
		upstream: 'udp://127.0.0.1#31082,udp://127.0.0.1#31083', expect: true },
	{ name: 'single UDP T1 only uses first port', fn: 'upstreams', entries: [ 'udp://8.8.8.8' ],
		upstream: 'udp://127.0.0.1#31082', expect: true },
	{ name: 'bare IPv4 parser defaults to TCP', fn: 'parts', entry: '1.1.1.1',
		expect: { protocol: 'tcp', address: '1.1.1.1' } },
	{ name: 'explicit TCP parser strips prefix', fn: 'parts', entry: 'tcp://1.1.1.1',
		expect: { protocol: 'tcp', address: '1.1.1.1' } },
	{ name: 'UDP parser strips prefix', fn: 'parts', entry: 'udp://8.8.8.8',
		expect: { protocol: 'udp', address: '8.8.8.8' } },
	{ name: 'three trust entries remain invalid', fn: 'count', expect: 'dns.trust_dns:too_many' }
];

for (let tier in [ 'T1', 'T2', 'T3' ]) {
	push(cases, { name: tier + ' explicit tcp prefixes equal bare IPv4 output',
		fn: 'explicit_tcp', tier, expect: true });
	push(cases, { name: tier + ' tcp://1.1.1.1 equals single bare 1.1.1.1 output',
		fn: 'explicit_tcp', tier, single: true, expect: true });
}
for (let tier in [ 'T2', 'T3' ])
	push(cases, { name: tier + ' ignores trust protocol and preserves complete chinadns output',
		fn: 'fallback', tier, expect: true });
for (let entry in [ 'udp://8.8.8.8#53', 'tls://8.8.8.8', 'udp://dns.google', 'tcp://8.8.8.8:53',
	'8.8.8.8#53', 'udp://dns.google@8.8.8.8', 'udp://[::1]', 'udp://256.8.8.8',
	'udp://08.8.8.8', 'UDP://8.8.8.8', 'udp://', 'https://8.8.8.8' ])
	push(cases, { name: 'reject ' + entry + ' at dns.trust_dns', fn: 'invalid', entry, expect: true });
for (let fixture in [ 't922-err-port', 't922-err-protocol', 't922-err-domain' ])
	push(cases, { name: fixture + ' returns CONFIG_INVALID and dns.trust_dns',
		fn: 'invalid_pipeline', fixture, expect: true });

export function run(c) {
	switch (c.fn) {
	case 'snapshot': return snapshot(DEFAULT).dns.trust_dns;
	case 'tunnels': return tunnels(c.entries);
	case 'upstreams': return upstreams(c);
	case 'parts': return trust_dns_parts(c.entry);
	case 'explicit_tcp': return explicit_tcp(c.tier, c.single);
	case 'fallback': return fallback(c.tier);
	case 'invalid': return invalid(c);
	case 'invalid_pipeline': return invalid_pipeline(c);
	case 'count':
		let r = config.normalize({ dns: { trust_dns: [ ...MIXED, 'udp://9.9.9.9' ] } });
		return r.errors[0].field + ':' + r.errors[0].code;
	}
	return false;
};
