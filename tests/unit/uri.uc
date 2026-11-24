'use strict';

import * as uri from 'aetherproxy.uri';

const UUID = '11111111-2222-4333-8444-555555555555';
const REALITY_KEY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const VMESS_JSON = {
	ps: 'v2rayN', add: 'vm.example.com', port: '443', id: UUID, aid: 0,
	scy: 'auto', net: 'tcp', type: 'none', host: '', path: '', tls: 'tls',
	sni: 'vm.example.com', fp: 'chrome', alpn: 'h2'
};
const VMESS_URI = 'vmess://' + b64enc(sprintf('%.J', VMESS_JSON));
const BODY_URI = `vless://${UUID}@body.example:443?security=tls#body`;
const BODY_TEXT = BODY_URI + '\n';
const BODY_B64 = b64enc(BODY_TEXT);
const BODY_URLSAFE_TEXT = `vless://${UUID}@body.example:443?security=tls#🌟\n`;
const BODY_B64URL = replace(replace(replace(b64enc(BODY_URLSAFE_TEXT), /\+/g, '-'), /\//g, '_'), /=+$/, '');
const SS_USER = b64enc('aes-128-gcm:pw');
const SS_OLD = b64enc('aes-128-gcm:oldpw@old-ss.example:8388');

export const cases = [
	{
		name: 'grpc multi and ECH sharing fields', fn: 'line',
		input: `vless://${UUID}@grpc.example:443?type=grpc&security=tls&mode=multi&ech=ECH%2Bconfig%3D`,
		expect: { node: {
			protocol: 'vless', address: 'grpc.example', port: 443, uuid: UUID,
			transport: 'grpc', security: 'tls', encryption: 'none',
			grpc_multi_mode: '1', ech_config_list: 'ECH+config='
		} }
	},
	{
		name: 'grpc gun is explicit false', fn: 'line',
		input: 'trojan://secret@grpc.example:443?type=grpc&mode=gun',
		expect: { node: {
			protocol: 'trojan', address: 'grpc.example', port: 443, password: 'secret',
			transport: 'grpc', security: 'tls', grpc_multi_mode: '0'
		} }
	},
	{
		name: 'grpc unknown mode skipped with reason', fn: 'line',
		input: 'trojan://secret@grpc.example:443?type=grpc&mode=unknown',
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'xhttp extra and REALITY pqv sharing fields', fn: 'line',
		input: `vless://${UUID}@xh.example:443?type=xhttp&security=reality&sni=xh.example&pbk=${REALITY_KEY}`
			+ '&mode=auto&extra=%7B%22headers%22%3A%7B%22X-Test%22%3A%22a%26b%22%7D%7D&pqv=PQV%2Bkey%3D',
		expect: { node: {
			protocol: 'vless', address: 'xh.example', port: 443, uuid: UUID, encryption: 'none',
			transport: 'xhttp', security: 'reality', sni: 'xh.example', reality_pbk: REALITY_KEY,
			xhttp_mode: 'auto', xhttp_extra: '{"headers":{"X-Test":"a&b"}}', reality_pqv: 'PQV+key='
		} }
	},
	{
		name: 'xhttp extra invalid JSON skipped with reason', fn: 'line',
		input: `vless://${UUID}@xh.example:443?type=xhttp&security=tls&extra=not-json`,
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'xhttp extra array skipped with reason', fn: 'line',
		input: `vless://${UUID}@xh.example:443?type=xhttp&security=tls&extra=%5B%5D`,
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'xhttp extra null skipped with reason', fn: 'line',
		input: `vless://${UUID}@xh.example:443?type=xhttp&security=tls&extra=null`,
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'xhttp extra invalid URL escape skipped', fn: 'line',
		input: `vless://${UUID}@xh.example:443?type=xhttp&security=tls&extra=%ZZ`,
		expect: { skip: 'malformed' }
	},
	{
		name: 'vless reality vision', fn: 'line',
		input: `vless://${UUID}@203.0.113.10:443?type=tcp&security=reality&flow=xtls-rprx-vision&sni=www.example.com&pbk=${REALITY_KEY}&sid=abcd&spx=%2F#vision`,
		expect: { node: {
			protocol: 'vless', address: '203.0.113.10', port: 443, uuid: UUID, label: 'vision',
			transport: 'raw', security: 'reality', encryption: 'none', flow: 'xtls-rprx-vision',
			sni: 'www.example.com', reality_pbk: REALITY_KEY, reality_sid: 'abcd', reality_spx: '/'
		} }
	},
	{
		name: 'vless Vision UDP443 sharing preserves flow', fn: 'line',
		input: `vless://${UUID}@edge.example:443?security=tls&flow=xtls-rprx-vision-udp443`,
		expect: { node: {
			protocol: 'vless', address: 'edge.example', port: 443, uuid: UUID,
			transport: 'raw', security: 'tls', encryption: 'none', flow: 'xtls-rprx-vision-udp443'
		} }
	},
	{
		name: 'legacy flow skips as invalid_value', fn: 'line',
		input: `vless://${UUID}@edge.example:443?security=tls&flow=xtls-rprx-direct`,
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'unknown flow skips as invalid_value', fn: 'line',
		input: `vless://${UUID}@edge.example:443?security=tls&flow=unknown`,
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'vless ws tls', fn: 'line',
		input: `vless://${UUID}@ws.example.com:443?type=ws&security=tls&host=cdn.example.com&path=%2Fws#ws`,
		expect: { node: {
			protocol: 'vless', address: 'ws.example.com', port: 443, uuid: UUID, label: 'ws',
			transport: 'ws', security: 'tls', encryption: 'none', host: 'cdn.example.com', path: '/ws'
		} }
	},
	{
		name: 'vmess v2rayN JSON', fn: 'line', input: VMESS_URI,
		expect: { node: {
			protocol: 'vmess', address: 'vm.example.com', port: 443, uuid: UUID, label: 'v2rayN',
			method: 'auto', transport: 'raw', security: 'tls', header_type: 'none',
			sni: 'vm.example.com', fingerprint: 'chrome', alpn: [ 'h2' ]
		} }
	},
	{
		name: 'trojan grpc', fn: 'line',
		input: 'trojan://secret@tj.example:443?type=grpc&serviceName=dns&sni=tj.example#grpc',
		expect: { node: {
			protocol: 'trojan', address: 'tj.example', port: 443, password: 'secret', label: 'grpc',
			transport: 'grpc', security: 'tls', service_name: 'dns', sni: 'tj.example'
		} }
	},
	{
		name: 'shadowsocks SIP002 base64 userinfo', fn: 'line',
		input: `ss://${SS_USER}@ss.example:8388#sip002`,
		expect: { node: {
			protocol: 'shadowsocks', address: 'ss.example', port: 8388, method: 'aes-128-gcm',
			password: 'pw', label: 'sip002', transport: 'raw', security: 'none'
		} }
	},
	{
		name: 'shadowsocks 2022 URL-encoded userinfo', fn: 'line',
		input: 'ss://2022-blake3-aes-128-gcm%3AYWFhYWFhYWFhYWFhYWFhYQ==%3AYWFhYWFhYWFhYWFhYWFhYQ==@ss2022.example:443#ss2022',
		expect: { node: {
			protocol: 'shadowsocks', address: 'ss2022.example', port: 443,
			method: '2022-blake3-aes-128-gcm', password: 'YWFhYWFhYWFhYWFhYWFhYQ==:YWFhYWFhYWFhYWFhYWFhYQ==',
			label: 'ss2022',
			transport: 'raw', security: 'none'
		} }
	},
	{
		name: 'shadowsocks old format', fn: 'line',
		input: `ss://${SS_OLD}#old`,
		expect: { node: {
			protocol: 'shadowsocks', address: 'old-ss.example', port: 8388,
			method: 'aes-128-gcm', password: 'oldpw', label: 'old', transport: 'raw', security: 'none'
		} }
	},
	{
		name: 'unsupported scheme', fn: 'line', input: 'tuic://token@h.example:443',
		expect: { skip: 'unsupported_scheme' }
	},
	{
		name: 'unsupported transport', fn: 'line',
		input: `vless://${UUID}@host.example:443?type=kcp`,
		expect: { skip: 'unsupported_transport' }
	},
	{
		name: 'unsupported security', fn: 'line',
		input: `vless://${UUID}@host.example:443?security=xtls`,
		expect: { skip: 'unsupported_security' }
	},
	{
		name: 'shadowsocks plugin', fn: 'line',
		input: `ss://${SS_USER}@ss.example:8388?plugin=obfs-local`,
		expect: { skip: 'ss_plugin' }
	},
	{
		/* A valid Base64 payload that is not JSON must not escape as an exception:
		 * every subscription line yields one node or one skip reason (docs/06). */
		name: 'vmess payload that is not JSON', fn: 'line', input: 'vmess://bm90IGpzb24=',
		expect: { skip: 'malformed' }
	},
	{
		name: 'vmess payload with invalid JSON syntax', fn: 'line',
		input: 'vmess://' + b64enc('{"add": "vm.example.com", '),
		expect: { skip: 'malformed' }
	},
	{
		name: 'vmess payload that is a JSON array', fn: 'line',
		input: 'vmess://' + b64enc('[1,2,3]'),
		expect: { skip: 'malformed' }
	},
	{
		name: 'vmess payload that is empty', fn: 'line', input: 'vmess://' + b64enc(''),
		expect: { skip: 'malformed' }
	},
	{
		name: 'vmess payload that is a JSON string', fn: 'line',
		input: 'vmess://' + b64enc('"not an object"'),
		expect: { skip: 'malformed' }
	},
	{
		name: 'vmess alterId', fn: 'line',
		input: 'vmess://' + b64enc(sprintf('%.J', { add: 'vm.example.com', port: '443', id: UUID, aid: 1 })),
		expect: { skip: 'vmess_alterid' }
	},
	{
		name: 'IPv6 literal', fn: 'line',
		input: `vless://${UUID}@[2001:db8::1]:443`,
		expect: { skip: 'ipv6_address' }
	},
	{
		name: 'malformed URI', fn: 'line', input: 'vless://not-an-authority',
		expect: { skip: 'malformed' }
	},
	{
		name: 'missing required UUID', fn: 'line', input: 'vless://@host.example:443',
		expect: { skip: 'missing_field' }
	},
	{
		name: 'insecure public transport', fn: 'line',
		input: 'trojan://secret@203.0.113.9:443?security=none',
		expect: { skip: 'insecure_transport' }
	},
	{
		name: 'invalid Xray value', fn: 'line',
		input: `vless://${UUID}@host.example:443?security=reality&sni=host.example&pbk=bad`,
		expect: { skip: 'invalid_value' }
	},
	{
		name: 'allowInsecure is ignored and warned', fn: 'line',
		input: 'trojan://secret@tj.example:443?allowInsecure=true#warning',
		expect: { node: {
			protocol: 'trojan', address: 'tj.example', port: 443, password: 'secret', label: 'warning',
			transport: 'raw', security: 'tls'
		}, warnings: [ { code: 'NODE_INSECURE_IGNORED', args: { label: 'warning' } } ] }
	},
	{
		name: 'URL-decode Chinese and emoji label', fn: 'line',
		input: `vless://${UUID}@host.example:443?security=tls#%E4%B8%AD%E6%96%87%F0%9F%8C%9F`,
		expect: { node: {
			protocol: 'vless', address: 'host.example', port: 443, uuid: UUID,
			label: '中文🌟', transport: 'raw', security: 'tls', encryption: 'none'
		} }
	},
	{
		name: 'plain body and skip counts', fn: 'body',
		input: BODY_URI + '\nnot-a-uri://x\n',
		expect: { ok: true, nodes: [ {
			protocol: 'vless', address: 'body.example', port: 443, uuid: UUID,
			label: 'body', transport: 'raw', security: 'tls', encryption: 'none'
		} ], skipped: { unsupported_scheme: 1 }, warnings: [], error: null }
	},
	{
		name: 'standard Base64 body', fn: 'body', input: BODY_B64,
		expect: { ok: true, nodes: [ {
			protocol: 'vless', address: 'body.example', port: 443, uuid: UUID,
			label: 'body', transport: 'raw', security: 'tls', encryption: 'none'
		} ], skipped: {}, warnings: [], error: null }
	},
	{
		name: 'URL-safe unpadded Base64 body', fn: 'body', input: BODY_B64URL,
		expect: { ok: true, nodes: [ {
			protocol: 'vless', address: 'body.example', port: 443, uuid: UUID,
			label: '🌟', transport: 'raw', security: 'tls', encryption: 'none'
		} ], skipped: {}, warnings: [], error: null }
	},
	{
		name: 'Clash YAML rejected', fn: 'body', input: 'proxies:\n  - name: test\n',
		expect: { ok: false, nodes: [], skipped: {}, warnings: [], error: 'SUB_FORMAT_UNSUPPORTED' }
	},
	{
		name: 'invalid Base64 body fails decoding', fn: 'body', input: '%%%not-base64%%%',
		expect: { ok: false, nodes: [], skipped: {}, warnings: [], error: 'SUB_DECODE_FAILED' }
	},
	{
		name: 'decoded body with no valid nodes has a distinct error', fn: 'body',
		input: 'tuic://token@h.example:443\n',
		expect: { ok: false, nodes: [], skipped: { unsupported_scheme: 1 }, warnings: [], error: 'SUB_NO_VALID_NODES' }
	},
	{
		/* One bad line must not abort the rest of the body (docs/06 step 3). */
		name: 'body keeps parsing after a non-JSON vmess line', fn: 'body',
		input: 'vmess://bm90IGpzb24=\n' + BODY_URI,
		expect: { ok: true, nodes: [
			{ protocol: 'vless', address: 'body.example', port: 443, uuid: UUID, label: 'body', transport: 'raw', security: 'tls', encryption: 'none' }
		], skipped: { malformed: 1 }, warnings: [], error: null }
	},
	{
		name: 'parse_body keeps duplicates (sub.plan deduplicates)', fn: 'body',
		input: BODY_URI + '\n' + BODY_URI,
		expect: { ok: true, nodes: [
			{ protocol: 'vless', address: 'body.example', port: 443, uuid: UUID, label: 'body', transport: 'raw', security: 'tls', encryption: 'none' },
			{ protocol: 'vless', address: 'body.example', port: 443, uuid: UUID, label: 'body', transport: 'raw', security: 'tls', encryption: 'none' }
		], skipped: {}, warnings: [], error: null }
	}
];

// T11.11: keep the legacy cases above unchanged apart from the unsupported scheme.
const WG_KEY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
for (let scheme in [ 'socks', 'socks5', 'http' ]) {
	let protocol = scheme == 'http' ? 'http' : 'socks';
	let base = { protocol, address: 'proxy.example', port: 1080, transport: 'raw', security: 'none' };
	push(cases, { name: scheme + ' no auth', fn: 'line', input: scheme + '://proxy.example:1080', expect: { node: base } });
	for (let userinfo in [ 'UsEr%3Ap%40ss%3Aword', b64enc('UsEr:p@ss:word'), 'VXNFcjpwQHNzOndvcmQ%3D' ])
		push(cases, { name: scheme + ' userinfo ' + userinfo, fn: 'line',
			input: scheme + '://' + userinfo + '@proxy.example:1080#name',
			expect: { node: { ...base, username: 'UsEr', password: 'p@ss:word', label: 'name' } } });
	for (let pair in [ [ 'user:', 'missing_field' ], [ ':pass', 'missing_field' ],
		[ '@@@', 'malformed' ], [ 'a', 'malformed' ], [ '%ZZ', 'malformed' ] ])
		push(cases, { name: scheme + ' bad auth ' + pair[0], fn: 'line',
			input: scheme + '://' + pair[0] + '@proxy.example:1080', expect: { skip: pair[1] } });
}
for (let scheme in [ 'hy2', 'hysteria2' ]) {
	let node = { protocol: 'hysteria', address: 'h.example', port: 443,
		hysteria_auth: 'Auth:p@ss+', transport: 'hysteria', security: 'tls', sni: 'sni.example', label: 'hy name' };
	push(cases, { name: scheme + ' auth SNI unknown query', fn: 'line',
		input: scheme + '://Auth%3Ap%40ss%2B@h.example:443/?sni=sni.example&obfs=ignored#hy%20name', expect: { node } });
	for (let query in [ 'insecure=1', 'allowInsecure=true', 'allowInsecure=0&insecure=1' ])
		push(cases, { name: scheme + ' warning ' + query, fn: 'line',
			input: scheme + '://Auth%3Ap%40ss%2B@h.example:443/?sni=sni.example&' + query + '#hy%20name',
			expect: { node, warnings: [ { code: 'NODE_INSECURE_IGNORED', args: { label: 'hy name' } } ] } });
	for (let auth in [ '', '@' ])
		push(cases, { name: scheme + ' required auth ' + auth, fn: 'line',
			input: scheme + '://' + auth + 'h.example:443', expect: { skip: 'missing_field' } });
}
const WG_NODE = { protocol: 'wireguard', address: 'wg.example', port: 51820, transport: 'raw', security: 'none',
	secret_key: WG_KEY, peer_public_key: WG_KEY, local_address: [ '10.0.0.2/32', '10.0.0.3/32' ] };
const WG_URI = 'wireguard://' + replace(WG_KEY, /=/g, '%3D') + '@wg.example:51820/?publickey='
	+ replace(WG_KEY, /=/g, '%3D') + '&address=10.0.0.2%2F32%2C10.0.0.3%2F32';
push(cases, { name: 'wireguard v2rayN required values', fn: 'line', input: WG_URI, expect: { node: WG_NODE } });
push(cases, { name: 'wireguard PSK zero keepalive ignores reserved', fn: 'line',
	input: WG_URI + '&presharedkey=' + WG_KEY + '&keepalive=%30&reserved=1%2C2%2C3#WG',
	expect: { node: { ...WG_NODE, preshared_key: WG_KEY, keepalive: 0, label: 'WG' } } });
for (let pair in [ [ '', 'missing_field' ], [ '?publickey=' + WG_KEY, 'missing_field' ],
	[ '?address=10.0.0.2', 'missing_field' ], [ '?publickey=bad&address=10.0.0.2', 'invalid_value' ],
	[ '?publickey=' + WG_KEY + '&address=bad', 'malformed' ] ])
	push(cases, { name: 'wireguard required/invalid ' + pair[0], fn: 'line',
		input: 'wireguard://' + WG_KEY + '@wg.example:51820/' + pair[0], expect: { skip: pair[1] } });
for (let key in [ 'bad', replace(WG_KEY, /=/g, ''), WG_KEY + '=', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=' ])
	push(cases, { name: 'wireguard invalid private key ' + key, fn: 'line',
		input: 'wireguard://' + key + '@wg.example:51820/?publickey=' + WG_KEY + '&address=10.0.0.2',
		expect: { skip: 'invalid_value' } });
for (let endpoint in [ 'wg.example:51820', '@wg.example:51820' ])
	push(cases, { name: 'wireguard missing private key ' + endpoint, fn: 'line',
		input: 'wireguard://' + endpoint + '/?publickey=' + WG_KEY + '&address=10.0.0.2',
		expect: { skip: 'missing_field' } });
for (let pair in [ [ '&presharedkey=bad', 'invalid_value' ], [ '&keepalive=65536', 'malformed' ],
	[ '&keepalive=oops', 'malformed' ] ])
	push(cases, { name: 'wireguard invalid optional ' + pair[0], fn: 'line', input: WG_URI + pair[0], expect: { skip: pair[1] } });
for (let scheme in [ 'socks', 'socks5', 'http', 'hy2', 'hysteria2', 'wireguard' ]) {
	let auth = scheme == 'wireguard' ? WG_KEY + '@' : (scheme == 'hy2' || scheme == 'hysteria2' ? 'auth@' : '');
	for (let pair in [ [ '[2001:db8::1]:443', 'ipv6_address' ], [ 'host:0', 'malformed' ],
		[ 'host:65536', 'malformed' ], [ 'host:abc', 'malformed' ], [ 'host', 'malformed' ] ])
		push(cases, { name: scheme + ' endpoint ' + pair[0], fn: 'line',
			input: scheme + '://' + auth + pair[0], expect: { skip: pair[1] } });
}
let mixed_nodes = [
	{ protocol: 'socks', address: 's.example', port: 1080, transport: 'raw', security: 'none' },
	{ protocol: 'http', address: 'p.example', port: 8080, transport: 'raw', security: 'none' },
	{ protocol: 'hysteria', address: 'h.example', port: 443, hysteria_auth: 'auth', transport: 'hysteria', security: 'tls' },
	WG_NODE
];
let mixed = 'socks5://s.example:1080\nhttp://p.example:8080\nhy2://auth@h.example:443\n' + WG_URI + '\nhy2://@bad:443';
for (let input in [ mixed, b64enc(mixed) ])
	push(cases, { name: 'new protocols mixed subscription ' + (input == mixed ? 'plain' : 'base64'), fn: 'body', input,
		expect: { ok: true, nodes: mixed_nodes, skipped: { missing_field: 1 }, warnings: [], error: null } });

// T16.64: equivalent standard share links (type=raw/tcp and optional single empty path /).
const T1664_VLESS_NODE = {
	protocol: 'vless', address: '203.0.113.20', port: 443, uuid: UUID, label: 'vless 标签',
	transport: 'raw', security: 'reality', encryption: 'none', flow: 'xtls-rprx-vision',
	sni: 'edge.example.com', reality_pbk: REALITY_KEY, reality_sid: 'abcd', reality_spx: '/edge/path'
};
for (let variant in [
	[ 'type=tcp no slash', '' , 'tcp' ],
	[ 'type=tcp trailing slash', '/', 'tcp' ],
	[ 'type=raw no slash', '', 'raw' ],
	[ 'type=raw trailing slash', '/', 'raw' ]
])
	push(cases, {
		name: 'T16.64 vless equivalent ' + variant[0], fn: 'line',
		input: `vless://${UUID}@203.0.113.20:443${variant[1]}?type=${variant[2]}&security=reality&flow=xtls-rprx-vision`
			+ `&sni=edge.example.com&pbk=${REALITY_KEY}&sid=abcd&spx=%2Fedge%2Fpath#vless%20%E6%A0%87%E7%AD%BE`,
		expect: { node: T1664_VLESS_NODE }
	});

const T1664_VLESS_WS_NODE = {
	protocol: 'vless', address: 'ws.example.com', port: 443, uuid: UUID, label: 'ws tag',
	transport: 'ws', security: 'tls', encryption: 'none', host: 'cdn.example.com', path: '/ws/v1'
};
for (let slash in [ '', '/' ])
	push(cases, {
		name: 'T16.64 vless ws encoded query path ' + (slash == '' ? 'no slash' : 'trailing slash'), fn: 'line',
		input: `vless://${UUID}@ws.example.com:443${slash}?type=ws&security=tls&host=cdn.example.com&path=%2Fws%2Fv1#ws%20tag`,
		expect: { node: T1664_VLESS_WS_NODE }
	});

const T1664_TROJAN_NODE = {
	protocol: 'trojan', address: 'tj.example.com', port: 443, password: 'secret-pass', label: 'trojan 标签',
	transport: 'raw', security: 'tls', sni: 'tj.example.com', alpn: [ 'h2', 'http/1.1' ]
};
for (let variant in [
	[ 'type=tcp no slash', '', 'tcp' ],
	[ 'type=tcp trailing slash', '/', 'tcp' ],
	[ 'type=raw no slash', '', 'raw' ],
	[ 'type=raw trailing slash', '/', 'raw' ]
])
	push(cases, {
		name: 'T16.64 trojan equivalent ' + variant[0], fn: 'line',
		input: `trojan://secret-pass@tj.example.com:443${variant[1]}?type=${variant[2]}&security=tls`
			+ '&sni=tj.example.com&alpn=h2,http%2F1.1#trojan%20%E6%A0%87%E7%AD%BE',
		expect: { node: T1664_TROJAN_NODE }
	});
push(cases, {
	name: 'T16.64 trojan bare trailing slash preserves fragment', fn: 'line',
	input: 'trojan://secret-pass@tj.example.com:443/#bare%20tag',
	expect: { node: {
		protocol: 'trojan', address: 'tj.example.com', port: 443, password: 'secret-pass',
		label: 'bare tag', transport: 'raw', security: 'tls'
	} }
});

// Shared transport() caller scope: VMess net=raw normalizes to transport=raw like net=tcp.
const VMESS_RAW_URI = 'vmess://' + b64enc(sprintf('%.J', { ...VMESS_JSON, net: 'raw' }));
push(cases, {
	name: 'T16.64 vmess net=raw normalizes to transport=raw', fn: 'line', input: VMESS_RAW_URI,
	expect: { node: {
		protocol: 'vmess', address: 'vm.example.com', port: 443, uuid: UUID, label: 'v2rayN',
		method: 'auto', transport: 'raw', security: 'tls', header_type: 'none',
		sni: 'vm.example.com', fingerprint: 'chrome', alpn: [ 'h2' ]
	} }
});

// Negative and boundary cases: reject unknown transport, non-empty path, double slash, invalid ports.
for (let pair in [
	[ 'vless unknown transport quic', `vless://${UUID}@203.0.113.20:443/?type=quic&security=tls#bad`, 'unsupported_transport' ],
	[ 'vless unknown transport uppercase RAW', `vless://${UUID}@203.0.113.20:443/?type=RAW&security=tls#bad`, 'unsupported_transport' ],
	[ 'trojan unknown transport kcp', 'trojan://secret-pass@tj.example.com:443/?type=kcp#bad', 'unsupported_transport' ],
	[ 'vless non-empty path with query', `vless://${UUID}@203.0.113.20:443/extra?type=raw&security=tls#bad`, 'malformed' ],
	[ 'vless non-empty path with trailing slash', `vless://${UUID}@203.0.113.20:443/extra/?type=raw&security=tls#bad`, 'malformed' ],
	[ 'trojan non-empty path with query', 'trojan://secret-pass@tj.example.com:443/extra?type=tcp#bad', 'malformed' ],
	[ 'trojan non-empty path without query', 'trojan://secret-pass@tj.example.com:443/extra#bad', 'malformed' ],
	[ 'vless double slash with query', `vless://${UUID}@203.0.113.20:443//?type=raw&security=tls#bad`, 'malformed' ],
	[ 'vless double slash without query', `vless://${UUID}@203.0.113.20:443//#bad`, 'malformed' ],
	[ 'trojan double slash with query', 'trojan://secret-pass@tj.example.com:443//?type=tcp#bad', 'malformed' ],
	[ 'trojan double slash without query', 'trojan://secret-pass@tj.example.com:443//#bad', 'malformed' ],
	[ 'vless port 0 with trailing slash', `vless://${UUID}@203.0.113.20:0/?type=raw&security=tls`, 'malformed' ],
	[ 'vless port 65536 with trailing slash', `vless://${UUID}@203.0.113.20:65536/?type=raw&security=tls`, 'malformed' ],
	[ 'vless non-numeric port with trailing slash', `vless://${UUID}@203.0.113.20:abc/?type=raw&security=tls`, 'malformed' ],
	[ 'trojan port 0 with trailing slash', 'trojan://secret-pass@tj.example.com:0/?type=raw', 'malformed' ],
	[ 'trojan port 65536 with trailing slash', 'trojan://secret-pass@tj.example.com:65536/?type=raw', 'malformed' ],
	[ 'trojan empty port with trailing slash', 'trojan://secret-pass@tj.example.com:/?type=raw', 'malformed' ],
	[ 'trojan missing port with trailing slash', 'trojan://secret-pass@tj.example.com/?type=raw', 'malformed' ],
	[ 'ss double slash still rejected', `ss://${SS_USER}@ss.example:8388//#bad`, 'malformed' ],
	[ 'hy2 double slash still rejected', 'hy2://auth@h.example:443//?sni=h.example#bad', 'malformed' ]
])
	push(cases, { name: 'T16.64 ' + pair[0], fn: 'line', input: pair[1], expect: { skip: pair[2] } });

// T16.65: VMess base64 JSON net=grpc preserves serviceName and three-state multiMode.
const VMESS_GRPC_BASE = {
	ps: 'vm-grpc', add: 'grpc.example.com', port: '443', id: UUID, aid: 0,
	scy: 'auto', net: 'grpc', tls: 'tls', sni: 'grpc.example.com'
};
const VMESS_GRPC_EXPECT_BASE = {
	protocol: 'vmess', address: 'grpc.example.com', port: 443, uuid: UUID, label: 'vm-grpc',
	method: 'auto', transport: 'grpc', security: 'tls', sni: 'grpc.example.com'
};
function vmess_uri(obj) {
	return 'vmess://' + b64enc(sprintf('%.J', obj));
}

for (let item in [
	[ 'multiMode bool true', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: true },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc', grpc_multi_mode: '1' } ],
	[ 'multiMode string true', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'true' },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc', grpc_multi_mode: '1' } ],
	[ 'multiMode string 1', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: '1' },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc', grpc_multi_mode: '1' } ],
	[ 'multiMode bool false', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: false },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc', grpc_multi_mode: '0' } ],
	[ 'multiMode string false', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'false' },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc', grpc_multi_mode: '0' } ],
	[ 'multiMode string 0', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: '0' },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc', grpc_multi_mode: '0' } ],
	[ 'multiMode omitted', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc' },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc' } ],
	[ 'multiMode null', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: null },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc' } ],
	[ 'multiMode empty string', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: '' },
		{ ...VMESS_GRPC_EXPECT_BASE, service_name: 'edge.grpc.svc' } ],
	[ 'serviceName empty string with multiMode true', { ...VMESS_GRPC_BASE, serviceName: '', multiMode: true },
		{ ...VMESS_GRPC_EXPECT_BASE, grpc_multi_mode: '1' } ],
	[ 'serviceName null with multiMode false', { ...VMESS_GRPC_BASE, serviceName: null, multiMode: false },
		{ ...VMESS_GRPC_EXPECT_BASE, grpc_multi_mode: '0' } ],
	[ 'serviceName and multiMode omitted', { ...VMESS_GRPC_BASE },
		{ ...VMESS_GRPC_EXPECT_BASE } ],
	[ 'path and type not guessed as gRPC dialect', { ...VMESS_GRPC_BASE, path: '/legacy', type: 'none' },
		{ ...VMESS_GRPC_EXPECT_BASE, path: '/legacy', header_type: 'none' } ],
	[ 'non-grpc vmess ignores serviceName and multiMode',
		{ ...VMESS_JSON, net: 'ws', path: '/ws', serviceName: 'ignored.svc', multiMode: true },
		{
			protocol: 'vmess', address: 'vm.example.com', port: 443, uuid: UUID, label: 'v2rayN',
			method: 'auto', transport: 'ws', security: 'tls', header_type: 'none', path: '/ws',
			sni: 'vm.example.com', fingerprint: 'chrome', alpn: [ 'h2' ]
		} ]
])
	push(cases, { name: 'T16.65 vmess grpc ' + item[0], fn: 'line', input: vmess_uri(item[1]), expect: { node: item[2] } });

for (let bad in [
	[ 'multiMode yes', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'yes' } ],
	[ 'multiMode no', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'no' } ],
	[ 'multiMode on', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'on' } ],
	[ 'multiMode multi', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'multi' } ],
	[ 'multiMode gun', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'gun' } ],
	[ 'multiMode uppercase TRUE', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'TRUE' } ],
	[ 'multiMode uppercase FALSE', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'FALSE' } ],
	[ 'multiMode bogus string', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 'bogus' } ],
	[ 'multiMode string 2', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: '2' } ],
	[ 'multiMode int 1', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 1 } ],
	[ 'multiMode int 0', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: 0 } ],
	[ 'multiMode array', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: [] } ],
	[ 'multiMode object', { ...VMESS_GRPC_BASE, serviceName: 'edge.grpc.svc', multiMode: {} } ],
	[ 'serviceName bool', { ...VMESS_GRPC_BASE, serviceName: true } ],
	[ 'serviceName int', { ...VMESS_GRPC_BASE, serviceName: 123 } ],
	[ 'serviceName array', { ...VMESS_GRPC_BASE, serviceName: [] } ],
	[ 'serviceName object', { ...VMESS_GRPC_BASE, serviceName: {} } ]
])
	push(cases, { name: 'T16.65 vmess grpc invalid ' + bad[0], fn: 'line', input: vmess_uri(bad[1]), expect: { skip: 'invalid_value' } });

export function run(c) {
	return c.fn == 'line' ? uri.parse_line(c.input) : uri.parse_body(c.input);
};
