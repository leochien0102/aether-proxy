'use strict';

// T16.87 (M13 part 3): per-URI 16 KiB (16384-byte) budget on the shared parser path.
// Covers exact 16383/16384/16385-byte boundaries across ASCII, UTF-8 multi-byte,
// space-padded non-empty lines, VMess/percent-encoded payloads, manual node.parse_node(),
// plaintext & whole-body Base64 subscriptions, neighbor isolation, SUB_MAX_NODES quota
// preservation, and >16 KiB total subscriptions made of valid short lines.

import * as C from 'aetherproxy.const';
import * as node from 'aetherproxy.node';
import * as uri from 'aetherproxy.uri';

const UUID = '11111111-2222-4333-8444-555555555555';
const LIMIT = C.URI_MAX_BYTES;
const PREFIX = `vless://${UUID}@edge.example:443?security=tls#`;

function repeat_str(s, count) {
	let out = '';
	let chunk = s;
	let n = count;
	while (n > 0) {
		if (n & 1)
			out += chunk;
		n >>= 1;
		if (n > 0)
			chunk += chunk;
	}
	return out;
}

function make_ascii_uri(target_bytes, host) {
	let prefix = `vless://${UUID}@${host ?? 'edge.example'}:443?security=tls#`;
	return prefix + repeat_str('a', target_bytes - length(prefix));
}

function make_utf8_uri(target_bytes) {
	// '中' is 3 UTF-8 bytes, '🌟' is 4 UTF-8 bytes; character count stays well below 16384.
	let prefix = `vless://${UUID}@utf8.example:443?security=tls#🌟`;
	let rem = target_bytes - length(prefix);
	let q = int(rem / 3);
	let r = rem % 3;
	return prefix + repeat_str('中', q) + repeat_str('a', r);
}

function make_padded_uri(target_bytes, lead, trail) {
	let l = lead ?? 2;
	let t = trail ?? 2;
	return repeat_str(' ', l) + make_ascii_uri(target_bytes - l - t, 'padded.example') + repeat_str(' ', t);
}

function make_pct_uri(target_bytes) {
	let prefix = `vless://${UUID}@pct.example:443?type=ws&security=tls&path=%2Fws#`;
	let rem = target_bytes - length(prefix);
	let q = int(rem / 3);
	let r = rem % 3;
	return prefix + repeat_str('%41', q) + repeat_str('a', r);
}

function make_vmess_uri(target_bytes) {
	let head = '{"ps":"';
	let tail = `","add":"vm.example","port":"443","id":"${UUID}","aid":0,"scy":"auto","net":"tcp","tls":"tls"}`;
	// 12282 raw JSON bytes -> 16376 base64 bytes -> 8 + 16376 = 16384 total bytes.
	let raw_json = head + repeat_str('x', 12282 - length(head) - length(tail)) + tail;
	let base = 'vmess://' + b64enc(raw_json);
	if (target_bytes == length(base))
		return base;
	if (target_bytes > length(base))
		return base + '#' + repeat_str('z', target_bytes - length(base) - 1);
	// Shorter than 16384: shrink JSON by 3 bytes (-4 b64 bytes) and pad via fragment.
	let shorter_json = head + repeat_str('x', 12279 - length(head) - length(tail)) + tail;
	let shorter = 'vmess://' + b64enc(shorter_json);
	return shorter + '#' + repeat_str('z', target_bytes - length(shorter) - 1);
}

function wrap_b64(text) {
	let enc = b64enc(text);
	let lines = [];
	for (let i = 0; i < length(enc); i += 76)
		push(lines, substr(enc, i, 76));
	return join('\r\n', lines) + '\r\n';
}

function summarize_line(res) {
	if (res.node != null)
		return { ok: true, address: res.node.address, label_bytes: length(res.node.label ?? '') };
	return { ok: false, skip: res.skip };
}

function summarize_node_parse(res) {
	if (res.ok)
		return { ok: true, address: res.node.address, label_bytes: length(res.node.label ?? '') };
	return { ok: false, code: res.code, detail: res.detail };
}

function summarize_body(res) {
	return {
		ok: res.ok,
		error: res.error,
		count: length(res.nodes),
		skipped: res.skipped,
		first_addr: length(res.nodes) ? res.nodes[0].address : null,
		last_addr: length(res.nodes) ? res.nodes[length(res.nodes) - 1].address : null
	};
}

const NEIGHBOR_A = `vless://${UUID}@neighbor-a.example:443?security=tls#A`;
const NEIGHBOR_B = `vless://${UUID}@neighbor-b.example:443?security=tls#B`;

function make_large_valid_sub(count) {
	let lines = [];
	for (let i = 1; i <= count; i++)
		push(lines, `vless://${UUID}@bulk-${i}.example.com:443?security=tls&sni=bulk-${i}.example.com#Node-${i}`);
	return join('\n', lines) + '\n';
}

const BULK_SUB = make_large_valid_sub(250);

