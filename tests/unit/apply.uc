'use strict';
// Verify lifecycle primitives with isolated files and command stubs (docs/04 and docs/03).

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
	{ name: 'bootstrap retries exit failure and invalid output then succeeds quietly on attempt three',
	  expect: 'PASS', kind: 'retry' },
	{ name: 'bootstrap stops after first success and emits one final fallback or failure',
	  expect: 'PASS', kind: 'retry_end' },
	{ name: 'LKG reads legacy format and ignores only invalid IP entries', expect: 'PASS', kind: 'lkg_read' },
	{ name: 'LKG preserves A and B and unchanged A does not rewrite or reorder', expect: 'PASS', kind: 'lkg_keep' },
	{ name: 'LKG evicts oldest of 65 addresses and moves changed addresses last', expect: 'PASS', kind: 'lkg_limit' },
	{ name: 'corrupt LKG is silent and successful resolution regenerates new format',
	  expect: 'PASS', kind: 'lkg_corrupt' },
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
	if (!sys.mkdir_p(`${base}/var/run/aether-proxy`))
		return { error: sys.error() };
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
	if (!loaded.ok || fs.stat(`${t.base}/var/run/aether-proxy/${C.SETS_SAVE_FILE}`) == null ||
	    sprintf('%.J', loaded.sets) != sprintf('%.J', exported.sets))
		return fail('sets_load mismatch or recovery source removed prematurely');
	if (!apply.sets_remove(c).ok || !apply.sets_remove(c).ok)
		return fail('sets_remove should delete the save file and be idempotent');
	let empty = apply.sets_load(c);
	if (!empty.ok || length(empty.sets.gfw4))
		return fail('empty sets_load should be idempotent');
	// A directory cannot be unlinked: removal must report FS_FAILED, not silent success.
	let saved_path = `${t.base}/var/run/aether-proxy/${C.SETS_SAVE_FILE}`;
	if (!sys.mkdir_p(saved_path))
		return fail('cannot prepare removal failure');
	if (apply.sets_remove(c).ok || index(read(`${t.base}/var/run/aether-proxy/${C.EVENTS_FILE}`),
	    '"code": "FS_FAILED"') < 0)
		return fail('sets_remove failure must emit FS_FAILED');
	if (!fs.rmdir(saved_path))
		return fail('cannot remove failure fixture');
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
	let env = (line) => write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) + line + '\n');
	let flushes = () => length(filter(split(read(t.log_path), '\n'), l => match(l, /ip route flush/)));
	// docs/04「真机验证」: table 233 is queried through `show table all`; nothing there, no flush.
	let before = flushes();
	if (!apply.route_del(c).ok || flushes() != before)
		return fail('route_del flushed (or failed on) a table without routes');
	// Linux 6.18 / iproute2 6.18 (H28K): per-table show and flush fail while the table never existed.
	env('STUB_IP_TABLE_MISSING=1');
	if (!apply.route_del(c).ok || flushes() != before)
		return fail('route_del failed on a never-created table (Dump/Flush terminated)');
	env('STUB_IP_TABLE_MISSING=0');
	write(`${t.base}/routes-left`, 'local default dev lo table 233 scope host\nlocal 127.0.0.1 dev lo table local\n');
	env(`STUB_IP_ROUTES_FILE=${t.base}/routes-left`);
	if (!apply.route_del(c).ok || flushes() != before + 1)
		return fail('route_del did not flush a table that has routes');
	// A failed flush with routes still there is a real failure, whatever the wording.
	env('STUB_IP_FLUSH_ERR="Flush terminated"');
	if (apply.route_del(c).ok)
		return fail('route_del accepted a failed flush that left routes in the table');
	// Routes of other tables do not count as table 233.
	write(`${t.base}/routes-left`, 'local 127.0.0.1 dev lo table local\nlocal 10.0.0.1 dev lo table 2330\n');
	if (!apply.route_del(c).ok)
		return fail('route_del mistook routes of other tables for table 233');
	env('STUB_IP_FLUSH_ERR=\nSTUB_IP_ROUTES_FILE=');
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

