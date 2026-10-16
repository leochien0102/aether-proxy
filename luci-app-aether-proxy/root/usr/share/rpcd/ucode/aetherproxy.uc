#!/usr/bin/env ucode
'use strict';

// rpcd ucode plugin for the `aetherproxy` ubus object (docs/10 "rpcd 插件").
//
// Thin layer per docs/10 "分层": validate arguments (whitelist + regex), forward
// to the aether-proxy CLI, and return its JSON reply unchanged. All logic lives
// in the CLI; none may grow here.

import * as C from 'aetherproxy.const';
import * as schema from 'aetherproxy.schema';
import * as sys from 'aetherproxy.sys';

// docs/10 "实现约定": check may need 30s (rendering + nft -c + xray -test); every
// other forwarded command must finish fast, because rpcd handles calls serially
// and long tasks must go through job_start instead.
const CHECK_TIMEOUT_SECS = 30;
const DEFAULT_TIMEOUT_SECS = 10;
const STDERR_FORWARD_BYTES = 512;


const SERVICE_ACTIONS = [ 'start', 'stop', 'restart' ];

// docs/10 "service": restarting can outlast any RPC timeout (procd waits for
// children to exit), so the action is backgrounded and the caller polls `status`
// to learn the result.
const SERVICE_SCRIPT = '"$0" "$1" </dev/null >/dev/null 2>&1 &';

// docs/10 "仅供测试": path overrides, like the other AETHER_PROXY_TEST_* variables;
// never set in production.
function cli_path() {
	return getenv('AETHER_PROXY_TEST_RPCD_CLI') ?? C.PROG_EXEC;
}

function init_path() {
	return getenv('AETHER_PROXY_TEST_RPCD_INIT') ?? C.PROG_INIT;
}

function usage(detail) {
	return { ok: false, code: 'USAGE', detail };
}

// json() throws on bad input; that is the expected control flow here (non-JSON
// CLI output becomes a CMD_FAILED reply), so catching it is not swallowing an
// error: the reason reaches the caller in the reply.
function parse_object(text) {
	try {
		let obj = json(text);
		return type(obj) == 'object' ? obj : null;
	}
	catch (e) {
		return null;
	}
}

function cli_failure(res, timeout) {
	if (res.timed_out)
		return { ok: false, code: 'CMD_FAILED', detail: `timeout after ${timeout}s` };

	return { ok: false, code: 'CMD_FAILED', detail: `exit ${res.code}: ${substr(res.stderr ?? '', 0, STDERR_FORWARD_BYTES)}` };
}

// docs/10 "转发": execute `/usr/bin/aether-proxy <subcommand> --json` (sys.run
// argv array, no shell) and return a stdout that parses as a JSON object as-is,
// no matter the exit code — the CLI JSON already carries ok/code (e.g. `job
// start` busy reports BUSY with exit 3). Anything else becomes CMD_FAILED.
// quiet: failures are reported in the reply instead of via syslog, because
// opening the syslog with our tag would change the ident of the rpcd process.
function call_cli(argv, timeout) {
	let res = sys.run([ cli_path(), ...argv, '--json' ], { timeout, quiet: true });

	let obj = parse_object(res.stdout);
	if (obj != null)
		return obj;

	return cli_failure(res, timeout);
}

// docs/10 "job_start 的参数": args is a string array, absent meaning empty.
// Returns null when the value is not an array of strings.
function string_args(value) {
	if (value == null)
		return [];

	if (type(value) != 'array')
		return null;

	for (let i = 0; i < length(value); i++)
		if (type(value[i]) != 'string')
			return null;

	return value;
}

