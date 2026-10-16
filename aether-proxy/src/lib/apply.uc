'use strict';

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as net from 'aetherproxy.net';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';

function system_path(ctx, path) {
	let root = ctx.root ?? '';
	return root == '' ? path : replace(root, /\/$/, '') + path;
};

function run_dir(ctx) {
	return system_path(ctx, ctx.run_dir ?? C.RUN_DIR);
};

function state_dir(ctx) {
	return system_path(ctx, ctx.state_dir ?? C.STATE_DIR);
};

function command(ctx, name) {
	return ctx.bin_dir ? `${ctx.bin_dir}/${name}` : name;
};

function array_has(values, item) {
	for (let value in values ?? [])
		if (value == item)
			return true;
	return false;
};

function nft_table_args() {
	return split(C.NFT_TABLE, ' ');
};

function setup_log(ctx) {
	log.set_run_dir(run_dir(ctx));
};

function failed(ctx, step, detail, code) {
	setup_log(ctx);
	log.event('error', code ?? 'START_FAILED', code == 'DNSMASQ_CONFDIR_NOT_FOUND' ? { servers: detail } : { step, detail });
	return { ok: false, detail };
};

function result(detail, extra) {
	return { ok: true, detail, ...(extra ?? {}) };
};

function exec(ctx, name, args, quiet) {
	let argv = [ command(ctx, name), ...args ];
	return sys.run(argv, { timeout: 10, quiet: quiet ?? false });
};

function missing_object(text) {
	let s = lc(`${text ?? ''}`);
	return index(s, 'no such file or directory') >= 0 || index(s, 'does not exist') >= 0 || index(s, 'not found') >= 0;
};

function nft_load(ctx, file) {
	setup_log(ctx);
	let r = exec(ctx, 'nft', [ '-f', file ]);
	return r.code == 0 ? result('nft ruleset loaded') : failed(ctx, 'nft_load', `nft -f ${file} failed (${r.code}): ${r.stderr}`);
};

function nft_delete(ctx) {
	setup_log(ctx);
	let r = exec(ctx, 'nft', [ 'delete', 'table', ...nft_table_args() ], true);
	if (r.code == 0 || missing_object(r.stderr + r.stdout))
		return result('nft table deleted or absent');
	return failed(ctx, 'nft_delete', `nft delete table failed (${r.code}): ${r.stderr}`);
};

function nft_table_exists(ctx) {
	setup_log(ctx);
	let r = exec(ctx, 'nft', [ 'list', 'table', ...nft_table_args() ], true);
	if (r.code == 0)
		return result('nft table exists', { exists: true });
	if (missing_object(r.stderr + r.stdout))
		return result('nft table absent', { exists: false });
	return failed(ctx, 'nft_table_exists', `nft list table failed (${r.code}): ${r.stderr}`);
};

function nft_flush_prerouting(ctx) {
	setup_log(ctx);
	let r = exec(ctx, 'nft', [ 'flush', 'chain', ...nft_table_args(), 'prerouting' ], true);
	if (r.code == 0 || missing_object(r.stderr + r.stdout))
		return result('prerouting flushed or absent');
	return failed(ctx, 'nft_flush_prerouting', `nft flush chain failed (${r.code}): ${r.stderr}`);
};

function ipv4_number(ip) {
	let p = map(split(ip, '.'), n => +n);
	return p[0] * 16777216 + p[1] * 65536 + p[2] * 256 + p[3];
};

function canonical_value(value) {
	if (type(value) == 'string')
		return net.ip_or_cidr(value) == null ? null : replace(value, /\/32$/, '');
	if (type(value) == 'object' && value.prefix) {
		let prefix = value.prefix;
		if (type(prefix.addr) == 'string' && type(prefix.len) == 'int')
			return net.ip_or_cidr(`${prefix.addr}/${prefix.len}`) == null ? null : (prefix.len == 32 ? prefix.addr : `${prefix.addr}/${prefix.len}`);
	}
	return null;
};

