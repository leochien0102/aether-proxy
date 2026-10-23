'use strict';

// DNS diagnostics and hotplug synchronization (docs/03 "直连境外 DNS（可选）"
// and "运营商下发的 DNS", docs/10 command conventions).
import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as log from 'aetherproxy.log';
import * as pipeline from 'aetherproxy.pipeline';
import * as state from 'aetherproxy.state';
import * as sys from 'aetherproxy.sys';

function finish(opts, value, exit) {
	return pipeline.finish(opts, value, exit, sprintf('%.J', value));
}

// A private savedir isolates configuration reads from /tmp/.uci.
// Absolute-path loading also disables libuci's global delta replay.
function load_config(opts, root) {
	let confdir = fs.realpath(opts.confdir ?? (root + C.CONFIG_DIR));
	if (confdir == null)
		return { ok: false, code: 'CONFIG_INVALID', detail: fs.error() ?? 'cannot locate configuration' };
	let pid = fs.readlink(C.PROC_DIR + '/self');
	if (pid == null)
		return { ok: false, code: 'FS_FAILED', detail: fs.error() ?? 'cannot determine process ID' };
	let run_dir = opts.run_dir ?? (root + C.RUN_DIR);
	if (!sys.mkdir_p(run_dir))
		return { ok: false, code: 'FS_FAILED', detail: sys.error() };
	let savedir = `${run_dir}/${C.DNS_TEST_SAVEDIR_PREFIX}${pid}`;
	if (!fs.mkdir(savedir, 0700))
		return { ok: false, code: 'FS_FAILED', detail: fs.error() ?? 'cannot create private UCI savedir' };
	let cursor = uci.cursor(confdir, savedir);
	let cfg = cursor != null && cursor.load(`${confdir}/${C.UCI_PACKAGE}`)
		? config.load(cursor) : { ok: false, errors: [], detail: 'cannot load configuration' };
	if (cursor != null)
		cursor.unload(C.UCI_PACKAGE);
	cursor = null;
	if (!fs.rmdir(savedir))
		return { ok: false, code: 'FS_FAILED', detail: fs.error() ?? 'cannot remove private UCI savedir' };
	if (!cfg.ok)
		return { ok: false, code: 'CONFIG_INVALID', detail: cfg.detail ?? 'invalid configuration', errors: cfg.errors };
	return cfg;
}

function test_direct(opts, snapshot) {
	// Keep sync-wan independent of the optional diagnostic socket implementation.
	let diagnostic = loadstring("import * as m from 'aetherproxy.dns_test'; return m;")();
	let results;
	try {
		results = diagnostic.run(snapshot);
	}
	catch (e) {
		// Entropy I/O errors must preserve the CLI's single-JSON/empty-stderr contract.
		let detail = e.message ?? `${e}`;
		let root = replace(opts.sys_root ?? '', /\/$/, '');
		log.set_run_dir(opts.run_dir ?? (root + C.RUN_DIR));
		log.event('error', 'FS_FAILED', { op: 'dns-test-random', path: C.RANDOM_DEVICE, detail });
		return finish(opts, { ok: false, code: 'FS_FAILED', detail }, 1);
	}
	// docs/03: { ok, results }; the job stores it unchanged.
	let value = { ok: true, results };
	let lines = [];
	for (let row in value.results) {
		push(lines, row.upstream + (row.unsupported ? ': unsupported' : ''));
		if (row.unsupported)
			continue;
		for (let key in [ 'unblocked', 'blocked' ]) {
			let result = row[key];
			let latency = result.latency_ms == null ? '' : `, ${result.latency_ms} ms`;
			push(lines, `  ${key} ${result.domain}: ${result.ok}/${result.total}${latency}`);
		}
	}
	return pipeline.finish(opts, value, 0, join('\n', lines));
}

export function run(args) {
	let parsed = pipeline.parse_args(args);
	let opts = parsed.opts ?? { json: index(args, '--json') >= 0 };
	if (parsed.error || length(parsed.positional) != 1
		|| index([ 'sync-wan', 'test-direct' ], parsed.positional[0]) < 0)
		return finish(opts, { ok: false, code: 'USAGE',
			detail: parsed.error ?? 'expected `dns sync-wan` or `dns test-direct`' }, 2);

	let root = replace(opts.sys_root ?? '', /\/$/, '');
	if (parsed.positional[0] == 'test-direct') {
		let cfg = load_config(opts, root);
		if (!cfg.ok)
			return finish(opts, cfg, cfg.code == 'CONFIG_INVALID' ? 2 : 1);
		return test_direct(opts, cfg.snapshot);
	}
	// Preserve sync-wan's pre-existing read path and skipped-operation behavior.
	let cfg = config.load(uci.cursor(opts.confdir ?? (root + C.CONFIG_DIR)));
	if (!cfg.ok)
		return finish(opts, { ok: false, code: 'CONFIG_INVALID',
			detail: 'invalid configuration', errors: cfg.errors }, 2);
	let value = { ok: true, wan_dns: null, reload: false };
	// docs/10: a skipped lookup (no wan, service stopped) reports wan_dns null.
	if (index(cfg.snapshot.dns.china_dns, 'wan') < 0)
		return finish(opts, value, 0);
	let current = state.read(opts.run_dir ?? (root + C.RUN_DIR));
	// docs/10: corrupt state is FS_FAILED; never guess the applied DNS or reload.
	if (current == null)
		return finish(opts, { ok: false, code: 'FS_FAILED', detail: state.error() }, 1);
	if (index([ 'starting', 'running', 'degraded', 'failsafe' ], current.state) < 0)
		return finish(opts, value, 0);

	value.wan_dns = pipeline.read_wan_dns(opts);
	if (sprintf('%.J', current.wan_dns) == sprintf('%.J', value.wan_dns))
		return finish(opts, value, 0);
	let init = root + C.PROG_INIT;
	let res = sys.run([ init, 'reload' ], { timeout: C.WAN_DNS_RELOAD_TIMEOUT_SECS });
	if (res.code != 0)
		return finish(opts, { ok: false, code: 'CMD_FAILED',
			detail: `${init} reload: exit ${res.code}: ${trim(res.stderr)}` }, 1);
	value.reload = true;
	return finish(opts, value, 0);
};
