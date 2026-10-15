'use strict';

import * as fs from 'fs';
import * as apply from 'aetherproxy.apply';
import * as net from 'aetherproxy.net';
import * as sys from 'aetherproxy.sys';
import * as C from 'aetherproxy.const';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const STUB_SRC = ROOT + '/tests/stubs/bin';
let serial = 0;

export const cases = [
	{ name: 'minimal CIDR cover for IPv4 intervals', expect: 'PASS', kind: 'range' },
	{ name: 'nft primitives are idempotent and report errors', expect: 'PASS', kind: 'nft' },
	{ name: 'dynamic set export converts ranges and save/load', expect: 'PASS', kind: 'sets' },
	{ name: 'policy route add and delete are idempotent', expect: 'PASS', kind: 'routes' },
	{ name: 'dnsmasq directory selection and fragment lifecycle', expect: 'PASS', kind: 'dnsmasq' },
	{ name: 'node resolution uses literal DNS and matching LKG', expect: 'PASS', kind: 'resolve' },
	{ name: 'boot list and conflicts', expect: 'PASS', kind: 'misc' }
];

function fail(text) {
	return `FAIL: ${text}`;
};

function write(path, text) {
	let slash = rindex(path, '/');
	let dir = substr(path, 0, slash);
	return sys.mkdir_p(dir) && sys.write_atomic(path, text);
};

function read(path) {
	return fs.readfile(path) ?? '';
};

function prepare() {
	serial++;
	let base = `/tmp/aether-proxy-apply-${fs.readlink('/proc/self')}-${time()}-${serial}`;
	let bin = `${base}/stubs/bin`, log_path = `${base}/calls.log`;
	if (!sys.mkdir_p(bin))
		return { error: sys.error() };
	for (let name in [ 'common.sh', 'nft', 'ip', 'resolveip', 'killall' ]) {
		let target = `${bin}/${name}`;
		if (!write(target, fs.readfile(`${STUB_SRC}/${name}`) ?? ''))
			return { error: `cannot copy stub ${name}` };
		if (!fs.chmod(target, 493))
			return { error: `cannot chmod stub ${name}` };
	}
	let ctx = { root: base, bin_dir: bin, run_dir: '/var/run/aether-proxy', state_dir: '/etc/aether-proxy/state', lan_ifaces: [ 'br-lan', 'eth0.2' ] };
	let env = `STUB_LOG='${log_path}'\nSTUB_IP_RULES_FILE='${base}/ip-rules'\nSTUB_IP_RULE_LINE='900: from all fwmark 0x80000/0x80000 lookup 233'\n`;
	if (!write(`${base}/stubs/stub.env`, env) || !write(`${base}/ip-rules`, ''))
		return { error: 'cannot initialize stub config' };
	return { base, bin, log_path, ctx };
};

function setup_nft_json(base, name) {
	// Shapes as `nft -j list set` prints them on a device (T2.8): bare values, and the
	// {"elem":{"val":...}} wrapper only for elements with extra attributes.
	let elements = [
		'1.2.3.4',
		{ prefix: { addr: '2.0.0.0', len: 24 } },
		{ range: [ '10.0.0.0', '10.0.0.255' ] },
		{ elem: { val: '3.3.3.3', timeout: 3600, expires: 3500 } }
	];
	return write(`${base}/${name}.json`, sprintf('%.J\n', { nftables: [ { set: { name, elem: elements } } ] }));
};

function run_range() {
	let cases = [
		[ '1.2.3.4', '1.2.3.4', [ '1.2.3.4' ] ],
		[ '192.0.2.0', '192.0.2.255', [ '192.0.2.0/24' ] ],
		[ '192.0.2.1', '192.0.2.6', [ '192.0.2.1', '192.0.2.2/31', '192.0.2.4/31', '192.0.2.6' ] ],
		[ '0.0.0.0', '255.255.255.255', [ '0.0.0.0/0' ] ]
	];
	for (let c in cases)
		if (sprintf('%.J', net.range_to_cidrs(c[0], c[1])) != sprintf('%.J', c[2]))
			return fail(`range ${c[0]}-${c[1]} => ${sprintf('%.J', net.range_to_cidrs(c[0], c[1]))}`);
	return net.range_to_cidrs('2.0.0.1', '2.0.0.0') == null ? 'PASS' : fail('reversed interval accepted');
};

