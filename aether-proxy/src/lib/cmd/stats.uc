'use strict';

// Dashboard counters, live history and quota (docs/design/b25-quota-heatmap-20261116.md §2.1/§3).
// Read-only Dashboard counters (docs/10 "Dashboard：概览页升级", part 1) and the B25
// daily usage history (docs/10 "stats history", T12.5). Missing runtime sources are
// independent nulls, never events: polling must not flood logd.
import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';
import * as config from 'aetherproxy.config';
import * as counters from 'aetherproxy.counters';
import * as log from 'aetherproxy.log';
import * as usage from 'aetherproxy.usage';
import * as state_file from 'aetherproxy.state';

function read_object(path) {
	let text = fs.readfile(path);
	if (text == null)
		return null;
	try {
		let value = json(text);
		return type(value) == 'object' ? value : null;
	}
	catch (e) {
		// Damaged transient state is unavailable, not a failure of this read-only request.
		return null;
	}
}

function proxy_bytes(opts) {
	return counters.proxy_counters({ bin_dir: opts.bin_dir ?? null });
}

function wan_bytes(root) {
	let routes = fs.readfile(root + C.PROC_NET_ROUTE);
	let devices = fs.readfile(root + C.PROC_NET_DEV);
	if (routes == null || devices == null)
		return null;
	let dev = null, metric = null;
	for (let line in split(routes, '\n')) {
		let fields = split(trim(line), /\s+/);
		if (length(fields) < 8 || fields[1] != '00000000' || !match(fields[6], /^[0-9]+$/))
			continue;
		if (metric == null || +fields[6] < metric) {
			dev = fields[0];
			metric = +fields[6];
		}
	}
	if (dev == null)
		return null;
	for (let line in split(devices, '\n')) {
		let parts = split(line, ':');
		if (length(parts) != 2 || trim(parts[0]) != dev)
			continue;
		let fields = split(trim(parts[1]), /\s+/);
		if (length(fields) < 9 || !match(fields[0], /^[0-9]+$/) || !match(fields[8], /^[0-9]+$/))
			return null;
		return { dev, tx_bytes: +fields[8], rx_bytes: +fields[0] };
	}
	return null;
}

function established(text, remote) {
	let count = 0;
	for (let line in split(text, '\n')) {
		let fields = split(trim(line), /\s+/);
		if (length(fields) < 4 || fields[3] != '01')
			continue;
		if (uc(split(fields[2], ':')[0]) == remote)
			count++;
	}
	return count;
}

function proxy_connections(root, run_dir) {
	let ip = read_object(`${run_dir}/${C.STATE_FILE}`)?.node_ip;
	if (type(ip) != 'string' || !match(ip, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/))
		return null;
	let octets = split(ip, '.');
	for (let octet in octets)
		if (+octet > 255)
			return null;
	let remote = join('', map(reverse(octets), x => sprintf('%02X', +x)));
	let tcp = fs.readfile(root + C.PROC_NET_TCP);
	let tcp6 = fs.readfile(root + C.PROC_NET_TCP6);
	if (tcp == null || tcp6 == null)
		return null;
	// /proc prints each 32-bit word in host order, including the IPv4-mapped prefix.
	return established(tcp, remote) + established(tcp6, '0000000000000000FFFF0000' + remote);
}

function usage_error(args, error) {
	return pipeline.finish({ json: index(args, '--json') >= 0 },
		{ ok: false, code: 'USAGE', detail: error }, 2, error);
}

// --days belongs to `stats history` (docs/10 "stats history"); parse_args has no
// numeric value option for it, so it is lifted out before the shared parsing and
// validated by the history branch alone.
function lift_days(args) {
	let rest = [], days = null;
	for (let i = 0; i < length(args); i++) {
		if (args[i] != '--days') {
			push(rest, args[i]);
			continue;
		}
		if (days != null)
			return { error: '--days given more than once' };
		if (i + 1 >= length(args))
			return { error: 'option --days needs a value' };
		days = args[++i];
	}
	return { args: rest, days };
}

function history_limit(raw) {
	if (raw == null)
		return C.USAGE_DAYS_KEEP;
	return match(raw, /^[0-9]+$/) != null && +raw >= 1 && +raw <= C.USAGE_DAYS_KEEP
		? +raw : null;
}

// The last `limit` dates with data, oldest first (docs/b25-heatmap.md §6). Only the
// five documented fields cross the API; load's private unknown fields do not.
function history_entries(days, limit) {
	let dates = sort(keys(days));
	if (length(dates) > limit)
		dates = slice(dates, length(dates) - limit);
	return map(dates, date => {
		let entry = days[date];
		return { date, tx: entry.tx, rx: entry.rx, observed: entry.observed, healthy: entry.healthy };
	});
}

