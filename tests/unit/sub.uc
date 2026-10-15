'use strict';

import * as sub from 'aetherproxy.sub';

function node(uuid, label, extra) {
	return {
		protocol: 'vless', address: 'edge.example.com', port: 443,
		uuid, encryption: 'none', transport: 'ws', security: 'tls',
		path: '/ws', host: 'cdn.example.com', sni: 'edge.example.com',
		...(label == null ? {} : { label }), ...(extra ?? {})
	};
}

function project(result) {
	return {
		counts: result.counts,
		current_changed: result.current_changed,
		added_sections: map(filter(result.changes, change => change.op == 'add'), change => change.section),
		deleted_sections: map(filter(result.changes, change => change.op == 'delete_section'), change => change.section),
		deleted_options: map(filter(result.changes, change => change.op == 'delete_option'), change => `${change.section}.${change.option}`),
		stale_set: map(filter(result.changes, change => change.option == 'stale' && change.op == 'set'), change => change.section),
		stale_cleared: map(filter(result.changes, change => change.option == 'stale' && change.op == 'delete_option'), change => change.section),
		set_uuid: map(filter(result.changes, change => change.option == 'uuid' && change.op == 'set'), change => `${change.section}:${change.value}`)
	};
}

export const cases = [
	{
		name: 'initial import plans named sections and counts nodes',
		old: {}, parsed: { nodes: [ node('uuid-a', 'A'), node('uuid-b', 'B') ], skipped: {} },
		ids: [ 'n_00000000000040008000000000000001', 'n_00000000000040008000000000000002' ], sub_name: 's_1234abcd',
		expect: {
			counts: { added: 2, updated: 0, stale: 0, revived: 0, removed: 0, skipped: {} },
			current_changed: false,
			added_sections: [ 'n_00000000000040008000000000000001', 'n_00000000000040008000000000000002' ],
			deleted_sections: [], deleted_options: [], stale_set: [], stale_cleared: [],
			set_uuid: [ 'n_00000000000040008000000000000001:uuid-a', 'n_00000000000040008000000000000002:uuid-b' ]
		}
	},
	{
		name: 'credential rotation reuses ID and marks current changed',
		old: { n_old: node('old-uuid', 'old') }, parsed: { nodes: [ node('new-uuid', 'new') ], skipped: {} },
		ids: [], current: 'n_old', sub_name: 's_1234abcd',
		expect: {
			counts: { added: 0, updated: 1, stale: 0, revived: 0, removed: 0, skipped: {} },
			current_changed: true, added_sections: [], deleted_sections: [], deleted_options: [], stale_set: [], stale_cleared: [],
			set_uuid: [ 'n_old:new-uuid' ]
		}
	},
	{
		name: 'duplicate strong key keeps the first and increments duplicate skip',
		old: {}, parsed: { nodes: [ node('same', 'first'), node('same', 'second') ], skipped: {} },
		ids: [ 'n_00000000000040008000000000000003' ], sub_name: 's_1234abcd',
		expect: {
			counts: { added: 1, updated: 0, stale: 0, revived: 0, removed: 0, skipped: { duplicate: 1 } },
			current_changed: false, added_sections: [ 'n_00000000000040008000000000000003' ],
			deleted_sections: [], deleted_options: [], stale_set: [], stale_cleared: [],
			set_uuid: [ 'n_00000000000040008000000000000003:same' ]
		}
	},
	{
		name: 'missing old flow is deleted when matched node omits it',
		old: { n_flow: node('same', 'A', { flow: 'xtls-rprx-vision' }) },
		parsed: { nodes: [ node('same', 'A') ], skipped: {} }, ids: [], current: 'n_flow', sub_name: 's_1234abcd',
		expect: {
			counts: { added: 0, updated: 1, stale: 0, revived: 0, removed: 0, skipped: {} },
			current_changed: true, added_sections: [], deleted_sections: [], deleted_options: [ 'n_flow.flow' ],
			stale_set: [], stale_cleared: [], set_uuid: []
		}
	},
	{
		name: 'disappearing current node is retained and marked stale',
		old: { n_current: node('gone', 'gone') }, parsed: { nodes: [], skipped: {} }, ids: [],
		current: 'n_current', sub_name: 's_1234abcd',
		expect: {
			counts: { added: 0, updated: 0, stale: 1, revived: 0, removed: 0, skipped: {} },
			current_changed: false, added_sections: [], deleted_sections: [], deleted_options: [],
			stale_set: [ 'n_current' ], stale_cleared: [], set_uuid: []
		}
	},
	{
		name: 'disappearing unreferenced node is deleted',
		old: { n_gone: node('gone', 'gone') }, parsed: { nodes: [], skipped: {} }, ids: [], sub_name: 's_1234abcd',
		expect: {
			counts: { added: 0, updated: 0, stale: 0, revived: 0, removed: 1, skipped: {} },
			current_changed: false, added_sections: [], deleted_sections: [ 'n_gone' ], deleted_options: [],
			stale_set: [], stale_cleared: [], set_uuid: []
		}
	},
	{
		name: 'stale node returning clears stale option without restart',
		old: { n_stale: { ...node('same', 'A'), stale: true } },
		parsed: { nodes: [ node('same', 'A') ], skipped: {} }, ids: [], current: 'n_stale', sub_name: 's_1234abcd',
		expect: {
			counts: { added: 0, updated: 0, stale: 0, revived: 1, removed: 0, skipped: {} },
			current_changed: false, added_sections: [], deleted_sections: [], deleted_options: [ 'n_stale.stale' ],
			stale_set: [], stale_cleared: [ 'n_stale' ], set_uuid: []
		}
	},
	{
		name: 'unchanged current node does not request reload',
		old: { n_current: node('same', 'A') }, parsed: { nodes: [ node('same', 'A') ], skipped: {} },
		ids: [], current: 'n_current', sub_name: 's_1234abcd',
		expect: {
			counts: { added: 0, updated: 0, stale: 0, revived: 0, removed: 0, skipped: {} },
			current_changed: false, added_sections: [], deleted_sections: [], deleted_options: [], stale_set: [], stale_cleared: [], set_uuid: []
		}
	}
];

export function run(c) {
	let next = 0;
	let result = sub.plan(c.old, c.parsed, {
		current: c.current,
		sub_name: c.sub_name,
		new_id: () => c.ids[next++]
	});
	return project(result);
};