function make_quota_sub(valid_count) {
	let lines = [
		make_ascii_uri(LIMIT + 1, 'over-quota-1.example'),
		make_padded_uri(LIMIT + 1, 3, 3)
	];
	for (let i = 1; i <= valid_count; i++)
		push(lines, `vless://${UUID}@q${i}.example:443?security=tls#q-${i}`);
	push(lines, make_utf8_uri(LIMIT + 1));
	return join('\r\n', lines) + '\r\n';
}

export const cases = [
	{
		name: 'production constant URI_MAX_BYTES is 16384',
		fn: () => C.URI_MAX_BYTES,
		expect: 16384
	},
	{
		name: 'synthetic ASCII boundary lengths are exact 16383/16384/16385 bytes',
		fn: () => [ length(make_ascii_uri(LIMIT - 1)), length(make_ascii_uri(LIMIT)), length(make_ascii_uri(LIMIT + 1)) ],
		expect: [ 16383, 16384, 16385 ]
	},
	{
		name: 'synthetic UTF-8 boundary lengths are exact 16383/16384/16385 bytes',
		fn: () => [ length(make_utf8_uri(LIMIT - 1)), length(make_utf8_uri(LIMIT)), length(make_utf8_uri(LIMIT + 1)) ],
		expect: [ 16383, 16384, 16385 ]
	},
	{
		name: 'parse_line ASCII 16383 bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_ascii_uri(LIMIT - 1))),
		expect: { ok: true, address: 'edge.example', label_bytes: LIMIT - 1 - length(PREFIX) }
	},
	{
		name: 'parse_line ASCII 16384 bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_ascii_uri(LIMIT))),
		expect: { ok: true, address: 'edge.example', label_bytes: LIMIT - length(PREFIX) }
	},
	{
		name: 'parse_line ASCII 16385 bytes rejected as malformed without truncation',
		fn: () => summarize_line(uri.parse_line(make_ascii_uri(LIMIT + 1))),
		expect: { ok: false, skip: 'malformed' }
	},
	{
		name: 'parse_line UTF-8 multi-byte 16383 bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_utf8_uri(LIMIT - 1))),
		expect: { ok: true, address: 'utf8.example', label_bytes: LIMIT - 1 - length(`vless://${UUID}@utf8.example:443?security=tls#`) }
	},
	{
		name: 'parse_line UTF-8 multi-byte 16384 bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_utf8_uri(LIMIT))),
		expect: { ok: true, address: 'utf8.example', label_bytes: LIMIT - length(`vless://${UUID}@utf8.example:443?security=tls#`) }
	},
	{
		name: 'parse_line UTF-8 multi-byte 16385 bytes rejected by byte length even though char count < 16384',
		fn: () => summarize_line(uri.parse_line(make_utf8_uri(LIMIT + 1))),
		expect: { ok: false, skip: 'malformed' }
	},
	{
		name: 'parse_line space-padded non-empty line at 16384 raw bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_padded_uri(LIMIT, 2, 2))),
		expect: { ok: true, address: 'padded.example', label_bytes: LIMIT - 4 - length(`vless://${UUID}@padded.example:443?security=tls#`) }
	},
	{
		name: 'parse_line space-padded non-empty line at 16385 raw bytes rejected before trim',
		fn: () => summarize_line(uri.parse_line(make_padded_uri(LIMIT + 1, 2, 2))),
		expect: { ok: false, skip: 'malformed' }
	},
	{
		name: 'parse_line percent-encoded URI 16384 bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_pct_uri(LIMIT))).ok,
		expect: true
	},
	{
		name: 'parse_line percent-encoded URI 16385 bytes rejected as malformed',
		fn: () => summarize_line(uri.parse_line(make_pct_uri(LIMIT + 1))),
		expect: { ok: false, skip: 'malformed' }
	},
	{
		name: 'parse_line VMess Base64 URI 16384 bytes allowed',
		fn: () => summarize_line(uri.parse_line(make_vmess_uri(LIMIT))).ok,
		expect: true
	},
	{
		name: 'parse_line VMess Base64 URI 16385 bytes rejected before Base64/JSON decode',
		fn: () => summarize_line(uri.parse_line(make_vmess_uri(LIMIT + 1))),
		expect: { ok: false, skip: 'malformed' }
	},
	{
		name: 'parse_line unsupported scheme at 16385 bytes rejected as malformed before scheme dispatch',
		fn: () => uri.parse_line('tuic://' + repeat_str('a', LIMIT - 6)),
		expect: { skip: 'malformed' }
	},
	{
		name: 'node.parse_node accepts 16384 bytes and rejects 16385 bytes (ASCII, UTF-8, padded)',
		fn: () => [
			summarize_node_parse(node.parse_node(make_ascii_uri(LIMIT))).ok,
			summarize_node_parse(node.parse_node(make_ascii_uri(LIMIT + 1))),
			summarize_node_parse(node.parse_node(make_utf8_uri(LIMIT))).ok,
			summarize_node_parse(node.parse_node(make_utf8_uri(LIMIT + 1))),
			summarize_node_parse(node.parse_node(make_padded_uri(LIMIT, 2, 2))).ok,
			summarize_node_parse(node.parse_node(make_padded_uri(LIMIT + 1, 2, 2)))
		],
		expect: [
			true,
			{ ok: false, code: 'CONFIG_INVALID', detail: 'malformed' },
			true,
			{ ok: false, code: 'CONFIG_INVALID', detail: 'malformed' },
			true,
			{ ok: false, code: 'CONFIG_INVALID', detail: 'malformed' }
		]
	},
	{
		name: 'parse_body CRLF strips delimiter so 16384-byte line is allowed while 16384+bare-CR EOF is rejected',
		fn: () => [
			summarize_body(uri.parse_body(make_ascii_uri(LIMIT) + '\r\n')).ok,
			summarize_body(uri.parse_body(make_ascii_uri(LIMIT) + '\r'))
		],
		expect: [
			true,
			{ ok: false, error: 'SUB_NO_VALID_NODES', count: 0, skipped: { malformed: 1 }, first_addr: null, last_addr: null }
		]
	},
	{
		name: 'parse_body counts leading/trailing spaces on non-empty lines without pre-trim bypass',
		fn: () => summarize_body(uri.parse_body(join('\r\n', [
			make_padded_uri(LIMIT, 2, 2),
			make_padded_uri(LIMIT + 1, 2, 2),
			repeat_str(' ', LIMIT + 50),
			''
		]))),
		expect: {
			ok: true, error: null, count: 1, skipped: { malformed: 1 },
			first_addr: 'padded.example', last_addr: 'padded.example'
		}
	},
	{
		name: 'parse_body plaintext oversized lines sandwiched between valid neighbors do not affect neighbors',
		fn: () => summarize_body(uri.parse_body(join('\r\n', [
			NEIGHBOR_A,
			make_ascii_uri(LIMIT + 1, 'bad-ascii.example'),
			make_utf8_uri(LIMIT + 1),
			make_padded_uri(LIMIT + 1, 1, 1),
			make_vmess_uri(LIMIT + 1),
			NEIGHBOR_B,
			''
		]))),
		expect: {
			ok: true, error: null, count: 2, skipped: { malformed: 4 },
			first_addr: 'neighbor-a.example', last_addr: 'neighbor-b.example'
		}
	},
	{
		name: 'parse_body wrapped whole-body Base64 oversized lines sandwiched between valid neighbors do not affect neighbors',
		fn: () => summarize_body(uri.parse_body(wrap_b64(join('\r\n', [
			NEIGHBOR_A,
			make_ascii_uri(LIMIT + 1, 'bad-b64.example'),
			make_utf8_uri(LIMIT + 1),
			make_padded_uri(LIMIT + 1, 3, 2),
			NEIGHBOR_B,
			''
		])))),
		expect: {
			ok: true, error: null, count: 2, skipped: { malformed: 3 },
			first_addr: 'neighbor-a.example', last_addr: 'neighbor-b.example'
		}
	},
	{
		name: 'parse_body all-oversized plaintext and Base64 fail with SUB_NO_VALID_NODES',
		fn: () => {
			let body = join('\n', [ make_ascii_uri(LIMIT + 1), make_utf8_uri(LIMIT + 1), make_padded_uri(LIMIT + 1, 2, 2) ]) + '\n';
			return [ summarize_body(uri.parse_body(body)), summarize_body(uri.parse_body(wrap_b64(body))) ];
		},
		expect: [
			{ ok: false, error: 'SUB_NO_VALID_NODES', count: 0, skipped: { malformed: 3 }, first_addr: null, last_addr: null },
			{ ok: false, error: 'SUB_NO_VALID_NODES', count: 0, skipped: { malformed: 3 }, first_addr: null, last_addr: null }
		]
	},
	{
		name: 'parse_body oversized lines do not consume SUB_MAX_NODES (1024) quota',
		fn: () => [
			summarize_body(uri.parse_body(make_quota_sub(C.SUB_MAX_NODES))),
			summarize_body(uri.parse_body(make_quota_sub(C.SUB_MAX_NODES + 1)))
		],
		expect: [
			{
				ok: true, error: null, count: 1024, skipped: { malformed: 3 },
				first_addr: 'q1.example', last_addr: 'q1024.example'
			},
			{
				ok: false, error: 'SUB_TOO_MANY_NODES', count: 0, skipped: { malformed: 2 },
				first_addr: null, last_addr: null
			}
		]
	},
	{
		name: 'parse_body accepts >16 KiB total subscription made of valid short lines (plaintext and Base64)',
		fn: () => [
			length(BULK_SUB) > LIMIT,
			summarize_body(uri.parse_body(BULK_SUB)),
			summarize_body(uri.parse_body(wrap_b64(BULK_SUB)))
		],
		expect: [
			true,
			{ ok: true, error: null, count: 250, skipped: {}, first_addr: 'bulk-1.example.com', last_addr: 'bulk-250.example.com' },
			{ ok: true, error: null, count: 250, skipped: {}, first_addr: 'bulk-1.example.com', last_addr: 'bulk-250.example.com' }
		]
	}
];

export function run(c) {
	return c.fn();
};
