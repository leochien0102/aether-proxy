'use strict';

import * as fs from 'fs';
import { parse_domains, parse_cidrs } from 'aetherproxy.data';

if (length(ARGV) != 1)
	die('usage: verify.uc <data-directory>');

let dir = ARGV[0];
let total_errors = 0;

for (let file in [ 'gfwlist.txt', 'chnlist.txt', 'apple.txt' ]) {
	let path = dir + '/' + file;
	let text = fs.readfile(path);

	if (text == null)
		die(`cannot read ${path}: ${fs.error() ?? 'unknown error'}`);

	let result = parse_domains(text);
	print(`${file}: ${length(result.items)} items, ${length(result.errors)} errors\n`);
	for (let error in result.errors)
		print(`  line ${error.line}: ${error.text}\n`);
	total_errors += length(result.errors);
}

for (let file in [ 'chnroute4.txt', 'gfw_static4.txt' ]) {
	let path = dir + '/' + file;
	let text = fs.readfile(path);

	if (text == null)
		die(`cannot read ${path}: ${fs.error() ?? 'unknown error'}`);

	let result = parse_cidrs(text);
	print(`${file}: ${length(result.items)} items, ${length(result.errors)} errors\n`);
	for (let error in result.errors)
		print(`  line ${error.line}: ${error.text}\n`);
	total_errors += length(result.errors);
}

if (total_errors)
	exit(1);