function run_nft() {
	let t = prepare();
	if (t.error) return fail(t.error);
	let c = t.ctx, nftout = `${t.base}/nft.out`;
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + `STUB_NFT_OUT_FILE='${nftout}'\n`);
	write(nftout, '');
	let loaded = apply.nft_load(c, '/fake/rules.nft');
	let deleted = apply.nft_delete(c);
	let absent = apply.nft_delete(c);
	write(nftout, 'table inet aetherproxy { }\n');
	let exists = apply.nft_table_exists(c);
	let flushed = apply.nft_flush_prerouting(c);
	if (!loaded.ok || !deleted.ok || !absent.ok || !exists.ok || !exists.exists || !flushed.ok)
		return fail('nft success/idempotence result mismatch');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_NFT_RC=1\n');
	write(nftout, 'Error: No such file or directory\n');
	let absent_table = apply.nft_table_exists(c), absent_chain = apply.nft_flush_prerouting(c);
	write(nftout, 'permission denied\n');
	let nft_error = apply.nft_table_exists(c);
	if (apply.nft_load(c, '/fake/bad.nft').ok || absent_table.exists || !absent_table.ok || !absent_chain.ok || nft_error.ok)
		return fail('nft missing/error handling mismatch');
	return 'PASS';
};

function run_sets() {
	let t = prepare();
	if (t.error) return fail(t.error);
	let c = t.ctx, env = read(`${t.base}/stubs/stub.env`);
	for (let name in C.NFT_DYNAMIC_SETS) {
		if (!setup_nft_json(t.base, name)) return fail(`cannot write ${name} fixture`);
		let key = { gfw4: 'GFW4', udirect4: 'UDIRECT4', uproxy4: 'UPROXY4' }[name];
		env += `STUB_NFT_${key}_OUT_FILE='${t.base}/${name}.json'\n`;
	}
	write(`${t.base}/stubs/stub.env`, env);
	let exported = apply.sets_export(c);
	if (!exported.ok || sprintf('%.J', exported.sets.gfw4) != sprintf('%.J', [ '1.2.3.4', '2.0.0.0/24', '3.3.3.3', '10.0.0.0/24' ]))
		return fail(`export result ${sprintf('%.J', exported)}`);
	if (!apply.sets_save(c, exported.sets).ok)
		return fail('sets_save failed');
	let loaded = apply.sets_load(c);
	if (!loaded.ok || fs.stat(`${t.base}/var/run/aether-proxy/${C.SETS_SAVE_FILE}`) != null ||
	    sprintf('%.J', loaded.sets) != sprintf('%.J', exported.sets))
		return fail('sets_load mismatch or file not removed');
	let empty = apply.sets_load(c);
	if (!empty.ok || length(empty.sets.gfw4))
		return fail('empty sets_load should be idempotent');
	if (apply.sets_save(c, { gfw4: [ 'bad' ], udirect4: [], uproxy4: [] }).ok)
		return fail('invalid set data accepted');
	write(`${t.base}/var/run/aether-proxy/${C.SETS_SAVE_FILE}`, '{invalid json');
	if (apply.sets_load(c).ok || fs.stat(`${t.base}/var/run/aether-proxy/${C.SETS_SAVE_FILE}`) == null)
		return fail('corrupt sets.save should fail and remain available for diagnosis');
	write(`${t.base}/block`, 'file');
	let blocked = { ...c, run_dir: '/block/subdir' };
	if (apply.sets_save(blocked, exported.sets).ok)
		return fail('sets_save directory error was accepted');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_NFT_RC=1\n');
	let export_error = apply.sets_export(c);
	return !export_error.ok ? 'PASS' : fail('nft set export failure accepted');
};