// Returns the `job start` argv for a (kind, args) pair from the parameter table
// in docs/10, or null when the pair violates it.
function job_argv(kind, args) {
	if (kind == 'probe_nodes') {
		if (length(args) > 256)
			return null;

		let seen = {};
		for (let i = 0; i < length(args); i++) {
			let id = args[i];
			if (match(id, schema.NODE_NAME_RE) == null || seen[id])
				return null;
			seen[id] = true;
		}

		return [ 'job', 'start', 'probe', 'nodes', ...args ];
	}

	if (kind == 'sub_update') {
		if (length(args) > 1)
			return null;
		if (length(args) == 1 && match(args[0], schema.SUBSCRIPTION_NAME_RE) == null)
			return null;

		return [ 'job', 'start', 'sub', 'update', ...args ];
	}

	if (kind == 'update_check')
		return length(args) == 0 ? [ 'job', 'start', 'update', 'check' ] : null;

	if (kind == 'update_data')
		return length(args) == 0 ? [ 'job', 'start', 'update', 'data' ] : null;

	if (kind == 'update_package') {
		// [<package>] or [<package>, "--previous"]; the flag is position-fixed.
		if (length(args) < 1 || length(args) > 2)
			return null;
		if (index(C.UPDATE_PACKAGES, args[0]) < 0)
			return null;
		if (length(args) == 2 && args[1] != '--previous')
			return null;

		return [ 'job', 'start', 'update', 'package', ...args ];
	}

	return null;
}

// `args` values are examples: rpcd derives each argument's ubus type from the value's type
// ('' string, 0 int32, [] array) and rejects calls with another type or an unknown name.
const methods = {
	version: {
		call: function(req) {
			return call_cli([ 'version' ], DEFAULT_TIMEOUT_SECS);
		},
		args: {}
	},

	status: {
		call: function(req) {
			return call_cli([ 'status' ], DEFAULT_TIMEOUT_SECS);
		},
		args: {}
	},

	service: {
		call: function(req) {
			let action = req?.args?.action;

			if (type(action) != 'string' || index(SERVICE_ACTIONS, action) < 0)
				return usage(`action must be one of ${join('|', SERVICE_ACTIONS)}`);

			// Fire and forget: the sh wrapper exits at once. A launch failure (rc
			// != 0) means nothing was started; sys.run logs it as CMD_FAILED and
			// the reply reports it instead of claiming success.
			let res = sys.run([ 'sh', '-c', SERVICE_SCRIPT, init_path(), action ], { timeout: DEFAULT_TIMEOUT_SECS });

			if (res.code != 0)
				return cli_failure(res, DEFAULT_TIMEOUT_SECS);

			return { ok: true, action: action };
		},
		args: { action: '' }
	},

	check: {
		call: function(req) {
			return call_cli([ 'check' ], CHECK_TIMEOUT_SECS);
		},
		args: {}
	},

	job_start: {
		call: function(req) {
			let a = req?.args ?? {};
			let kind = a.kind;
			let args = string_args(a.args);

			if (type(kind) != 'string')
				return usage('kind is required');

			if (args == null)
				return usage('args must be an array of strings');

			let argv = job_argv(kind, args);
			if (argv == null)
				return usage(`invalid args for kind ${kind}`);

			return call_cli(argv, DEFAULT_TIMEOUT_SECS);
		},
		args: { kind: '', args: [] }
	},

	job_status: {
		call: function(req) {
			let id = req?.args?.id;

			if (type(id) != 'string' || match(id, C.JOB_ID_RE) == null)
				return usage('id must match j_<seconds>_<pid>');

			return call_cli([ 'job', 'status', id ], DEFAULT_TIMEOUT_SECS);
		},
		args: { id: '' }
	},

	events: {
		call: function(req) {
			let a = req?.args ?? {};
			let since = a.since;
			let level = a.level;
			let argv = [ 'events' ];

			// Absent equals not sent; 0 is a valid timestamp and must survive.
			if (since != null) {
				if (type(since) != 'int' || since < 0)
					return usage('since must be a non-negative integer timestamp');
				push(argv, '--since', `${since}`);
			}

			if (level != null) {
				if (type(level) != 'string' || index(C.EVENT_LEVELS, level) < 0)
					return usage(`level must be one of ${join('|', C.EVENT_LEVELS)}`);
				push(argv, '--level', level);
			}

			return call_cli(argv, DEFAULT_TIMEOUT_SECS);
		},
		args: { since: 0, level: '' }
	}
};

return { aetherproxy: methods };