function lkg_path(t) {
	return `${t.base}/etc/aether-proxy/state/${C.NODE_IP_FILE}`;
};

function resolve_calls(t) {
	return filter(split(read(t.log_path), '\n'), l => match(l, /^resolveip /));
};

function resolve_events(t) {
	return filter(split(read(`${t.base}/var/run/aether-proxy/${C.EVENTS_FILE}`), '\n'),
		l => match(l, /NODE_RESOLVE_/));
};

function configure_sequence(t, rc, outputs) {
	let seq = `${t.base}/sequence`;
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) +
		`STUB_RESOLVEIP_SEQUENCE='${seq}'\n`);
	for (let i = 0; i < length(rc); i++) {
		write(`${seq}/${i + 1}.rc`, `${rc[i]}\n`);
		write(`${seq}/${i + 1}.out`, outputs[i]);
	}
};

function run_retry() {
	let t = prepare();
	if (t.error) return fail(t.error);
	// The first response has an IP but exits nonzero; the second exits zero without an IPv4.
	configure_sequence(t, [ 1, 0, 0 ], [ '198.51.100.1\n', 'not-an-ip\n::1\n',
		'invalid\n198.51.100.3\n198.51.100.4\n' ]);
	let r = apply.resolve_node(t.ctx, 'retry.example');
	if (!r.ok || r.source != 'dns' || r.ip != '198.51.100.3')
		return fail(`third response: ${sprintf('%.J', r)}`);
	let calls = resolve_calls(t);
	if (length(calls) != 3 || length(filter(calls, l => l == 'resolveip -4 -t 3 retry.example')) != 3)
		return fail(`retry count/timeout: ${sprintf('%.J', calls)}`);
	return fs.stat(`${t.base}/var/run/aether-proxy/${C.EVENTS_FILE}`) == null
		? 'PASS' : fail('intermediate DNS failure emitted an event');
};

function run_retry_end() {
	let t = prepare();
	if (t.error) return fail(t.error);
	configure_sequence(t, [ 0 ], [ '203.0.113.1\n' ]);
	let first = apply.resolve_node(t.ctx, 'first.example');
	if (!first.ok || length(resolve_calls(t)) != 1)
		return fail('first success did not stop immediately');
	write(`${t.base}/stubs/stub.env`, read(`${t.base}/stubs/stub.env`) +
		'STUB_RESOLVEIP_SEQUENCE=\nSTUB_RESOLVEIP_RC=1\n');
	let fallback = apply.resolve_node(t.ctx, 'first.example');
	let missing = apply.resolve_node(t.ctx, 'missing.example');
	let events = resolve_events(t);
	if (!fallback.ok || fallback.source != 'lkg' || fallback.ip != '203.0.113.1' || missing.ok)
		return fail('fallback reused wrong address or ignored matching LKG');
	if (length(resolve_calls(t)) != 7 || length(events) != 2)
		return fail(`retry/event count mismatch: ${length(resolve_calls(t))} calls, ${length(events)} events`);
	return index(events[0], 'NODE_RESOLVE_FALLBACK') >= 0 && index(events[1], 'NODE_RESOLVE_FAILED') >= 0
		? 'PASS' : fail('final event codes mismatch');
};

function run_lkg_read() {
	let t = prepare();
	if (t.error) return fail(t.error);
	write(lkg_path(t), '{"address":"old.example","ip":"198.51.100.1"}');
	if (apply.read_lkg(t.ctx)['old.example'] != '198.51.100.1')
		return fail('legacy entry unreadable');
	// A changed/new address triggers format migration; mere reads need not rewrite flash.
	apply.update_lkg(t.ctx, { 'new.example': '198.51.100.2' });
	let migrated = json(read(lkg_path(t)));
	if (migrated.nodes?.['old.example'] != '198.51.100.1' || migrated.address != null)
		return fail('legacy migration lost original entry');
	write(lkg_path(t), '{"nodes":{"a.example":"203.0.113.1","bad.example":"999.0.0.1",' +
		'"b.example":"203.0.113.2","object.example":{},"null.example":null}}');
	let valid = apply.read_lkg(t.ctx);
	return length(valid) == 2 && valid['a.example'] == '203.0.113.1' && valid['b.example'] == '203.0.113.2'
		? 'PASS' : fail(`valid entries: ${sprintf('%.J', valid)}`);
};