function elem_to_cidrs(value) {
	let single = canonical_value(value);
	if (single != null)
		return [ single ];
	if (type(value) == 'object' && value.range && type(value.range) == 'array' && length(value.range) == 2)
		return net.range_to_cidrs(value.range[0], value.range[1]);
	return null;
};

function sort_values(values) {
	let unique = {}, out = [];
	for (let item in values) {
		if (!unique[item]) {
			unique[item] = true;
			push(out, item);
		}
	}
	return sort(out, (a, b) => {
		let pa = net.cidr_parts(a), pb = net.cidr_parts(b);
		let aa = ipv4_number(replace(a, /\/.*$/, ''));
		let ab = ipv4_number(replace(b, /\/.*$/, ''));
		return aa != ab ? (aa < ab ? -1 : 1) : pa.len - pb.len;
	});
};

function decode_set(text, name) {
	let doc;
	try {
		doc = json(text);
	}
	catch (e) {
		return { error: `invalid nft JSON: ${e}` };
	}

	let found = null;
	for (let row in doc?.nftables ?? [])
		if (row.set?.name == name)
			found = row.set;
	if (found == null)
		return { error: `nft JSON contains no set named ${name}` };

	let values = [];
	// libnftables JSON lists plain elements as bare values ("1.2.3.4", {"prefix":...},
	// {"range":[...]}); only elements carrying timeout/counter/comment are wrapped as
	// {"elem":{"val":...}}.
	for (let item in found.elem ?? []) {
		let value = item;
		if (type(item) == 'object' && item.elem != null)
			value = item.elem?.val ?? item.elem;
		let cidrs = elem_to_cidrs(value);
		if (cidrs == null)
			return { error: `unsupported ${name} element ${sprintf('%.J', value)}` };
		push(values, ...cidrs);
	}
	return { values: sort_values(values) };
};

function sets_export(ctx) {
	setup_log(ctx);
	let sets = {};
	for (let name in C.NFT_DYNAMIC_SETS) {
		let r = exec(ctx, 'nft', [ '-j', 'list', 'set', ...nft_table_args(), name ]);
		if (r.code != 0)
			return failed(ctx, 'sets_export', `nft list set ${name} failed (${r.code}): ${r.stderr}`);
		let decoded = decode_set(r.stdout, name);
		if (decoded.error)
			return failed(ctx, 'sets_export', decoded.error);
		sets[name] = decoded.values;
	}
	return result('dynamic sets exported', { sets });
};

function valid_sets(sets) {
	if (type(sets) != 'object')
		return false;
	for (let name in C.NFT_DYNAMIC_SETS) {
		if (type(sets[name]) != 'array')
			return false;
		for (let item in sets[name])
			if (type(item) != 'string' || net.ip_or_cidr(item) == null)
				return false;
	}
	return true;
};

function sets_save(ctx, sets) {
	setup_log(ctx);
	if (!valid_sets(sets))
		return failed(ctx, 'sets_save', 'sets must contain valid IPv4 arrays for all dynamic sets');
	if (!sys.mkdir_p(run_dir(ctx)))
		return failed(ctx, 'sets_save', `cannot create ${run_dir(ctx)}: ${sys.error()}`);
	let path = `${run_dir(ctx)}/${C.SETS_SAVE_FILE}`;
	if (!sys.write_atomic(path, sprintf('%.J\n', sets)))
		return failed(ctx, 'sets_save', `cannot write ${path}: ${sys.error()}`);
	return result('dynamic sets saved');
};

function sets_load(ctx) {
	setup_log(ctx);
	let path = `${run_dir(ctx)}/${C.SETS_SAVE_FILE}`;
	let text = fs.readfile(path);
	if (text == null && fs.stat(path) == null)
		return result('no saved dynamic sets', { sets: { gfw4: [], udirect4: [], uproxy4: [] } });
	if (text == null)
		return failed(ctx, 'sets_load', `cannot read ${path}: ${fs.error() ?? 'unknown error'}`);
	let sets;
	try {
		sets = json(text);
	}
	catch (e) {
		return failed(ctx, 'sets_load', `invalid ${path}: ${e}`);
	}
	if (!valid_sets(sets))
		return failed(ctx, 'sets_load', `invalid dynamic sets in ${path}`);
	if (!fs.unlink(path))
		return failed(ctx, 'sets_load', `cannot remove ${path}: ${fs.error() ?? 'unknown error'}`);
	return result('dynamic sets loaded and save file removed', { sets });
};

