'use strict';

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
	START_FAILED: 'error',
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
	MANIFEST_BAD_SIGNATURE: 'error',
	NO_SPACE: 'error', ARCH_UNSUPPORTED: 'error',
	CMD_FAILED: 'error'
};

// aether-proxy level -> syslog priority name, and numeric rank for filtering.
const PRIORITY = { error: 'err', warn: 'warning', notice: 'notice', info: 'info', debug: 'debug' };
const RANK = { error: 0, warn: 1, notice: 2, info: 3, debug: 4 };

// Default level is notice (docs/09 "levels").
let threshold = 'notice';
let opened = false;

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

// Returns true if the line was handed to syslog, false if filtered by level.
// Unknown codes are a programming error and die loudly (docs/12 rule 8).
function event(level, code, args, message) {
	if (EVENTS[code] == null)
		die(`log.event: unknown event code '${code}'`);

	level ??= EVENTS[code];

	if (RANK[level] == null)
		die(`log.event: unknown level '${level}'`);

	if (RANK[level] > RANK[threshold])
		return false;

	if (!opened) {
		// Facility daemon; the tag is what `logread -e '^aether-proxy'` matches.
		syslog.openlog(C.SYSLOG_TAG, [], 'daemon');
		opened = true;
	}

	return syslog.syslog(PRIORITY[level], '%s', format_line(code, args, message));
}

export { event, set_level, format_line };
