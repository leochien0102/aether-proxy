'use strict';

// Shared configuration/data reading and deterministic rendering (docs/04 "启动" and "重载").
// Reload reuses one read result with different runtimes; check/render and daemon startup
// retain the combined build() API.

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
	'--custom-dir': 'custom_dir', '--run-dir': 'run_dir',
	'--sys-root': 'sys_root', '--bin-dir': 'bin_dir'
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

// Read once before node resolution, including warning events and all six list paths.
// Failures retain build()'s { ok: false, code, detail, errors, exit } contract.
export function read(opts) {
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
	return { ok: true, snapshot: cfg.snapshot, data: d.data, paths, warnings };
};

// No file reads or warning events here. A fresh context leaves the read result reusable
// after node resolution and sets export; selecting nft must not invoke other renderers.
// The successful result has build()'s shape; artifacts contains only the selected output
// when `only` is supplied (keys follow ARTIFACT_FILES: nft/chinadns/dnsmasq/xray).
export function render(loaded, runtime, only) {
	if (!loaded.ok)
		return loaded;
	if (only != null && RENDERERS[only] == null)
		return { ok: false, exit: 1, code: 'RENDER_INVALID', detail: `unknown renderer ${only}`, errors: [] };
	runtime ??= static_runtime();
	let ctx = {
		data: loaded.data,
		runtime: {
			node_ip: runtime.node_ip ?? null,
			dns_tier: runtime.dns_tier ?? 'T2',
			restored: runtime.restored ?? {}
		},
		paths: loaded.paths
	};
	let artifacts = {};

	for (let name, mod in RENDERERS) {
		if (only != null && name != only)
			continue;
		try {
			artifacts[name] = mod.render(loaded.snapshot, ctx);
		}
		catch (e) {
			// A renderer exception is a bug, but the CLI must still answer in its documented format.
			return {
				ok: false, exit: 1, code: 'RENDER_INVALID',
				detail: `renderer ${name} failed: ${e.message ?? e}`, errors: []
			};
		}
	}

	return { ok: true, snapshot: loaded.snapshot, ctx, artifacts, warnings: loaded.warnings };
};

// Compatibility entry point: same signature, defaults, errors and four artifacts.
export function build(opts) {
	return render(read(opts), opts.runtime);
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
