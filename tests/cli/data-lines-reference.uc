'use strict';

// T10.7 semantic oracle: keep the former ucode counting algorithm independent
// of grep so whitespace, comments and an unterminated final line cannot drift.
import * as fs from 'fs';

let counts = {};
for (let path in ARGV) {
	let text = fs.readfile(path);
	if (text == null)
		die(`cannot read reference data ${path}: ${fs.error() ?? 'unknown error'}`);
	let lines = 0;
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (length(line) && substr(line, 0, 1) != '#')
			lines++;
	}
	counts[path] = lines;
}
print(sprintf('%.J', counts) + '\n');