function ip_rule_matches(text) {
	let mark = replace(C.FWMARK, /0x0+/g, '0x');
	for (let line in split(text ?? '', '\n')) {
		if (split(line, ':')[0] == `${C.RULE_PREF}` && index(line, `fwmark ${mark}`) >= 0 && index(line, `lookup ${C.ROUTE_TABLE}`) >= 0)
			return true;
	}
	return false;
};

function route_add(ctx) {
	setup_log(ctx);
	let show = exec(ctx, 'ip', [ 'rule', 'show' ]);
	if (show.code != 0)
		return failed(ctx, 'route_add', `ip rule show failed (${show.code}): ${show.stderr}`);
	if (!ip_rule_matches(show.stdout)) {
		let add = exec(ctx, 'ip', [ 'rule', 'add', 'fwmark', C.FWMARK, 'lookup', `${C.ROUTE_TABLE}`, 'pref', `${C.RULE_PREF}` ]);
		if (add.code != 0)
			return failed(ctx, 'route_add', `ip rule add failed (${add.code}): ${add.stderr}`);
	}
	let route = exec(ctx, 'ip', [ 'route', 'replace', 'local', 'default', 'dev', 'lo', 'table', `${C.ROUTE_TABLE}` ]);
	return route.code == 0 ? result('policy route installed') : failed(ctx, 'route_add', `ip route replace failed (${route.code}): ${route.stderr}`);
};

function route_del(ctx) {
	setup_log(ctx);
	let show = exec(ctx, 'ip', [ 'rule', 'show' ]);
	if (show.code != 0)
		return failed(ctx, 'route_del', `ip rule show failed (${show.code}): ${show.stderr}`);
	let found = ip_rule_matches(show.stdout);
	let attempts = 0;
	while (found && attempts++ < 16) {
		let del = exec(ctx, 'ip', [ 'rule', 'del', 'fwmark', C.FWMARK, 'lookup', `${C.ROUTE_TABLE}`, 'pref', `${C.RULE_PREF}` ]);
		if (del.code != 0)
			return failed(ctx, 'route_del', `ip rule del failed (${del.code}): ${del.stderr}`);
		show = exec(ctx, 'ip', [ 'rule', 'show' ]);
		if (show.code != 0)
			return failed(ctx, 'route_del', `ip rule show failed (${show.code}): ${show.stderr}`);
		found = ip_rule_matches(show.stdout);
	}
	if (found)
		return failed(ctx, 'route_del', 'more than 16 duplicate policy rules remain');
	let flush = exec(ctx, 'ip', [ 'route', 'flush', 'table', `${C.ROUTE_TABLE}` ], true);
	// An already empty table makes ip(8) fail with "No such process" (ESRCH, seen on a device):
	// nothing to remove is success for an idempotent cleanup.
	if (flush.code != 0 && index(flush.stderr ?? '', 'No such process') >= 0)
		return result('policy rules and routes removed');
	return flush.code == 0 ? result('policy rules and routes removed') : failed(ctx, 'route_del', `ip route flush failed (${flush.code}): ${flush.stderr}`);
};

function list_files(path) {
	let entries = fs.lsdir(path);
	return entries == null ? null : sort(entries);
};

// dnsmasq.conf.<uci section>. The init script writes <file>.<pid> first and renames it;
// a killed init leaves that temp file behind, which is not an instance.
function instance_conf(name) {
	return match(name, /^dnsmasq\.conf\.[^.]+$/) != null;
};

