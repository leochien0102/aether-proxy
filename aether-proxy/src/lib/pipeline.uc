'use strict';

// Steps shared by `check` and `render` (docs/04 "启动" steps 2 and 5): option parsing, reading
// the configuration and rule data, building the render context and running the four renderers.
// The daemon will reuse build() with its own runtime.

import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as config from 'aetherproxy.config';
import * as data from 'aetherproxy.data';
import * as nft from 'aetherproxy.render.nft';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as dnsmasq from 'aetherproxy.render.dnsmasq';
import * as xray from 'aetherproxy.render.xray';

const RENDERERS = { nft, chinadns, dnsmasq, xray };

// Value options (test-only ones included, docs/10 "仅供测试的选项") -> key in the result.
const VALUE_OPTS = {
	'--confdir': 'confdir', '--data-dir': 'data_dir', '--baseline-dir': 'baseline_dir',
	'--custom-dir': 'custom_dir', '--run-dir': 'run_dir'
};
const FLAG_OPTS = { '--json': 'json', '--no-precheck': 'no_precheck' };

// Returns { opts, positional } or { error } (a usage error).
export function parse_args(args) {
	let opts = {};
	let positional = [];

	for (let i = 0; i < length(args); i++) {
		let a = args[i];

		if (VALUE_OPTS[a] != null) {
			if (i + 1 >= length(args))
				return { error: `option ${a} needs a value` };

			opts[VALUE_OPTS[a]] = args[++i];
		}
		else if (FLAG_OPTS[a] != null) {
			opts[FLAG_OPTS[a]] = true;
		}
		else if (substr(a, 0, 1) == '-') {
			return { error: `unknown option ${a}` };
		}
		else {
			push(positional, a);
		}
	}

	log.set_run_dir(opts.run_dir ?? C.RUN_DIR);
	return { opts, positional };
};

export function run_dir(opts) {
	return opts.run_dir ?? C.RUN_DIR;
};

// The runtime that check and render both use (docs/tasks/m1 T1.7).
function static_runtime() {
	return { node_ip: null, dns_tier: 'T2', restored: {} };
}

// Reads configuration and data, renders all four artifacts.
//
// Returns { ok: true, snapshot, ctx, artifacts: { nft, chinadns, dnsmasq, xray }, warnings }
// or      { ok: false, code, detail, errors, exit }
// where `exit` is the process exit code for the failure (docs/10: 1 runtime, 2 config).
// Only reads; it never writes to the system.
export function build(opts) {
	let cursor = uci.cursor(opts.confdir);
	let cfg = config.load(cursor);

	if (!cfg.ok) {
		return {
			ok: false, exit: 2, code: 'CONFIG_INVALID',
			detail: `${length(cfg.errors)} configuration error(s)`, errors: cfg.errors
		};
	}

	let warnings = cfg.warnings ?? [];

	for (let w in warnings)
		log.event(null, w.code, w.args);

	let dopts = { data_dir: opts.data_dir, baseline_dir: opts.baseline_dir, custom_dir: opts.custom_dir };
	let d = data.load(dopts);
	let dom = data.resolve_domain_paths(dopts);
	let errors = [ ...d.errors, ...dom.errors ];

	if (length(errors)) {
		// TODO(design): docs/04 gives no code or exit status for unusable rule data; it is
		// reported like a configuration problem (exit 2, nothing touched).
		return {
			ok: false, exit: 2, code: 'CONFIG_INVALID',
			detail: `${length(errors)} rule data error(s)`, errors
		};
	}

	let custom_dir = opts.custom_dir ?? C.CUSTOM_DIR;
	// All six paths are always passed: chinadns.uc silently drops lines for missing ones.
	let paths = {
		gfwlist: dom.paths.gfwlist,
		chnlist: dom.paths.chnlist,
		apple: dom.paths.apple,
		proxy_domain: custom_dir + '/' + C.CUSTOM_DOMAIN_FILES.proxy_domain,
		direct_domain: custom_dir + '/' + C.CUSTOM_DOMAIN_FILES.direct_domain,
		boot_list: run_dir(opts) + '/' + C.BOOT_LIST_FILE
	};
	let runtime = opts.runtime ?? static_runtime();
	let ctx = {
		data: d.data,
		runtime: {
			node_ip: runtime.node_ip ?? null,
			dns_tier: runtime.dns_tier ?? 'T2',
			restored: runtime.restored ?? {}
		},
		paths
	};
	let artifacts = {};

	for (let name, mod in RENDERERS) {
		try {
			artifacts[name] = mod.render(cfg.snapshot, ctx);
		}
		catch (e) {
			// A renderer exception is a bug, but the CLI must still answer in its documented format.
			return {
				ok: false, exit: 1, code: 'RENDER_INVALID',
				detail: `renderer ${name} failed: ${e.message ?? e}`, errors: []
			};
		}
	}

	return { ok: true, snapshot: cfg.snapshot, ctx, artifacts, warnings };
};

// Prints the result: one JSON object on stdout with --json (human text goes to stderr),
// otherwise human text. Returns the exit code.
export function finish(opts, result, exit, human) {
	if (opts.json) {
		print(sprintf('%.J', result), '\n');
	}
	else if (human) {
		if (exit == 0)
			print(human + '\n');
		else
			warn(human + '\n');
	}

	return exit;
};

export function describe_errors(res) {
	let lines = [ `${res.code}: ${res.detail}` ];

	for (let e in (res.errors ?? []))
		push(lines, '  ' + (e.field ?? e.file ?? e.item ?? '-') + ': ' + e.code + (e.detail ? ` (${e.detail})` : ''));

	return join('\n', lines);
};
