'use strict';

// Cover the first-line-only contract from docs/04 "components" versions.
import { parse_version } from 'aetherproxy.component_version';

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

export function run(c) {
	let got = parse_version(c.text);
	return got == c.want ? 'PASS' : sprintf('FAIL: got %.J, want %.J', got, c.want);
};
