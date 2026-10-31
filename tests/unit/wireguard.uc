'use strict';

// T11.3: manual WireGuard validation and exact Xray mapping, including inert old fields.
import { SCHEMA } from 'aetherproxy.schema';
import * as config from 'aetherproxy.config';
import * as outbound from 'aetherproxy.render.outbound';

function repeat(value, count) {
	let out = '';
	for (let i = 0; i < count; i++) out += value;
	return out;
}

const KEY = 'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=';
const BASE = { protocol: 'wireguard', address: 'wg.example', port: '51820',
	secret_key: KEY, peer_public_key: KEY, local_address: ['10.7.0.2/24', '10.8.0.2'] };
export const cases = [
	{ name: 'WireGuard protocol enum', kind: 'enum', expect: true },
	{ name: 'WireGuard schema fields', kind: 'fields', expect: true },
	{ name: 'WireGuard required valid', expect: [] },
	{ name: 'WireGuard optional valid', patch: { preshared_key: KEY, keepalive: '65535' }, expect: [] },
	{ name: 'WireGuard explicit zero valid', patch: { keepalive: '0' }, expect: [] },
	{ name: 'WireGuard missing secret', patch: { secret_key: '' }, expect: ['node.secret_key:required'] },
	{ name: 'WireGuard missing peer key', patch: { peer_public_key: '' }, expect: ['node.peer_public_key:required'] },
	{ name: 'WireGuard empty addresses', patch: { local_address: [] }, expect: ['node.local_address:required'] },
	{ name: 'WireGuard IPv6 rejected', patch: { local_address: ['::1/128'] }, expect: ['node.local_address:invalid_cidr'] },
	{ name: 'WireGuard bad prefix rejected', patch: { local_address: ['10.0.0.2/33'] }, expect: ['node.local_address:invalid_cidr'] },
	{ name: 'WireGuard negative keepalive', patch: { keepalive: '-1' }, expect: ['node.keepalive:out_of_range'] },
	{ name: 'WireGuard large keepalive', patch: { keepalive: '65536' }, expect: ['node.keepalive:out_of_range'] },
	{ name: 'WireGuard decimal keepalive', patch: { keepalive: '1.5' }, expect: ['node.keepalive:invalid_int'] },
	{ name: 'WireGuard original endpoint exact outbound', kind: 'render', expect: true },
	{ name: 'WireGuard resolved endpoint PSK zero exact outbound', kind: 'render', ip: '203.0.113.9',
		patch: { preshared_key: KEY, keepalive: '0' }, expect: true },
	{ name: 'WireGuard inactive fields kept without validation', kind: 'inactive', expect: true }
];
for (let field in ['secret_key', 'peer_public_key', 'preshared_key'])
	for (let value in ['credential-sentinel', repeat('A', 43), repeat('A', 44), repeat('A', 36) + 'AAA=',
		repeat('A', 43) + '=', repeat('/', 43) + '=', KEY + '\n', [KEY]])
		// 43 As + '=' is a valid zero key; exercise it separately below.
		if (value != repeat('A', 43) + '=')
			push(cases, { name: `WireGuard ${field} malformed ${length(cases)}`, patch: { [field]: value },
				expect: [`node.${field}:invalid_value`] });
push(cases, { name: 'WireGuard zero bytes Base64 valid', patch: { secret_key: repeat('A', 43) + '=' }, expect: [] });

export function run(c) {
	if (c.kind == 'enum')
		return index(filter(SCHEMA.node, f => f.name == 'protocol')[0].enum, 'wireguard') >= 0;
	if (c.kind == 'fields')
		return length(filter(SCHEMA.node, f => index(['secret_key', 'peer_public_key', 'local_address',
			'preshared_key', 'keepalive'], f.name) >= 0 && index(f.protocols ?? [], 'wireguard') >= 0)) == 5;
	let n = { ...BASE, ...(c.patch ?? {}) };
	if (c.kind == 'inactive') {
		n = { protocol: 'http', address: 'edge.example', port: '80', secret_key: 'credential-sentinel',
			local_address: ['garbage'], keepalive: 'garbage' };
		let r = config.normalize({ nodes: { n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: n } });
		return r.ok && r.snapshot.nodes.n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.secret_key == n.secret_key;
	}
	if (c.kind == 'render') {
		n.port = 51820;
		// Legacy stream/mux fields must not affect WireGuard or cause Xray preflight failure.
		n.transport = 'ws'; n.security = 'tls'; n.mux = true;
		let peer = { publicKey: KEY, endpoint: (c.ip ?? n.address) + ':51820', allowedIPs: ['0.0.0.0/0'] };
		if (c.patch) { peer.preSharedKey = KEY; peer.keepAlive = 0; }
		let expected = { tag: 'proxy', protocol: 'wireguard', settings: {
			secretKey: KEY, address: BASE.local_address, peers: [peer] } };
		if (c.patch) n.keepalive = 0;
		return sprintf('%.J', outbound.build_outbound(n, c.ip)) == sprintf('%.J', expected);
	}
	let errors = config.validate_node(n);
	if (index(sprintf('%.J', errors), 'credential-sentinel') >= 0 || index(sprintf('%.J', errors), KEY) >= 0)
		return ['credential leaked'];
	return map(errors, e => e.field + ':' + e.code);
};
