'use strict';
// Test helper: reads one JSON document from stdin and prints the value at a dotted path
// (array indexes as numbers), or the word "<missing>". Objects and arrays print as JSON.
// Usage: ... | tests/host/ucode tests/cli/jget.uc -- ok.path

import * as fs from 'fs';

let doc = json(fs.stdin.read('all'));
let cur = doc;

if (doc == null) {
	print('<invalid-json>\n');
	exit(0);
}

for (let part in split(ARGV[0] ?? '', '.')) {
	if (part == '')
		continue;

	cur = (type(cur) == 'array') ? cur[+part] : cur?.[part];
}

if (cur == null)
	print('<missing>\n');
else if (type(cur) == 'object' || type(cur) == 'array')
	print(sprintf('%.J', cur), '\n');
else
	print(cur, '\n');