function parse_conf_file(path) {
	let text = fs.readfile(path);
	if (text == null)
		return null;
	let confdir = null, interfaces = [];
	for (let line in split(text, '\n')) {
		line = trim(line);
		if (match(line, /^conf-dir=/)) {
			let value = substr(line, 9);
			confdir = split(value, ',')[0];
			confdir = trim(confdir, '"');
		}
		else if (match(line, /^interface=/))
			push(interfaces, trim(substr(line, 10), '"'));
	}
	return confdir == null ? null : { confdir, interfaces };
};

// Locates the conf-dir dnsmasq generates its instance configuration into. This is the
// detection half of dnsmasq_confdir, kept free of event logging so that `status` notices
// can reuse it read-only (docs/10 「概览页」); apply wraps it with the reporting below.
// Returns { ok, confdir } or { ok: false, code, detail }.
function find_dnsmasq_confdir(ctx) {
	let dir = system_path(ctx, C.DNSMASQ_CONFIG_DIR);
	let names = list_files(dir);
	if (names == null)
		return { ok: false, code: 'DNSMASQ_CONFDIR_NOT_FOUND', detail: `cannot list ${dir}: ${fs.error() ?? 'unknown error'}` };
	// dns.dnsmasq_instance pins one instance by its UCI section name (03).
	if (ctx.dnsmasq_instance) {
		let config = parse_conf_file(`${dir}/dnsmasq.conf.${ctx.dnsmasq_instance}`);
		if (config == null)
			return { ok: false, code: 'DNSMASQ_CONFDIR_NOT_FOUND', detail: `dnsmasq instance '${ctx.dnsmasq_instance}' has no conf-dir in ${dir}` };
		return { ok: true, confdir: system_path(ctx, config.confdir) };
	}
	let candidates = [];
	for (let name in names) {
		if (!instance_conf(name))
			continue;
		let config = parse_conf_file(`${dir}/${name}`);
		if (config != null)
			push(candidates, config);
	}
	let selected = [];
	for (let config in candidates)
		for (let iface in config.interfaces)
			if (array_has(ctx.lan_ifaces, iface)) {
				if (!array_has(selected, config.confdir))
					push(selected, config.confdir);
				break;
			}
	// No LAN match: instances without interface= serve every interface. Count distinct
	// conf-dirs, not files, so two configs pointing at one directory are not ambiguous.
	if (length(selected) == 0)
		for (let config in candidates)
			if (length(config.interfaces) == 0 && !array_has(selected, config.confdir))
				push(selected, config.confdir);
	selected = sort(selected);
	if (length(selected) != 1)
		return { ok: false, code: 'DNSMASQ_CONFDIR_NOT_FOUND', detail: `no unique conf-dir for LAN interfaces ${join(',', ctx.lan_ifaces ?? [])}` };
	return { ok: true, confdir: system_path(ctx, selected[0]) };
};

function dnsmasq_confdir(ctx) {
	setup_log(ctx);
	let found = find_dnsmasq_confdir(ctx);
	if (!found.ok)
		return failed(ctx, 'dnsmasq_confdir', found.detail, found.code);
	return result('dnsmasq conf-dir found', { confdir: found.confdir });
};

function dnsmasq_restart(ctx) {
	let path = system_path(ctx, C.DNSMASQ_INIT);
	let r = sys.run([ path, 'restart' ], { timeout: 10 });
	return r.code == 0 ? null : `dnsmasq restart failed (${r.code}): ${r.stderr}`;
};

