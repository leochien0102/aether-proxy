'use strict';

// Table-driven tests for the pure part of config.uc: normalize(raw) -> [field:code, ...].

import { normalize } from 'aetherproxy.config';

const NODE = 'n_11111111111111111111111111111111';

function vless(extra) {
	let n = { protocol: 'vless', address: 'a.example.com', port: '443', uuid: 'u', security: 'tls' };

	for (let k, v in extra)
		n[k] = v;

	return { nodes: { [NODE]: n } };
}

export const cases = [
	{ name: 'empty config is valid', raw: {}, expect: [] },
	{ name: 'invalid bool', raw: { main: { quic_block: 'yes' } }, expect: [ 'main.quic_block:invalid_bool' ] },
	{ name: 'int out of range', raw: { main: { boot_wait_timeout: '601' } }, expect: [ 'main.boot_wait_timeout:out_of_range' ] },
	{ name: 'int not a number', raw: { probe: { timeout: '5s' } }, expect: [ 'probe.timeout:invalid_int' ] },
	{ name: 'CIDR with host bits', raw: { hosts: [ { ip: '192.168.1.5/24' } ] }, expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'IPv4 leading zero', raw: { hosts: [ { ip: '192.168.01.5' } ] }, expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'nested CIDRs allowed', raw: { hosts: [ { ip: '192.168.1.0/24' }, { ip: '192.168.1.10' } ] }, expect: [] },
	{ name: 'bad upstream', raw: { dns: { direct_dns: 'https://8.8.8.8' } }, expect: [ 'dns.direct_dns:invalid_upstream' ] },
	{ name: 'bad boot target', raw: { main: { boot_check_targets: '1.1.1.1' } }, expect: [ 'main.boot_check_targets:invalid_hostport' ] },
	{ name: 'bad node name', raw: { nodes: { n_x: { protocol: 'trojan', security: 'tls', address: 'a.b', port: '1', password: 'p' } } },
	  expect: [ 'node.n_x:invalid_name' ] },
	{ name: 'node port 0', raw: vless({ port: '0' }), expect: [ 'node.' + NODE + '.port:out_of_range' ] },
	{ name: 'numeric address must be IPv4', raw: vless({ address: '1.2.3' }), expect: [ 'node.' + NODE + '.address:invalid_address' ] },
	{ name: 'trojan needs password', raw: { nodes: { [NODE]: { protocol: 'trojan', security: 'tls', address: 'a.b', port: '1' } } },
	  expect: [ 'node.' + NODE + '.password:required' ] },
	{ name: 'reality needs sni and pbk', raw: vless({ security: 'reality' }),
	  expect: [ 'node.' + NODE + '.sni:required', 'node.' + NODE + '.reality_pbk:required' ] },
	{ name: 'stale node in use is allowed', raw: { main: { enabled: '1', node: NODE }, ...vless({ stale: '1' }) }, expect: [] }
];

export function run(c) {
	let r = normalize(c.raw);

	return map(r.errors ?? [], e => e.field + ':' + e.code);
};
