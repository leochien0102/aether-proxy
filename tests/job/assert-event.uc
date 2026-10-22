'use strict';

// Check the worker's single CMD_FAILED and its exact args, per docs/09 and T9.15.
// Derive cmd from the saved argv so quoting/options are checked without temp paths in goldens.
import * as fs from 'fs';

let events_path = ARGV[0];
let job = json(fs.readfile(ARGV[1]));
let expected = json(ARGV[3]);
let text = fs.readfile(events_path);
if (text == null && fs.error() != 'No such file or directory')
	die(`cannot read ${events_path}\n`);
let events = [];
for (let line in split(trim(text ?? ''), '\n')) {
	if (line == '')
		continue;
	let event = json(line);
	if (event.code == 'CMD_FAILED')
		push(events, event);
}
if (expected == null) {
	if (length(events) != 0)
		die(`expected no CMD_FAILED, got ${length(events)}\n`);
	exit(0);
}
if (length(events) != 1)
	die(`expected one CMD_FAILED, got ${length(events)}\n`);
let argv = [ ARGV[2], ...job.argv ];
if (index(argv, '--json') < 0)
	push(argv, '--json');
expected.cmd = join(' ', argv);
let event = events[0];
if (event.level != 'error')
	die(`expected error level, got ${event.level}\n`);
if (join(',', sort(keys(event.args))) != join(',', sort(keys(expected))))
	die(`unexpected event fields: ${sprintf('%.J', event.args)}\n`);
for (let key in keys(expected))
	if (sprintf('%.J', event.args[key]) != sprintf('%.J', expected[key]))
		die(`unexpected ${key}: ${sprintf('%.J', event.args[key])}\n`);
