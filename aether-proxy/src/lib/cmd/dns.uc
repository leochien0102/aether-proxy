'use strict';

// Hotplug's business logic: compare current ISP DNS with the applied observation,
// then request one asynchronous reload (docs/03 "运营商下发的 DNS", docs/10 "dns sync-wan").
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as pipeline from 'aetherproxy.pipeline';
import * as state from 'aetherproxy.state';
import * as sys from 'aetherproxy.sys';

function finish(opts, value, exit) {
	return pipeline.finish(opts, value, exit, sprintf('%.J', value));
}

export function run(args) {
	let parsed = pipeline.parse_args(args);
	let opts = parsed.opts ?? { json: index(args, '--json') >= 0 };
	if (parsed.error || length(parsed.positional) != 1 || parsed.positional[0] != 'sync-wan')
		return finish(opts, { ok: false, code: 'USAGE',
			detail: parsed.error ?? 'expected `dns sync-wan`' }, 2);

	let root = replace(opts.sys_root ?? '', /\/$/, '');
	let cfg = config.load(uci.cursor(opts.confdir ?? (root + C.CONFIG_DIR)));
	if (!cfg.ok)
		return finish(opts, { ok: false, code: 'CONFIG_INVALID',
			detail: 'invalid configuration', errors: cfg.errors }, 2);
	let value = { ok: true, wan_dns: null, reload: false };
	// TODO(design): 10 does not define wan_dns for a skipped lookup. Use null when
	// wan is not configured or the service is stopped; do not perform unnecessary I/O.
	if (index(cfg.snapshot.dns.china_dns, 'wan') < 0)
		return finish(opts, value, 0);
	let current = state.read(opts.run_dir ?? (root + C.RUN_DIR));
	// TODO(design): 03 does not specify corrupt state handling. Refuse to reload rather
	// than guess the applied DNS; match the existing node/mode selection error contract.
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
