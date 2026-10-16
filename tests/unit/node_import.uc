'use strict';
// Manual node import planning (docs/10 "`log`、`node import`、`custom`"). Pure functions
// of aetherproxy.node, table-driven.

import * as identity from 'aetherproxy.identity';
import { plan_changes, strong_keys } from 'aetherproxy.node';

const ZERO32 = '00000000000000000000000000000000';  // 32 hex zeros
const N_ZERO = 'n_' + ZERO32;

const VLESS_WS = {
	protocol: 'vless', address: 'example.com', port: 443,
	uuid: '11111111-2222-4333-8444-555555555555',
	transport: 'ws', security: 'tls', sni: 'example.com',
	path: '/ws', host: 'cdn.example.com', label: 'Edge One'
};

export const cases = [
	{ name: 'plan writes the section and identity keys', kind: 'plan',
	  node: VLESS_WS, id: N_ZERO,
	  expect: [
		{ op: 'add', section: N_ZERO, value: 'node' },
		{ op: 'set', section: N_ZERO, option: 'label', value: 'Edge One' },
		{ op: 'set', section: N_ZERO, option: 'source', value: 'manual' },
		{ op: 'set', section: N_ZERO, option: 'match_strong',
		  value: identity.keys(VLESS_WS).strong },
		{ op: 'set', section: N_ZERO, option: 'match_weak',
		  value: identity.keys(VLESS_WS).weak },
		{ op: 'set', section: N_ZERO, option: 'protocol', value: 'vless' },
		{ op: 'set', section: N_ZERO, option: 'address', value: 'example.com' },
		{ op: 'set', section: N_ZERO, option: 'port', value: '443' },
		{ op: 'set', section: N_ZERO, option: 'uuid', value: '11111111-2222-4333-8444-555555555555' },
		{ op: 'set', section: N_ZERO, option: 'transport', value: 'ws' },
		{ op: 'set', section: N_ZERO, option: 'host', value: 'cdn.example.com' },
		{ op: 'set', section: N_ZERO, option: 'path', value: '/ws' },
		{ op: 'set', section: N_ZERO, option: 'security', value: 'tls' },
		{ op: 'set', section: N_ZERO, option: 'sni', value: 'example.com' }
	  ] },
	{ name: 'plan falls back to address:port without a label', kind: 'plan',
	  node: { protocol: 'shadowsocks', address: 'ss.example.com', port: 8388,
		method: 'aes-256-gcm', password: 'pw', transport: 'raw', security: 'none' },
	  id: 'n_a',
	  expect_partial: { label: 'ss.example.com:8388', source: 'manual' }, expect: 'ok' },
	{ name: 'plan port is stored as a string', kind: 'plan',
	  node: { protocol: 'trojan', address: 't.example.com', port: 443, password: 'x' },
	  id: 'n_b',
	  expect_partial: { port: '443' }, expect: 'ok' },
	{ name: 'plan skips unset options and empty alpn', kind: 'plan',
	  node: { protocol: 'vless', address: 'v.example.com', port: 80, uuid: 'u', alpn: [] },
	  id: 'n_c',
	  expect_absent: [ 'sni', 'security', 'transport', 'alpn', 'flow' ], expect: 'ok' },
	{ name: 'plan keeps a non-empty alpn list', kind: 'plan',
	  node: { protocol: 'vless', address: 'v.example.com', port: 80, uuid: 'u', alpn: [ 'h2', 'http/1.1' ] },
	  id: 'n_d',
	  expect_partial: { alpn: [ 'h2', 'http/1.1' ] }, expect: 'ok' },

	{ name: 'strong_keys computes fresh keys, ignoring stored ones', kind: 'keys',
	  snapshot: { nodes: {
		n_1: { protocol: 'vless', address: 'example.com', port: 443, uuid: 'u1',
			transport: 'raw', security: 'none', match_strong: 'stale-stored-value' }
	  } },
	  expect: { n_1: identity.keys({ protocol: 'vless', address: 'example.com', port: 443, uuid: 'u1', transport: 'raw', security: 'none' }).strong } },
];

// NOTE: with the pinned ucode, `export function f() {...}` must be terminated by `;`.
export function run(c) {
	if (c.kind == 'keys')
		return strong_keys(c.snapshot);

	let planned = plan_changes(c.node, c.id);

	if (c.expect_partial != null || c.expect_absent != null) {
		let options = {};
		for (let change in planned.changes)
			if (change.op == 'set')
				options[change.option] = change.value;

		if (c.expect_absent != null)
			for (let field in c.expect_absent)
				if (options[field] != null)
					return `UNEXPECTED OPTION ${field}`;

		for (let k, v in (c.expect_partial ?? {}))
			if (sprintf('%.J', options[k]) != sprintf('%.J', v))
				return `MISMATCH ${k}: ${sprintf('%.J', options[k])}`;

		return planned.changes[0].op == 'add' ? 'ok' : planned.changes[0];
	}

	return planned.changes;
};
