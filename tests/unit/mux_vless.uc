'use strict';

// docs/05 "config node": only VLESS renders flow, so only VLESS conflicts with Mux.
// Use plain objects: these regression tests need no UCI cursor or shared savedir.
import * as config from 'aetherproxy.config';
import * as outbound from 'aetherproxy.render.outbound';

const ID = 'n_11111111111111111111111111111111';
const VISION = [ 'xtls-rprx-vision', 'xtls-rprx-vision-udp443' ];
const BASE = { address: 'edge.example', port: '443', security: 'tls', mux: '1' };
const CREDENTIALS = {
	vless: { uuid: '11111111-1111-4111-8111-111111111111' },
	vmess: { uuid: '11111111-1111-4111-8111-111111111111' },
	trojan: { password: 'secret' },
	shadowsocks: { password: 'secret', method: 'aes-128-gcm' }
};

export const cases = [];

for (let flow in VISION) {
	push(cases, {
		name: 'vless ' + flow + ' with Mux still conflicts', protocol: 'vless', flow,
		expect: [ { field: 'mux', code: 'conflict', detail: 'Mux is incompatible with ' + flow } ]
	});
	for (let protocol in [ 'trojan', 'vmess', 'shadowsocks' ])
		push(cases, {
			name: protocol + ' retains ' + flow + ' with Mux but never renders flow',
			protocol, flow, render: true,
			expect: { valid_node: [], retained: flow, mux: { enabled: true }, no_flow: true, unchanged: true }
		});
}

// Removing the conflict must not skip schema checks or any later check_node rules.
const INVALID = [
	{ name: 'invalid flow enum', extra: { flow: 'arbitrary' },
		field: 'flow', code: 'invalid_enum',
		detail: '"arbitrary" is not one of xtls-rprx-vision|xtls-rprx-vision-udp443' },
	{ name: 'invalid Mux bool', extra: { mux: 'true' },
		field: 'mux', code: 'invalid_bool', detail: '"true" is not 0 or 1' },
	{ name: 'Mux concurrency out of range', extra: { mux_concurrency: '1025' },
		field: 'mux_concurrency', code: 'out_of_range', detail: '1025 is outside -1..1024' },
	{ name: 'invalid Mux UDP443 enum', extra: { mux_xudp_udp443: 'yes' },
		field: 'mux_xudp_udp443', code: 'invalid_enum', detail: '"yes" is not one of reject|allow|skip' },
	{ name: 'invalid REALITY key', extra: { reality_pbk: 'bad' },
		field: 'reality_pbk', code: 'invalid_reality_key',
		detail: 'must be a 32-byte key in unpadded base64url (43 characters)' },
	{ name: 'invalid REALITY short ID', extra: { reality_sid: 'a' },
		field: 'reality_sid', code: 'invalid_short_id', detail: 'must be hex with an even length of at most 16 characters' },
	{ name: 'invalid certificate hash', extra: { pinned_cert_sha256: 'bad' },
		field: 'pinned_cert_sha256', code: 'invalid_cert_hash', detail: '"bad" is not a SHA-256 hex digest' }
];
for (let protocol in [ 'trojan', 'vmess', 'shadowsocks' ])
	for (let c in INVALID)
		push(cases, { name: protocol + ' leftover flow still rejects ' + c.name,
			protocol, flow: VISION[0], extra: c.extra,
			expect: [ { field: c.field, code: c.code, detail: c.detail } ] });

push(cases, {
	name: 'shadowsocks leftover flow still rejects unsupported method', protocol: 'shadowsocks', flow: VISION[0],
	extra: { method: 'unsupported' },
	expect: [ { field: 'method', code: 'unsupported_method',
		detail: '"unsupported" is not a supported shadowsocks method' } ]
});
push(cases, {
	name: 'trojan leftover flow still rejects insecure public transport', protocol: 'trojan', flow: VISION[0],
	extra: { security: 'none' },
	expect: [ { field: 'security', code: 'insecure_transport',
		detail: 'trojan without TLS/REALITY is only allowed to a private IPv4 address' } ]
});
for (let protocol in [ 'trojan', 'vmess', 'shadowsocks' ]) {
	let field = protocol == 'vmess' ? 'uuid' : 'password';
	push(cases, {
		name: protocol + ' leftover flow still requires ' + field, protocol, flow: VISION[0],
		extra: { [field]: '' }, expect: [ { field, code: 'required', detail: field + ' is required' } ]
	});
}

export function run(c) {
	let raw = { ...BASE, ...CREDENTIALS[c.protocol], protocol: c.protocol, flow: c.flow, ...(c.extra ?? {}) };
	let result = config.normalize({ nodes: { [ID]: raw } });
	if (!c.render)
		return map(result.errors ?? [], e => ({
			field: replace(e.field, 'node.' + ID + '.', ''), code: e.code, detail: e.detail
		}));
	if (!result.ok)
		return result.errors;

	let node = result.snapshot.nodes[ID];
	let actual = outbound.build_outbound(node);
	let without_flow = { ...raw };
	delete without_flow.flow;
	let baseline = config.normalize({ nodes: { [ID]: without_flow } });
	return {
		valid_node: config.validate_node(raw),
		retained: node.flow,
		mux: actual.mux,
		no_flow: match(sprintf('%.J', actual), /"flow":/) == null,
		unchanged: baseline.ok
			&& sprintf('%.J', actual) == sprintf('%.J', outbound.build_outbound(baseline.snapshot.nodes[ID]))
	};
};
