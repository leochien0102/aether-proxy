'use strict';

// T9.41 / review B-F1: the same contract must hold at UCI, URI and subscription boundaries.
import * as config from 'aetherproxy.config';
import * as uri from 'aetherproxy.uri';
import * as xray from 'aetherproxy.render.xray';

const ID = 'n_11111111111111111111111111111111';
const BASE = { protocol: 'vless', address: 'edge.example', port: '443', uuid: 'id', security: 'tls' };
const PBK = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
export const fingerprints = [
	'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq',
	'random', 'randomized', 'randomizednoalpn',
	'hellofirefox_120', 'hellofirefox_148', 'hellochrome_120', 'hellochrome_131', 'hellochrome_133',
	'helloios_13', 'helloios_14', 'helloedge_106', 'hellosafari_26_3', 'hello360_11_0', 'helloqq_11_1',
	'hellorandomized', 'hellorandomizedalpn', 'hellorandomizednoalpn',
	'hellofirefox_auto', 'hellofirefox_55', 'hellofirefox_56', 'hellofirefox_63', 'hellofirefox_65',
	'hellofirefox_99', 'hellofirefox_102', 'hellofirefox_105',
	'hellochrome_auto', 'hellochrome_58', 'hellochrome_62', 'hellochrome_70', 'hellochrome_72',
	'hellochrome_83', 'hellochrome_87', 'hellochrome_96', 'hellochrome_100', 'hellochrome_102',
	'hellochrome_106_shuffle', 'helloios_auto', 'helloios_11_1', 'helloios_12_1',
	'helloandroid_11_okhttp', 'helloedge_85', 'helloedge_auto', 'hellosafari_16_0', 'hellosafari_auto',
	'hello360_auto', 'hello360_7_5', 'helloqq_auto', 'hellochrome_100_psk', 'hellochrome_112_psk_shuf',
	'hellochrome_114_padding_psk_shuf', 'hellochrome_115_pq', 'hellochrome_115_pq_psk', 'hellochrome_120_pq'
];
export const cases = [];
function repeated(size) {
	let out = '';
	for (let i = 0; i < size; i++) out += 'a';
	return out;
}
function add(name, extra, field, code) {
	push(cases, { name: 'T9.41 ' + name, extra, field, expect: code ?? null });
}
for (let security in [ 'tls', 'reality' ]) {
	let extra = { security, sni: 'edge.example', reality_pbk: PBK };
	for (let value in [ ...fingerprints, 'ChRoMe', 'unsafe', 'hellogolang', 'bogus', 'chrome ' ]) {
		let good = index(fingerprints, lc(value)) >= 0 || (security == 'tls' && value in [ 'unsafe', 'hellogolang' ]);
		add(security + ' fingerprint ' + value, { ...extra, fingerprint: value },
			'fingerprint', good ? null : 'invalid_value');
	}
	for (let item in [ [ 'null', { fingerprint: null } ], [ 'missing', {} ], [ 'empty', { fingerprint: '' } ] ])
		add(security + ' fingerprint ' + item[0], { ...extra, ...item[1] }, 'fingerprint');
}
for (let value in [ 'auto', 'packet-up', 'stream-up', 'stream-one', 'bogus', 'AUTO' ])
	add('xhttp mode ' + value, { transport: 'xhttp', xhttp_mode: value }, 'xhttp_mode',
		value in [ 'auto', 'packet-up', 'stream-up', 'stream-one' ] ? null : 'invalid_value');
for (let field in [ 'xhttp_mode', 'encryption' ])
	for (let item in [ [ 'null', { [field]: null } ], [ 'missing', {} ], [ 'empty', { [field]: '' } ] ])
		add(field + ' ' + item[0], { transport: 'xhttp', ...item[1] }, field);
