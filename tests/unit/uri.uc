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
		name: 'unsupported scheme', fn: 'line', input: 'hysteria2://token@h.example:443',
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
		input: 'hysteria2://token@h.example:443\n',
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

export function run(c) {
	return c.fn == 'line' ? uri.parse_line(c.input) : uri.parse_body(c.input);
};
