'use strict';

import * as pipeline from 'aetherproxy.pipeline';

export const cases = [
	{ name: 'legacy validator stderr retained', main: {}, expect: 'bad config' },
	{ name: 'legacy validator stdout fallback retained', main: {}, stdout: true, expect: 'bad config' }
];
for (let field in ['socks_username', 'socks_password', 'http_username', 'http_password'])
	push(cases, { name: field + ' hides raw engine diagnostics even when disabled', field,
		expect: 'Xray validation failed (exit 1); engine output withheld for explicit proxy credentials' });

export function run(c) {
	let main = c.main ?? { socks_enabled: false, http_enabled: false };
	if (c.field)
		main[c.field] = 'LOCAL_SECRET"\\';
	let text = c.field ? 'LOCAL_SECRET"\\ LOCAL_SECRET\\"\\\\' : ' bad config\n';
	return pipeline.xray_validation_detail({main}, { code: 1, stderr: c.stdout ? '' : text, stdout: text });
};
