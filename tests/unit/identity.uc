'use strict';

import * as identity from 'aetherproxy.identity';

function vless(address, uuid, label, path, sni, stale) {
	let node = {
		protocol: 'vless', address, port: 443, transport: 'ws', security: 'tls',
		uuid, label, path, host: 'cdn.example.com', service_name: 'grpc', sni
	};
	if (stale != null)
		node.stale = stale;
	return node;
}

const old_credential = vless('Example.COM', 'old-uuid', 'old-label', '/shared', 'sni.example', false);
const new_credential = vless('example.com', 'new-uuid', 'new-label', '/shared', 'sni.example', false);
const old_label = vless('203.0.113.1', 'old-ip', 'keep-label', '/same', 'node.example', false);
const new_label = vless('203.0.113.2', 'new-ip', 'keep-label', '/same', 'node.example', false);
const old_ambiguous_a = vless('203.0.113.3', 'credential-a', 'old-a', '/same', 'node.example', false);
const old_ambiguous_b = vless('203.0.113.3', 'credential-b', 'old-b', '/same', 'node.example', false);
const new_ambiguous = vless('203.0.113.3', 'credential-c', 'new-c', '/same', 'node.example', false);
const old_stale = vless('203.0.113.4', 'same-uuid', 'revive', '/same', 'node.example', true);
const new_stale = vless('203.0.113.4', 'same-uuid', 'revive', '/same', 'node.example', false);

function id(number) {
	return 'n_' + sprintf('%032x', number);
}

export const cases = [
	{
		name: 'keys are direct un-hashed strings with lowercase address',
		kind: 'keys',
		node: vless('EXAMPLE.COM', 'user-id', 'label', '/ws', 'sni.example', false),
		expect: {
			strong: 'vless|example.com|443|ws|/ws|cdn.example.com|grpc|tls|sni.example|user-id',
			weak: 'vless|example.com|443|ws|/ws|cdn.example.com|grpc'
		}
	},
	{
		name: 'credential rotation matches the unique weak key',
		kind: 'match',
		old: { n_old: old_credential }, new: [ new_credential ], ids: [], referenced: [],
		expect: {
			assign: [ { id: 'n_old', from: 'weak', label: 'new-label', address: 'example.com', uuid: 'new-uuid', stale: false } ],
			stale: [], removed: [], revived: []
		}
	},
	{
		name: 'changed IP with a unique same-protocol label matches by label',
		kind: 'match',
		old: { n_old: old_label }, new: [ new_label ], ids: [], referenced: [],
		expect: {
			assign: [ { id: 'n_old', from: 'label', label: 'keep-label', address: '203.0.113.2', uuid: 'new-ip', stale: false } ],
			stale: [], removed: [], revived: []
		}
	},
	{
		name: 'ambiguous weak key is not used',
		kind: 'match',
		old: { n_a: old_ambiguous_a, n_b: old_ambiguous_b }, new: [ new_ambiguous ],
		ids: [ id(1) ], referenced: [],
		expect: {
			assign: [ { id: id(1), from: 'new', label: 'new-c', address: '203.0.113.3', uuid: 'credential-c', stale: false } ],
			stale: [], removed: [ 'n_a', 'n_b' ], revived: []
		}
	},
	{
		name: 'strong key separates nodes sharing address and port',
		kind: 'match',
		old: {
			n_one: vless('203.0.113.5', 'uuid-one', 'one', '/one', 'one.example', false),
			n_two: vless('203.0.113.5', 'uuid-two', 'two', '/two', 'two.example', false)
		},
		new: [ vless('203.0.113.5', 'uuid-two', 'two-new', '/two', 'two.example', false) ],
		ids: [], referenced: [],
		expect: {
			assign: [ { id: 'n_two', from: 'strong', label: 'two-new', address: '203.0.113.5', uuid: 'uuid-two', stale: false } ],
			stale: [], removed: [ 'n_one' ], revived: []
		}
	},
	{
		name: 'unmatched referenced and unreferenced old nodes stale or removed',
		kind: 'match', old: { n_a: old_label, n_b: new_label }, new: [],
		ids: [], referenced: [ 'n_a' ],
		expect: { assign: [], stale: [ 'n_a' ], removed: [ 'n_b' ], revived: [] }
	},
	{
		name: 'stale node revival reuses ID and clears stale',
		kind: 'match', old: { n_stale: old_stale }, new: [ new_stale ],
		ids: [], referenced: [ 'n_stale' ],
		expect: {
			assign: [ { id: 'n_stale', from: 'strong', label: 'revive', address: '203.0.113.4', uuid: 'same-uuid', stale: false } ],
			stale: [], removed: [], revived: [ 'n_stale' ]
		}
	},
	{
		name: 'new nodes receive injected deterministic IDs',
		kind: 'match', old: {},
		new: [ vless('203.0.113.6', 'new-a', 'a', '/a', 'a.example', false), vless('203.0.113.7', 'new-b', 'b', '/b', 'b.example', false) ],
		ids: [ id(6), id(7) ], referenced: [],
		expect: {
			assign: [
				{ id: id(6), from: 'new', label: 'a', address: '203.0.113.6', uuid: 'new-a', stale: false },
				{ id: id(7), from: 'new', label: 'b', address: '203.0.113.7', uuid: 'new-b', stale: false }
			],
			stale: [], removed: [], revived: []
		}
	},
	{
		name: 'one old node cannot be matched more than once',
		kind: 'match', old: { n_only: old_credential },
		new: [ new_credential, vless('example.com', 'new-uuid', 'new-label', '/shared', 'sni.example', false) ],
		ids: [ id(8) ], referenced: [],
		expect: {
			assign: [
				{ id: 'n_only', from: 'weak', label: 'new-label', address: 'example.com', uuid: 'new-uuid', stale: false },
				{ id: id(8), from: 'new', label: 'new-label', address: 'example.com', uuid: 'new-uuid', stale: false }
			],
			stale: [], removed: [], revived: []
		}
	}
];

function summarize(result) {
	return {
		assign: map(result.assign, item => ({
			id: item.id, from: item.from, label: item.node.label ?? null,
			address: item.node.address ?? null, uuid: item.node.uuid ?? null,
			stale: item.node.stale
		})),
		stale: result.stale,
		removed: result.removed,
		revived: result.revived
	};
}

export function run(c) {
	if (c.kind == 'keys')
		return identity.keys(c.node);

	let next = 0;
	let result = identity.match(c.old, c.new, {
		referenced: node_id => index(c.referenced, node_id) >= 0,
		new_id: () => c.ids[next++]
	});

	return summarize(result);
};
