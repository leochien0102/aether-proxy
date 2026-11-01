'use strict';

// Read-only Dashboard counters (docs/10 "Dashboard：概览页升级", part 1).
// Missing runtime sources are independent nulls, never events: polling must not flood logd.
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';
import * as counters from 'aetherproxy.counters';

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

export function run(args) {
	let parsed = pipeline.parse_args(args);
	let error = parsed.error;
	if (!error && length(parsed.positional))
		error = 'stats takes no arguments';
	for (let key in keys(parsed.opts ?? {}))
		if (!(key in [ 'json', 'run_dir', 'sys_root', 'bin_dir' ]))
			error = `option ${key} is not supported by stats`;
	if (error)
		return pipeline.finish({ json: index(args, '--json') >= 0 },
			{ ok: false, code: 'USAGE', detail: error }, 2, error);
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
