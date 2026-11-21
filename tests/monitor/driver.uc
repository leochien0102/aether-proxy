'use strict';
// Exercise monitor side effects against isolated fixtures (docs/04 recovery and docs/07 probes).

import * as fs from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as sys from 'aetherproxy.sys';
import * as uci from 'uci';
import * as config from 'aetherproxy.config';
import * as pipeline from 'aetherproxy.pipeline';
import * as monitor from 'aetherproxy.monitor';
import * as reload from 'aetherproxy.reload';
import * as usage from 'aetherproxy.usage';
import * as supervise from 'aetherproxy.supervise';
import * as C from 'aetherproxy.const';

let pass = 0, fail = 0;
function ok(name) { pass++; print(`PASS  ${name}\n`); }
function bad(name, detail) { fail++; print(`FAIL  ${name}${detail ? ': ' + detail : ''}\n`); }
function check(value, name, detail) { if (value) ok(name); else bad(name, detail); }

function write(path, value) {
	let parent = substr(path, 0, rindex(path, '/'));
	return sys.mkdir_p(parent) && sys.write_atomic(path, value);
};

function state_write(ctx, value) {
	return sys.write_atomic(`${replace(ctx.root, /\/$/, '')}${C.RUN_DIR}/${C.STATE_FILE}`, sprintf('%.J\n', value));
};

function settings(root, confdir, data_dir, baseline_dir, custom_dir, bin_dir) {
	let opts = { sys_root: root, confdir, data_dir, baseline_dir, custom_dir, bin_dir, run_dir: C.RUN_DIR };
	let ctx = { root, bin_dir, run_dir: C.RUN_DIR, state_dir: C.STATE_DIR, lan_ifaces: [ 'br-lan' ] };
	let applied_context = pipeline.read(opts);
	if (!applied_context.ok)
		return { error: `pipeline failed: ${applied_context.detail}` };
	// Legacy scenarios isolate DNS/failsafe actions; T9.40's real-daemon suite covers degradation.
	applied_context.snapshot.main.degrade_gfw = false;
	let cfg = applied_context;
	let built = pipeline.render(applied_context, { node_ip: '203.0.113.20', dns_tier: 'T2', restored: {} });
	if (!built.ok)
		return { error: `pipeline failed: ${built.detail}` };
	let current = `${replace(root, /\/$/, '')}${C.RUN_DIR}/${C.DAEMON_CURRENT_DIR}`;
	if (!sys.mkdir_p(current))
		return { error: sys.error() };
	for (let name, file in C.ARTIFACT_FILES)
		if (!sys.write_atomic(`${current}/${file}`, built.artifacts[name]))
			return { error: sys.error() };
	if (!sys.mkdir_p(`${replace(root, /\/$/, '')}${C.STATE_DIR}`))
		return { error: sys.error() };
	let service = {
		state: 'degraded', dns_tier: 'T2', dns_failsafe: false, node_ip: '203.0.113.20',
		node_id: cfg.snapshot.main.node, since: time(),
		components: {
			[C.XRAY_COMPONENT]: { path: `${bin_dir}/${C.XRAY_COMPONENT}` },
			[C.CHINADNS_COMPONENT]: { path: `${bin_dir}/${C.CHINADNS_COMPONENT}` }
		}
	};
	state_write(ctx, service);
	return { opts, ctx, snapshot: cfg.snapshot, applied_context, state: service, current };
};

function count(text, needle) {
	let found = 0;
	for (let line in split(text ?? '', '\n'))
		if (index(line, needle) >= 0)
			found++;
	return found;
};

function no_external_children(d) {
	for (let key in [ 'dns', 'xray' ]) {
		let child = d.children[key];
		if (child == null)
			continue;
		let done = false;
		child.stop(() => { done = true; uloop.end(); });
		while (!done)
			uloop.run(100);
	}
};

function base_daemon(args, initial, heatmap_enabled) {
	let s = settings(args[1], args[2], args[3], args[4], args[5], args[6]);
	if (s.error)
		return s;
	if (heatmap_enabled != null)
		s.snapshot.stats.heatmap_enabled = heatmap_enabled;
	let d = monitor.create_daemon({
		ctx: s.ctx, opts: s.opts, snapshot: s.snapshot, applied_context: s.applied_context,
		children: { dns: null, xray: null }, state: s.state
	});
	d.machine = { ...d.machine, ...initial };
	return { ...s, daemon: d };
};

// Run after heatmap-on in the same sysroot, with a new daemon and on-disk history.
function scenario_heatmap_seed(args, payload, enable_at_runtime) {
	let name = enable_at_runtime ? 'T16.46 runtime enable' : 'T16.45 same-day restart';
	let root = args[1], path = root + C.USAGE_FILE;
	let tm = localtime(time());
	let today = sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
	let disk = { tx: 200000000, rx: 1800000000, observed: 1800, healthy: 1500 };
	let seed = sprintf('%.J', { schema: 1, updated_at: time(), days: { [today]: disk } });
	check(write(path, seed), `${name}: persisted 2 GB before daemon creation`);
	let setup = base_daemon(args, {}, !enable_at_runtime);
	check(!setup.error, `${name}: creates a fresh monitor`, setup.error);
	if (setup.error)
		return;
	let d = setup.daemon, counters_path = root + '/nft-counters.json';
	let state_path = `${root}${C.RUN_DIR}/${C.STATE_FILE}`;
	check(d.usage_ready === false && d.usage_days == null && d.usage.last_tx == null && d.usage.last_rx == null,
		`${name}: creation defers disk and nft baselines to the first enabled sample`);
	function sample(tx, rx) {
		write(counters_path, payload(tx, rx));
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		return json(fs.readfile(state_path)).usage_today;
	};
	if (enable_at_runtime) {
		sample(699000000, 899000000);
		let disabled = json(fs.readfile(state_path));
		check(!('usage_today' in disabled) && d.usage_ready === false && d.usage_days == null &&
			d.usage.last_tx == null && d.usage.last_rx == null && fs.readfile(path) == seed,
			`${name}: a disabled tick neither publishes, seeds nor samples usage`);
		print(`${name} evidence disabled state.json: ` + sprintf('%.J', disabled) + '\n');
		d.snapshot = { ...d.snapshot, stats: { ...d.snapshot.stats, heatmap_enabled: true } };
	}
	let first = sample(700000000, 900000000);
	check(d.usage_ready === true && d.usage_days?.[today]?.rx == disk.rx &&
		d.usage.last_tx == 700000000 && d.usage.last_rx == 900000000,
		`${name}: the first enabled tick loads history and records the nft baselines`);
	if (enable_at_runtime) {
		print(`${name} evidence first enabled state.json: ` + sprintf('%.J', { usage_today: first }) + '\n');
		// Another snapshot replacement must not re-seed the already sampled daemon.
		d.snapshot = { ...d.snapshot, stats: { ...d.snapshot.stats } };
	}
	check(first?.date == today && first.tx == disk.tx && first.rx == disk.rx &&
		first.observed == disk.observed && first.healthy == disk.healthy,
		`${name}: first snapshot retains disk totals without adding nft history`, sprintf('%.J', first));
	let second = sample(700002500, 900004000);
	check(second?.date == today && second.tx == disk.tx + 2500 && second.rx == disk.rx + 4000,
		`${name}: state.json grows by exactly the new traffic`, sprintf('%.J', second));
	print(`${name} evidence seed: ` + seed + '\n');
	print(`${name} evidence state.json: ` + sprintf('%.J', { usage_today: second }) + '\n');
	check(fs.readfile(path) == seed, `${name}: live samples do not rewrite history`);

	// Drive a synthetic local date crossing and the normal flush without waiting for midnight.
	let tomorrow = timelocal({ year: tm.year, mon: tm.mon, mday: tm.mday + 1, hour: 12, min: 0, sec: 0 });
	usage.sample(d.usage, { now: tomorrow, tx: 700002500, rx: 900004000, elapsed: 0 });
	monitor.flush_usage(d);
	let persisted = json(fs.readfile(path));
	check(persisted.days[today]?.tx == disk.tx + 2500 && persisted.days[today]?.rx == disk.rx + 4000 &&
		persisted.days[d.usage.day]?.tx == 0 && d.usage.day > today,
		`${name}: crossing writes the complete old day`, sprintf('%.J', persisted));
	print(`${name} evidence usage.json: ` + sprintf('%.J', persisted) + '\n');
	no_external_children(d);
};

