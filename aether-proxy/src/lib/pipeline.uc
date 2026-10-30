'use strict';

// Shared configuration/data reading and deterministic rendering (docs/04 "启动" and "重载").
// Reload reuses one read result with different runtimes; check/render and daemon startup
// retain the combined build() API. Daemon applies freeze child-process list inputs by
// generation (docs/tasks/m9 T9.43 revision); rendering itself remains pure.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as sys from 'aetherproxy.sys';
import { ipv4 } from 'aetherproxy.net';
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

// docs/03 "运营商下发的 DNS": only live default-route interfaces contribute IPv4 DNS.
// Keep parsing pure so malformed ubus replies are treated like an unavailable WAN.
export function wan_dns_from_dump(dump) {
	if (type(dump) != 'object' || type(dump.interface) != 'array')
		return [];
	let interfaces = filter(dump.interface, iface => type(iface) == 'object' &&
		type(iface.interface) == 'string' && iface.up == true);
	sort(interfaces, (a, b) => a.interface < b.interface ? -1 : a.interface > b.interface ? 1 : 0);
	let out = [];
	for (let iface in interfaces) {
		if (type(iface.route) != 'array' || type(iface['dns-server']) != 'array')
			continue;
		let defaults = filter(iface.route, route => type(route) == 'object' &&
			route.target == '0.0.0.0' && route.mask == 0);
		if (!length(defaults))
			continue;
		for (let value in iface['dns-server'])
			if (type(value) == 'string' && ipv4(value) != null && index(out, value) < 0)
				push(out, value);
	}
	return out;
};

export function read_wan_dns(opts) {
	let bin = opts.bin_dir ? `${opts.bin_dir}/ubus` : 'ubus';
	let result = sys.run([ bin, 'call', 'network.interface', 'dump' ],
		{ timeout: C.WAN_DNS_TIMEOUT_SECS, quiet: true });
	// No event on failure or timeout: the fallback exists specifically for WAN startup (03).
	if (result.code != 0)
		return [];
	try {
		return wan_dns_from_dump(json(result.stdout));
	}
	catch (e) {
		// A malformed dump is unavailable DNS, not a configuration error.
		return [];
	}
};

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
	let wan_dns = index(cfg.snapshot.dns.china_dns, 'wan') >= 0 ? read_wan_dns(opts) : null;
	cfg.snapshot.dns.china_dns = config.expand_china_dns(cfg.snapshot.dns.china_dns, wan_dns);
	return { ok: true, snapshot: cfg.snapshot, wan_dns, data: d.data, paths, warnings };
};

// Only application paths call these helpers. CLI read/build/render keep source paths.
function frozen_error(detail) {
	return { ok: false, exit: 1, code: 'RENDER_INVALID', detail, errors: [] };
};

function remove_generation(path) {
	let removed = sys.run([ 'rm', '-rf', path ], { timeout: 10 });
	return removed.code == 0;
};

function applied_dir(ctx) {
	return replace(ctx.root ?? '', /\/$/, '') + (ctx.run_dir ?? C.RUN_DIR) + '/' + C.APPLIED_SUBDIR;
};

// Tests may pass real data paths together with a simulated system root, like apply's hashing.
function source_file(ctx, path) {
	if (path == null)
		return { ok: true, source: null, content: '' };
	let rooted = (ctx.root ?? '') + path;
	let actual = ctx.root && fs.stat(rooted) != null ? rooted : path;
	let content = fs.readfile(actual), read_error = fs.error() ?? 'unknown error';
	if (content != null)
		return { ok: true, source: path, content };
	let st = fs.stat(actual), stat_error = fs.error() ?? 'unknown error';
	if (st == null && stat_error == 'No such file or directory')
		return { ok: true, source: path, content: '' };
	return frozen_error(`cannot freeze ${actual}: ${read_error}`);
};

function file_hashes(paths) {
	let result = sys.run([ 'sha256sum', ...paths ], { timeout: 10 });
	if (result.code != 0)
		return frozen_error(`sha256sum failed (${result.code}): ${result.stderr}`);
	let hashes = [];
	for (let line in split(trim(result.stdout), '\n')) {
		let m = match(line, /^([0-9a-fA-F]{64})[[:space:]]/);
		if (m == null)
			return frozen_error('cannot parse frozen file hash');
		push(hashes, lc(m[1]));
	}
	return length(hashes) == length(paths) ? { ok: true, hashes } : frozen_error('missing frozen file hash');
};

