'use strict';

// `aether-proxy log` (docs/10 "`log`、`node import`、`custom`", docs/09 "子进程日志").
//
// Xray and chinadns-ng inherit the daemon's stdout/stderr, so all three share the
// `aether-proxy` syslog tag; the source is told apart by the message format:
//   xray          `2026/10/16 12:00:00.123456 [Warning] …`
//   dns (chinadns-ng) `[main.zig:164 main] …` or `[dnl.c:541 dnl_init] …`
//   aether-proxy  everything else
// The on-device log check recorded in docs/10 also found C source locations and ANSI colors.

import * as C from 'aetherproxy.const';
import * as logtrim from 'aetherproxy.logtrim';
import * as pipeline from 'aetherproxy.pipeline';
import * as fs from 'fs';

const XRAY_LINE_RE = /^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:.]+ \[(Debug|Info|Warning|Error)\]/;
const DNS_LINE_RE = /\[[A-Za-z0-9_]+\.(zig|c):[0-9]+/;
const ANSI_COLOR_RE = /\x1b\[[0-9;]*m/g;
const TAG = 'aether-proxy[';

// Pure: source class of one syslog message (docs/10).
export function classify(message) {
	// Strip SGR only for matching: select_lines must retain the original bytes for display.
	let plain = replace(message ?? '', ANSI_COLOR_RE, '');
	if (match(plain, XRAY_LINE_RE) != null)
		return 'xray';
	if (match(plain, DNS_LINE_RE) != null)
		return 'dns';
	return 'aether-proxy';
};

// Returns the message after the `aether-proxy[<pid>]: ` tag, or null when the line is not
// tagged for us. The tag must be preceded by `<facility>.<level> ` so that a message which
// merely quotes a similar string is not mistaken for one of ours (docs/10 line shape).
// The pinned ucode's index() has no start offset, so the search resumes via substr().
function message_of(line) {
	let from = 0;

	for (;;) {
		let at = index(substr(line, from), TAG);
		if (at < 0)
			return null;

		let abs = from + at;
		let head_ok = abs > 0 && match(substr(line, 0, abs), /[a-z0-9]+\.[a-z]+[[:space:]]*$/) != null;
		let close = head_ok ? index(substr(line, abs), ']: ') : -1;
		let pid = (close > 0) ? substr(line, abs + length(TAG), close - length(TAG)) : null;

		if (pid != null && match(pid, /^[0-9]+$/) != null)
			return substr(line, abs + close + 3);

		from = abs + 1;
	}
};

// Pure: classify the tagged lines, keep the requested source, return the last n in their
// original order. Each entry carries the original full line (docs/10 output shape).
export function select_lines(text, source, n) {
	let kept = [];

	for (let line in split(text ?? '', '\n')) {
		if (line == '')
			continue;

		let message = message_of(line);
		if (message == null)
			continue;

		let class_of = classify(message);
		if (source != 'all' && class_of != source)
			continue;

		push(kept, { source: class_of, text: line });
	}

	return length(kept) > n ? slice(kept, length(kept) - n) : kept;
};

function parse_args(args) {
	let opts = { source: 'all', lines: C.LOG_LINES_DEFAULT };
	let seen = {};

	for (let i = 0; i < length(args); i++) {
		let arg = args[i];

		if (arg == '--json') {
			opts.json = true;
			continue;
		}

		if (arg == '--run-dir' && i + 1 < length(args)) {
			opts.run_dir = args[++i];
			continue;
		}
		if (arg != '--source' && arg != '--lines')
			return { error: `unknown option ${arg}` };

		if (i + 1 >= length(args))
			return { error: `option ${arg} needs a value` };

		let value = args[++i];
		let key = substr(arg, 2);

		if (seen[key])
			return { error: `option ${arg} may be specified only once` };
		seen[key] = true;

		if (key == 'source') {
			if (index(C.LOG_SOURCES, value) < 0)
				return { error: `--source must be one of ${join('|', C.LOG_SOURCES)}` };
			opts.source = value;
		}
		else if (match(value, /^[0-9]+$/) == null || +value < 1 || +value > C.LOG_LINES_MAX) {
			return { error: `--lines must be an integer between 1 and ${C.LOG_LINES_MAX}` };
		}
		else {
			opts.lines = +value;
		}
	}

	return { opts };
};

function human(lines, source) {
	if (!length(lines))
		return `no ${source == 'all' ? '' : source + ' '}log lines`;

	return join('\n', map(lines, l => l.text));
}

// Truncate in place: the collector may still hold the live inode open. Atomic
// replacement (the normal config-write rule) would leave it writing an old file.
function clear_logs(args) {
	let opts = { json: true, run_dir: C.RUN_DIR };
	for (let i = 0; i < length(args); i++) {
		if (args[i] == '--json')
			continue;
		if (args[i] == '--run-dir' && i + 1 < length(args)) {
			opts.run_dir = args[++i];
			continue;
		}
		return pipeline.finish(opts,
			{ ok: false, code: 'USAGE', detail: `unknown clear option ${args[i]}` }, 2);
	}

	for (let name in [ C.RAW_LOG_FILE, `${C.RAW_LOG_FILE}.1`, C.EVENTS_FILE ]) {
		let path = `${opts.run_dir}/${name}`;
		// This ucode version may lose open() errno; stat distinguishes missing
		// files from permission/I/O failures. r+ never creates a vanished file.
		if (fs.stat(path) == null) {
			let error = fs.error() ?? 'unknown error';
			if (error == 'No such file or directory')
				continue;
			return pipeline.finish(opts,
				{ ok: false, code: 'FS_FAILED', detail: `stat ${path}: ${error}` }, 1);
		}
		let file = fs.open(path, 'r+');
		if (file == null)
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED',
				detail: `open ${path}: ${fs.error() ?? 'unknown error'}` }, 1);
		let truncated = file.truncate(0);
		let error = truncated ? null : (file.error() ?? 'unknown error');
		let closed = file.close();
		if (!truncated || !closed)
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED',
				detail: `clear ${path}: ${error ?? fs.error() ?? 'close failed'}` }, 1);
	}
	return pipeline.finish(opts, { ok: true }, 0);
}