for (let mode in [ 'native', 'xorpub', 'random' ])
	for (let rtt in [ '0rtt', '1rtt' ])
		for (let bytes in [ 32, 1184 ]) {
			let key = replace(replace(replace(b64enc(repeated(bytes)), /\+/g, '-'), /\//g, '_'), /=+$/, '');
			add('encryption ' + mode + ' ' + rtt + ' ' + bytes,
				{ encryption: 'mlkem768x25519plus.' + mode + '.' + rtt + '.' + key }, 'encryption');
		}
for (let bytes in [ 31, 33, 1183, 1185 ]) {
	let key = replace(b64enc(repeated(bytes)), /=+$/, '');
	add('encryption invalid key bytes ' + bytes,
		{ encryption: 'mlkem768x25519plus.native.1rtt.' + key }, 'encryption', 'invalid_value');
}
add('encryption valid multiple keys',
	{ encryption: 'mlkem768x25519plus.native.1rtt.' + PBK + '.' + PBK }, 'encryption');
add('encryption valid padding', { encryption: 'mlkem768x25519plus.native.1rtt.100-100-100.' + PBK }, 'encryption');
add('encryption padding only fails closed', { encryption: 'mlkem768x25519plus.native.1rtt.100-100-100' },
	'encryption', 'invalid_value');
for (let value in [ 'none', 'bogus', 'mlkem768x25519plus.native.1rtt',
	'mlkem768x25519plus.bad.1rtt.' + PBK, 'mlkem768x25519plus.native.2rtt.' + PBK,
	'mlkem768x25519plus.native.1rtt.' + PBK + 'a', 'mlkem768x25519plus.native.1rtt.' + PBK + '=' ])
	add('encryption ' + value, { encryption: value }, 'encryption', value == 'none' ? null : 'invalid_value');
for (let method in [ '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305' ]) {
	let size = method == '2022-blake3-aes-128-gcm' ? 16 : 32;
	let extra = { protocol: 'shadowsocks', method };
	let key = b64enc(repeated(size));
	for (let bytes in [ size - 1, size, size + 1 ])
		add(method + ' bytes ' + bytes,
			{ ...extra, password: b64enc(repeated(bytes)) }, 'password',
			bytes == size ? null : 'invalid_value');
	for (let item in [ [ 'multi valid', key + ':' + key ], [ 'multi bad', key + ':pw' ],
		[ 'leading empty', ':' + key ], [ 'trailing empty', key + ':' ], [ 'middle empty', key + '::' + key ],
		[ 'illegal base64', '!!!!' ], [ 'unpadded', replace(key, /=+$/, '') ] ])
		add(method + ' ' + item[0], { ...extra, password: item[1] }, 'password',
			item[0] == 'multi valid' && method != '2022-blake3-chacha20-poly1305' ? null : 'invalid_value');
	add(method + ' raw key fallback', { ...extra, password: replace(repeated(size), /a/g, '!') }, 'password');
	add(method + ' base64 CRLF', { ...extra, password: key + '\r\n' }, 'password');
	for (let item in [ [ 'null', { password: null } ], [ 'missing', {} ], [ 'empty', { password: '' } ] ])
		add(method + ' password ' + item[0], { ...extra, ...item[1] }, 'password', 'required');
}
add('inactive fields preserved', { security: 'none', address: '192.168.1.2', fingerprint: 'bogus',
	xhttp_mode: 'bogus', protocol: 'vmess', encryption: 'bogus' }, 'fingerprint');
add('opaque PQV remains accepted', { security: 'reality', sni: 'edge.example', reality_pbk: PBK,
	reality_pqv: 'GARBAGE' }, 'reality_pqv');
add('opaque ECH remains accepted', { ech_config_list: 'GARBAGE' }, 'ech_config_list');
for (let query in [ 'fp=bogus', 'encryption=bogus', 'type=xhttp&mode=bogus' ])
	push(cases, { name: 'T9.41 URI rejects ' + query, query, expect: 'invalid_value' });
push(cases, { name: 'T9.41 URI rejects SS2022 password', ss: true, expect: 'invalid_value' });
push(cases, { name: 'T9.41 subscription skips invalid and retains valid', subscription: true, expect: true });

export function raw(c) { return { ...BASE, ...(c.extra ?? {}) }; };
export function normalized(c) { return config.normalize({ nodes: { [ID]: raw(c) } }); };
export function artifact(c) {
	let result = normalized(c);
	if (!result.ok) {
		// Independent Xray oracle: render rejected values without allowing the validator
		// to filter them out first. This path is test-only, never a production renderer change.
		result = config.normalize({ nodes: { [ID]: BASE } });
		result.snapshot.nodes[ID] = { ...result.snapshot.nodes[ID], ...c.extra };
	}
	result.snapshot.main.node = ID;
	return xray.render(result.snapshot, {});
};
export function run(c) {
	if (c.query != null)
		return uri.parse_line('vless://id@edge.example:443?security=tls&' + c.query).skip;
	if (c.ss)
		return uri.parse_line('ss://2022-blake3-aes-128-gcm:pw@edge.example:443').skip;
	if (c.subscription) {
		let parsed = uri.parse_body('vless://id@edge.example:443?security=tls&fp=bogus\n'
			+ 'vless://id@edge.example:443?security=tls&encryption=bogus\n'
			+ 'vless://id@edge.example:443?security=tls&type=xhttp&mode=bogus\n'
			+ 'ss://2022-blake3-aes-128-gcm:pw@edge.example:443\n'
			+ 'vless://id@edge.example:443?security=tls\n');
		return length(parsed.nodes) == 1 && parsed.skipped.invalid_value == 4;
	}
	let errors = config.validate_node(raw(c));
	let norm = normalized(c);
	if (c.expect == null && (!norm.ok || length(errors)))
		return 'unexpected validation error';
	if (c.name == 'T9.41 inactive fields preserved')
		for (let field in [ 'fingerprint', 'encryption', 'xhttp_mode' ])
			if (norm.snapshot.nodes[ID][field] != c.extra[field])
				return 'inactive value lost';
	let a = filter(errors, e => e.field == 'node.' + c.field)[0]?.code;
	let b = filter(norm.errors ?? [], e => e.field == 'node.' + ID + '.' + c.field)[0]?.code;
	return a == b ? (a ?? null) : 'normalize/validate disagree';
};
