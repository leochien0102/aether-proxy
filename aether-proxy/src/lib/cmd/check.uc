'use strict';

// `aether-proxy check`: validates the configuration, renders all artifacts into the staging
// directory and runs the external validators (docs/04 "启动" steps 2, 3, 5). The only thing it
// writes is <run-dir>/staging/.

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as sys from 'aetherproxy.sys';
import * as pipeline from 'aetherproxy.pipeline';

// Locates a component binary in the order of docs/01 "组件二进制的查找顺序".
// Returns { path, source } or null.
function find_component(name, configured, options) {
	if (options?.bin_dir) {
		let from_bin_dir = `${options.bin_dir}/${name}`;
		if (fs.access(from_bin_dir, 'x'))
			return { path: from_bin_dir, source: 'bin-dir' };
	}

	if (configured != null && configured != '')
		return fs.access(configured, 'x') ? { path: configured, source: 'uci' } : null;

	for (let dir in split(getenv('PATH') ?? '', ':')) {
		if (dir != '' && fs.access(`${dir}/${name}`, 'x'))
			return { path: `${dir}/${name}`, source: 'path' };
	}

	return null;
}

// A table that exercises the tproxy and socket expressions, so `nft -c` fails when
// kmod-nft-tproxy / kmod-nft-socket are missing (docs/02 "内核与模块前提").
function precheck_ruleset() {
	return join('\n', [
		'table inet aetherproxy_precheck {',
		'\tchain probe {',
		'\t\ttype filter hook prerouting priority mangle; policy accept;',
		'\t\tmeta l4proto tcp socket transparent 1 accept',
		`\t\tmeta l4proto tcp tproxy ip to 127.0.0.1:${C.TPROXY_PORT} accept`,
		'\t}',
		'}',
		''
	]);
}

// Everything that talks to the live system lives here so that --no-precheck can skip it.
// Returns { items: [ { item, ok, detail? } ], components: { <name>: { found, path?, source? } } }.
// Read-only apart from a scratch file inside the staging directory.
function precheck(snapshot, staging, options) {
	options ??= {};
	let items = [];
	let root = options.sys_root ?? '';
	let prefix = root == '' ? '' : replace(root, /\/$/, '');
	let nft_bin = options.bin_dir ? `${options.bin_dir}/nft` : 'nft';
	let ip_bin = options.bin_dir ? `${options.bin_dir}/ip` : 'ip';

	function add(item, ok, detail) {
		push(items, ok ? { item, ok } : { item, ok, detail });
	}

	// nft usable, with tproxy and socket support.
	let probe = staging + '/' + C.PRECHECK_NFT_FILE;

	if (!sys.write_atomic(probe, precheck_ruleset())) {
		add('nft', false, sys.error());
	}
	else {
		let r = sys.run([ nft_bin, '-c', '-f', probe ], { timeout: 10, quiet: true });

		add('nft', r.code == 0, r.code == 0 ? null : trim(r.stderr) || `nft exited ${r.code} (is nft installed, are kmod-nft-tproxy and kmod-nft-socket loaded?)`);

		if (!fs.unlink(probe))
			add('nft', false, `cannot remove ${probe}: ${fs.error() ?? 'unknown error'}`);
	}

	// ip rule with fwmark/mask needs ip-full. `ip rule help` only prints usage; busybox ip
	// has no "FWMARK[/MASK]" selector in it.
	// TODO(design): the "fwmark FWMARK[/MASK]" help text is assumed from iproute2 and was not
	// verified against busybox ip on 24.10.8.
	let ip = sys.run([ ip_bin, 'rule', 'help' ], { timeout: 5, quiet: true });
	let help = ip.stdout + '\n' + ip.stderr;

	add('ip_rule_fwmark', index(help, 'FWMARK') >= 0 && index(help, '/MASK') >= 0,
		'ip rule does not support fwmark/mask (install ip-full)');

	// lan_ifaces must exist.
	for (let ifname in (snapshot.main.lan_ifaces ?? [])) {
		let ok = index(ifname, '/') < 0 && fs.stat(prefix + C.SYS_CLASS_NET + '/' + ifname) != null;

		add('lan_iface:' + ifname, ok, `interface ${ifname} does not exist`);
	}

	let components = {};

	for (let name, key in { [C.XRAY_COMPONENT]: 'xray_bin', [C.CHINADNS_COMPONENT]: 'chinadns_bin' }) {
		let found = find_component(name, snapshot.main[key], options);

		components[name] = found ? { found: true, ...found } : { found: false };
	}

	return { items, components };
}