function dnsmasq_install(ctx, content) {
	setup_log(ctx);
	if (type(content) != 'string')
		return failed(ctx, 'dnsmasq_install', 'content must be a string');
	let found = dnsmasq_confdir(ctx);
	if (!found.ok)
		return found;
	if (!sys.mkdir_p(found.confdir))
		return failed(ctx, 'dnsmasq_install', `cannot create ${found.confdir}: ${sys.error()}`);
	let path = `${found.confdir}/${C.DNSMASQ_FRAGMENT}`;
	let previous = fs.readfile(path);
	if (previous == null && fs.stat(path) != null)
		return failed(ctx, 'dnsmasq_install', `cannot read existing ${path}: ${fs.error() ?? 'unknown error'}`);
	if (!sys.write_atomic(path, content))
		return failed(ctx, 'dnsmasq_install', `cannot write ${path}: ${sys.error()}`);
	let err = dnsmasq_restart(ctx);
	if (err != null) {
		let restored = previous != null ? sys.write_atomic(path, previous) : fs.unlink(path);
		if (!restored)
			err += `; rollback failed: ${previous != null ? sys.error() : fs.error() ?? 'unknown error'}`;
		return failed(ctx, 'dnsmasq_install', err);
	}
	return result('dnsmasq fragment installed');
};

// Removal does not need the unique LAN conf-dir that install needs: our fragment is looked
// for in every dnsmasq instance's conf-dir, so cleanup still works while dnsmasq is being
// regenerated or the LAN interfaces changed since install.
function dnsmasq_remove(ctx) {
	setup_log(ctx);
	let dir = system_path(ctx, C.DNSMASQ_CONFIG_DIR);
	let names = list_files(dir);
	if (names == null)
		return failed(ctx, 'dnsmasq_remove', `cannot list ${dir}: ${fs.error() ?? 'unknown error'}`);
	let confdirs = [];
	for (let name in names) {
		if (!instance_conf(name))
			continue;
		let config = parse_conf_file(`${dir}/${name}`);
		if (config != null && !array_has(confdirs, config.confdir))
			push(confdirs, config.confdir);
	}
	let removed = {};
	for (let confdir in sort(confdirs)) {
		let path = `${system_path(ctx, confdir)}/${C.DNSMASQ_FRAGMENT}`;
		if (fs.stat(path) == null)
			continue;
		let previous = fs.readfile(path);
		if (previous == null)
			return failed(ctx, 'dnsmasq_remove', `cannot read ${path}: ${fs.error() ?? 'unknown error'}`);
		if (!fs.unlink(path))
			return failed(ctx, 'dnsmasq_remove', `cannot remove ${path}: ${fs.error() ?? 'unknown error'}`);
		removed[path] = previous;
	}
	if (!length(removed))
		return result('dnsmasq fragment absent');
	let err = dnsmasq_restart(ctx);
	if (err != null) {
		for (let path, previous in removed)
			if (!sys.write_atomic(path, previous))
				err += `; rollback of ${path} failed: ${sys.error()}`;
		return failed(ctx, 'dnsmasq_remove', err);
	}
	return result('dnsmasq fragment removed');
};

function dnsmasq_hup(ctx) {
	setup_log(ctx);
	let r = exec(ctx, 'killall', [ '-HUP', 'dnsmasq' ]);
	return r.code == 0 ? result('dnsmasq received HUP') : failed(ctx, 'dnsmasq_hup', `killall -HUP dnsmasq failed (${r.code}): ${r.stderr}`);
};

// Scans the generated dnsmasq configuration and every fragment except our own for
// `server=` lines — the detection half of dnsmasq_extra_servers, shared with the `status`
// notices (docs/10 「概览页」). Read-only and event-free; apply wraps it with the
// DNSMASQ_EXTRA_SERVERS reporting below. Returns { ok, servers } or { ok: false, code, detail }.
function scan_extra_servers(ctx) {
	let found = find_dnsmasq_confdir(ctx);
	if (!found.ok)
		return { ok: false, code: found.code, detail: found.detail };
	let config_dir = system_path(ctx, C.DNSMASQ_CONFIG_DIR);
	let generated = list_files(config_dir), fragments = list_files(found.confdir);
	if (generated == null || fragments == null)
		return { ok: false, code: 'START_FAILED', detail: `cannot list generated dnsmasq configuration: ${fs.error() ?? 'unknown error'}` };
	let own = `${found.confdir}/${C.DNSMASQ_FRAGMENT}`;
	let servers = [], paths = map(generated, n => `${config_dir}/${n}`);
	for (let name in fragments)
		if (`${found.confdir}/${name}` != own)
			push(paths, `${found.confdir}/${name}`);
	for (let path in paths) {
		let text = fs.readfile(path);
		if (text == null)
			return { ok: false, code: 'START_FAILED', detail: `cannot read ${path}: ${fs.error() ?? 'unknown error'}` };
		for (let line in split(text, '\n')) {
			line = trim(line);
			if (match(line, /^server=/) && !array_has(servers, line))
				push(servers, line);
		}
	}
	return { ok: true, servers: sort(servers) };
};

