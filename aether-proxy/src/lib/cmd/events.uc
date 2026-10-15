'use strict';

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';

const LEVELS = [ 'error', 'warn', 'notice', 'info', 'debug' ];
const LEVEL_RANK = { error: 0, warn: 1, notice: 2, info: 3, debug: 4 };

// A requested level includes events at that severity and all more severe levels.
export function filter_events(events, since, level) {
	let out = [];

	for (let event in events) {
		if (since != null && event.ts < since)
			continue;
		if (level != null && LEVEL_RANK[event.level] > LEVEL_RANK[level])
			continue;
		push(out, event);
	}

	return out;
};

function parse_args(args) {
	let opts = { json: false, run_dir: C.RUN_DIR, since: null, level: null };
	let seen = {};

	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json') {
			opts.json = true;
			continue;
		}

		if (arg == '--run-dir' || arg == '--since' || arg == '--level') {
			if (i + 1 >= length(args))
				return { error: `option ${arg} needs a value` };

			let value = args[++i];
			let key = arg == '--run-dir' ? 'run_dir' : substr(arg, 2);
			if (seen[key])
				return { error: `option ${arg} may be specified only once` };
			seen[key] = true;

			if (key == 'since') {
				if (match(value, /^[0-9]+$/) == null)
					return { error: '--since must be a non-negative integer timestamp' };
				opts.since = +value;
			}
			else if (key == 'level') {
				if (index(LEVELS, value) < 0)
					return { error: `--level must be one of ${join('|', LEVELS)}` };
				opts.level = value;
			}
			else {
				opts.run_dir = value;
			}
			continue;
		}

		return { error: `unknown option ${arg}` };
	}

	log.set_run_dir(opts.run_dir);
	return { opts };
};

function load_events(run_dir) {
	let path = run_dir + '/' + C.EVENTS_FILE;
	let stat = fs.stat(path);
	if (stat == null) {
		let detail = fs.error() ?? 'unknown error';
		if (detail == 'No such file or directory')
			return { events: [] };
		return { error: `stat ${path}: ${detail}`, path };
	}

	let text = fs.readfile(path);
	if (text == null)
		return { error: `read ${path}: ${fs.error() ?? 'unknown error'}`, path };
	if (text == '')
		return { events: [], skipped: 0 };

	let events = [];
	let skipped = 0;
	let lines = split(text, '\n');
	let count = length(lines);
	if (lines[count - 1] == '')
		count--;

	for (let i = 0; i < count; i++) {
		let line = trim(lines[i]);
		if (line == '') {
			skipped++;
			continue;
		}

		let event;
		try {
			event = json(line);
		}
		catch (e) {
			skipped++;
			continue;
		}

		if (type(event) != 'object' || (type(event.ts) != 'int' && type(event.ts) != 'double')
			|| index(LEVELS, event.level) < 0 || type(event.code) != 'string' || type(event.args) != 'object') {
			skipped++;
			continue;
		}

		push(events, event);
	}

	return { events, skipped };
};

function usage(args, detail) {
	let json = index(args, '--json') >= 0;
	return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail, errors: [] }, 2, detail);
}

function event_error(opts, err) {
	// Do not append an error event to the same JSONL file that failed to parse or read.
	return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: err.error }, 1, err.error);
}

function human_events(events, skipped) {
	let lines = [];
	if (!length(events))
		push(lines, 'No events.');
	else
		for (let event in events)
			push(lines, `${event.ts} ${event.level} ${event.code} ${sprintf('%J', event.args)}`);

	if (skipped)
		push(lines, `Skipped malformed event lines: ${skipped}`);

	return join('\n', lines);
}

export function run(args) {
	let parsed = parse_args(args);
	if (parsed.error)
		return usage(args, parsed.error);

	let opts = parsed.opts;
	let loaded = load_events(opts.run_dir);
	if (loaded.error)
		return event_error(opts, loaded);

	let selected = filter_events(loaded.events, opts.since, opts.level);
	return pipeline.finish(opts, { ok: true, events: selected, skipped: loaded.skipped }, 0,
		human_events(selected, loaded.skipped));
};