function run_lkg_keep() {
	let t = prepare();
	if (t.error) return fail(t.error);
	configure_sequence(t, [ 0, 0, 0 ], [ '203.0.113.1\n', '203.0.113.2\n', '203.0.113.1\n' ]);
	if (!apply.resolve_node(t.ctx, 'a.example').ok || !apply.resolve_node(t.ctx, 'b.example').ok)
		return fail('sequential resolutions failed');
	// Atomic replacement changes the inode; a hard link keeps the old inode allocated.
	let path = lkg_path(t), link = `${t.base}/lkg-link`;
	if (sys.run([ 'ln', path, link ], { timeout: 10 }).code != 0)
		return fail('cannot link LKG');
	let before = fs.stat(path).inode;
	if (!apply.resolve_node(t.ctx, 'a.example').ok || fs.stat(path).inode != before)
		return fail('unchanged A rewrote LKG');
	let nodes = apply.read_lkg(t.ctx);
	return join(',', keys(nodes)) == 'a.example,b.example' && nodes['a.example'] == '203.0.113.1' &&
		nodes['b.example'] == '203.0.113.2' ? 'PASS' : fail('A/B retention or order mismatch');
};

function run_lkg_limit() {
	let t = prepare();
	if (t.error) return fail(t.error);
	for (let i = 0; i < 65; i++)
		if (!apply.update_lkg(t.ctx, { [`node-${i}.example`]: '203.0.113.1' }).ok)
			return fail(`cannot save address ${i}`);
	let nodes = apply.read_lkg(t.ctx), order = keys(nodes);
	if (length(nodes) != 64 || nodes['node-0.example'] != null || order[63] != 'node-64.example')
		return fail('65-address eviction mismatch');
	apply.update_lkg(t.ctx, { 'node-1.example': '203.0.113.2' });
	order = keys(apply.read_lkg(t.ctx));
	return order[0] == 'node-2.example' && order[63] == 'node-1.example'
		? 'PASS' : fail('changed address was not moved last');
};

function run_lkg_corrupt() {
	let t = prepare();
	if (t.error) return fail(t.error);
	for (let text in [ '{broken', 'null', '[]', '{"nodes":[]}', '{"nodes":"wrong"}' ]) {
		write(lkg_path(t), text);
		if (length(apply.read_lkg(t.ctx)))
			return fail(`corrupt cache not empty: ${text}`);
	}
	if (length(resolve_events(t)) || fs.stat(`${t.base}/var/run/aether-proxy/${C.EVENTS_FILE}`) != null)
		return fail('reading corrupt cache emitted events');
	configure_sequence(t, [ 0 ], [ '203.0.113.4\n' ]);
	let r = apply.resolve_node(t.ctx, 'fresh.example');
	let obj = json(read(lkg_path(t)));
	return r.ok && obj.nodes?.['fresh.example'] == '203.0.113.4' && !length(resolve_events(t))
		? 'PASS' : fail('successful DNS did not silently regenerate cache');
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
	if (!found.ok || sprintf('%.J', found.conflicts) != sprintf('%.J', [ 'clash', 'mihomo', 'passwall2', 'ssr-plus' ]))
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
	if (c.kind == 'retry') return run_retry();
	if (c.kind == 'retry_end') return run_retry_end();
	if (c.kind == 'lkg_read') return run_lkg_read();
	if (c.kind == 'lkg_keep') return run_lkg_keep();
	if (c.kind == 'lkg_limit') return run_lkg_limit();
	if (c.kind == 'lkg_corrupt') return run_lkg_corrupt();
	if (c.kind == 'misc') return run_misc();
	return fail('unknown case');
};