let scenario = ARGV[0];
let opts = base_daemon(ARGV, {});
if (opts.error) {
	bad('monitor integration setup', opts.error);
	exit(1);
}
if (!uloop.init()) {
	bad('uloop initializes');
	exit(1);
}

if (match(scenario, /^failover-/)) {
	let d = opts.daemon, original = d.state.node_id;
	let conf = opts.opts.confdir + '/aetherproxy', uci_before = fs.readfile(conf);
	let events_path = opts.ctx.root + C.RUN_DIR + '/' + C.EVENTS_FILE;
	let calls_path = opts.ctx.root + C.RUN_DIR + '/calls.log';
	let reserved = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	let listener = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	check(reserved != null && reserved.bind({ address: '127.0.0.1', port: 0 }) &&
		listener != null && listener.bind({ address: '127.0.0.1', port: 0 }) && listener.listen(64),
		'T16.17 real loopback reachable and refused endpoints');
	let dead_port = reserved.sockname().port, live_port = listener.sockname().port;
	d.snapshot.sub.failover = scenario != 'failover-off';
	d.snapshot.dns.direct_dns_enabled = false;
	d.snapshot.dns.allow_china_fallback = false;
	d.snapshot.main.degrade_gfw = false;
	d.snapshot.nodes[original].port = dead_port;
	d.state.node_ip = '127.0.0.1';
	d.machine = { ...d.machine, node_ip: '127.0.0.1', state: 'running', dns_tier: 'T1',
		last_node_refresh: time(), ever_healthy: true };
	let template = { protocol: 'socks', security: 'none', transport: 'raw', address: '127.0.0.1' };
	let excluded = 'n_ffffffffffffffffffffffffffffffff';
	let dead = 'n_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
	let first = 'n_dddddddddddddddddddddddddddddddd';
	let later = 'n_00000000000000000000000000000000';
	let unlisted = 'n_cccccccccccccccccccccccccccccccc';
	// Deliberately differ from both lexical and list order. Neither excluded node may be probed.
	d.snapshot.nodes[unlisted] = { ...template, port: live_port };
	d.snapshot.nodes[excluded] = { ...template, port: live_port, disabled: true };
	d.snapshot.nodes[dead] = { ...template, port: dead_port };
	d.snapshot.nodes[first] = { ...template, port: live_port };
	d.snapshot.nodes[later] = { ...template, port: live_port };
	d.snapshot.main.failover_nodes = [ later, dead, excluded, first, 'missing' ];
	if (scenario != 'failover-opt-out')
		push(d.snapshot.main.failover_nodes, original);
	if (scenario == 'failover-all-dead') {
		d.snapshot.nodes[first].port = dead_port;
		d.snapshot.nodes[later].port = dead_port;
	}
	if (scenario == 'failover-rollback')
		write(opts.ctx.root + '/xray-test-rc', '1');
	d.reload = reload.run_live;
	function tick_once() {
		d.skip_next = false;
		monitor.tick(d);
		while (d.busy) uloop.run(100);
	};
	let success = scenario == 'failover-success';
	if (success) {
		let polls = 0, reads = 0, closes = 0;
		let sock = {
			connect: () => false,
			getopt: () => { reads++; return 0; },
			close: () => { closes++; }
		};
		d.node_probe_socket = {
			create: () => sock,
			error: () => 115, // EINPROGRESS
			poll: () => { polls++; return [[ sock, 0, 1 ]]; }
		};
		tick_once();
		delete d.node_probe_socket;
		check(polls == 1 && reads == 0 && closes == 1 && d.machine.failover_failures == 1,
			'T16.20 silent poll timeout counts as the first live-IP failure without reading SO_ERROR');
	}
	else
		tick_once();
	tick_once();
	check(d.state.node_id == original && count(fs.readfile(events_path), '"NODE_FAILOVER"') == 0,
		'T16.17 two live-IP failures do not switch');
	tick_once();
	let disabled = scenario == 'failover-off' || scenario == 'failover-opt-out';
	if (success) {
		check(d.state.node_id == first && d.snapshot.main.node == first,
			'T16.21 UCI insertion order skips current, unlisted, disabled and dead candidates');
		check(count(fs.readfile(events_path), '"NODE_FAILOVER"') == 1 &&
			index(fs.readfile(events_path), 'node_tcp_failed_3') >= 0,
			'T16.17 successful failover emits notice with TCP reason');
		let calls = fs.readfile(calls_path) ?? '';
		check(count(calls, 'run -test') >= 1 && count(calls, 'nft -f ') >= 1 &&
			count(fs.readfile(opts.ctx.root + '/calls.log'), 'xray run -c') >= 1,
			'T16.17 failover uses reload validation nft and Xray restart');
		check(d.machine.failover_candidates[excluded] == null && d.machine.failover_candidates[unlisted] == null &&
			d.machine.failover_candidates[original] == null &&
			d.machine.failover_candidates[dead] != null && d.machine.failover_candidates[first] != null &&
			d.machine.failover_candidates[later] == null,
			'T16.17 first reachable stops candidate iteration');
		let node = json(fs.readfile(opts.current + '/xray.json')).outbounds[0];
		check(node.settings.servers[0].port == live_port, 'T16.17 reload installs chosen candidate artifact');
		// The original endpoint recovers, but only the new live endpoint is observed.
		d.snapshot.nodes[original].port = live_port;
		tick_once();
		check(d.state.node_id == first && count(fs.readfile(events_path), '"NODE_FAILOVER"') == 1,
			'T16.17 original recovery never switches back');
		// New failure during cooldown does not cause another candidate attempt.
		d.snapshot.nodes[first].port = dead_port;
		for (let i = 0; i < 4; i++) tick_once();
		check(d.state.node_id == first && count(fs.readfile(events_path), '"NODE_FAILOVER"') == 1,
			'T16.17 successful switch enforces ten-minute cooldown');
		// Match daemon's user-reload publication: it replaces state/snapshot but retains machine history.
		d.state.node_id = original;
		d.snapshot.main.node = original;
		d.snapshot.nodes[original].port = dead_port;
		let manual_at = time();
		d.state.last_reload = { at: manual_at, target_node: original, ok: true };
		for (let i = 0; i < 3; i++) tick_once();
		check(d.state.node_id == original && d.machine.failover_until >= manual_at + 600 &&
			count(fs.readfile(events_path), '"NODE_FAILOVER"') == 1,
			'T16.17 manual node selection is protected for ten minutes');
	}
	else {
		check(d.state.node_id == original, 'T16.17 failed or disabled failover preserves runtime node');
		check(count(fs.readfile(events_path), '"NODE_FAILOVER_FAILED"') == (disabled ? 0 : 1),
			'T16.17 disabled is silent and failed attempt emits one warn');
		if (!disabled) {
			check(d.machine.failover_until >= time() + 590 && d.machine.failover_latched,
				'T16.17 failed attempt latches fault and starts ten-minute cooldown');
			let remembered = sprintf('%.J', d.machine.failover_candidates);
			for (let i = 0; i < 3; i++) tick_once();
			check(count(fs.readfile(events_path), '"NODE_FAILOVER_FAILED"') == 1 &&
				sprintf('%.J', d.machine.failover_candidates) == remembered,
				'T16.17 sustained fault never repeats candidate attempts');
			// Rearm a distinct fault, expire global cooldown, retain candidate cooldown.
			d.machine.failover_latched = false;
			d.machine.failover_failures = 0;
			d.machine.failover_until = 0;
			for (let i = 0; i < 3; i++) tick_once();
			let previous = json(remembered), unchanged = true;
			for (let id, stamp in previous)
				unchanged = unchanged && d.machine.failover_candidates[id] == stamp;
			check(unchanged, 'T16.17 same candidates not retried within thirty minutes');
		}
	}
	check(fs.readfile(conf) == uci_before &&
		config.load(uci.cursor(opts.opts.confdir, opts.ctx.root + '/uci-savedir')).snapshot.main.node == original,
		'T16.17 UCI unchanged byte-for-byte and main.node retains user selection');
	let probe = fs.readfile(opts.ctx.root + C.RUN_DIR + '/' + C.NODE_PROBE_LOG) ?? '';
	let records = filter(split(trim(probe), '\n'), line => line != '');
	let failovers = filter(records, line => json(line).action == 'failover');
	check(length(failovers) == (disabled ? 0 : (success ? 1 : 2)),
		'T16.17 each attempted failover appends one action=failover record', probe);
	reserved.close();
	listener.close();
	no_external_children(d);
}
else if (match(scenario, /^disabled-/)) {
	let d = opts.daemon;
	d.snapshot.probe.fail_threshold = 1;
	d.snapshot.probe.recover_threshold = 2;
	d.snapshot.dns.allow_china_fallback = scenario != 'disabled-no-fallback';
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', ever_healthy: true };
	if (scenario == 'disabled-t3' || scenario == 'disabled-recover') {
		d.machine.state = 'degraded';
		d.machine.dns_tier = 'T3';
		d.machine.last_t2_retry = time() - 301;
		d.machine.proxy_ok_count = scenario == 'disabled-recover' ? 1 : 0;
	}
	if (scenario == 'disabled-stale-t2') {
		d.machine.state = 'degraded';
		d.machine.dns_tier = 'T2';
	}
	if (scenario == 'disabled-outage') {
		d.machine.xray_down_count = 1;
		let path = `${opts.ctx.root}/proc/net/tcp`;
		let lines = split(fs.readfile(path), '\n');
		check(write(path, join('\n', filter(lines, line => index(line, '7968') < 0))),
			'disabled-outage removes Xray listener');
	}
	let retry_before = d.machine.last_t2_retry;
	let log_path = `${opts.ctx.root}${C.RUN_DIR}/calls.log`;
	monitor.tick(d);
	while (d.busy) uloop.run(100);
	let expected = scenario == 'disabled-no-fallback' || scenario == 'disabled-recover' ? 'T1' : 'T3';
	check(d.machine.dns_tier == expected, `${scenario}: applies ${expected} without T2`, sprintf('%.J', d.machine));
	check(count(fs.readfile(log_path), `-t 5 ${d.snapshot.dns.dns_probe_domain}`) == 0,
		`${scenario}: no direct-tier DNS probe is executed`);
	if (scenario == 'disabled-t3')
		check(d.machine.last_t2_retry == retry_before && !d.machine.t2_retry_pending,
			'disabled-t3: five-minute retry stays disabled');
	if (scenario == 'disabled-recover')
		check(d.machine.state == 'running', 'disabled-recover: healthy threshold restores running/T1');
	no_external_children(d);
}
else if (scenario == 'proxy-tier') {
	let d = opts.daemon;
	let state = config.load(uci.cursor(opts.opts.confdir, opts.ctx.root + '/uci-savedir')).snapshot;
	state.main.degrade_gfw = false;
	state.probe.fail_threshold = 3;
	state.probe.recover_threshold = 1;
	d.snapshot = state;
	monitor.tick(d);
	uloop.run(100);
	check(!d.busy && d.machine.state == 'running' && d.machine.dns_tier == 'T1',
		'healthy HTTP probe enters T1', sprintf('state=%s tier=%s probe=%s expected=%s', d.machine.state, d.machine.dns_tier,
		sprintf('%.J', d.machine.last_probe), d.snapshot.probe.expect_code));
	for (let i = 0; i < 3; i++) {
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		uloop.run(100);
	}
	check(d.machine.state == 'degraded' && d.machine.dns_tier == 'T2',
		'three failed HTTP probes downgrade to T2', sprintf('state=%s tier=%s failures=%d', d.machine.state, d.machine.dns_tier, d.machine.proxy_fail_count));
	let calls = fs.readfile(`${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/calls.log`) ?? '';
	let children_calls = fs.readfile(`${replace(opts.ctx.root, /\/$/, '')}/calls.log`) ?? '';
	check(count(calls, 'curl ') == 4, 'proxy action sampled each health round');
	check(count(children_calls, 'chinadns-ng ') >= 2 && count(calls, 'killall -HUP dnsmasq') >= 2,
		'T1/T2 transitions restart chinadns and HUP dnsmasq',
		sprintf('dns=%d hup=%d', count(children_calls, 'chinadns-ng '), count(calls, 'killall -HUP dnsmasq')));
	let cd = fs.readfile(`${opts.current}/${C.ARTIFACT_FILES.chinadns}`) ?? '';
	// Follow the configured upstreams, not a default predating T8.22.
	let direct_upstreams = 'trust-dns ' + join(',', d.snapshot.dns.direct_dns);
	check(index(cd, direct_upstreams) >= 0, 'T2 render has direct upstreams');
	no_external_children(d);
}
else if (scenario == 'xray-failsafe') {
	let d = opts.daemon;
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', xray_down_count: 0, xray_down_reported: false };
	let before = fs.readfile(`${replace(opts.ctx.root, /\/$/, '')}/proc/net/tcp`) ?? '';
	write(`${replace(opts.ctx.root, /\/$/, '')}/proc/net/tcp`, replace(before, /.*7968.*\n/g, ''));
	monitor.tick(d);
	while (d.busy) uloop.run(100);
	uloop.run(100);
	check(d.machine.state == 'running' && d.machine.xray_down_count == 1,
		'first missing-listener round does not enter failsafe');
	monitor.tick(d);
	while (d.busy)
		uloop.run(100);
	let calls = fs.readfile(`${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/calls.log`) ?? '';
	check(d.machine.state == 'failsafe', 'two missing-listener rounds enter failsafe');
	check(index(calls, 'nft flush chain inet aetherproxy prerouting') >= 0, 'failsafe clears prerouting only');
	check(d.machine.dns_tier == 'T2', 'failsafe selects T2');
	let table_path = `${replace(opts.ctx.root, /\/$/, '')}/nft-table`;
	if (fs.stat(table_path) != null && !fs.unlink(table_path))
		bad('test removes nft table before recovery', fs.error());
	write(`${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/${C.SETS_SAVE_FILE}`,
		sprintf('%.J\n', { gfw4: [ '198.51.100.10' ], udirect4: [], uproxy4: [] }));
	let restored = `${replace(opts.ctx.root, /\/$/, '')}/proc/net/tcp`;
	let tcp = fs.readfile(restored) ?? '';
	write(restored, tcp + '  1: 0100007F:7968 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n');
	let saved_path = `${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/${C.SETS_SAVE_FILE}`;
	let saved_before = fs.readfile(saved_path);
	monitor.tick(d);
	while (d.busy) uloop.run(100);
	uloop.run(100);
	check(fs.readfile(saved_path) == saved_before,
		'failed missing-table reload preserves sets.save byte for byte');
	check(d.machine.state == 'failsafe', 'failed missing-table reload stays in failsafe');
	// The one-shot failure has cleared; the next tick must restore the same elements.
	monitor.tick(d);
	while (d.busy) uloop.run(100);
	uloop.run(100);
	calls = fs.readfile(`${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/calls.log`) ?? '';
	check(d.machine.state == 'degraded', 'listener recovery returns to degraded');
	check(count(calls, 'nft -f ') >= 1, 'listener recovery reloads the ruleset');
	check(count(calls, 'nft -j list set') == 0, 'missing table avoids sets_export');
	let nft_file = fs.readfile(`${opts.current}/${C.ARTIFACT_FILES.nft}`) ?? '';
	check(index(nft_file, 'elements = { 198.51.100.10 }') >= 0, 'missing-table reload consumes sets.save');
	check(fs.stat(`${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/${C.SETS_SAVE_FILE}`) == null, 'sets.save is consumed');
	no_external_children(d);
}
else if (scenario == 'node-unreachable' || scenario == 'unhealthy-refresh') {
	let d = opts.daemon;
	let log_path = `${opts.ctx.root}${C.RUN_DIR}/calls.log`;
	let events_path = `${opts.ctx.root}${C.RUN_DIR}/${C.EVENTS_FILE}`;
	let lkg_path = `${opts.ctx.root}/etc/aether-proxy/state/${C.NODE_IP_FILE}`;
	let address = d.snapshot.nodes[d.snapshot.main.node].address;
	let original_lkg = sprintf('%.J\n', { nodes: { [address]: '203.0.113.20' } });
	check(write(lkg_path, original_lkg), 'T16.15 seeds verified monitor LKG');
	let lkg_inode = fs.stat(lkg_path).inode;
	// Bind without listening: the failure case is a real, deterministic refused TCP port.
	let listener = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	check(listener != null && listener.bind({ address: '127.0.0.1', port: 0 }),
		`${scenario}: reserves a loopback probe endpoint`);
	d.snapshot.nodes[d.snapshot.main.node].port = listener.sockname().port;
	write(`${opts.ctx.root}/resolve-ip`, '127.0.0.1\n');
	d.snapshot.dns.direct_dns_enabled = false;
	d.snapshot.dns.allow_china_fallback = false;
	d.snapshot.probe.fail_threshold = 1;
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', ever_healthy: true };
	let before = {};
	for (let name, file in C.ARTIFACT_FILES)
		before[file] = fs.readfile(`${opts.current}/${file}`);
	if (scenario == 'node-unreachable')
		d.machine.last_node_refresh = time() - C.MONITOR_NODE_REFRESH_SECS;
	monitor.tick(d);
	while (d.busy) uloop.run(100);
	let calls = fs.readfile(log_path) ?? '';
	let events = fs.readfile(events_path) ?? '';
	check(fs.readfile(lkg_path) == original_lkg && fs.stat(lkg_path).inode == lkg_inode,
		'T16.15 rejected candidate does not write LKG');
	check(d.machine.node_ip == '203.0.113.20' && d.state.node_ip == '203.0.113.20',
		`${scenario}: rejected IP leaves machine and published node_ip unchanged`);
	check(count(fs.readfile(`${opts.ctx.root}/calls.log`), 'xray ') == 0 && count(calls, 'run -test') == 0,
		`${scenario}: rejected IP neither tests nor restarts Xray`);
	let unchanged = true;
	for (let file, content in before)
		unchanged = unchanged && fs.readfile(`${opts.current}/${file}`) == content;
	check(unchanged && count(calls, 'nft -j list set') == 0 && count(calls, 'nft -f ') == 0,
		`${scenario}: rejected IP leaves all artifacts unchanged and skips sets export/load`);
	let decoded = map(filter(split(trim(events), '\n'), line => length(line)), line => json(line));
	let rejected = filter(decoded, e => e.code == 'NODE_IP_UNREACHABLE');
	check(length(rejected) == 1 && rejected[0].level == 'warn' &&
		rejected[0].args.node == d.snapshot.main.node && rejected[0].args.ip == '127.0.0.1' &&
		rejected[0].args.address == d.snapshot.nodes[d.snapshot.main.node].address &&
		rejected[0].args.port == listener.sockname().port,
		`${scenario}: NODE_IP_UNREACHABLE carries warn and all four fields`);
	check(count(events, 'NODE_IP_CHANGED') == 0 && count(events, 'START_FAILED') == 0,
		`${scenario}: rejection completes normally without NODE_IP_CHANGED or action error`);
	if (scenario == 'node-unreachable') {
		let probe_path = `${opts.ctx.root}${C.RUN_DIR}/${C.NODE_PROBE_LOG}`;
		let records = map(filter(split(trim(fs.readfile(probe_path)), '\n'), line => line != ''), line => json(line));
		let record = records[0];
		let fields = [ 'ts', 'address', 'attempts', 'raw', 'ip', 'source', 'elapsed_ms',
			'tier', 'node_ip_before', 'reachable', 'action' ];
		check(length(records) == 1 && join(',', sort(keys(record))) == join(',', sort(fields)) &&
			record.address == d.snapshot.nodes[d.snapshot.main.node].address &&
			record.attempts == 1 && record.raw == '127.0.0.1\n' && record.ip == '127.0.0.1' &&
			record.source == 'dns' && record.elapsed_ms >= 0 && record.ts >= time() - 10 &&
			record.tier == 'T1' && record.node_ip_before == '203.0.113.20' &&
			record.reachable === false && record.action == 'unreachable',
			'forensics: exactly one complete JSON record matches refused candidate and raw stdout');
		check(rejected[0].args.source == 'dns' && rejected[0].args.raw == record.raw,
			'forensics: unreachable event carries source and exact raw stdout');

		for (let gap in [ 60, 120, 240, 600 ]) {
			let attempted = d.machine.last_node_refresh_attempt;
			check(d.machine.node_probe_retry_at == attempted + gap,
				`retry: rejected candidate schedules ${gap} seconds`);
			let obs = { now: attempted + gap - 1, proxy_ok: true };
			check(index(monitor.next(d.machine, obs, d.snapshot).actions, 'refresh_node_ip') < 0,
				`retry: no refresh before ${gap}-second deadline`);
			obs.now++;
			check(index(monitor.next(d.machine, obs, d.snapshot).actions, 'refresh_node_ip') >= 0,
				`retry: refresh at ${gap}-second deadline`);
			// Advance only the fixture's clock fields, not wall time or the production tick.
			d.machine.last_node_refresh = time() - gap;
			d.machine.last_node_refresh_attempt = time() - gap;
			d.machine.node_probe_retry_at = time();
			monitor.tick(d);
			while (d.busy) uloop.run(100);
		}
		check(d.machine.node_probe_failures == 1,
			'retry: normal 600-second cadence resets failure series');
		let edge = { ...d.machine, state: 'running', node_probe_failures: 4,
			node_probe_retry_at: d.machine.last_node_refresh_attempt + 600 };
		let edge_obs = { now: d.machine.last_node_refresh_attempt + 60, proxy_ok: false };
		check(index(monitor.next(edge, edge_obs, d.snapshot).actions, 'refresh_node_ip') >= 0,
			'retry: unhealthy edge overrides long backoff after 60-second debounce');
		check(length(filter(split(trim(fs.readfile(probe_path)), '\n'), line => line != '')) == 5,
			'forensics: every fast retry adds exactly one JSON line');

		// Same-IP success resets backoff without introducing a new TCP probe.
		write(`${opts.ctx.root}/resolve-ip`, '203.0.113.20\n');
		d.machine.last_node_refresh_attempt = time() - 60;
		d.machine.node_probe_retry_at = time();
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		check(d.machine.node_probe_failures == 0 && d.machine.node_probe_retry_at == null,
			'retry: same-IP resolution resets backoff');
		let healthy = { now: d.machine.last_node_refresh_attempt + 599, proxy_ok: true };
		check(index(monitor.next(d.machine, healthy, d.snapshot).actions, 'refresh_node_ip') < 0,
			'retry: success waits through 599 seconds');
		healthy.now++;
		check(index(monitor.next(d.machine, healthy, d.snapshot).actions, 'refresh_node_ip') >= 0,
			'retry: success returns to 600-second cadence');
		write(`${opts.ctx.root}/resolve-always-fail`, '1\n');
		d.machine.last_node_refresh = time() - 600;
		d.machine.last_node_refresh_attempt = time() - 600;
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		records = map(filter(split(trim(fs.readfile(probe_path)), '\n'), line => line != ''), line => json(line));
		record = records[length(records) - 1];
		check(record.source == 'lkg' && record.raw == '' && record.attempts == 3 &&
			record.action == 'keep' && record.reachable == null,
			'forensics: fallback retains empty stdout and three attempts');
		check(fs.readfile(lkg_path) == original_lkg && fs.stat(lkg_path).inode == lkg_inode,
			'T16.15 fallback preserves LKG bytes and inode');
		print('probe samples:\n' + join('\n', [
			sprintf('%J', records[5]), sprintf('%J', records[0]), sprintf('%J', record)
		]) + '\n');
		check(fs.unlink(`${opts.ctx.root}/resolve-always-fail`), 'forensics: clears controlled DNS failure');

		let oversized = '';
		for (let i = 0; i < 6554; i++)
			oversized += '1234567890';
		write(probe_path, oversized);
		let long_raw = '127.0.0.1\n';
		for (let i = 0; i < 600; i++)
			long_raw += 'x';
		write(`${opts.ctx.root}/resolve-ip`, long_raw);
		d.machine.last_node_refresh = time() - 600;
		d.machine.last_node_refresh_attempt = time() - 600;
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		record = json(trim(fs.readfile(probe_path)));
		check(fs.readfile(probe_path + '.1') == oversized &&
			fs.stat(probe_path).size <= C.NODE_PROBE_LOG_MAX,
			'forensics: oversized log rotates to .1 and active log stays bounded');
		check(length(record.raw) == 512 && record.raw == substr(long_raw, 0, 512),
			'forensics: raw stdout is truncated to 512 bytes');
		let last_event = json(filter(split(trim(fs.readfile(events_path)), '\n'),
			line => index(line, 'NODE_IP_UNREACHABLE') >= 0)[-1]);
		check(last_event.args.raw == record.raw && last_event.args.source == 'dns',
			'forensics: event uses identical 512-byte truncation');

		// A failed rotation must not block subsequent refreshes, and warns only once.
		check(fs.unlink(probe_path + '.1') && sys.mkdir_p(probe_path + '.1'),
			'forensics: makes rotation destination unwritable as a file');
		for (let i = 0; i < 2; i++) {
			write(probe_path, oversized);
			d.machine.last_node_refresh = time() - 600;
			d.machine.last_node_refresh_attempt = time() - 600;
			monitor.tick(d);
			while (d.busy) uloop.run(100);
		}
		let warnings = filter(split(trim(fs.readfile(events_path)), '\n'),
			line => index(line, 'node-probe') >= 0 && index(line, 'FS_FAILED') >= 0);
		check(length(warnings) == 1 && d.machine.node_probe_retry_at != null,
			'forensics: log failures warn once without blocking candidate handling');
	}
	if (scenario == 'unhealthy-refresh') {
		check(count(calls, 'resolveip ') == 1 && count(events, 'PROXY_UNHEALTHY') == 1,
			'unhealthy-refresh: unhealthy transition tick immediately resolves before 600 seconds');
		let attempted = d.machine.last_node_refresh_attempt;
		d.machine.state = 'running';
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		check(count(fs.readfile(log_path), 'resolveip ') == 1 &&
			count(fs.readfile(events_path), 'PROXY_UNHEALTHY') == 2,
			'unhealthy-refresh: second unhealthy edge inside 60 seconds does not resolve');
		let edge = { ...d.machine, state: 'running' };
		let observation = { now: attempted + C.NODE_REFRESH_MIN_GAP_SECS - 1, proxy_ok: false };
		check(index(monitor.next(edge, observation, d.snapshot).actions, 'refresh_node_ip') < 0,
			'unhealthy-refresh: 59-second edge is debounced');
		observation.now++;
		check(count(join('\n', monitor.next(edge, observation, d.snapshot).actions), 'refresh_node_ip') == 1,
			'unhealthy-refresh: 60-second edge refreshes exactly once');
		let restarted = monitor.create_daemon(d);
		check(restarted.machine.last_node_refresh_attempt == null,
			'unhealthy-refresh: daemon recreation resets debounce state');
	}
	print(`${scenario} calls:\n${fs.readfile(log_path)}events:\n${fs.readfile(events_path)}`);
	listener.close();
	no_external_children(d);
}
else if (scenario == 'node-refresh') {
	let d = opts.daemon;
	let lkg_path = `${opts.ctx.root}/etc/aether-proxy/state/${C.NODE_IP_FILE}`;
	let address = d.snapshot.nodes[d.snapshot.main.node].address;
	let original_lkg = sprintf('%.J\n', { nodes: { [address]: '203.0.113.19' } });
	check(write(lkg_path, original_lkg), 'T16.15 seeds LKG before successful switch');
	let listener = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	check(listener != null && listener.bind({ address: '127.0.0.1', port: 0 }) && listener.listen(8),
		'node refresh listens on a real loopback TCP endpoint');
	d.snapshot.nodes[d.snapshot.main.node].port = listener.sockname().port;
	write(`${opts.ctx.root}/resolve-ip`, '127.0.0.1\n');
	let tcp_path = `${opts.ctx.root}/proc/net/tcp`;
	let lines = split(fs.readfile(tcp_path), '\n');
	check(write(tcp_path, join('\n', filter(lines, line => index(line, '7968') < 0))),
		'node refresh removes the static Xray listener fixture');
	d.children.xray = supervise.create({
		name: C.XRAY_COMPONENT,
		argv: [ `${opts.ctx.bin_dir}/xray`, 'run', '-c', `${opts.current}/${C.ARTIFACT_FILES.xray}` ],
		run_dir: `${opts.ctx.root}${C.RUN_DIR}`, backoff: [ 5 ], stable_secs: 300
	});
	d.children.xray.start();
	check(monitor.wait_xray_port(opts.ctx), 'node refresh starts with a real supervised Xray substitute');
	check(write(`${opts.ctx.root}/xray-listen-delay`, '1\n'), 'node refresh enables delayed replacement');
	d.machine.node_probe_failures = 3;
	d.machine.node_probe_retry_at = time() + 240;
	d.machine.node_ip = '203.0.113.19';
	d.machine.last_node_refresh = time() - C.MONITOR_NODE_REFRESH_SECS - 1;
	let observed_pending = false;
	let pending = uloop.timer(200, () => {
		observed_pending = true;
		check(d.busy && fs.readfile(lkg_path) == original_lkg,
			'T16.15 TCP acceptance does not save LKG before delayed Xray ready');
	});
	monitor.tick(d);
	while (d.busy)
		uloop.run(100);
	check(observed_pending, 'T16.15 observes pending Xray readiness');
	check(d.machine.node_ip == '127.0.0.1', 'node refresh publishes the resolved IP');
	let lkg = json(fs.readfile(`${opts.ctx.root}/etc/aether-proxy/state/${C.NODE_IP_FILE}`));
	check(lkg.nodes[d.snapshot.nodes[d.snapshot.main.node].address] == '127.0.0.1',
		'T16.15 accepted switch saves LKG after Xray ready');
	let events = fs.readfile(`${opts.ctx.root}${C.RUN_DIR}/${C.EVENTS_FILE}`) ?? '';
	check(count(events, 'NODE_IP_CHANGED') == 1 && count(events, 'NODE_IP_UNREACHABLE') == 0,
		'node refresh: successful TCP probe emits NODE_IP_CHANGED without unreachable event');
	let probe = json(trim(fs.readfile(`${opts.ctx.root}${C.RUN_DIR}/${C.NODE_PROBE_LOG}`)));
	check(probe.action == 'switch' && probe.reachable === true && probe.raw == '127.0.0.1\n' &&
		probe.source == 'dns' && probe.node_ip_before == '203.0.113.19',
		'forensics: successful switch records the pre-switch IP and TCP verdict');
	check(d.machine.node_probe_failures == 0 && d.machine.node_probe_retry_at == null,
		'retry: successful switch clears pending backoff');
	let changed = json(filter(split(trim(events), '\n'), line => index(line, 'NODE_IP_CHANGED') >= 0)[0]);
	check(changed.args.raw == probe.raw && changed.args.source == probe.source,
		'forensics: changed event matches probe source and raw');
	listener.close();
	check(index(fs.readfile(`${opts.ctx.root}/proc/net/tcp6`) ?? '', ':7968 ') >= 0,
		'node refresh finishes only after the delayed Xray listener is ready');
	check(d.machine.xray_down_count == 0 && !d.machine.xray_down_reported,
		'node refresh does not count its deliberate restart as an outage');
	no_external_children(d);
}
else if (scenario == 'heatmap-off' || scenario == 'heatmap-on') {
	// T12.3 B25: the sampling entry point only. Day-level accounting is unit-tested with
	// a fake clock; here the fixture counters prove who runs the nft counter query.
	let d = opts.daemon;
	// A closed switch must also remove a field left by an earlier enabled run.
	d.state.usage_today = { date: '2026-01-01', tx: 1 };
	let counters_path = `${opts.ctx.root}/nft-counters.json`;
	let log_path = `${opts.ctx.root}${C.RUN_DIR}/calls.log`;
	let payload = (tx, rx) => sprintf('%.J', { nftables: [
		{ counter: { family: 'inet', table: 'aetherproxy', name: 'proxy_tx', packets: 1, bytes: tx } },
		{ counter: { family: 'inet', table: 'aetherproxy', name: 'proxy_rx', packets: 1, bytes: rx } }
	] }) + '\n';
	write(counters_path, payload(1000, 2000));
	monitor.tick(d);
	while (d.busy) uloop.run(100);
	if (scenario == 'heatmap-off') {
		check(count(fs.readfile(log_path), 'list counters') == 0,
			'heatmap-off: a closed switch never queries the nft counters');
		check(d.usage.day == null && d.usage.tx == 0 && d.usage.rx == 0 && d.usage.observed == 0,
			'heatmap-off: nothing is aggregated', sprintf('%.J', d.usage));
		write(counters_path, payload(5000, 6000));
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		check(count(fs.readfile(log_path), 'list counters') == 0,
			'heatmap-off: still no counter query after counters changed');
		check(d.usage.day == null, 'heatmap-off: still nothing aggregated');
		check(!('usage_today' in json(fs.readfile(`${opts.ctx.root}${C.RUN_DIR}/${C.STATE_FILE}`))),
			'T16.8 monitor disabled snapshot omits usage_today');
	}
	else {
		check(count(fs.readfile(log_path), 'list counters') == 1,
			'heatmap-on: an open switch samples once per tick');
		check(d.usage.day != null && d.usage.tx == 0 && d.usage.last_tx == 1000 && d.usage.last_rx == 2000,
			'heatmap-on: the first sample only records the baseline', sprintf('%.J', d.usage));
		let first = json(fs.readfile(`${opts.ctx.root}${C.RUN_DIR}/${C.STATE_FILE}`)).usage_today;
		check(first?.date == d.usage.day && first?.tx == 0 && first?.rx == 0 &&
			first?.observed == 0 && first?.healthy == 0 && first.at >= time() - 1 && first.at <= time(),
			'T16.8 monitor first snapshot has all live-day fields', sprintf('%.J', first));
		d.machine.state = 'degraded'; // Exercise the existing degraded-health assertion with nonzero elapsed.
		d.usage_mono_ms -= 1000; // Advance the sample window without a wall-clock sleep.
		write(counters_path, payload(3500, 4000));
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		check(count(fs.readfile(log_path), 'list counters') == 2,
			'heatmap-on: each tick samples once');
		check(d.usage.tx == 2500 && d.usage.rx == 2000, 'heatmap-on: deltas accumulate',
			sprintf('%.J', d.usage));
		check(d.usage.healthy == 0, 'heatmap-on: degraded rounds never count healthy');
		let second = json(fs.readfile(`${opts.ctx.root}${C.RUN_DIR}/${C.STATE_FILE}`)).usage_today;
		check(second.tx == 2500 && second.rx == 2000 && second.observed > first.observed &&
			second.healthy == 0 && second.at >= first.at,
			'T16.8 monitor live snapshot grows with samples', sprintf('%.J', second));
		print('T16.8 evidence monitor state.json: ' + sprintf('%.J', { usage_today: second }) + '\n');
		check(fs.stat(`${opts.ctx.root}/etc/aether-proxy/usage.json`) == null,
			'T16.8 monitor same-day ticks do not create usage.json');
		write(counters_path, 'not json');
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		check(d.usage.tx == 2500 && d.usage.last_tx == 3500,
			'heatmap-on: unreadable counters skip bytes and keep the baseline', sprintf('%.J', d.usage));
		write(counters_path, payload(3600, 4100));
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		check(d.usage.tx == 2600 && d.usage.rx == 2100,
			'heatmap-on: the next good read resumes the series', sprintf('%.J', d.usage));
	}
	no_external_children(d);
	if (scenario == 'heatmap-on') {
		scenario_heatmap_seed(ARGV, payload, false);
		scenario_heatmap_seed(ARGV, payload, true);
	}
}
else if (scenario == 'heatmap-persist' || scenario == 'heatmap-corrupt' || scenario == 'heatmap-persist-off') {
	// T12.4 B25: the persistence wiring. The crossed day is produced by driving the pure
	// sampler with yesterday's noon, so the next tick's real wall clock crosses the local
	// date and flushes; every later flush goes through monitor.flush_usage() directly.
	let d = opts.daemon;
	let usage_dir = `${opts.ctx.root}/etc/aether-proxy`;
	let usage_file = `${usage_dir}/usage.json`;
	let events_path = `${opts.ctx.root}${C.RUN_DIR}/${C.EVENTS_FILE}`;
	let noon_before = days => {
		let base = localtime(time());
		return timelocal({ year: base.year, mon: base.mon, mday: base.mday - days, hour: 12, min: 0, sec: 0 });
	};
	let date_of = stamp => {
		// ucode's localtime() already returns 1-based months (see usage.uc local_date).
		let tm = localtime(stamp);
		return sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
	};
	let events = () => fs.readfile(events_path) ?? '';
	if (scenario == 'heatmap-persist-off') {
		// A closed switch must not even load the history, let alone write a file (docs §2).
		usage.sample(d.usage, { tx: 1000, rx: 2000, now: time(), elapsed: 0, cap: 60,
			state: 'running', proxy_ok: true });
		monitor.flush_usage(d);
		check(fs.stat(usage_file) == null,
			'heatmap-persist-off: a closed switch never creates or writes usage.json');
		check(d.usage_days == null, 'heatmap-persist-off: a closed switch never loads the history');
	}
	else if (scenario == 'heatmap-persist') {
		let seeded = { schema: 1, updated_at: 1790000000,
			quota: { bytes: 100000000000, set_at: 17 }, future: 'keep', days: {
			'2026-01-01': { tx: 11, rx: 22, observed: 30, healthy: 20 } } };
		sys.mkdir_p(usage_dir);
		check(write(usage_file, sprintf('%.J', seeded) + '\n'), 'heatmap-persist: the seed history is in place');
		usage.sample(d.usage, { tx: 1000, rx: 2000, now: noon_before(1), elapsed: 0, cap: 60,
			state: 'running', proxy_ok: true });
		usage.sample(d.usage, { tx: 1500, rx: 2600, now: noon_before(1) + 30, elapsed: 30, cap: 60,
			state: 'running', proxy_ok: true });
		monitor.tick(d);
		while (d.busy) uloop.run(100);
		let text = fs.readfile(usage_file);
		check(text != null, 'heatmap-persist: the crossing tick rewrites usage.json');
		let data = json(text);
		let published = json(fs.readfile(`${opts.ctx.root}${C.RUN_DIR}/${C.STATE_FILE}`)).usage_today;
		check(published?.date == date_of(time()) && published.tx == 0 && published.observed == 0,
			'T16.8 monitor crossing publishes the new local day', sprintf('%.J', published));
		check(data.quota?.bytes == 100000000000 && data.quota?.set_at == 17 && data.future == 'keep',
			'T16.2 monitor crossing flush preserves quota and unknown fields', text);
		// Change quota after the first flush cached history, then cross another day.
		check(usage.set_quota(usage_file, 1000000000000, 18).ok,
			'T16.2 CLI-style quota edit succeeds between monitor flushes');
		let live = d.usage.day;
		usage.sample(d.usage, { tx: 1600, rx: 2700, now: noon_before(-1), elapsed: 30, cap: 60,
			state: 'running', proxy_ok: true });
		monitor.flush_usage(d);
		let reloaded = json(fs.readfile(usage_file));
		check(reloaded.quota?.bytes == 1000000000000 && reloaded.quota?.set_at == 18 &&
			reloaded.future == 'keep' && reloaded.days[live]?.tx != null,
			'T16.2 monitor second crossing rereads quota rather than overwriting the CLI edit', sprintf('%.J', reloaded));
		// Restore the sampler to today so the existing retry assertions stay unchanged.
		d.usage.day = live;
		d.usage.tx = 0; d.usage.rx = 0; d.usage.observed = 0; d.usage.healthy = 0;
		let yesterday = date_of(noon_before(1)), today = date_of(time());
		check(data.schema == 1 && type(data.updated_at) == 'int',
			'heatmap-persist: the document carries schema 1 and a wall-clock updated_at', text);
		check(data.days[yesterday]?.tx == 500 && data.days[yesterday]?.rx == 600 &&
			data.days[yesterday]?.observed == 30 && data.days[yesterday]?.healthy == 30,
			'heatmap-persist: the crossed-out day is persisted with its accumulators', text);
		check(data.days['2026-01-01']?.tx == 11,
			'heatmap-persist: previously persisted days survive the flush', text);
		check(data.days[today]?.tx == 0 && data.days[today]?.observed == 0,
			'heatmap-persist: the live day is written as an entry', text);
		check(length(keys(data.days)) == 3, 'heatmap-persist: no stray dates are written', text);
		check((fs.stat(usage_file).mode & 511) == 384,
			'heatmap-persist: usage.json has mode 0600', sprintf('%J', fs.stat(usage_file).mode));
		check(length(fs.glob(`${usage_dir}/usage.json.tmp.*`) ?? []) == 0,
			'heatmap-persist: no atomic-write residue');
		check(count(events(), 'FS_FAILED') == 0, 'heatmap-persist: a successful flush is silent', events());
		check(usage.set_quota(usage_file, null, 19).ok,
			'T16.2 quota clear succeeds between monitor flushes');
		monitor.flush_usage(d);
		let cleared = json(fs.readfile(usage_file));
		check(cleared.quota?.bytes == null && cleared.quota?.set_at == null && cleared.future == 'keep',
			'T16.2 monitor flush preserves cleared quota without resurrecting the old value');
		// A failed rewrite leaves the target alone and does not block; the next flush retries.
		fs.unlink(usage_file);
		fs.mkdir(usage_file);
		monitor.flush_usage(d);
		check(fs.stat(usage_file)?.type == 'directory',
			'heatmap-persist: a failed rewrite does not delete or replace the target');
		check(count(events(), 'FS_FAILED') == 1 && count(events(), usage_file) == 1,
			'heatmap-persist: the failed rewrite warns once', events());
		fs.rmdir(usage_file);
		monitor.flush_usage(d);
		data = json(fs.readfile(usage_file));
		check(data.days[yesterday]?.tx == 500 && data.days['2026-01-01']?.tx == 11,
			'heatmap-persist: the next attempt after a failure persists the merged history', sprintf('%.J', data));
		check(count(events(), 'FS_FAILED') == 1, 'heatmap-persist: the retry is silent again', events());
		check(length(fs.glob(`${usage_dir}/usage.json.tmp.*`) ?? []) == 0,
			'heatmap-persist: the retried write leaves no residue');
	}
	else {
		// heatmap-corrupt: an unparsable file is an empty history with exactly one warn,
		// never deleted; the next successful write overwrites it (docs §5).
		sys.mkdir_p(usage_dir);
		check(write(usage_file, 'not json at all'), 'heatmap-corrupt: the corrupt seed is in place');
		usage.sample(d.usage, { tx: 1000, rx: 2000, now: noon_before(1), elapsed: 0, cap: 60,
			state: 'running', proxy_ok: true });
		usage.sample(d.usage, { tx: 1100, rx: 2100, now: noon_before(1) + 30, elapsed: 30, cap: 60,
			state: 'running', proxy_ok: true });
		monitor.flush_usage(d);
		check(count(events(), 'FS_FAILED') == 1 && count(events(), usage_file) == 1,
			'heatmap-corrupt: the corrupt file warns exactly once', events());
		let data = json(fs.readfile(usage_file));
		check(data.schema == 1 && data.days[date_of(noon_before(1))]?.tx == 100,
			'heatmap-corrupt: the flush overwrites the corrupt file with the live history', sprintf('%.J', data));
		usage.sample(d.usage, { tx: 1200, rx: 2200, now: noon_before(1) + 60, elapsed: 30, cap: 60,
			state: 'running', proxy_ok: true });
		monitor.flush_usage(d);
		check(count(events(), 'FS_FAILED') == 1,
			'heatmap-corrupt: the cached empty history does not warn again', events());
		check(json(fs.readfile(usage_file)).days[date_of(noon_before(1))]?.tx == 200,
			'heatmap-corrupt: accumulation continues on the empty history', sprintf('%.J', data));
	}
	no_external_children(d);
}
else if (index([ 'immediate-proxy', 'immediate-xray', 'immediate-retry' ], scenario) >= 0) {
	let d = opts.daemon;
	d.snapshot.probe.fail_threshold = 1;
	d.snapshot.probe.recover_threshold = 2;
	d.snapshot.dns.allow_china_fallback = true;
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', ever_healthy: true };
	if (scenario == 'immediate-xray') {
		d.machine.xray_down_count = 1;
		let path = `${opts.ctx.root}/proc/net/tcp`;
		let lines = split(fs.readfile(path), '\n');
		check(write(path, join('\n', filter(lines, line => index(line, '7968') < 0))),
			'immediate-xray removes listener');
	}
	if (scenario == 'immediate-retry') {
		d.machine.state = 'degraded';
		d.machine.dns_tier = 'T3';
		d.machine.last_t2_retry = time() - 301;
	}
	let automatic_rounds = 0;
	d.interval = uloop.interval(10000, () => {
		automatic_rounds++;
		monitor.tick(d);
	});
	let started = clock(true);
	monitor.tick(d);
	// Five seconds is shorter than the normal 10 s degraded/failsafe cadence. The extra round
	// comes from a one-shot timer: the 10 s period itself must never be shortened.
	let log_path = `${opts.ctx.root}${C.RUN_DIR}/calls.log`;
	// Count DNS-tier probes separately from T16.12's immediate node resolution.
	let dns_calls = () => count(fs.readfile(log_path), `-t 5 ${d.snapshot.dns.dns_probe_domain}`);
	let expected_dns = scenario == 'immediate-retry' ? 2 : 1;
	for (let i = 0; i < 50 && (dns_calls() < expected_dns || d.busy || d.immediate != null); i++)
		uloop.run(100);
	let ended = clock(true);
	let elapsed = ended[0] - started[0] + (ended[1] - started[1]) / 1000000000;
	let calls = fs.readfile(log_path) ?? '';
	check(automatic_rounds == 0 && elapsed < 5 && dns_calls() == expected_dns,
		`${scenario}: T2 transition probes DNS within 5 seconds`,
		sprintf('automatic=%d DNS=%d elapsed=%.3f', automatic_rounds, count(calls, 'resolveip '), elapsed));
	if (scenario != 'immediate-retry') {
		check(d.machine.dns_tier == 'T2' && d.machine.dns_fail_count == 1,
			`${scenario}: immediate DNS failure counts once in T2`, sprintf('%.J', d.machine));
		let samples = count(calls, 'resolveip ');
		uloop.run(250);
		check(automatic_rounds == 0 && count(fs.readfile(log_path), 'resolveip ') == samples,
			`${scenario}: ordinary T2 round does not schedule another immediate round`);
		monitor.tick(d);
		while (d.busy)
			uloop.run(100);
		check(d.machine.dns_tier == 'T3' && dns_calls() == 2,
			`${scenario}: two consecutive DNS failures enter T3`, sprintf('%.J', d.machine));
	}
	else {
		check(d.machine.dns_tier == 'T3' && !d.machine.t2_retry_pending,
			'immediate-retry: failed fresh T2 sample returns to T3');
	}
	let samples = count(fs.readfile(log_path), 'resolveip ');
	monitor.tick(d);
	while (d.busy)
		uloop.run(100);
	uloop.run(250);
	check(automatic_rounds == 0 && count(fs.readfile(log_path), 'resolveip ') == samples + 1,
		`${scenario}: ordinary T3 round does not schedule another immediate round`);
	d.interval.cancel();
	no_external_children(d);
}
else if (scenario == 'immediate-locked') {
	// T8.19 review: the immediate T2 round is a one-shot timer. If a user command holds the
	// lock when it fires, the round is skipped once (one BUSY event) and the normal period
	// continues; it must not be retried continuously.
	let d = opts.daemon;
	d.snapshot.probe.fail_threshold = 1;
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', ever_healthy: true };
	let automatic_rounds = 0;
	d.interval = uloop.interval(10000, () => { automatic_rounds++; monitor.tick(d); });
	monitor.tick(d);
	while (d.busy)
		uloop.run(100);
	check(d.machine.dns_tier == 'T2', 'immediate-locked: proxy failure enters T2', sprintf('%.J', d.machine));
	let held = sys.lock(`${replace(opts.ctx.root, /\/$/, '')}${C.LOCK_FILE}`);
	check(held != null, 'immediate-locked: test holds the global lock');
	let events_path = `${replace(opts.ctx.root, /\/$/, '')}${C.RUN_DIR}/events.jsonl`;
	let busy_before = count(fs.readfile(events_path), '"BUSY"');
	// Wait for the one-shot round itself (a loaded host can fire it after 300 ms), then
	// keep running long enough that a retry loop would add a second BUSY.
	for (let i = 0; i < 30 && count(fs.readfile(events_path), '"BUSY"') == busy_before; i++)
		uloop.run(100);
	uloop.run(300);
	let busy_after = count(fs.readfile(events_path), '"BUSY"');
	check(automatic_rounds == 0 && busy_after - busy_before == 1 && d.immediate == null,
		'immediate-locked: a skipped immediate round is tried once, not retried',
		sprintf('automatic=%d BUSY events=%d', automatic_rounds, busy_after - busy_before));
	held?.close();
	d.interval.cancel();
	no_external_children(d);
}
else {
	bad('unknown monitor integration scenario', scenario);
}

uloop.done();
print(`monitor-driver: ${pass} passed, ${fail} failed\n`);
exit(fail ? 1 : 0);
