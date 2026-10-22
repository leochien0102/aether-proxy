'use strict';

// T9.23: pure WAN dump selection, token grammar, expansion and fixture rendering (docs/03,05).
import * as config from 'aetherproxy.config';
import * as pipeline from 'aetherproxy.pipeline';
import * as chinadns from 'aetherproxy.render.chinadns';

function iface(name, dns, up, routes) {
	return { interface: name, up: up ?? true, 'dns-server': dns,
		route: routes ?? [ { target: '0.0.0.0', mask: 0 } ] };
}

const ISP = [ '202.96.128.86', '202.96.134.133' ];
export const cases = [
	{ name: 'wan default route contributes DNS; lan without default route does not', fn: 'dump',
		dump: { interface: [ iface('wan', ISP), iface('lan', [ '192.168.1.1' ], true, []) ] }, expect: ISP },
	{ name: 'interfaces sorted by name; per-interface order and global uniqueness preserved', fn: 'dump',
		dump: { interface: [ iface('wan_b', [ ISP[1], '114.114.114.114' ]),
			iface('wan_a', ISP), iface('down', [ '1.1.1.1' ], false) ] },
		expect: [ ...ISP, '114.114.114.114' ] },
	{ name: 'ignore IPv6 DNS and invalid IPv4 values', fn: 'dump',
		dump: { interface: [ iface('wan', [ '2001:db8::53', '256.1.1.1', '01.1.1.1', null, 1, ISP[0] ]) ] },
		expect: [ ISP[0] ] },
	{ name: 'no IPv4 DNS returns empty observation not fallback', fn: 'dump',
		dump: { interface: [ iface('wan', [ '2001:db8::53' ]) ] }, expect: [] },
	{ name: 'non-default IPv4 route and IPv6 default route ignored', fn: 'dump',
		dump: { interface: [ iface('wan', ISP, true, [ { target: '0.0.0.0', mask: 8 },
			{ target: '::', mask: 0 } ]) ] }, expect: [] },
	{ name: 'wan expands in place and deduplicates configured 114', fn: 'expand',
		entries: [ 'wan', '114.114.114.114', 'wan' ], wan: [ ...ISP, '114.114.114.114' ],
		expect: [ ...ISP, '114.114.114.114' ] },
	{ name: 'empty WAN falls back to 223.5.5.5 and deduplicates it', fn: 'expand',
		entries: [ 'wan', '223.5.5.5', '114.114.114.114' ], wan: [],
		expect: [ '223.5.5.5', '114.114.114.114' ] },
	{ name: 'default china_dns is wan plus 114', fn: 'defaults', expect: [ 'wan', '114.114.114.114' ] },
	{ name: 'explicit old defaults remain unchanged', fn: 'normalize',
		entries: [ '223.5.5.5', '114.114.114.114' ], expect: [ '223.5.5.5', '114.114.114.114' ] },
	{ name: 'wan and upstream grammar coexist', fn: 'normalize',
		entries: [ 'wan', 'tls://dns.example@1.1.1.1#853' ],
		expect: [ 'wan', 'tls://dns.example@1.1.1.1#853' ] },
	{ name: 'wan forbidden in direct_dns', fn: 'other', field: 'direct_dns', expect: false },
	{ name: 'wan forbidden in trust_dns', fn: 'other', field: 'trust_dns', expect: false }
];
for (let i, dump in [ null, [], 'invalid', {}, { interface: {} }, { interface: [ null, 1, {},
	iface('wan', {}, true), iface('wan2', ISP, true, [ null, 1, {} ]) ] } ])
	push(cases, { name: 'malformed dump safely returns no DNS: case ' + i,
		fn: 'dump', dump, expect: [] });
for (let entry in [ 'WAN', 'wan#53', 'udp://wan', 'wan.example', 'wan ', 'wan@1.1.1.1#0' ])
	push(cases, { name: 'reject invalid china_dns token ' + entry,
		fn: 'invalid', entries: [ entry ], expect: 'dns.china_dns:invalid_upstream' });
for (let tier in [ 'T1', 'T2', 'T3' ])
	push(cases, { name: tier + ' renderer expands context DNS without mutating input',
		fn: 'render', tier, expect: true });

export function run(c) {
	switch (c.fn) {
	case 'dump': return pipeline.wan_dns_from_dump(c.dump);
	case 'expand': return config.expand_china_dns(c.entries, c.wan);
	case 'defaults': return config.normalize({}).snapshot.dns.china_dns;
	case 'normalize': return config.normalize({ dns: { china_dns: c.entries } }).snapshot.dns.china_dns;
	case 'other':
		let dns = {};
		dns[c.field] = [ 'wan' ];
		return config.normalize({ dns }).ok;
	case 'invalid':
		let r = config.normalize({ dns: { china_dns: c.entries } });
		return r.ok ? 'unexpected success' : r.errors[0].field + ':' + r.errors[0].code;
	case 'render':
		let snapshot = config.normalize({}).snapshot;
		let ctx = { wan_dns: ISP, runtime: { dns_tier: c.tier } };
		let before = sprintf('%.J', { snapshot, ctx });
		let text = chinadns.render(snapshot, ctx);
		let china = join(',', [ ...ISP, '114.114.114.114' ]);
		return index(text, 'china-dns ' + china + '\n') >= 0 &&
			index(text, 'group udirect\ngroup-upstream ' + china + '\n') >= 0 &&
			(c.tier != 'T3' || index(text, 'trust-dns ' + china + '\n') >= 0) &&
			before == sprintf('%.J', { snapshot, ctx }) && text == chinadns.render(snapshot, ctx);
	}
	return false;
};
