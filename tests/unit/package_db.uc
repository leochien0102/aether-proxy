'use strict';

// M4-19: package database parsing, canonical release strings and mismatch decisions.
import * as db from 'aetherproxy.package_db';
import * as versions from 'aetherproxy.component_version';

const OPKG = join('\n', [
	'Package: aether-proxy',
	'Version: 1.1.2-r1',
	'Architecture: all',
	'',
	'Package: aether-xray',
	'Version: 26.10.31-1',
	'',
	'Package: no-version',
	'Architecture: all',
	''
]);

const APK = join('\n', [
	'P:aether-proxy',
	'V:1.1.2-r1',
	'K:all',
	'',
	'P:aether-dns',
	'V:1.0.2-r1',
	''
]);

export const cases = [
	{ name: 'opkg parses package and version pairs', kind: 'opkg', text: OPKG,
		want: { 'aether-proxy': '1.1.2-r1', 'aether-xray': '26.10.31-1' }, expect: 'PASS' },
	{ name: 'opkg ignores a block without a version', kind: 'opkg', text: OPKG,
		absent: 'no-version', expect: 'PASS' },
	{ name: 'opkg empty text', kind: 'opkg', text: '', want: {}, expect: 'PASS' },
	{ name: 'opkg null text', kind: 'opkg', text: null, want: {}, expect: 'PASS' },
	{ name: 'apk parses P/V blocks', kind: 'apk', text: APK,
		want: { 'aether-proxy': '1.1.2-r1', 'aether-dns': '1.0.2-r1' }, expect: 'PASS' },
	{ name: 'apk ignores unrelated K fields', kind: 'apk', text: APK,
		absent: 'K', expect: 'PASS' },
	{ name: 'apk empty text', kind: 'apk', text: '', want: {}, expect: 'PASS' }
];

for (let pair in [
	[ '26.10.31-1', '26.10.31-r1' ], [ '26.10.31-r1', '26.10.31-r1' ],
	[ '1.0.2', '1.0.2' ], [ '1.0.0-beta-1', '1.0.0-beta-r1' ],
	[ '26.316.50246~0695113', '26.316.50246~0695113' ], [ '', null ], [ null, null ]
])
	push(cases, { name: `canonical release ${pair[0]}`, kind: 'normalize',
		input: pair[0], want: pair[1], expect: 'PASS' });

for (let pair in [
	[ '26.10.31-1', '26.10.31' ], [ '26.10.31-r1', '26.10.31' ],
	[ '1.0.2', '1.0.2' ], [ '', null ], [ null, null ]
])
	push(cases, { name: `release core ${pair[0]}`, kind: 'core',
		input: pair[0], want: pair[1], expect: 'PASS' });

for (let row in [
	[ '1.0.2-r1', '1.0.2', false ], [ '26.10.31-r1', '26.10.31', false ],
	[ '1.0.1-r1', '1.0.0', true ], [ null, '1.0.2', false ], [ '1.0.2', null, false ]
])
	push(cases, { name: `mismatch ${row[0]} vs ${row[1]}`, kind: 'mismatch',
		installed: row[0], banner: row[1], want: row[2], expect: 'PASS' });

export function run(test) {
	if (test.kind == 'opkg' || test.kind == 'apk') {
		let got = test.kind == 'opkg' ? db.parse_opkg(test.text) : db.parse_apk(test.text);
		if (test.absent != null)
			return got[test.absent] == null ? 'PASS'
				: sprintf('FAIL: unexpected %s in %.J', test.absent, got);
		let seen = 0;
		for (let key, value in test.want) {
			if (got[key] != value)
				return sprintf('FAIL: %s = %.J, expected %.J', key, got[key], value);
			seen++;
		}
		return length(keys(got)) == seen ? 'PASS'
			: sprintf('FAIL: got %.J, expected %.J', got, test.want);
	}
	if (test.kind == 'normalize') {
		let got = versions.normalize_release(test.input);
		return got == test.want ? 'PASS' : sprintf('FAIL: got %.J, expected %.J', got, test.want);
	}
	if (test.kind == 'core') {
		let got = versions.release_core(test.input);
		return got == test.want ? 'PASS' : sprintf('FAIL: got %.J, expected %.J', got, test.want);
	}
	if (test.kind == 'mismatch') {
		let got = versions.version_mismatch(test.installed, test.banner);
		return got === test.want ? 'PASS' : sprintf('FAIL: got %.J, expected %.J', got, test.want);
	}
	return 'FAIL: unknown case kind';
};
