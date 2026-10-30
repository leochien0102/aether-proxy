'use strict';
// T9.43: real monitor actions and atomic reloads must retain one applied generation (docs/04).

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as pipeline from 'aetherproxy.pipeline';
import * as monitor from 'aetherproxy.monitor';
import * as reload from 'aetherproxy.reload';
import * as apply from 'aetherproxy.apply';

let base = ARGV[0], root = `${base}/root`, current = `${root}${C.RUN_DIR}/current`;
let pass = 0, fail = 0;
function check(value, name) {
	print(`${value ? 'PASS' : 'FAIL'}  T9.43: ${name}\n`);
	if (value) pass++; else fail++;
};
function write(path, text) {
	if (!sys.write_atomic(path, text)) die(`write ${path}: ${sys.error()}`);
};
function remove(path) {
	if (fs.stat(path) != null && !fs.unlink(path)) die(`unlink ${path}: ${fs.error()}`);
};
function flag(name, on) {
	if (on) write(`${root}/${name}`, '1\n'); else remove(`${root}/${name}`);
};
function tick(d) {
	monitor.tick(d);
	while (d.busy) uloop.run(50);
};
function stop_children(d) {
	for (let key in [ 'dns', 'xray' ]) {
		if (d.children[key] == null) continue;
		let stopped = false;
		d.children[key].stop(() => { stopped = true; uloop.end(); });
		while (!stopped) uloop.run(50);
	}
};
function install(loaded, runtime) {
	let built = pipeline.render(loaded, runtime);
	if (!built.ok) die(built.detail);
	for (let name, file in C.ARTIFACT_FILES) write(`${current}/${file}`, built.artifacts[name]);
	return built;
};
function expected(d, loaded, label, names) {
	let built = pipeline.render(loaded, { node_ip: d.machine.node_ip, dns_tier: d.machine.dns_tier,
		degraded_mode: d.machine.degraded_mode, restored: {} });
	for (let name in names) {
		let actual = fs.readfile(`${current}/${C.ARTIFACT_FILES[name]}`);
		check(actual == built.artifacts[name], `${label} keeps ${name}`);
		if (actual != built.artifacts[name])
			print(sprintf('EVIDENCE %s: B route=%J B DNS=%J B credential=%J\n', label,
				index(actual, '20.0.0.0/8') >= 0, index(actual, '203.0.113.21') >= 0,
				index(actual, 'secret-B') >= 0));
	}

};

if (!uloop.init()) die('uloop init failed');
if (!sys.mkdir_p(current)) die(sys.error());
let opts = { confdir: `${root}/etc/config`, sys_root: root, bin_dir: `${base}/bin`,
	data_dir: `${base}/A/data`, baseline_dir: `${base}/A/baseline`, custom_dir: `${base}/A/custom` };
let ctx = { root, bin_dir: opts.bin_dir, run_dir: C.RUN_DIR, state_dir: C.STATE_DIR,
	lan_ifaces: [ 'br-lan' ] };
let a = pipeline.read(opts);
if (!a.ok) die(sprintf('%.J', a));
let built = install(a, { node_ip: '203.0.113.20', dns_tier: 'T1' });
let hashes = apply.artifact_hashes(ctx, current);
let state = { state: 'running', dns_tier: 'T1', node_ip: '203.0.113.20',
	node_id: a.snapshot.main.node, mode: a.snapshot.main.mode, wan_dns: a.wan_dns,
	degraded_mode: null, render_hash: hashes.hashes,
	components: { xray: { path: `${base}/bin/xray` }, 'chinadns-ng': { path: `${base}/bin/chinadns-ng` } } };
let d = monitor.create_daemon({ ctx, opts, snapshot: a.snapshot, applied_context: a,
	state, children: {}, reload: reload.run_live });

// A is installed. Save B without reloading; replace files atomically so cache identity changes.
write(`${root}/etc/config/aetherproxy`, fs.readfile(`${base}/B/aetherproxy`));
write(`${base}/wan.json`, fs.readfile(`${base}/B/wan.json`));
for (let file in [ 'chnroute4.txt', 'gfw_static4.txt' ])
	write(`${base}/A/baseline/${file}`, fs.readfile(`${base}/B/baseline/${file}`));
