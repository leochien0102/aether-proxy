'use strict';

// T11.8: schema, secret-free validation and exact Hysteria2 outbound mapping.
import { SCHEMA } from 'aetherproxy.schema';
import * as config from 'aetherproxy.config';
import * as outbound from 'aetherproxy.render.outbound';

const ID = 'n_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const BASE = { protocol: 'hysteria', address: '192.0.2.1', port: '443', hysteria_auth: 'credential-sentinel' };
export const cases = [
	{ name: 'Hysteria schema enum', kind: 'enum', expect: true },
	{ name: 'Hysteria schema fields', kind: 'fields', expect: true },
	{ name: 'Hysteria defaults', kind: 'defaults', expect: true },
	{ name: 'Hysteria valid required', expect: [] },
	{ name: 'Hysteria missing auth', patch: { hysteria_auth: '' }, expect: ['node.hysteria_auth:required'] },
	{ name: 'Hysteria list auth', patch: { hysteria_auth: ['credential-sentinel'] },
		expect: ['node.hysteria_auth:invalid_value'] },
	{ name: 'Hysteria object auth', patch: { hysteria_auth: { auth: 'credential-sentinel' } },
		expect: ['node.hysteria_auth:invalid_value'] },
	{ name: 'Hysteria numeric auth', patch: { hysteria_auth: 12345 },
		expect: ['node.hysteria_auth:invalid_value'] },
	{ name: 'Hysteria wrong transport', patch: { transport: 'ws' }, expect: ['node.transport:conflict'] },
	{ name: 'Hysteria wrong security', patch: { security: 'none' }, expect: ['node.security:conflict'] },
	{ name: 'Hysteria timeout low', patch: { hysteria_udp_idle_timeout: '1' },
		expect: ['node.hysteria_udp_idle_timeout:out_of_range'] },
	{ name: 'Hysteria timeout high', patch: { hysteria_udp_idle_timeout: '601' },
		expect: ['node.hysteria_udp_idle_timeout:out_of_range'] },
	{ name: 'Hysteria timeout fraction', patch: { hysteria_udp_idle_timeout: '2.5' },
		expect: ['node.hysteria_udp_idle_timeout:invalid_int'] },
	{ name: 'Hysteria timeout minimum', patch: { hysteria_udp_idle_timeout: '2' }, expect: [] },
	{ name: 'Hysteria timeout maximum', patch: { hysteria_udp_idle_timeout: '600' }, expect: [] },
	{ name: 'Hysteria exact minimal render and inactive Mux', kind: 'render', expect: true },
	{ name: 'Hysteria resolved address TLS mapping timeout', kind: 'render', full: true, expect: true },
	{ name: 'Hysteria origin domain SNI fallback', kind: 'render', domain: true, expect: true },
	{ name: 'Hysteria inactive fields preserved', kind: 'inactive', expect: true }
];

export function run(c) {
	if (c.kind == 'enum')
		return index(filter(SCHEMA.node, f => f.name == 'protocol')[0].enum, 'hysteria') >= 0;
	if (c.kind == 'fields')
		return length(filter(SCHEMA.node,
			f => index(['hysteria_auth', 'hysteria_udp_idle_timeout'], f.name) >= 0)) == 2;

	let n = { ...BASE, ...(c.patch ?? {}) };
	if (c.domain)
		n.address = 'hy.example';
	if (c.kind == 'inactive')
		n = { protocol: 'http', address: '192.0.2.1', port: '80',
			hysteria_auth: ['credential-sentinel'], hysteria_udp_idle_timeout: 'garbage' };
	let r = config.normalize({ nodes: { [ID]: n } });
	if (c.kind == 'inactive')
		return r.ok && r.snapshot.nodes[ID].hysteria_udp_idle_timeout == 'garbage'
			&& r.snapshot.nodes[ID].hysteria_auth[0] == 'credential-sentinel';
	if (c.kind == 'defaults')
		return r.ok && r.snapshot.nodes[ID].transport == 'hysteria' && r.snapshot.nodes[ID].security == 'tls';
	if (c.kind == 'render') {
		if (!r.ok)
			return false;
		n = r.snapshot.nodes[ID];
		// Retained generic settings must not enable Mux or unrelated transport output.
		n.mux = true;
		n.mux_concurrency = 8;
		n.path = '/old';
		n.service_name = 'old-service';
		let tls = c.domain ? { serverName: 'hy.example' } : {};
		let hs = { version: 2, auth: BASE.hysteria_auth };
		if (c.full) {
			n.sni = 'hy.example';
			n.alpn = ['h3'];
			n.fingerprint = 'chrome';
			n.verify_name = 'hy.example';
			n.pinned_cert_sha256 = 'aabb';
			n.ech_config_list = 'opaque';
			n.hysteria_udp_idle_timeout = 600;
			tls = { serverName: n.sni, alpn: n.alpn, fingerprint: n.fingerprint,
				pinnedPeerCertSha256: 'aabb', verifyPeerCertByName: n.verify_name, echConfigList: 'opaque' };
			hs.udpIdleTimeout = 600;
		}
		let ip = c.full || c.domain ? '203.0.113.9' : null;
		let expected = { tag: 'proxy', protocol: 'hysteria',
			settings: { version: 2, address: ip ?? BASE.address, port: 443 },
			streamSettings: { network: 'hysteria', security: 'tls', tlsSettings: tls, hysteriaSettings: hs } };
		return sprintf('%.J', outbound.build_outbound(n, ip)) == sprintf('%.J', expected);
	}
	let errors = config.validate_node(n);
	if (index(sprintf('%.J', errors), 'credential-sentinel') >= 0)
		return ['credential leaked'];
	return map(errors, e => e.field + ':' + e.code);
};