function run_routes() {
	let t = prepare();
	if (t.error) return fail(t.error);
	let c = t.ctx;
	let add = apply.route_add(c), again = apply.route_add(c);
	let log1 = read(t.log_path);
	if (!add.ok || !again.ok || length(filter(split(log1, '\n'), l => match(l, /ip rule add/))) != 1)
		return fail('route_add did not avoid duplicate ip rule');
	let del = apply.route_del(c), again_del = apply.route_del(c);
	if (!del.ok || !again_del.ok)
		return fail('route_del failed or was not idempotent');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_IP_FLUSH_ESRCH=1\n');
	if (!apply.route_del(c).ok)
		return fail('route_del treated an already empty table (ESRCH) as a failure');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_IP_FLUSH_ESRCH=0\n');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_IP_RC=1\n');
	return !apply.route_add(c).ok && !apply.route_del(c).ok ? 'PASS' : fail('ip rule query/deletion failure accepted');
};

function make_dnsmasq_tree(t) {
	let root = t.base;
	write(`${root}/var/etc/dnsmasq.conf.lan`, 'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\nserver=9.9.9.9\n');
	write(`${root}/var/etc/dnsmasq.conf.guest`, 'interface=br-guest\nconf-dir=/tmp/dnsmasq-guest.d\n');
	write(`${root}/tmp/dnsmasq.d/other.conf`, 'server=8.8.8.8\n');
	write(`${root}/stubs/stub.env`, read(`${root}/stubs/stub.env`) + 'STUB_KILLALL_RC=0\n');
	write(`${root}/etc/init.d/dnsmasq`, '#!/bin/sh\n. "$(dirname "$0")/../../stubs/stub.env"\nprintf "dnsmasq %s\\n" "$*" >>"$STUB_LOG"\nexit 0\n');
	fs.chmod(`${root}/etc/init.d/dnsmasq`, 493);
};

function run_dnsmasq() {
	let t = prepare();
	if (t.error) return fail(t.error);
	make_dnsmasq_tree(t);
	let c = t.ctx, found = apply.dnsmasq_confdir(c);
	if (!found.ok || found.confdir != `${t.base}/tmp/dnsmasq.d`)
		return fail(`confdir selection: ${sprintf('%.J', found)}`);
	let installed = apply.dnsmasq_install(c, 'server=127.0.0.1#31053\n');
	let extra = apply.dnsmasq_extra_servers(c);
	if (!installed.ok || !extra.ok || sprintf('%.J', extra.servers) != sprintf('%.J', [ 'server=8.8.8.8', 'server=9.9.9.9' ]))
		return fail(`install/extra servers mismatch: ${sprintf('%.J', extra)}`);
	// Removal must not depend on finding a unique LAN conf-dir (LAN interfaces changed since install).
	let moved = apply.dnsmasq_remove({ ...c, lan_ifaces: [ 'br-gone' ] });
	if (!moved.ok || fs.stat(`${found.confdir}/${C.DNSMASQ_FRAGMENT}`) != null)
		return fail(`remove without a unique LAN conf-dir: ${sprintf('%.J', moved)}`);
	apply.dnsmasq_install(c, 'server=127.0.0.1#31053\n');
	let removed = apply.dnsmasq_remove(c), removed_again = apply.dnsmasq_remove(c);
	let hup = apply.dnsmasq_hup(c);
	if (!removed.ok || !removed_again.ok || !hup.ok || fs.stat(`${found.confdir}/${C.DNSMASQ_FRAGMENT}`) != null)
		return fail('dnsmasq remove/HUP mismatch');
	if (length(filter(split(read(t.log_path), '\n'), l => match(l, /dnsmasq restart/))) != 4)
		return fail('restart call count mismatch');
	write(`${t.base}/etc/init.d/dnsmasq`, '#!/bin/sh\nexit 1\n');
	fs.chmod(`${t.base}/etc/init.d/dnsmasq`, 493);
	if (apply.dnsmasq_install(c, 'server=127.0.0.1#31053\n').ok)
		return fail('restart failure accepted');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_KILLALL_RC=1\n');
	let hup_failed = apply.dnsmasq_hup(c);
	// dns.dnsmasq_instance pins an instance by section name, ignoring lan_ifaces.
	let pinned = apply.dnsmasq_confdir({ ...c, dnsmasq_instance: 'guest' });
	if (!pinned.ok || pinned.confdir != `${t.base}/tmp/dnsmasq-guest.d`)
		return fail(`pinned dnsmasq_instance: ${sprintf('%.J', pinned)}`);
	if (apply.dnsmasq_confdir({ ...c, dnsmasq_instance: 'nosuch' }).ok)
		return fail('unknown dnsmasq_instance accepted');
	// Seen on a device: the only instance has no interface= line, plus a temp file
	// (<file>.<pid>) left by an interrupted dnsmasq init with the same conf-dir.
	let lone = `${t.base}/lone`;
	write(`${lone}/var/etc/dnsmasq.conf.cfg01411c`, 'conf-dir=/tmp/dnsmasq.d\n');
	write(`${lone}/var/etc/dnsmasq.conf.cfg01411c.2670`, 'conf-dir=/tmp/dnsmasq.d\n');
	let lone_found = apply.dnsmasq_confdir({ ...c, root: lone });
	if (!lone_found.ok || lone_found.confdir != `${lone}/tmp/dnsmasq.d`)
		return fail(`all-interfaces instance with a leftover temp file: ${sprintf('%.J', lone_found)}`);
	let absent = { ...c, root: `${t.base}/empty-root` };
	return !hup_failed.ok && !apply.dnsmasq_confdir(absent).ok ? 'PASS' : fail('HUP/conf-dir failure accepted');
};