for (let file in [ 'direct_ip.txt', 'proxy_ip.txt' ])
	write(`${base}/A/custom/${file}`, fs.readfile(`${base}/B/custom/${file}`));
for (let file in [ 'gfwlist.txt', 'chnlist.txt', 'apple.txt' ])
	write(`${base}/A/data/${file}`, fs.readfile(`${base}/B/baseline/${file}`));
let b = pipeline.read(opts);
if (!b.ok) die(sprintf('%.J', b));
pipeline.render(b, { dns_tier: 'T1' });
check(a.data.chnroute4[0] == '10.0.0.0/8' && b.data.chnroute4[0] == '20.0.0.0/8',
	'A data survives B cache warming');
let wan_calls = fs.readfile(`${base}/wan-calls`);

function recover(loaded, label) {
	let applied_before = d.applied_context;
	let queries_before = fs.readfile(`${base}/wan-calls`);
	flag('health-fail', false);
	flag('dns-fail', false);
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', ever_healthy: true,
		degraded_mode: null, proxy_fail_count: 0, dns_fail_count: 0, table_missing_count: 0 };
	d.state = { ...d.state, dns_tier: 'T1', degraded_mode: null };
	remove(`${root}/nft-table`);
	tick(d);
	check(d.machine.table_missing_count == 1 && fs.stat(`${root}/nft-table`) == null,
		`${label} missing table waits two rounds`);
	tick(d);
	expected(d, loaded, `${label} missing-table recovery`, [ 'nft' ]);
	flag('health-fail', true);
	tick(d);
	check(d.machine.dns_tier == 'T2', `${label} enters T2`);
	expected(d, loaded, `${label} T1 to T2`, [ 'chinadns' ]);
	flag('dns-fail', true);
	tick(d);
	tick(d);
	check(d.machine.dns_tier == 'T3', `${label} enters T3`);
	expected(d, loaded, `${label} T2 to T3`, [ 'chinadns' ]);
	// Trigger fragment recovery without actually stopping chinadns: its listener is present.
	d.machine.dns_failsafe = true;
	d.machine.chinadns_down_reported = true;
	tick(d);
	let dnsmasq = pipeline.render(loaded, { dns_tier: 'T3' }).artifacts.dnsmasq;
	check(fs.readfile(`${root}/tmp/dnsmasq.d/${C.DNSMASQ_FRAGMENT}`) == dnsmasq,
		`${label} dnsmasq recovery keeps generation`);
	flag('dns-fail', false);
	flag('health-fail', false);
	tick(d);
	check(d.machine.dns_tier == 'T1', `${label} T3 recovers to T1`);
	expected(d, loaded, `${label} T3 to T1`, [ 'chinadns' ]);
	d.machine.node_ip = '203.0.113.19';
	d.machine.last_node_refresh = time() - C.MONITOR_NODE_REFRESH_SECS - 1;
	tick(d);
	check(d.machine.node_ip == '203.0.113.20', `${label} node IP refresh succeeds`);
	expected(d, loaded, `${label} node IP refresh`, [ 'nft', 'xray' ]);
	check(d.applied_context == applied_before && d.applied_context?.snapshot == d.snapshot,
		`${label} recovery preserves paired snapshot and complete context`);
	check(fs.readfile(`${base}/wan-calls`) == queries_before, `${label} recovery performs no WAN reads`);
};

recover(a, 'saved B without reload');
check(fs.readfile(`${base}/wan-calls`) == wan_calls, 'monitor never reobserves WAN DNS');

