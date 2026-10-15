'use strict';

import * as fs from 'fs';
import * as syslog from 'log';
import * as C from 'aetherproxy.const';

// Event catalog from docs/09-logging.md. Codes are a machine protocol: only append.
// The value is the default level, used when the caller passes level == null.
const EVENTS = {
	SERVICE_STARTED: 'notice', SERVICE_STOPPED: 'notice',
	BUSY: 'warn',
	CONFIG_INVALID: 'error',
	PRECHECK_FAILED: 'error',
	RENDER_INVALID: 'error',
	START_FAILED: 'error', START_RETRY: 'warn',
	JOB_LOST: 'warn',
	NET_WAIT_TIMEOUT: 'warn',
	COMPONENT_MISSING: 'error', COMPONENT_TOO_OLD: 'error',
	NODE_RESOLVE_FALLBACK: 'warn', NODE_RESOLVE_FAILED: 'error',
	NODE_IP_CHANGED: 'notice',
	NODE_STALE: 'warn', NODE_STALE_IN_USE: 'warn',
	NODE_INSECURE_IGNORED: 'warn',
	PROXY_HEALTHY: 'notice', PROXY_UNHEALTHY: 'warn',
	DNS_TIER_CHANGED: 'warn',
	XRAY_DOWN_FAILOPEN: 'error', XRAY_DOWN: 'error', XRAY_RECOVERED: 'notice',
	DNS_DOWN_FAILSAFE: 'error', DNS_RECOVERED: 'notice',
	NFT_TABLE_RESTORED: 'warn',
	DNSMASQ_CONFDIR_NOT_FOUND: 'error', DNSMASQ_EXTRA_SERVERS: 'warn',
	IPV6_PRESENT: 'warn',
	SUB_UPDATED: 'notice',
	SUB_FETCH_FAILED: 'error', SUB_DECODE_FAILED: 'error', SUB_FORMAT_UNSUPPORTED: 'error',
	SUB_APPLY_INVALID: 'error', SUB_PROXY_UNAVAILABLE: 'error',
	SUB_SHRANK: 'warn',
	UPDATE_AVAILABLE: 'notice',
	UPDATE_INSTALLED: 'notice', UPDATE_VERIFY_FAILED: 'error', UPDATE_ROLLED_BACK: 'error',
	DATA_UPDATED: 'notice',
	UPDATE_FETCH_FAILED: 'error', MANIFEST_BAD_SIGNATURE: 'error',
	NO_SPACE: 'error', ARCH_UNSUPPORTED: 'error',
	CMD_FAILED: 'error', FS_FAILED: 'error', CMD_RUN: 'debug',
	CHILD_STARTED: 'info', CHILD_CRASHED: 'warn', SUB_NO_VALID_NODES: 'error'
};

// aether-proxy level -> syslog priority name, and numeric rank for filtering.
const PRIORITY = { error: 'err', warn: 'warning', notice: 'notice', info: 'info', debug: 'debug' };
const RANK = { error: 0, warn: 1, notice: 2, info: 3, debug: 4 };

// Default level is notice (docs/09 "levels").
let threshold = 'notice';
let opened = false;
let event_run_dir = C.RUN_DIR;

function set_level(level) {
	if (RANK[level] == null)
		return false;

	threshold = level;
	return true;
}

// Scalars are printed bare when safe, everything else JSON-quoted so a line stays
// parseable as space-separated k=v.
function fmt_value(v) {
	if (type(v) == 'int' || type(v) == 'double' || type(v) == 'bool')
		return sprintf('%J', v);

	if (type(v) == 'string' && length(v) && !match(v, /[\s"=\[\]]/))
		return v;

	return sprintf('%J', v);
}

function format_line(code, args, message) {
	let parts = [ code ];

	if (message != null && message != '')
		push(parts, message);

	let kv = [];

	// Insertion order of args is preserved on purpose, callers control it.
	for (let k in (args ?? {}))
		push(kv, k + '=' + fmt_value(args[k]));

	if (length(kv))
		push(parts, '[' + join(' ', kv) + ']');

	return join(' ', parts);
}

function open_syslog() {
	if (opened)
		return;

	// Facility daemon; the tag is what `logread -e '^aether-proxy'` matches.
	syslog.openlog(C.SYSLOG_TAG, [], 'daemon');
	opened = true;
}

function fs_err() {
	return fs.error() ?? 'unknown error';
}

function fs_failed(op, path, detail) {
	open_syslog();
	syslog.syslog(PRIORITY.error, '%s', format_line('FS_FAILED', { op, path, detail }));
}

// Retain the newer half once the JSONL history exceeds the configured ring size.
export function trim_event_history(text) {
	let lines = split(text ?? '', '\n');
	let count = length(lines);
	if (count && lines[count - 1] == '')
		count--;
	if (count <= 500)
		return text ?? '';

	let retained = [];
	for (let i = count >> 1; i < count; i++)
		push(retained, lines[i]);

	return join('\n', retained) + '\n';
};

function append_event(level, code, args) {
	if (RANK[level] > RANK.notice)
		return;

	let path = event_run_dir + '/' + C.EVENTS_FILE;
	let line = sprintf('%J', { ts: time(), level, code, args: args ?? {} }) + '\n';
	let fp = fs.open(path, 'a');

	if (!fp) {
		fs_failed('open', path, fs_err());
		return;
	}

	let written = fp.write(line);
	let write_err = fs.error();
	let closed = fp.close();
	if (written == null || !closed) {
		fs_failed('write', path, write_err ?? fs_err());
		return;
	}

	let text = fs.readfile(path);
	if (text == null) {
		fs_failed('read', path, fs_err());
		return;
	}

	let trimmed = trim_event_history(text);
	if (trimmed == text)
		return;

	let pid = fs.readlink('/proc/self');
	let temp = `${path}.tmp.${pid ?? 'unknown'}`;
	let tmp_fp = fs.open(temp, 'w');
	if (!tmp_fp) {
		fs_failed('open', temp, fs_err());
		return;
	}

	let tmp_written = tmp_fp.write(trimmed);
	let tmp_error = fs.error();
	let tmp_closed = tmp_fp.close();
	if (tmp_written == null || !tmp_closed) {
		let detail = tmp_error ?? fs_err();
		if (!fs.unlink(temp))
			detail += `; unlink ${temp}: ${fs_err()}`;
		fs_failed('write', temp, detail);
		return;
	}

	if (!fs.rename(temp, path)) {
		let detail = fs_err();
		if (!fs.unlink(temp))
			detail += `; unlink ${temp}: ${fs_err()}`;
		fs_failed('rename', path, detail);
	}
}

// Returns true if the line was handed to syslog, false if filtered by level.
// Unknown codes are a programming error and die loudly (docs/12 rule 8).
function event(level, code, args, message) {
	if (EVENTS[code] == null)
		die(`log.event: unknown event code '${code}'`);

	level ??= EVENTS[code];

	if (RANK[level] == null)
		die(`log.event: unknown level '${level}'`);

	append_event(level, code, args);

	if (RANK[level] > RANK[threshold])
		return false;

	open_syslog();

	return syslog.syslog(PRIORITY[level], '%s', format_line(code, args, message));
}

function set_run_dir(path) {
	event_run_dir = path ?? C.RUN_DIR;
}

export { event, set_level, set_run_dir, format_line };