function publish_generation(loaded, ctx, files, current) {
	let parent = applied_dir(ctx), stage = `${parent}/${C.APPLIED_CANDIDATE}`;
	if (!sys.mkdir_p(parent) || !remove_generation(stage))
		return frozen_error(`cannot prepare ${stage}: ${sys.error() ?? 'cleanup failed'}`);
	if (!fs.mkdir(stage, 0700))
		return frozen_error(`cannot create ${stage}: ${fs.error() ?? 'unknown error'}`);
	let paths = [], sources = {};
	for (let key, file in C.APPLIED_FILES) {
		push(paths, `${stage}/${file}`);
		sources[key] = files[key].source;
		if (!sys.write_atomic(`${stage}/${file}`, files[key].content)) {
			remove_generation(stage);
			return frozen_error(`cannot write frozen ${key}: ${sys.error()}`);
		}
	}
	let hashed = file_hashes(paths), manifest = [];
	if (hashed.ok) {
		let i = 0;
		for (let key in C.APPLIED_FILES)
			push(manifest, { key, source: sources[key], hash: hashed.hashes[i++] });
		if (!sys.write_atomic(`${stage}/${C.APPLIED_MANIFEST}`, sprintf('%.J\n', manifest)))
			hashed = frozen_error(`cannot write frozen manifest: ${sys.error()}`);
		else
			hashed = file_hashes([ `${stage}/${C.APPLIED_MANIFEST}` ]);
	}
	if (!hashed.ok) {
		remove_generation(stage);
		return hashed;
	}
	let generation_dir = `${parent}/${hashed.hashes[0]}`;
	// Never overwrite the active generation, even if its files were externally damaged.
	if (generation_dir == current?.generation_dir) {
		remove_generation(stage);
		return frozen_error('active frozen generation does not match its content identity');
	}
	if (!remove_generation(generation_dir) || !fs.rename(stage, generation_dir)) {
		let error = fs.error() ?? 'generation cleanup failed';
		remove_generation(stage);
		return frozen_error(`cannot publish ${generation_dir}: ${error}`);
	}
	let frozen_paths = {};
	for (let key, file in C.APPLIED_FILES)
		frozen_paths[key] = `${generation_dir}/${file}`;
	return { ...loaded, paths: frozen_paths, source_paths: sources, generation_dir };
};

// Capture bytes before hashing/copying: source replacement cannot change an already captured
// candidate. Reuse reads the current immutable files but never rewrites them or creates a copy.
export function freeze(loaded, ctx, current) {
	if (!loaded.ok)
		return loaded;
	let files = {}, reuse = current?.generation_dir != null;
	for (let key in C.APPLIED_FILES) {
		let file = source_file(ctx, loaded.paths?.[key]);
		if (!file.ok)
			return file;
		files[key] = file;
		if (!reuse)
			continue;
		if (current.source_paths[key] != file.source || fs.readfile(current.paths[key]) != file.content)
			reuse = false;
	}
	if (reuse)
		return { ...loaded, paths: current.paths, source_paths: current.source_paths,
			generation_dir: current.generation_dir };
	return publish_generation(loaded, ctx, files, current);
};

export function discard_frozen(loaded, current) {
	if (loaded?.generation_dir == null || loaded.generation_dir == current?.generation_dir)
		return true;
	return remove_generation(loaded.generation_dir);
};

// Cleanup is after the successful switch (or after startup rollback), never before actions.
// TODO(design): if post-commit cleanup fails, keep the working generation and log the error;
// retry cleanup on the next successful apply rather than undo an already committed service.
export function prune_frozen(ctx, current) {
	let parent = applied_dir(ctx);
	if (fs.stat(parent) == null) {
		let error = fs.error() ?? 'unknown error';
		if (error == 'No such file or directory')
			return true;
		log.event('error', 'FS_FAILED', { op: 'stat', path: parent, detail: error });
		return false;
	}
	let entries = fs.lsdir(parent);
	if (entries == null) {
		log.event('error', 'FS_FAILED', { op: 'lsdir', path: parent, detail: fs.error() ?? 'unknown error' });
		return false;
	}
	let ok = true;
	for (let entry in entries) {
		let path = `${parent}/${entry}`;
		if (path != current?.generation_dir && !remove_generation(path))
			ok = false;
	}
	return ok;
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
		wan_dns: loaded.wan_dns ?? null,
		runtime: {
			node_ip: runtime.node_ip ?? null,
			dns_tier: runtime.dns_tier ?? 'T2',
			degraded_mode: runtime.degraded_mode ?? null,
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

	return { ok: true, snapshot: loaded.snapshot, wan_dns: loaded.wan_dns ?? null,
		ctx, artifacts, warnings: loaded.warnings };
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