function run_resolve() {
	let t = prepare();
	if (t.error) return fail(t.error);
	let c = t.ctx, out = `${t.base}/resolve.out`;
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + `STUB_RESOLVEIP_OUT_FILE='${out}'\n`);
	write(out, '198.51.100.4\n198.51.100.5\n');
	let literal = apply.resolve_node(c, '203.0.113.8');
	let dns = apply.resolve_node(c, 'node.example');
	let lkg_text = read(`${t.base}/etc/aether-proxy/state/${C.NODE_IP_FILE}`);
	if (!literal.ok || literal.source != 'literal' || !dns.ok || dns.ip != '198.51.100.4' || dns.source != 'dns')
		return fail(`literal/DNS result: ${sprintf('%.J', [ literal, dns ])}`);
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_RESOLVEIP_RC=1\n');
	let lkg = apply.resolve_node(c, 'node.example');
	let missing = apply.resolve_node(c, 'other.example');
	return lkg.ok && lkg.source == 'lkg' && lkg.ip == '198.51.100.4' && !missing.ok && lkg_text ? 'PASS' : fail(`LKG result ${sprintf('%.J', [ lkg, missing ])}`);
};

function run_misc() {
	let t = prepare();
	if (t.error) return fail(t.error);
	let c = t.ctx;
	let boot = apply.write_boot_list(c, [ 'Baidu.com', 'google.com', 'google.com' ]);
	let text = read(`${t.base}/var/run/aether-proxy/${C.BOOT_LIST_FILE}`);
	if (!boot.ok || text != 'baidu.com\ngoogle.com\n' || apply.write_boot_list(c, [ 'bad/name' ]).ok)
		return fail(`boot list result: ${text}`);
	let table_file = `${t.base}/tables.out`;
	write(table_file, 'table inet fw4\ntable inet ss_spec\ntable inet passwall2\n');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + `STUB_NFT_OUT_FILE='${table_file}'\nSTUB_KILLALL_RC=0\n`);
	let found = apply.conflicts(c);
	if (!found.ok || sprintf('%.J', found.conflicts) != sprintf('%.J', [ 'clash', 'mihomo', 'passwall2', 'ss_spec' ]))
		return fail(`conflict list: ${sprintf('%.J', found)}`);
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + 'STUB_NFT_RC=1\n');
	return !apply.conflicts(c).ok ? 'PASS' : fail('nft failure in conflict check accepted');
};

export function run(c) {
	if (c.kind == 'range') return run_range();
	if (c.kind == 'nft') return run_nft();
	if (c.kind == 'sets') return run_sets();
	if (c.kind == 'routes') return run_routes();
	if (c.kind == 'dnsmasq') return run_dnsmasq();
	if (c.kind == 'resolve') return run_resolve();
	if (c.kind == 'misc') return run_misc();
	return fail('unknown case');
};