function dnsmasq_extra_servers(ctx) {
	setup_log(ctx);
	let scan = scan_extra_servers(ctx);
	if (!scan.ok)
		return failed(ctx, 'dnsmasq_extra_servers', scan.detail, scan.code);
	if (length(scan.servers))
		log.event('warn', 'DNSMASQ_EXTRA_SERVERS', { servers: join(';', scan.servers) });
	return result('external dnsmasq servers collected', { servers: scan.servers });
};

function read_lkg(ctx, address) {
	let path = `${state_dir(ctx)}/${C.NODE_IP_FILE}`;
	let text = fs.readfile(path);
	if (text == null)
		return null;
	try {
		let obj = json(text);
		// The LKG entry is bound to the node address, so switching nodes never reuses another node's IP.
		return obj.address == address && net.ipv4(obj.ip) != null ? obj.ip : null;
	}
	catch (e) {
		return null;
	}
};

function resolve_node(ctx, address) {
	setup_log(ctx);
	if (type(address) != 'string' || address == '')
		return failed(ctx, 'resolve_node', 'address must be a non-empty string');
	if (net.ipv4(address) != null)
		return result('literal IPv4 address', { ip: address, source: 'literal' });
	let resolved = exec(ctx, 'resolveip', [ '-4', '-t', '5', address ], true);
	if (resolved.code == 0) {
		let ips = [];
		for (let line in split(trim(resolved.stdout), '\n'))
		if (net.ipv4(trim(line)) != null && !array_has(ips, trim(line)))
				push(ips, trim(line));
		if (length(ips)) {
			// Several A records: take the first valid one (03-dns.md, bootstrap resolution).
			let ip = ips[0], path = `${state_dir(ctx)}/${C.NODE_IP_FILE}`;
			let old = read_lkg(ctx, address);
			if (old != ip) {
				if (!sys.mkdir_p(state_dir(ctx)))
					return failed(ctx, 'resolve_node', `cannot create ${state_dir(ctx)}: ${sys.error()}`);
				if (!sys.write_atomic(path, sprintf('%.J\n', { address, ip })))
					return failed(ctx, 'resolve_node', `cannot write ${path}: ${sys.error()}`);
			}
			return result('node address resolved', { ip, source: 'dns' });
		}
	}
	let lkg = read_lkg(ctx, address);
	if (lkg != null) {
		log.event('warn', 'NODE_RESOLVE_FALLBACK', { node: address, domain: address, lkg_ip: lkg });
		return result('last-known-good address used', { ip: lkg, source: 'lkg' });
	}
	log.event('error', 'NODE_RESOLVE_FAILED', { node: address, domain: address, lkg_ip: '' });
	return { ok: false, detail: `cannot resolve ${address}` };
};

function write_boot_list(ctx, domains) {
	setup_log(ctx);
	if (type(domains) != 'array')
		return failed(ctx, 'write_boot_list', 'domains must be an array');
	let values = [];
	for (let domain in domains) {
		if (type(domain) != 'string' || net.domain(domain) == null)
			return failed(ctx, 'write_boot_list', `invalid domain ${domain}`);
		if (!array_has(values, lc(domain)))
			push(values, lc(domain));
	}
	let path = `${run_dir(ctx)}/${C.BOOT_LIST_FILE}`;
	if (!sys.mkdir_p(run_dir(ctx)))
		return failed(ctx, 'write_boot_list', `cannot create ${run_dir(ctx)}: ${sys.error()}`);
	if (!sys.write_atomic(path, length(values) ? join('\n', sort(values)) + '\n' : ''))
		return failed(ctx, 'write_boot_list', `cannot write ${path}: ${sys.error()}`);
	return result('boot list written');
};

