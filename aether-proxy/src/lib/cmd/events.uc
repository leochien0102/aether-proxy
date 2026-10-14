'use strict';

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';

const LEVELS = [ 'error', 'warn', 'notice', 'info', 'debug' ];

// `level` is an exact-match filter; docs/10 does not define threshold semantics.
export function filter_events(events, since, level) {
	let out = [];

	// TODO(design): use an inclusive lower bound; docs/10 does not define --since boundary semantics.
	for (let event in events) {
		if (since != null && event.ts < since)
			continue;
		if (level != null && event.level != level)
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

	let events = [];
	let lines = split(text, '\n');
	for (let i, line in lines) {
		if (line == '' && i == length(lines) - 1)
			continue;
		if (line == '')
			return { error: `parse ${path}: empty line ${i + 1}`, path };

		let event = json(line);
		// TODO(design): docs/09 does not define recovery from a corrupt JSONL row; fail closed.
		if (type(event) != 'object' || (type(event.ts) != 'int' && type(event.ts) != 'double')
			|| index(LEVELS, event.level) < 0 || type(event.code) != 'string' || type(event.args) != 'object')
			return { error: `parse ${path}: invalid event on line ${i + 1}`, path };

		push(events, event);
	}

	return { events };
};

function usage(args, detail) {
	let json = index(args, '--json') >= 0;
	return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail, errors: [] }, 2, detail);
}

function event_error(opts, err) {
	// Do not append an error event to the same JSONL file that failed to parse or read.
	return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: err.error }, 1, err.error);
}

function human_events(events) {
	if (!length(events))
		return 'No events.';

	return join('\n', map(events, event =>
		`${event.ts} ${event.level} ${event.code} ${sprintf('%J', event.args)}`));
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
	return pipeline.finish(opts, { ok: true, events: selected }, 0, human_events(selected));
};