export { precheck };

export function run(args) {
	let p = pipeline.parse_args(args);

	if (p.error || length(p.positional)) {
		let detail = p.error ?? 'check takes no arguments';

		return pipeline.finish({ json: !!(p.opts?.json || index(args, '--json') >= 0) },
			{ ok: false, code: 'USAGE', detail, errors: [] }, 2, `${detail}\nUsage: aether-proxy check [--json]`);
	}

	let opts = p.opts;
	let res = pipeline.build(opts);

	function fail(code, detail, errors, exit) {
		log.event(null, code, { detail });

		let r = { ok: false, code, detail, errors };

		return pipeline.finish(opts, r, exit, pipeline.describe_errors(r));
	}

	if (!res.ok) {
		log.event(null, res.code, { detail: res.detail });

		return pipeline.finish(opts, { ok: false, code: res.code, detail: res.detail, errors: res.errors },
			res.exit, pipeline.describe_errors(res));
	}

	let staging = pipeline.run_dir(opts) + '/' + C.STAGING_SUBDIR;

	if (!sys.mkdir_p(staging))
		return fail('RENDER_INVALID', `cannot create ${staging}: ${sys.error()}`, [], 1);

	let files = {};

	for (let name, file in C.ARTIFACT_FILES) {
		let path = staging + '/' + file;

		if (!sys.write_atomic(path, res.artifacts[name]))
			return fail('RENDER_INVALID', `cannot write ${path}: ${sys.error()}`, [], 1);

		files[name] = path;
	}

	let result = { ok: true, staging, files, warnings: res.warnings, precheck: null, validation: null };

	if (opts.no_precheck) {
		result.precheck = { skipped: true };
		result.validation = { skipped: true };

		return pipeline.finish(opts, result, 0, `ok: rendered to ${staging} (checks skipped)`);
	}

	let pc = precheck(res.snapshot, staging);
	let bad = filter(pc.items, i => !i.ok);

	result.precheck = { skipped: false, items: pc.items, components: pc.components };

	if (length(bad)) {
		return fail('PRECHECK_FAILED', `${length(bad)} precheck item(s) failed`,
			map(bad, i => ({ item: i.item, code: 'failed', detail: i.detail })), 1);
	}

	// Missing components are not a failure here (the user may not have downloaded them yet);
	// they are surfaced as warnings and the matching validator is skipped.
	// TODO(design): docs/04 step 3 treats a missing binary as COMPONENT_MISSING at start;
	// whether `check` should fail on it is not specified. Version checks (COMPONENT_TOO_OLD)
	// and the chinadns-ng trial run (docs/03 "核实项") are not done here either.
	for (let name, c in pc.components) {
		if (!c.found)
			push(result.warnings, { code: 'COMPONENT_MISSING', args: { component: name } });
	}

	let validation = {};
	let errors = [];

	let r = sys.run([ options.bin_dir ? `${options.bin_dir}/nft` : 'nft', '-c', '-f', files.nft ], { timeout: 10, quiet: true });

	validation.nft = { ok: r.code == 0 };

	if (r.code != 0)
		push(errors, { item: 'nft', code: 'failed', detail: trim(r.stderr) });

	let xr = pc.components[C.XRAY_COMPONENT];

	if (!xr.found) {
		validation.xray = { skipped: true, detail: 'xray binary not found' };
	}
	else {
		r = sys.run([ xr.path, 'run', '-test', '-c', files.xray ], { timeout: 20, quiet: true });
		validation.xray = { ok: r.code == 0, path: xr.path };

		if (r.code != 0)
			push(errors, { item: 'xray', code: 'failed', detail: trim(r.stderr) || trim(r.stdout) });
	}

	result.validation = validation;

	if (length(errors))
		return fail('RENDER_INVALID', `${length(errors)} validation(s) failed`, errors, 4);

	return pipeline.finish(opts, result, 0, `ok: rendered and validated in ${staging}`);
};
