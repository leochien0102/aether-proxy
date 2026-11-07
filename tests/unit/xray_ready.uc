'use strict';
// T15.5 pure contracts use the actual renderers, not a duplicate tier selector.
import * as ready from 'aetherproxy.xray_ready';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as xray from 'aetherproxy.render.xray';
import * as net from 'aetherproxy.net';
import * as C from 'aetherproxy.const';

export const cases = [
	{ name: 'W1 renderer references single TCP UDP and mixed tuples without unused ports',
		kind: 'references', expect: 'PASS' },
	{ name: 'W2 T2 T3 only require TPROXY and broken artifacts fail closed', kind: 'tiers', expect: 'PASS' },
	{ name: 'W4 pure tcp6 udp6 states addresses and malformed rows', kind: 'tables', expect: 'PASS' },
	{ name: 'A3 explicit endian IPv4 IPv6 LE BE and invalid parameter rejection', kind: 'endian', expect: 'PASS' }
];

function snapshot(trust) {
	return { main: {}, dns: { trust_dns: trust, china_dns: [ '192.0.2.1' ],
		direct_dns: [ 'tcp://192.0.2.2' ], direct_dns_enabled: true } };
};

export function run(c) {
	if (c.kind == 'references') {
		for (let trust in [ [ 'tcp://8.8.8.8' ], [ 'udp://8.8.8.8' ],
			[ 'udp://8.8.8.8', 'tcp://1.1.1.1' ], [ 'tcp://8.8.8.8', 'udp://1.1.1.1' ] ]) {
			let s = snapshot(trust), ctx = { runtime: { dns_tier: 'T1' } };
			let dns = chinadns.render(s, ctx);
			let xr = xray.render(s, ctx);
			let result = ready.requirements('# comment\n' + dns + dns, xr);
			if (!result.ok || length(result.required) != length(trust) + 1)
				return 'reference count/duplicate mismatch';
			for (let i = 0; i < length(trust); i++)
				if (result.required[i + 1].port != C.DNS_TUNNEL_PORTS[i] ||
				    result.required[i + 1].protocol != substr(trust[i], 0, 3))
					return 'protocol/port mismatch';
		}
		let s = snapshot([ 'tcp://8.8.8.8' ]);
		let xr = xray.build(s, {});
		xr.inbounds[1].port = 40123;
		let result = ready.requirements('group first\ngroup-upstream tcp://127.0.0.1#40123\n' +
			'group second\ngroup-upstream udp://127.0.0.1#40123 # repeated port, different protocol\n', sprintf('%.J', xr));
		return result.ok && length(result.required) == 3 ? 'PASS' : 'dynamic/group reference mismatch';
	}
	if (c.kind == 'tiers') {
		let s = snapshot([ 'tcp://8.8.8.8' ]);
		let xr = xray.render(s, {});
		for (let tier in [ 'T2', 'T3' ]) {
			let result = ready.requirements(chinadns.render(s, { runtime: { dns_tier: tier } }), xr);
			if (!result.ok || length(result.required) != 1)
				return 'unreferenced DNS tunnel required';
		}
		for (let bad in [ 'null', 'false', '1', '[]', '{', '{}', '{"inbounds":[null]}' ])
			if (ready.requirements('', bad).ok)
				return 'bad artifact accepted';
		for (let bad_dns in [ '', 'garbage\n', 'trust-dns\n', 'group-upstream nonsense\n' ])
			if (ready.requirements(bad_dns, xr).ok)
				return 'bad DNS artifact accepted';
		if (ready.requirements('trust-dns tcp://127.0.0.1#31082\n', '{"inbounds":[{"tag":1}]}').ok)
			return 'bad inbound tag accepted';
		let built = xray.build(s, {});
		let remote = ready.requirements('trust-dns udp://192.0.2.1#31082\n' +
			'group boot\ngroup-upstream tcp://127.0.0.1#44000\n', xr);
		if (!remote.ok || length(remote.required) != 1)
			return 'ordinary remote/private endpoint wrongly managed';
		built.inbounds = slice(built.inbounds, 1);
		if (ready.requirements('', sprintf('%.J', built)).ok)
			return 'missing TPROXY definition accepted';
		built = xray.build(s, {});
		built.inbounds[1].listen = '127.0.0.2';
		if (ready.requirements('group arbitrary\ngroup-upstream tcp://127.0.0.1#31082\n', sprintf('%.J', built)).ok)
			return 'DNS address mismatch accepted';
		built = xray.build(s, {});
		built.inbounds[1].settings.network = 'udp';
		if (ready.requirements('trust-dns tcp://127.0.0.1#31082\n', sprintf('%.J', built)).ok)
			return 'protocol conflict accepted';
		built.inbounds = [ built.inbounds[0] ];
		return !ready.requirements('trust-dns tcp://127.0.0.1#31082\n', sprintf('%.J', built)).ok
			? 'PASS' : 'missing DNS tunnel accepted';
	}
	if (c.kind == 'endian') {
		for (let little in [ true, false ])
			for (let ipv6 in [ false, true ]) {
				let address = ipv6
					? (little ? '00000000000000000000000001000000' : '00000000000000000000000000000001')
					: (little ? '0100007F' : '7F000001');
				let remote = ipv6
					? (little ? 'B80D01207856341201EFCDAB89674523' : '20010DB812345678ABCDEF0123456789')
					: (little ? '076433C6' : 'C6336407');
				let text = `0: ${address}:7968 ${remote}:9C41 0A 00000000:00000000 00:00000000 00000000 0 0 123\n`;
				let result = net.socket_rows(text, ipv6, little);
				if (!result.ok || result.rows[0].address != net.address_hex(ipv6 ? '::1' : '127.0.0.1'))
					return 'explicit byte order mismatch';
				let peer = net.address_hex(ipv6 ? '2001:db8:1234:5678:abcd:ef01:2345:6789' : '198.51.100.7');
				if (result.rows[0].remote_address != peer || result.rows[0].remote_port != 40001)
					return 'remote tuple byte order mismatch';
			}
		for (let bad in [ null, 0, 1, 'true', 'false', [], {} ])
			if (net.socket_rows('', false, bad).ok)
				return 'invalid byte order accepted';
		return !net.socket_rows('', false).ok ? 'PASS' : 'missing byte order accepted';
	}
	let row = ' 0: 00000000000000000000000001000000:9C40 00000000000000000000000000000000:0000 ';
	for (let state in [ '0A', '07', '01', '02' ]) {
		let parsed = net.socket_rows(row + state + ' 00000000:00000000 00:00000000 00000000 0 0 123\n', true, true);
		if (!parsed.ok || parsed.rows[0].address != net.address_hex('::1') || parsed.rows[0].state != state)
			return 'IPv6 state/address parse mismatch';
	}
	for (let bad in [ null, 'broken\n', row + '0A\n', replace(row, '9C40', 'ZZZZ') +
		'0A 0 0 0 0 0 123\n' ])
		if (net.socket_rows(bad, true, true).ok)
			return 'bad table accepted';
	return net.address_hex('::1') != net.address_hex('127.0.0.1') && net.address_hex('::0::1') == null
		? 'PASS' : 'address families conflated';
};