// The open handle is retained from read through rewrite: never replace the collector's inode.
function trim_file(path, kind, since, now) {
	if (fs.stat(path) == null) {
		let error = fs.error() ?? 'unknown error';
		return error == 'No such file or directory' ? { kept: 0, dropped: 0 }
			: { error: `stat ${path}: ${error}` };
	}
	let file = fs.open(path, 'r+');
	if (file == null)
		return { error: `open ${path}: ${fs.error() ?? 'unknown error'}` };
	let text = file.read('all');
	let error = file.error();
	let result;
	if (text == null || error != null) {
		error ??= 'read failed';
	}
	else {
		result = logtrim.filter_text(text, kind, since, now);
		if (!file.seek(0) || file.write(result.text) != length(result.text))
			error = file.error() ?? 'rewrite failed';
		// seek flushes stdio output before ftruncate, including the empty-file case.
		else if (!file.seek(length(result.text)) || !file.truncate(length(result.text)))
			error = file.error() ?? 'truncate failed';
	}
	if (!file.close())
		error ??= fs.error() ?? 'close failed';
	return error != null ? { error: `truncate ${path}: ${error}` } : result;
}

function truncate_logs(args) {
	let opts = { json: index(args, '--json') >= 0, run_dir: C.RUN_DIR };
	let seen = {};
	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json')
			continue;
		if ((arg != '--since' && arg != '--run-dir') || seen[arg] || i + 1 >= length(args))
			return pipeline.finish(opts, { ok: false, code: 'USAGE', detail: `invalid option ${arg}` },
				2, `invalid option ${arg}`);
		seen[arg] = true;
		let value = args[++i];
		if (arg == '--run-dir' && length(value) && substr(value, 0, 2) != '--') {
			opts.run_dir = value;
			continue;
		}
		if (arg != '--since' || match(value, /^[0-9]+$/) == null || !logtrim.valid_epoch(+value))
			return pipeline.finish(opts, { ok: false, code: 'USAGE', detail: `invalid ${arg} value` },
				2, `invalid ${arg} value`);
		opts.since = +value;
	}
	if (opts.since == null) {
		let path = `${opts.run_dir}/${C.STATE_FILE}`;
		let present = fs.stat(path);
		let stat_error = present == null ? fs.error() : null;
		if (present == null && stat_error != 'No such file or directory')
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: `stat ${path}: ${stat_error}` },
				1, `stat ${path}: ${stat_error}`);
		let text = present != null ? fs.readfile(path) : null;
		if (present != null && text == null)
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: `read ${path} failed` },
				1, `read ${path} failed`);
		let state;
		if (text != null) {
			try { state = json(text); }
			catch (e) { state = null; } // A corrupt marker is not an authoritative startup time.
		}
		// Older daemons only published since; new snapshots keep startup independent of transitions.
		let marker = state?.started_at ?? state?.since;
		if (!logtrim.valid_epoch(marker))
			return pipeline.finish(opts, { ok: false, code: 'NOT_RUNNING', detail: 'no valid startup marker' },
				2, 'no valid startup marker');
		opts.since = marker;
	}
	let result = { ok: true, since: opts.since, kept: {}, dropped: {} };
	let names = { events: C.EVENTS_FILE, raw: C.RAW_LOG_FILE, raw1: `${C.RAW_LOG_FILE}.1` };
	let now = time();
	for (let kind, name in names) {
		let filtered = trim_file(`${opts.run_dir}/${name}`, kind, opts.since, now);
		if (filtered.error)
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: filtered.error },
				1, filtered.error);
		result.kept[kind] = filtered.kept;
		result.dropped[kind] = filtered.dropped;
	}
	return pipeline.finish(opts, result, 0, sprintf('logs truncated since %s: %.J', opts.since, result.kept));
}

