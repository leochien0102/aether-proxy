'use strict';

// `aether-proxy custom get|set` (docs/10 "`log`、`node import`、`custom`", docs/05
// "列表文件的解析规则"). Validation and saving live here, not in rpcd: the LuCI layer
// only forwards content through `save_file`.

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as data from 'aetherproxy.data';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';
import * as sub from 'aetherproxy.sub';
import * as sys from 'aetherproxy.sys';

// List name -> file name, reusing the renderer-side constants (docs/12 rule 5).
const NAME_TO_FILE = {
	direct_domain: C.CUSTOM_DOMAIN_FILES.direct_domain,
	proxy_domain: C.CUSTOM_DOMAIN_FILES.proxy_domain,
	direct_ip: C.CUSTOM_IP_FILES.direct_ip4,
	proxy_ip: C.CUSTOM_IP_FILES.proxy_ip4
};

const DOMAIN_NAMES = [ 'direct_domain', 'proxy_domain' ];

const USAGE = 'Usage: aether-proxy custom get <name>\n       aether-proxy custom set <name> --content <text>';

function parse_args(args) {
	let opts = {}, positional = [];

	for (let i = 0; i < length(args); i++) {
		let arg = args[i];

		if (arg == '--json') {
			opts.json = true;
			continue;
		}

		let key = {
			'--content': 'content', '--custom-dir': 'custom_dir',
			'--run-dir': 'run_dir', '--sys-root': 'sys_root'
		}[arg];

		if (key != null) {
			if (i + 1 >= length(args))
				return { error: `option ${arg} needs a value` };
			opts[key] = args[++i];
			continue;
		}

		if (substr(arg, 0, 1) == '-')
			return { error: `unknown option ${arg}` };

		push(positional, arg);
	}

	return { opts, positional };
}

function usage(opts, detail) {
	return pipeline.finish(opts, { ok: false, code: 'USAGE', detail }, 2, `${detail}\n${USAGE}`);
}

function fs_error() {
	return fs.error() ?? 'unknown error';
}

// A missing file is an empty list (docs/05); any other read failure is an I/O error.
function read_list(path) {
	let text = fs.readfile(path);
	if (text != null)
		return { ok: true, text };

	let detail = fs_error();
	if (detail == 'No such file or directory')
		return { ok: true, text: null };
	return { ok: false, detail: `read ${path}: ${detail}` };
}

// True when the service holds one of the states that follow the rendered output
// (docs/10: starting/running/degraded). An unreadable state file counts as not running;
// the reason is logged, never swallowed.
function service_running(run_dir) {
	let path = `${run_dir}/${C.STATE_FILE}`;
	let text = fs.readfile(path);

	if (text == null) {
		let detail = fs_error();
		if (detail != 'No such file or directory')
			log.event('error', 'FS_FAILED', { op: 'read', path, detail });
		return false;
	}

	let value = null;
	try {
		value = json(text);
	}
	catch (e) {
		value = null;
	}
	if (type(value) != 'object') {
		log.event('error', 'FS_FAILED', { op: 'parse', path, detail: 'expected a JSON object' });
		return false;
	}

	return index([ 'starting', 'running', 'degraded' ], value.state) >= 0;
}

// Reload through the init script after a successful save (docs/10). A failure is reported
// in the reply's `reload` field; the file is never rolled back.
function reload_service(root) {
	let init = sub.system_path(root, C.PROG_INIT);
	let res = sys.run([ init, 'reload' ], { timeout: C.CUSTOM_RELOAD_TIMEOUT_SECS, quiet: true });

	if (res.code != 0) {
		log.event('error', 'CMD_FAILED', {
			cmd: `${init} reload`, rc: res.code,
			stderr: substr(trim(res.stderr), 0, 200), timed_out: res.timed_out
		});
		return 'failed';
	}

	return true;
}

export function run(args) {
	let parsed = parse_args(args);
	if (parsed.error)
		return usage({ json: index(args, '--json') >= 0 }, parsed.error);

	let opts = parsed.opts;
	let action = parsed.positional[0];
	let name = parsed.positional[1];

	if ((action != 'get' && action != 'set') || length(parsed.positional) != 2)
		return usage(opts, 'expected `custom get <name>` or `custom set <name> --content <text>`');

	if (type(name) != 'string' || NAME_TO_FILE[name] == null)
		return usage(opts, `name must be one of ${join('|', sort(keys(NAME_TO_FILE)))}`);

	let root = opts.sys_root ?? '';
	let custom_dir = opts.custom_dir ?? sub.system_path(root, C.CUSTOM_DIR);
	let run_dir = opts.run_dir ?? sub.system_path(root, C.RUN_DIR);
	let path = `${custom_dir}/${NAME_TO_FILE[name]}`;

	if (action == 'get') {
		let file = read_list(path);
		if (!file.ok) {
			log.event('error', 'FS_FAILED', { op: 'read', path, detail: file.detail });
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: file.detail }, 1,
				`cannot read ${path}`);
		}
		return pipeline.finish(opts, { ok: true, name, content: file.text ?? '' }, 0,
			file.text ?? '');
	}

	// --- set ---
	if (opts.content == null)
		return usage(opts, 'custom set needs --content');
	if (length(opts.content) > C.CUSTOM_MAX_BYTES)
		return usage(opts, `content must not exceed ${C.CUSTOM_MAX_BYTES} bytes`);

	// Line-by-line validation (docs/05); at most CUSTOM_INVALID_MAX offenders are reported.
	let checked = index(DOMAIN_NAMES, name) >= 0
		? data.parse_domains(opts.content)
		: data.parse_cidrs(opts.content);
	if (length(checked.errors)) {
		let errors = slice(checked.errors, 0, C.CUSTOM_INVALID_MAX);
		let detail = `${length(checked.errors)} invalid line(s)`;
		return pipeline.finish(opts, { ok: false, code: 'CONFIG_INVALID', detail, errors }, 2, detail);
	}

	// A trailing newline is added when missing (docs/10); identical content is not written.
	let content = match(opts.content, /\n$/) != null ? opts.content : opts.content + '\n';
	let existing = read_list(path);
	if (!existing.ok) {
		log.event('error', 'FS_FAILED', { op: 'read', path, detail: existing.detail });
		return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: existing.detail }, 1,
			`cannot read ${path}`);
	}

	let changed = existing.text != content;
	let reload = false;

	if (changed) {
		if (!sys.write_atomic(path, content)) {
			let detail = `write ${path}: ${sys.error()}`;
			log.event('error', 'FS_FAILED', { op: 'write', path, detail });
			return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail }, 1,
				`cannot write ${path}`);
		}

		if (service_running(run_dir))
			reload = reload_service(root);
	}

	return pipeline.finish(opts, { ok: true, name, changed, reload }, 0,
		`${name}: ${changed ? 'saved' : 'unchanged'}${reload === true ? ', reloaded' : reload == 'failed' ? ', reload failed' : ''}`);
};