for (let kind in [ 'read', 'render', 'validation', 'action' ]) {
	// Restore exact A outputs and hashes before each independent failed transaction.
	install(a, { node_ip: '203.0.113.20', dns_tier: 'T1' });
	d.state.render_hash = apply.artifact_hashes(ctx, current).hashes;
	let previous = d.applied_context, snapshot = d.snapshot;
	if (kind == 'read') write(`${root}/etc/config/aetherproxy`, "config main 'main'\n option mode 'invalid'\n");
	if (kind == 'render') {
		// Runtime-only reload uses the supplied applied context, including renderer errors.
		let broken = { ...a, snapshot: { ...a.snapshot, hosts: [ null ] } };
		d.applied_context = broken;
	}
	if (kind == 'validation') flag('nft-check-fail-after', true);
	if (kind == 'action') flag('nft-load-fail', true);
	let changed = reload.run_live(d, null, kind == 'render' ? { mode: 'gfw' } : null);
	check(!changed.ok, `${kind} reload fails`);
	if (kind == 'render') d.applied_context = previous;
	check(d.applied_context == previous && d.snapshot == snapshot, `${kind} failure retains A context and snapshot`);
	flag('nft-check-fail-after', false);
	flag('nft-load-fail', false);
	write(`${root}/etc/config/aetherproxy`, fs.readfile(`${base}/B/aetherproxy`));
	recover(a, `${kind} failure`);
}

// Publish B only after every action succeeds; subsequent recovery must switch all inputs.
let changed = reload.run_live(d);
check(changed.ok && changed.snapshot.main.node == b.snapshot.main.node, 'full B reload succeeds');
if (changed.ok) {
	d.state = changed.state;
	d.snapshot = changed.snapshot;
	d.applied_context = changed.applied_context;
	check(d.applied_context?.snapshot == d.snapshot && d.applied_context?.data.chnroute4[0] == '20.0.0.0/8',
		'full success returns B context with same snapshot');
	recover(b, 'successful B reload');
}
// Both no-action branches must also adopt the newly read context, not just its snapshot.
let old_context = d.applied_context;
let unchanged = reload.run(d);
check(unchanged.ok && !length(unchanged.actions) && unchanged.applied_context != old_context &&
	unchanged.applied_context.snapshot == unchanged.snapshot, 'no-change reload returns fresh complete context');
check(d.snapshot == unchanged.snapshot && d.applied_context == unchanged.applied_context,
	'direct reload switches snapshot and context at the same success point');
if (unchanged.ok) {
	d.state = unchanged.state;
	d.snapshot = unchanged.snapshot;
	d.applied_context = unchanged.applied_context;
}
let live_sets = { gfw4: [ '198.51.100.98' ], udirect4: [], uproxy4: [] };
install(b, { node_ip: d.machine.node_ip, dns_tier: d.machine.dns_tier, restored: live_sets });
write(`${root}/gfw4-elem`, sprintf('%.J', live_sets.gfw4));
let before_dynamic = fs.readfile(`${current}/${C.ARTIFACT_FILES.nft}`);
let dynamic_noop = reload.run_live(d);
check(dynamic_noop.ok && !length(dynamic_noop.actions) && dynamic_noop.applied_context != d.applied_context &&
	fs.readfile(`${current}/${C.ARTIFACT_FILES.nft}`) == before_dynamic,
	'exported-set no-op reload switches complete context without replacing nft');
remove(`${root}/gfw4-elem`);

// Even unreadable/invalid pending inputs must not prevent recovery of the applied service.
write(`${root}/etc/config/aetherproxy`, 'not UCI at all\n');
write(`${base}/A/baseline/chnroute4.txt`, 'not a CIDR\n');
wan_calls = fs.readfile(`${base}/wan-calls`);
recover(b, 'invalid pending disk inputs');
check(fs.readfile(`${base}/wan-calls`) == wan_calls, 'invalid pending inputs cause no WAN query');

// Runtime degradation keeps the complete transaction/rollback machinery without reading B.
let degraded_context = { ...a, snapshot: { ...a.snapshot,
	main: { ...a.snapshot.main, mode: 'bypass_cn' } }, warnings: [ { code: 'test-warning' } ] };
d.applied_context = degraded_context;
d.snapshot = degraded_context.snapshot;
install(degraded_context, { node_ip: '203.0.113.20', dns_tier: 'T1' });
d.state = { ...d.state, state: 'running', mode: 'bypass_cn', dns_tier: 'T1', degraded_mode: null };
d.machine = monitor.initial_state(d.state, time());
flag('health-fail', true);
flag('nft-load-fail', true);
tick(d);
check(d.applied_context == degraded_context && d.snapshot == degraded_context.snapshot &&
	d.state.degraded_mode == null, 'failed degradation retains applied context and snapshot');