function read_logstats(path) {
	if (fs.lstat(path)?.type != 'file')
		return null;
	let text = fs.readfile(path);
	let row;
	// A snapshot may be unreadable or momentarily incomplete while awk replaces its contents.
	try { row = text != null ? json(text) : null; }
	catch (e) { return null; }
	if (type(row) != 'object' || type(row.name) != 'string' || !length(row.name))
		return null;
	for (let key in [ 'accepted', 'dropped', 'second_limit', 'minute_limit' ]) {
		if (type(row[key]) != 'int' || row[key] < 0)
			return null;
	}
	for (let key in [ 'first_drop', 'last_drop' ]) {
		if (row[key] != null && type(row[key]) != 'int')
			return null;
	}
	return row;
}

function log_stats(args) {
	let opts = { json: index(args, '--json') >= 0, run_dir: C.RUN_DIR };
	let seen_dir = false;
	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json')
			continue;
		let value = args[i + 1];
		if (arg == '--run-dir' && !seen_dir && value && substr(value, 0, 2) != '--') {
			seen_dir = true;
			opts.run_dir = value;
			i++;
			continue;
		}
		let detail = `invalid log stats option ${arg}`;
		return pipeline.finish(opts, { ok: false, code: 'USAGE', detail }, 2, detail);
	}

	let files = fs.lsdir(opts.run_dir);
	if (files == null) {
		let error = fs.error();
		if (error != 'No such file or directory') {
			let detail = `list ${opts.run_dir}: ${error ?? 'unknown error'}`;
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail }, 1, detail);
		}
	}
	let rows = [];
	for (let file in sort(files ?? [])) {
		if (substr(file, -length(C.CHILD_LOG_STATS_SUFFIX)) != C.CHILD_LOG_STATS_SUFFIX)
			continue;
		let row = read_logstats(`${opts.run_dir}/${file}`);
		if (row != null)
			push(rows, row);
	}
	let table = [ 'NAME\tACCEPTED\tDROPPED\tFIRST_DROP\tLAST_DROP\tSECOND_LIMIT\tMINUTE_LIMIT' ];
	for (let row in rows) {
		push(table, join('\t', [ row.name, row.accepted, row.dropped, row.first_drop ?? '-',
			row.last_drop ?? '-', row.second_limit, row.minute_limit ]));
	}
	return pipeline.finish(opts, { ok: true, stats: rows }, 0, join('\n', table));
}

export function run(args) {
	if (args[0] == 'stats')
		return log_stats(slice(args, 1));
	if (args[0] == 'truncate')
		return truncate_logs(slice(args, 1));
	if (args[0] == 'clear')
		return clear_logs(slice(args, 1));
	let parsed = parse_args(args);
	if (parsed.error)
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			{ ok: false, code: 'USAGE', detail: parsed.error }, 2, parsed.error);

	let dir = parsed.opts.run_dir ?? C.RUN_DIR;
	let text = '';
	// Previous segment precedes the live segment, regardless of wall-clock jumps.
	for (let name in [ `${C.RAW_LOG_FILE}.1`, C.RAW_LOG_FILE ]) {
		let path = `${dir}/${name}`;
		let data = fs.readfile(path);
		if (data == null && fs.stat(path) != null)
			return pipeline.finish(parsed.opts,
				{ ok: false, code: 'FS_FAILED', detail: `cannot read ${path}` }, 1, `cannot read ${path}`);
		text += (data ?? '') + '\n';
	}
	let lines = select_lines(text, parsed.opts.source, parsed.opts.lines);
	return pipeline.finish(parsed.opts,
		{ ok: true, source: parsed.opts.source, lines }, 0, human(lines, parsed.opts.source));
};
