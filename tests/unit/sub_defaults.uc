'use strict';

// Effective subscription settings and the shared raw reader (docs/05, docs/06, T9.17).
import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import { SCHEMA } from 'aetherproxy.schema';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const URL = 'https://sub.example/list';
const DEFAULTS = { user_agent: C.PROG + '/' + C.VERSION, fetch_via: 'auto', interval_hours: 24 };

function effective(result) {
	if (!result.ok)
		return result;
	let subs = {};
	for (let name, sub in result.snapshot.subscriptions)
		subs[name] = { user_agent: sub.user_agent, fetch_via: sub.fetch_via, interval_hours: sub.interval_hours };
	return { sub: result.snapshot.sub, subs };
}

function normalized(common, overrides) {
	return config.normalize({ sub: common, subscriptions: { s_00000001: { url: URL, ...overrides } } });
}

export const cases = [
	{
		name: 'T9.17 old config materializes all three defaults',
		kind: 'normalize', common: null, overrides: {},
		expect: { sub: DEFAULTS, subs: { s_00000001: DEFAULTS } }
	},
	{
		name: 'T9.17 empty options inherit common settings',
		kind: 'normalize', common: { user_agent: 'x', fetch_via: 'direct', interval_hours: '12' },
		overrides: { user_agent: '', fetch_via: '', interval_hours: '' },
		expect: {
			sub: { user_agent: 'x', fetch_via: 'direct', interval_hours: 12 },
			subs: { s_00000001: { user_agent: 'x', fetch_via: 'direct', interval_hours: 12 } }
		}
	},
	{
		name: 'T9.17 partial common settings fall back per field',
		kind: 'normalize', common: { interval_hours: '0' }, overrides: { user_agent: 'own' },
		expect: {
			sub: { ...DEFAULTS, interval_hours: 0 },
			subs: { s_00000001: { user_agent: 'own', fetch_via: 'auto', interval_hours: 0 } }
		}
	},
	{
		name: 'T9.17 load inherits common values preserves zero and legacy explicit values',
		kind: 'fixture',
		expect: {
			sub: { user_agent: 'x', fetch_via: 'direct', interval_hours: 12 },
			subs: {
				s_00000001: { user_agent: 'x', fetch_via: 'direct', interval_hours: 12 },
				s_00000002: { user_agent: 'x', fetch_via: 'direct', interval_hours: 0 },
				s_00000003: { user_agent: 'legacy UA', fetch_via: 'auto', interval_hours: 24 }
			}
		}
	},
	{
		name: 'T9.17 invalid common and subscription values have distinct field paths',
		kind: 'invalid',
		expect: [
			'sub.fetch_via:invalid_enum', 'sub.interval_hours:out_of_range',
			'subscription.s_00000001.fetch_via:invalid_enum',
			'subscription.s_00000001.interval_hours:invalid_int'
		]
	},
	{
		name: 'T9.17 negative subscription interval is rejected',
		kind: 'negative', expect: [ 'subscription.s_00000001.interval_hours:out_of_range' ]
	},
	{
		name: 'T9.17 fractional common interval is rejected',
		kind: 'fractional', expect: [ 'sub.interval_hours:invalid_int' ]
	},
	{
		name: 'T9.17 subscription schema has no inherited field defaults',
		kind: 'schema', expect: [ null, null, null ]
	},
	{
		name: 'T9.17 raw reader supports isolated package and strips metadata',
		kind: 'reader', expect: true
	},
	{
		name: 'T9.17 raw section inventory is shared by both callers',
		kind: 'inventory', expect: true
	}
];

function reader_test() {
	let names = [], packages = [];
	let cursor = {
		get_all: (package_name, section) => {
			push(names, section);
			push(packages, package_name);
			return { '.name': section, '.type': section, marker: section };
		},
		foreach: (package_name, kind, cb) => {
			push(packages, package_name);
			cb({ '.name': kind + '_name', '.type': kind, marker: kind });
		}
	};
	let raw = config.read_raw(cursor, 'isolated_test');
	if (join(',', names) != 'main,dns,update,probe,sub')
		return false;
	if (length(filter(packages, p => p != 'isolated_test')))
		return false;
	let sections = [ raw.main, raw.dns, raw.update, raw.probe, raw.sub,
		raw.hosts[0], raw.subscriptions.subscription_name, raw.nodes.node_name ];
	return length(filter(sections, s => join(',', keys(s)) != 'marker')) == 0;
}

function inventory_test() {
	let config_source = fs.readfile(ROOT + '/aether-proxy/src/lib/config.uc');
	let sub_source = fs.readfile(ROOT + '/aether-proxy/src/lib/sub.uc');
	if (config_source == null || sub_source == null)
		die('cannot read raw reader sources');
	// Guard the architectural requirement, not only equivalent runtime behavior.
	return length(match(config_source, /\[ 'main', 'dns', 'update', 'probe', 'sub' \]/g) ?? []) == 1
		&& index(config_source, 'normalize(read_raw(cursor, C.UCI_PACKAGE))') >= 0
		&& index(sub_source, 'config.normalize(config.read_raw(cursor, C.SUB_SNAPSHOT_PACKAGE))') >= 0
		&& match(sub_source, /cursor\.foreach\(/) == null
		&& match(sub_source, /\[ 'main', 'dns'/) == null;
}

export function run(c) {
	switch (c.kind) {
	case 'normalize':
		return effective(normalized(c.common, c.overrides));
	case 'fixture':
		return effective(config.load(uci.cursor(ROOT + '/tests/fixtures/t917-sub-defaults')));
	case 'invalid':
		let result = normalized({ interval_hours: '-1', fetch_via: 'foo' },
			{ interval_hours: '1.5', fetch_via: 'foo' });
		return map(result.errors ?? [], e => e.field + ':' + e.code);
	case 'negative':
		return map(normalized(null, { interval_hours: '-1' }).errors ?? [], e => e.field + ':' + e.code);
	case 'fractional':
		return map(normalized({ interval_hours: '1.5' }, {}).errors ?? [], e => e.field + ':' + e.code);
	case 'schema':
		return map(filter(SCHEMA.subscription,
			f => f.name in [ 'user_agent', 'fetch_via', 'interval_hours' ]), f => f.default);
	case 'reader':
		return reader_test();
	case 'inventory':
		return inventory_test();
	}
	die('unknown subscription defaults test kind');
};