flag('nft-load-fail', false);
tick(d);
check(d.state.degraded_mode == 'gfw' && d.applied_context == degraded_context,
	'degradation changes runtime only and retains warnings');
expected(d, degraded_context, 'degradation with invalid pending disk', [ 'nft', 'chinadns' ]);
flag('health-fail', false);
tick(d);
check(d.state.degraded_mode == null && d.applied_context == degraded_context,
	'restoration changes runtime only');
expected(d, degraded_context, 'restoration with invalid pending disk', [ 'nft', 'chinadns' ]);
check(fs.readfile(`${base}/wan-calls`) == wan_calls, 'runtime reload never queries WAN');

// Null, absent and empty collections are distinct renderer inputs, never a reason to read disk.
for (let field in [ 'data', 'paths', 'wan_dns' ]) {
	for (let form in [ 'missing', 'null', 'empty' ]) {
		let context = { ...a, snapshot: { ...a.snapshot } };
		if (form == 'missing') delete context[field];
		else context[field] = form == 'null' ? null : (field == 'wan_dns' ? [] : {});
		for (let enabled in [ false, true ]) {
			context.snapshot.dns = { ...a.snapshot.dns, direct_dns_enabled: enabled };
			for (let tier in [ 'T1', 'T2', 'T3' ]) {
				d.applied_context = context;
				d.snapshot = context.snapshot;
				let from_tier = tier == 'T1' ? 'T3' : tier == 'T3' && enabled ? 'T2' : 'T1';
				if (tier == 'T2' && !enabled) from_tier = 'T2';
				let from_state = tier == 'T1' || (tier == 'T3' && enabled) ? 'degraded' : 'running';
				d.state = { ...d.state, state: from_state, dns_tier: from_tier, degraded_mode: null };
				d.machine = monitor.initial_state(d.state, time());
				d.machine.ever_healthy = true;
				d.machine.table_missing_count = 1;
				d.machine.dns_fail_count = 1;
				remove(`${root}/nft-table`);
				flag('health-fail', tier != 'T1');
				flag('dns-fail', tier == 'T3');
				tick(d);
				let label = `${field}/${form}/direct=${enabled}/tier=${tier}`;
				check(d.machine.dns_tier == (tier == 'T2' && !enabled ? 'T3' : tier),
					`${label} applies allowed tier boundary`);
				expected(d, context, label, [ 'nft', 'chinadns' ]);
			}
		}
	}
}
check(fs.readfile(`${base}/wan-calls`) == wan_calls, 'empty null missing contexts never query WAN');

// Saved dynamic sets remain retryable until nft accepts the rebuilt table (no strategy change).
d.applied_context = a;
d.snapshot = a.snapshot;
d.machine = monitor.initial_state({ ...d.state, state: 'running', dns_tier: 'T1' }, time());
flag('health-fail', false);
remove(`${root}/nft-table`);
d.machine.table_missing_count = 1;
let saved_path = `${root}${C.RUN_DIR}/${C.SETS_SAVE_FILE}`;
let saved = sprintf('%.J\n', { gfw4: [ '198.51.100.99' ], udirect4: [], uproxy4: [] });
write(saved_path, saved);
flag('nft-load-fail', true);
tick(d);
check(fs.readfile(saved_path) == saved, 'failed nft load preserves sets.save byte for byte');
flag('nft-load-fail', false);
tick(d);
check(fs.stat(saved_path) == null && index(fs.readfile(`${current}/${C.ARTIFACT_FILES.nft}`),
	'elements = { 198.51.100.99 }') >= 0, 'successful nft load restores elements then consumes sets.save');
// A missing internal context is an error, never permission to fall back to disk.
d.applied_context = null;
remove(`${root}/nft-table`);
d.machine.table_missing_count = 1;
tick(d);
check(fs.stat(`${root}/nft-table`) == null && d.snapshot == a.snapshot,
	'missing applied context fails recovery without reading pending disk');
let missing = reload.run_live(d, null, { mode: 'gfw' });
check(!missing.ok && d.applied_context == null,
	'missing applied context fails runtime reload without adopting pending disk');
stop_children(d);
uloop.done();
print(`applied-context: ${pass} passed, ${fail} failed\n`);
exit(fail ? 1 : 0);
