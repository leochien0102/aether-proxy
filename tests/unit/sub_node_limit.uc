'use strict';

import * as C from 'aetherproxy.const';
import * as uri from 'aetherproxy.uri';

const UUID = '11111111-2222-4333-8444-555555555555';
const LIMIT = C.SUB_MAX_NODES;

function make_uri(i, query) {
	let q = query ? ('?' + query) : '?security=tls';
	return `vless://${UUID}@n${i}.limit.example:443${q}#node-${i}`;
}

function make_distinct(count) {
	let lines = [];
	for (let i = 1; i <= count; i++)
		push(lines, make_uri(i));
	return join('\n', lines);
}

function make_duplicates(count) {
	let line = make_uri(1);
	let lines = [];
	for (let i = 0; i < count; i++)
		push(lines, line);
	return join('\n', lines);
}

function to_b64url_unpadded(text) {
	return replace(replace(replace(b64enc(text), /\+/g, '-'), /\//g, '_'), /=+$/, '');
}

function summarize(res) {
	return {
		ok: res.ok,
		error: res.error,
		count: length(res.nodes),
		skipped: res.skipped,
		warnings: length(res.warnings),
		first_addr: length(res.nodes) ? res.nodes[0].address : null,
		last_addr: length(res.nodes) ? res.nodes[length(res.nodes) - 1].address : null
	};
}

function make_mixed(valid_count) {
	let lines = [
		'',
		'   ',
		'tuic://token@skip1.example:443',
		'not-a-uri',
		`vless://${UUID}@[2001:db8::1]:443#v6`
	];
	for (let i = 1; i <= valid_count; i++) {
		push(lines, make_uri(i));
		if (i == 500) {
			push(lines, '\t');
			push(lines, 'ssr://ignored');
		}
	}
	push(lines, '');
	push(lines, 'vmess://bm90IGpzb24=');
	push(lines, 'tuic://token@skip2.example:443');
	return join('\r\n', lines);
}

function make_early_stop_body() {
	let lines = [
		'tuic://token@before.example:443',
		make_uri(1, 'security=tls&allowInsecure=1')
	];
	for (let i = 2; i <= LIMIT + 1; i++)
		push(lines, make_uri(i));
	// Must never be parsed once the 1025th candidate stops parse_body().
	push(lines, 'vmess://bm90IGpzb24=');
	push(lines, 'not-a-uri-after-limit');
	return join('\n', lines);
}

export const cases = [
	{
		name: 'production limit constant is 1024',
		fn: () => C.SUB_MAX_NODES,
		expect: 1024
	},
	{
		name: 'plaintext exact 1024 distinct candidates succeeds',
		fn: () => summarize(uri.parse_body(make_distinct(LIMIT))),
		expect: {
			ok: true, error: null, count: 1024, skipped: {}, warnings: 0,
			first_addr: 'n1.limit.example', last_addr: 'n1024.limit.example'
		}
	},
	{
		name: 'plaintext 1025 distinct candidates fails with SUB_TOO_MANY_NODES',
		fn: () => summarize(uri.parse_body(make_distinct(LIMIT + 1))),
		expect: {
			ok: false, error: 'SUB_TOO_MANY_NODES', count: 0, skipped: {}, warnings: 0,
			first_addr: null, last_addr: null
		}
	},
	{
		name: 'plaintext 1025th candidate stops immediately without parsing trailing lines or returning warnings',
		fn: () => summarize(uri.parse_body(make_early_stop_body())),
		expect: {
			ok: false, error: 'SUB_TOO_MANY_NODES', count: 0,
			skipped: { unsupported_scheme: 1 }, warnings: 0,
			first_addr: null, last_addr: null
		}
	},
	{
		name: 'duplicate candidates count before deduplication: 1024 allowed',
		fn: () => summarize(uri.parse_body(make_duplicates(LIMIT))),
		expect: {
			ok: true, error: null, count: 1024, skipped: {}, warnings: 0,
			first_addr: 'n1.limit.example', last_addr: 'n1.limit.example'
		}
	},
	{
		name: 'duplicate candidates count before deduplication: 1025 rejected',
		fn: () => summarize(uri.parse_body(make_duplicates(LIMIT + 1))),
		expect: {
			ok: false, error: 'SUB_TOO_MANY_NODES', count: 0, skipped: {}, warnings: 0,
			first_addr: null, last_addr: null
		}
	},
	{
		name: 'blank and skippable lines do not consume quota at 1024',
		fn: () => summarize(uri.parse_body(make_mixed(LIMIT))),
		expect: {
			ok: true, error: null, count: 1024,
			skipped: { ipv6_address: 1, malformed: 2, unsupported_scheme: 3 },
			warnings: 0,
			first_addr: 'n1.limit.example', last_addr: 'n1024.limit.example'
		}
	},
	{
		name: 'blank and skippable lines plus 1025 valid candidates fails at 1025th',
		fn: () => summarize(uri.parse_body(make_mixed(LIMIT + 1))),
		expect: {
			ok: false, error: 'SUB_TOO_MANY_NODES', count: 0,
			// Trailing malformed + unsupported_scheme lines after 1025th are not parsed.
			skipped: { ipv6_address: 1, malformed: 1, unsupported_scheme: 2 },
			warnings: 0,
			first_addr: null, last_addr: null
		}
	},
	{
		name: 'standard Base64 body enforces exact 1024 allowance',
		fn: () => summarize(uri.parse_body(b64enc(make_mixed(LIMIT)))),
		expect: {
			ok: true, error: null, count: 1024,
			skipped: { ipv6_address: 1, malformed: 2, unsupported_scheme: 3 },
			warnings: 0,
			first_addr: 'n1.limit.example', last_addr: 'n1024.limit.example'
		}
	},
	{
		name: 'standard Base64 body rejects 1025 candidates with SUB_TOO_MANY_NODES',
		fn: () => summarize(uri.parse_body(b64enc(make_distinct(LIMIT + 1)))),
		expect: {
			ok: false, error: 'SUB_TOO_MANY_NODES', count: 0, skipped: {}, warnings: 0,
			first_addr: null, last_addr: null
		}
	},
	{
		name: 'URL-safe unpadded Base64 body rejects 1025 candidates with SUB_TOO_MANY_NODES',
		fn: () => summarize(uri.parse_body(to_b64url_unpadded(make_duplicates(LIMIT + 1)))),
		expect: {
			ok: false, error: 'SUB_TOO_MANY_NODES', count: 0, skipped: {}, warnings: 0,
			first_addr: null, last_addr: null
		}
	}
];

export function run(c) {
	return c.fn();
};
