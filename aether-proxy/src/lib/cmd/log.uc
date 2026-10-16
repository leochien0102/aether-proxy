'use strict';

// `aether-proxy log` (docs/10 "`log`、`node import`、`custom`", docs/09 "子进程日志").
//
// Xray and chinadns-ng inherit the daemon's stdout/stderr, so all three share the
// `aether-proxy` syslog tag; the source is told apart by the message format:
//   xray          `2026/10/16 12:00:00.123456 [Warning] …`
//   dns (chinadns-ng) `[main.zig:123] …`
//   aether-proxy  everything else
// Both child formats are inferred from the upstream sources; docs/10 says to re-check them
// during the T8.13 on-device acceptance and adjust these two rules if they differ.

import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';
import * as sys from 'aetherproxy.sys';

const XRAY_LINE_RE = /^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:.]+ \[(Debug|Info|Warning|Error)\]/;
const DNS_LINE_RE = /\[[A-Za-z0-9_]+\.zig:[0-9]+/;
const TAG = 'aether-proxy[';

// Pure: source class of one syslog message (docs/10).
export function classify(message) {
	if (match(message ?? '', XRAY_LINE_RE) != null)
		return 'xray';
	if (match(message ?? '', DNS_LINE_RE) != null)
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

export function run(args) {
	let parsed = parse_args(args);
	if (parsed.error)
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			{ ok: false, code: 'USAGE', detail: parsed.error }, 2, parsed.error);

	// A missing or failing logread is the documented CMD_FAILED case (docs/10); sys.run
	// records the CMD_FAILED event itself.
	let res = sys.run([ 'logread' ], { timeout: C.LOGREAD_TIMEOUT_SECS });
	if (res.code != 0)
		return pipeline.finish(parsed.opts,
			{ ok: false, code: 'CMD_FAILED',
			  detail: `logread exited ${res.code}${res.timed_out ? ' (timeout)' : ''}: ${trim(res.stderr)}` },
			1, 'logread is unavailable');

	let lines = select_lines(res.stdout, parsed.opts.source, parsed.opts.lines);
	return pipeline.finish(parsed.opts,
		{ ok: true, source: parsed.opts.source, lines }, 0, human(lines, parsed.opts.source));
};
