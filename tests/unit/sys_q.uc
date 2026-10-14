'use strict';
// sys.q(): shell single-quote escaping (docs/12-ucode.md, coding rule 2).
// Each case is also round-tripped through a real shell: `printf %s <q(arg)>` must print arg back.

import { q } from 'aetherproxy.sys';
import * as fs from 'fs';

export const cases = [
	{ name: 'empty string',     arg: '',            expect: "''" },
	{ name: 'plain word',       arg: 'abc',         expect: "'abc'" },
	{ name: 'space',            arg: 'a b',         expect: "'a b'" },
	{ name: 'single quote',     arg: "it's",        expect: "'it'\\''s'" },
	{ name: 'only quote',       arg: "'",           expect: "''\\'''" },
	{ name: 'newline',          arg: "a\nb",         expect: "'a\nb'" },
	{ name: 'dollar',           arg: '$HOME ${x}',  expect: "'$HOME ${x}'" },
	{ name: 'backtick',         arg: '`id` $(id)',  expect: "'`id` $(id)'" },
	{ name: 'double quote, \\', arg: '"a\\b"',      expect: "'\"a\\b\"'" },
];

// NOTE: with the pinned ucode, `export function f() {...}` must be terminated by `;`.
export function run(c) {
	let quoted = q(c.arg);

	let p = fs.popen('printf %s ' + quoted, 'r');
	if (p == null)
		return 'ROUNDTRIP-ERROR: popen failed: ' + fs.error();
	let out = p.read('all');
	p.close();
	if (out != c.arg)
		return sprintf('ROUNDTRIP-MISMATCH: shell printed %.J', out);

	return quoted;
};
