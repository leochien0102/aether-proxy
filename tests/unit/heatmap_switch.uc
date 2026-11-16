'use strict';

// T12.2 B25 switch: `config stats 'stats'` with heatmap_enabled defaulting to off
// (docs/05, docs/b25-heatmap.md). A missing section, an unset option, an empty value
// and anything other than '1' are all off without a config error, so an upgraded
// configuration stays closed and a hand-edited value cannot fail the service.
// The sampling/persistence/API layers do not exist yet (T12.3+); this card only
// pins the switch and the closed default.

import * as fs from 'fs';
import * as uci from 'uci';
import { SCHEMA } from 'aetherproxy.schema';
import * as config from 'aetherproxy.config';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');

function heatmap(result) {
	if (!result.ok)
		return { ok: false, errors: map(result.errors ?? [], e => e.field + ':' + e.code) };
	return { ok: true, heatmap_enabled: result.snapshot.stats.heatmap_enabled };
}

// Load the packaged default file through a real UCI cursor (docs/05 「默认配置文件」).
function shipped_default() {
	let base = `/tmp/aether-proxy-t122-${fs.readlink('/proc/self')}-${time()}`;
	fs.mkdir(base);
	fs.writefile(`${base}/aetherproxy`, fs.readfile(ROOT + '/aether-proxy/files/aether-proxy.config'));
	let r = heatmap(config.load(uci.cursor(base)));
	fs.unlink(`${base}/aetherproxy`);
	fs.rmdir(base);
	return r;
}

function fixture_load(dir) {
	return heatmap(config.load(uci.cursor(ROOT + '/tests/fixtures/' + dir)));
}

export const cases = [
	{
		name: 'T12.2 schema declares heatmap_enabled as an off-by-default lenient bool',
		kind: 'schema',
		expect: [ { name: 'heatmap_enabled', type: 'bool', default: false, off_unless_one: true } ]
	},
	{
		name: 'T12.2 section absent (upgraded config) is off without errors',
		kind: 'raw', raw: {},
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 absent section object is off',
		kind: 'raw', raw: { stats: null },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 empty section is off',
		kind: 'raw', raw: { stats: {} },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 explicit 0 is off',
		kind: 'raw', raw: { stats: { heatmap_enabled: '0' } },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 empty value is off without errors',
		kind: 'raw', raw: { stats: { heatmap_enabled: '' } },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 explicit 1 is on',
		kind: 'raw', raw: { stats: { heatmap_enabled: '1' } },
		expect: { ok: true, heatmap_enabled: true }
	},
	{
		name: 'T12.2 non-1 values are off without a config error',
		kind: 'raw', raw: { stats: { heatmap_enabled: 'true' } },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 junk values are off without a config error',
		kind: 'raw', raw: { stats: { heatmap_enabled: 'yes' } },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 padded 1 is off (only the exact value enables)',
		kind: 'raw', raw: { stats: { heatmap_enabled: ' 1' } },
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 packaged default configuration loads with the switch off',
		kind: 'shipped',
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 pre-B25 fixture (no stats section) stays off',
		kind: 'fixture', dir: 't923-default',
		expect: { ok: true, heatmap_enabled: false }
	},
	{
		name: 'T12.2 fixture with heatmap_enabled=1 reads back on',
		kind: 'fixture', dir: 't122-heatmap-on',
		expect: { ok: true, heatmap_enabled: true }
	}
];

export function run(c) {
	switch (c.kind) {
	case 'schema':
		return SCHEMA.stats;
	case 'raw':
		return heatmap(config.normalize(c.raw));
	case 'shipped':
		return shipped_default();
	case 'fixture':
		return fixture_load(c.dir);
	}
	die('unknown heatmap switch test kind');
};