function conflicts(ctx) {
	setup_log(ctx);
	let table_list = exec(ctx, 'nft', [ 'list', 'tables' ]);
	if (table_list.code != 0)
		return failed(ctx, 'conflicts', `nft list tables failed (${table_list.code}): ${table_list.stderr}`);
	let names = [];
	for (let line in split(table_list.stdout, '\n')) {
		let parts = split(trim(line), /[[:space:]]+/);
		if (length(parts) >= 3 && parts[0] == 'table')
			push(names, parts[2]);
	}
	let active = [];
	for (let name in names)
		if (name == C.CONFLICT_NFT_SSR || substr(name, 0, length(C.CONFLICT_NFT_PASSWALL_PREFIX)) == C.CONFLICT_NFT_PASSWALL_PREFIX)
			push(active, name);
	for (let process in C.CONFLICT_PROCESSES) {
		// killall -0 verified on the lede busybox (2026-10-15): rc 0 when the process exists, 1 when it does not.
		let check = exec(ctx, 'killall', [ '-0', process ], true);
		if (check.code == 0)
			push(active, process);
	}
	return result('conflicting services inspected', { conflicts: sort(active) });
};

function sha256_file(path) {
	let r = sys.run([ 'sha256sum', path ], { timeout: 10 });
	if (r.code != 0)
		return { ok: false, detail: `sha256sum ${path} failed (${r.code}): ${r.stderr}` };
	let m = match(trim(r.stdout), /^([0-9a-fA-F]{64})\s/);
	if (m == null)
		return { ok: false, detail: `cannot parse sha256sum output for ${path}` };
	return { ok: true, hash: lc(m[1]) };
};

// List files chinadns-ng reads by path: *-file keys and group-dnl, comma-separated.
function chinadns_list_paths(text) {
	let paths = [];
	for (let line in split(text ?? '', '\n')) {
		let m = match(trim(line), /^([a-z0-9-]+)[ \t]+(.+)$/);
		if (m == null || !(match(m[1], /-file$/) || m[1] == 'group-dnl'))
			continue;
		for (let path in split(m[2], ','))
			if (trim(path) != '')
				push(paths, trim(path));
	}
	return paths;
};

// Hashes of the rendered artifacts in dir, as compared by reload (04). chinadns.conf names its
// domain lists by path, so its hash also covers the content of every list it references: a
// changed custom or data list must restart chinadns-ng even though the config text is the same.
function artifact_hashes(ctx, dir) {
	let hashes = {};
	for (let name, file in C.ARTIFACT_FILES) {
		let own = sha256_file(`${dir}/${file}`);
		if (!own.ok)
			return own;
		hashes[name] = own.hash;
	}
	let parts = [ hashes.chinadns ];
	for (let path in chinadns_list_paths(fs.readfile(`${dir}/${C.ARTIFACT_FILES.chinadns}`))) {
		// Default lists are device paths under the system root; --custom-dir/--data-dir (tests)
		// put real paths into the config, so fall back to the path as written.
		let full = system_path(ctx, path);
		if (fs.stat(full) == null && fs.stat(path) != null)
			full = path;
		if (fs.stat(full) == null) {
			push(parts, `${path}:missing`);
			continue;
		}
		let list = sha256_file(full);
		if (!list.ok)
			return list;
		push(parts, `${path}:${list.hash}`);
	}
	hashes.chinadns = join(',', parts);
	return { ok: true, hashes };
};

export {
	nft_load, nft_delete, nft_table_exists, nft_flush_prerouting,
	sets_export, sets_save, sets_load,
	route_add, route_del,
	dnsmasq_confdir, dnsmasq_install, dnsmasq_remove, dnsmasq_hup, dnsmasq_extra_servers,
	scan_extra_servers,
	resolve_node, write_boot_list, conflicts,
	artifact_hashes
};
