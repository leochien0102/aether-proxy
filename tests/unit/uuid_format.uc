'use strict';

// docs/05 rule 7 and T9.37: UUID acceptance follows Xray's byte lengths, not Unicode characters.
// Exercise both snapshot and single-node validation so subscriptions share the same rule.
import * as config from 'aetherproxy.config';
import * as uri from 'aetherproxy.uri';

const ID = 'n_11111111111111111111111111111111';
const BASE = { address: 'edge.example', port: '443', security: 'tls' };
const HEX = 'abcdef0123456789abcdef0123456789';
const THIRTY = '123456789012345678901234567890';
const VALUES = [
	{ name: 'standard 36-byte lowercase', value: 'abcdef01-2345-6789-abcd-ef0123456789', valid: true },
	{ name: 'standard 36-byte uppercase', value: 'ABCDEF01-2345-6789-ABCD-EF0123456789', valid: true },
	{ name: '32-byte hex without hyphens', value: HEX, valid: true },
	{ name: '35-byte UUID missing one hyphen', value: 'abcdef012345-6789-abcd-ef0123456789', valid: true },
	{ name: 'short-id-123', value: 'short-id-123', valid: true },
	{ name: 'three Chinese characters are 9 bytes', value: '中文名', valid: true },
	{ name: 'exactly 30 ASCII bytes', value: THIRTY, valid: true },
	{ name: '31 ASCII bytes', value: THIRTY + '1', valid: false },
	{ name: '36-byte UUID containing z', value: 'abcdef01-2345-6789-abcd-ef012345678z', valid: false },
	{ name: '37 bytes even with 32 hex digits', value: '-----' + HEX, valid: false },
	{ name: 'ten Chinese characters are 30 bytes', value: '一二三四五六七八九十', valid: true },
	{ name: 'eleven Chinese characters are 33 bytes', value: '一二三四五六七八九十百', valid: false },
	// Hyphen count and location are deliberately unrestricted within the total byte limit.
	{ name: '33 bytes with leading hyphen', value: '-' + HEX, valid: true },
	{ name: '34 bytes with trailing hyphens', value: HEX + '--', valid: true },
	{ name: '36 bytes with adjacent leading hyphens', value: '----' + HEX, valid: true },
	{ name: 'UUID version is not checked', value: '00000000-0000-0000-0000-000000000000', valid: true },
	{ name: 'one non-hex byte', value: 'z', valid: true },
	{ name: '32 non-hex bytes', value: THIRTY + 'zz', valid: false },
	{ name: '36 bytes with only 31 hex digits', value: '-----' + substr(HEX, 0, 31), valid: false },
	{ name: 'empty UUID remains required', value: '', required: true },
	{ name: 'missing UUID remains required', value: null, required: true }
];

export const cases = [];

for (let protocol in [ 'vless', 'vmess' ])
	for (let c in VALUES) {
		let code = c.required ? 'required' : 'invalid_uuid';
		push(cases, {
			name: protocol + ' ' + c.name, protocol, value: c.value,
			expect: {
				ok: c.valid ?? false,
				snapshot_errors: c.valid ? [] : [ { field: 'node.' + ID + '.uuid', code } ],
				node_errors: c.valid ? [] : [ { field: 'node.uuid', code } ],
				retained: c.valid ? c.value : null
			}
		});
	}

for (let protocol in [ 'trojan', 'shadowsocks' ])
	push(cases, {
		name: protocol + ' retains invalid unused UUID', protocol, value: THIRTY + '1',
		expect: { ok: true, snapshot_errors: [], node_errors: [], retained: THIRTY + '1' }
	});

function link(protocol, value) {
	if (protocol == 'vmess')
		return 'vmess://' + b64enc(sprintf('%.J', {
			add: BASE.address, port: BASE.port, id: value, tls: 'tls', net: 'tcp'
		}));
	return 'vless://' + value + '@edge.example:443?security=tls';
}

for (let protocol in [ 'vless', 'vmess' ]) {
	push(cases, {
		name: protocol + ' subscription skips 31-byte UUID as invalid_value', subscription: true, protocol,
		value: THIRTY + '1',
		expect: { line: { skip: 'invalid_value' }, ok: true, uuids: [ 'short-id-123' ], skipped: { invalid_value: 1 } }
	});
	push(cases, {
		name: protocol + ' subscription accepts 30-byte UUID', subscription: true, protocol, value: THIRTY,
		expect: { line: { uuid: THIRTY }, ok: true, uuids: [ THIRTY, 'short-id-123' ], skipped: {} }
	});
}

function error_codes(errors) {
	return map(errors ?? [], e => ({ field: e.field, code: e.code }));
}

export function run(c) {
	if (c.subscription) {
		let input = link(c.protocol, c.value);
		let line = uri.parse_line(input);
		let body = uri.parse_body(input + '\n' + link(c.protocol, 'short-id-123'));
		return {
			line: line.skip != null ? line : { uuid: line.node?.uuid },
			ok: body.ok, uuids: map(body.nodes, n => n.uuid), skipped: body.skipped
		};
	}

	let raw = { ...BASE, protocol: c.protocol, uuid: c.value };
	if (index([ 'trojan', 'shadowsocks' ], c.protocol) >= 0)
		raw.password = 'secret';
	if (c.protocol == 'shadowsocks')
		raw.method = 'aes-128-gcm';
	let result = config.normalize({ nodes: { [ID]: raw } });
	return {
		ok: result.ok,
		snapshot_errors: error_codes(result.errors),
		node_errors: error_codes(config.validate_node(raw)),
		retained: result.ok ? result.snapshot.nodes[ID].uuid : null
	};
};
