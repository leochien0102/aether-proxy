'use strict';

// Cover the first-line-only contract from docs/04 "components" versions.
import * as versions from 'aetherproxy.component_version';

export const cases = [
	{ name: 'Xray real banner multiline',
		text: 'Xray 26.9.30 (Xray, Penetrates Everything.)\nOther line', want: '26.9.30', expect: 'PASS' },
	{ name: 'ChinaDNS real banner multiline',
		text: 'ChinaDNS-NG 2025.06.20 be347b5 | fixture\nOther line', want: '2025.06.20', expect: 'PASS' },
	{ name: 'empty output', text: '', want: null, expect: 'PASS' },
	{ name: 'single field', text: 'Xray', want: null, expect: 'PASS' },
	{ name: 'empty first line', text: '\nXray 26.9.30', want: null, expect: 'PASS' },
	{ name: 'whitespace separated CRLF',
		text: '  Xray\t26.9.30  more\r\n', want: '26.9.30', expect: 'PASS' }
];

// Each valid pair is checked in both directions; unknowns must never coerce to zero.
for (let pair in [
	[ '26.3.26', '26.3.27', -1 ], [ '26.3.27', '26.3.27', 0 ], [ '26.3.28', '26.3.27', 1 ],
	[ '2025.08.08', '2025.08.09', -1 ], [ '2025.08.09', '2025.08.09', 0 ],
	[ '2025.08.10', '2025.08.09', 1 ], [ '26.10.21', '26.3.27', 1 ],
	[ '2025.12.31', '2026.1.1', -1 ], [ '1.2', '1.10', -1 ],
	[ 'v26.9.30', '26.3.27', 1 ], [ '26.9.30-r1', '26.9.30', 0 ],
	[ '26.9.30+abc', '26.9.30', 0 ], [ '26.9.30-r01+build.2', '26.9.30', 0 ],
	[ '026.003.027', '26.3.27', 0 ], [ '2025.08.009', '2025.8.9', 0 ],
	[ '1.2', '1.2.0.0', 0 ], [ '1.2.0.1', '1.2', 1 ], [ '0.0', '0.0.0', 0 ],
	[ '99999999999999999999999999.2', '99999999999999999999999998.10', 1 ]
])
	push(cases, { name: `numeric comparison ${pair[0]} vs ${pair[1]}`, kind: 'cmp',
		left: pair[0], right: pair[1], want: pair[2], expect: 'PASS' });

for (let bad in [ null, '', ' ', '26', 'v', '26..3', '.26.3', '26.3.', '26.-3', '-26.3',
	'26.3x', '26.3 beta', '26.3\n', '26.3-r', '26.3-rx', '26.3+', '26.3-rc1',
	'vv26.3', '0x1.2', 263, [], {} ])
	push(cases, { name: sprintf('unknown comparison %.J', bad), kind: 'cmp',
		left: bad, right: '26.3.27', want: null, expect: 'PASS' });

// Missing object fields are a distinct input from an explicitly null value.
push(cases, { name: 'missing version field comparison', kind: 'cmp',
	left: {}.version, right: '26.3.27', want: null, expect: 'PASS' });

export function run(c) {
	if (c.kind == 'cmp') {
		if (type(versions.version_cmp) != 'function')
			return 'FAIL: shared numeric comparator is missing';
		let got = versions.version_cmp(c.left, c.right);
		let reverse = versions.version_cmp(c.right, c.left);
		let want_reverse = c.want == null ? null : -c.want;
		return got === c.want && reverse === want_reverse ? 'PASS'
			: sprintf('FAIL: got %.J / reverse %.J, want %.J / %.J', got, reverse, c.want, want_reverse);
	}
	let got = versions.parse_version(c.text);
	return got == c.want ? 'PASS' : sprintf('FAIL: got %.J, want %.J', got, c.want);
};