// T12.5 `stats history`: read-only daily usage for the heatmap. Reads the switch from
// the configuration first — with it off the usage file is never opened (docs/b25-heatmap.md
// §2). A missing or corrupt file is an empty history (§5/§8), never an error reply.
function history_cmd(opts, limit, args) {
	let root = replace(opts.sys_root ?? '', /\/$/, '');
	let cfg = config.load(uci.cursor(opts.confdir ?? (root + C.CONFIG_DIR)));
	if (!cfg.ok) {
		let res = {
			ok: false, code: 'CONFIG_INVALID',
			detail: `${length(cfg.errors)} configuration error(s)`, errors: cfg.errors
		};
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			res, 2, pipeline.describe_errors(res));
	}
	if (cfg.snapshot.stats.heatmap_enabled !== true)
		return pipeline.finish(opts, { ok: true, enabled: false, days: [], quota: usage.quota_of(null) }, 0,
			sprintf('%.J', { ok: true, enabled: false, days: [], quota: usage.quota_of(null) }));
	let loaded = usage.load(root + C.USAGE_FILE);
	// T16.8, design §2.1: overlay only today's fresh tmpfs accumulators.
	// Filtering happens afterwards so a newly added date participates in --days.
	let now = time(), tm = localtime(now);
	let live = state_file.usage_today_of(read_object(pipeline.run_dir(opts) + '/' + C.STATE_FILE), now);
	let today = sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
	// Live already includes the startup seed, so it replaces rather than adds to the disk entry.
	if (live != null && live.date == today)
		loaded.days[today] = { tx: live.tx, rx: live.rx, observed: live.observed, healthy: live.healthy };
	let result = { ok: true, enabled: true,
		days: history_entries(loaded.days, limit), updated_at: loaded.updated_at,
		quota: usage.quota_of(loaded.document) };
	return pipeline.finish(opts, result, 0, sprintf('%.J', result));
}

function warn_load(loaded, path, opts) {
	if (loaded.error != null) {
		log.set_run_dir(pipeline.run_dir(opts));
		log.event('warn', 'FS_FAILED', { op: loaded.op, path, detail: loaded.error });
	}
}

function quota_cmd(parsed, args) {
	let opts = parsed.opts;
	let words = parsed.positional;
	let action = words[1] ?? 'show';
	let bytes = action == 'set' ? usage.parse_quota(words[2]) : null;
	let count = action == 'set' ? 3 : action == 'show' ? 1 : 2;
	if (index([ 'show', 'set', 'clear' ], action) < 0 || length(words) != count ||
		(action == 'set' && bytes == null))
		return usage_error(args, 'stats quota [set <integer bytes|G|GB|T|TB>|clear]');
	let path = replace(opts.sys_root ?? '', /\/$/, '') + C.USAGE_FILE;
	let loaded = action == 'show' ? usage.load(path) : null;
	let written = action == 'show' ? null : usage.set_quota(path, bytes, time());
	warn_load(loaded ?? written.loaded, path, opts);
	if (written != null && !written.ok) {
		log.set_run_dir(pipeline.run_dir(opts));
		log.event('error', 'FS_FAILED', { op: 'write', path, detail: written.error });
		return pipeline.finish(opts, { ok: false, code: 'FS_FAILED', detail: written.error }, 1, written.error);
	}
	let result = { ok: true, quota: written?.quota ?? usage.quota_of(loaded?.document) };
	return pipeline.finish(opts, result, 0, sprintf('%.J', result));
}

export function run(args) {
	let lifted = lift_days(args);
	if (lifted.error != null)
		return usage_error(args, lifted.error);
	let parsed = pipeline.parse_args(lifted.args);
	let error = parsed.error;
	let history = !error && parsed.positional[0] == 'history';
	let quota = !error && parsed.positional[0] == 'quota';
	if (!error && !quota && length(parsed.positional) > (history ? 1 : 0))
		error = history ? 'stats history takes no arguments' : 'stats takes no arguments';
	if (!error) {
		let allowed = quota ? [ 'json', 'run_dir', 'sys_root' ]
			: history ? [ 'json', 'confdir', 'run_dir', 'sys_root' ]
			: [ 'json', 'run_dir', 'sys_root', 'bin_dir' ];
		for (let key in keys(parsed.opts ?? {}))
			if (!(key in allowed))
				error = `option ${key} is not supported by ${history ? 'stats history' : 'stats'}`;
	}
	if (!error && !history && lifted.days != null)
		error = '--days is only valid with stats history';
	if (!error && history && lifted.days != null && history_limit(lifted.days) == null)
		error = `--days must be an integer between 1 and ${C.USAGE_DAYS_KEEP}`;
	if (error)
		return usage_error(args, error);
	if (quota)
		return quota_cmd(parsed, args);
	if (history)
		return history_cmd(parsed.opts, history_limit(lifted.days), args);
	let opts = parsed.opts;
	let root = replace(opts.sys_root ?? '', /\/$/, '');
	let total = fs.readfile(root + C.CONNTRACK_COUNT);
	total = total != null && match(trim(total), /^[0-9]+$/) ? +trim(total) : null;
	let now = clock(true);
	let result = {
		ok: true, at_ms: now[0] * 1000 + now[1] / 1000000,
		proxy: proxy_bytes(opts), wan: wan_bytes(root),
		connections: { proxy: proxy_connections(root, pipeline.run_dir(opts)), total }
	};
	return pipeline.finish(opts, result, 0, sprintf('%.J', result));
};
