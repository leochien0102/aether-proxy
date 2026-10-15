'use strict';

import * as state from 'aetherproxy.state';
import * as fs from 'fs';

const DIR = `/tmp/aether-proxy-test-state.${fs.readlink('/proc/self')}`;

export const cases = [
	{ name: 'valid state.json is returned', content: '{"state":"running"}', expect: 'running' },
	{ name: 'corrupt state.json returns null with an error instead of throwing', content: '{broken', expect: 'error' },
	{ name: 'non-object state.json returns null with an error', content: '[1,2]', expect: 'error' }
];

export function run(c) {
	fs.mkdir(DIR);
	fs.writefile(`${DIR}/state.json`, c.content);
	let got = state.read(DIR);
	let err = state.error();
	fs.unlink(`${DIR}/state.json`);
	fs.rmdir(DIR);
	if (got == null)
		return err != null ? 'error' : 'null without error';
	return got.state;
};
