'use strict';
// Exercise monitor side effects against isolated fixtures (docs/04 recovery and docs/07 probes).

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as sys from 'aetherproxy.sys';
import * as uci from 'uci';
import * as config from 'aetherproxy.config';
import * as pipeline from 'aetherproxy.pipeline';
import * as monitor from 'aetherproxy.monitor';
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
	let cfg = config.load(uci.cursor(confdir));
	if (!cfg.ok)
		return { error: `config invalid: ${sprintf('%.J', cfg.errors)}` };
	let built = pipeline.build({ ...opts, runtime: { node_ip: '203.0.113.20', dns_tier: 'T2', restored: {} } });
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
	return { opts, ctx, snapshot: cfg.snapshot, state: service, current };
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

function base_daemon(args, initial) {
	let s = settings(args[1], args[2], args[3], args[4], args[5], args[6]);
	if (s.error)
		return s;
	let d = monitor.create_daemon({
		ctx: s.ctx, opts: s.opts, snapshot: s.snapshot,
		children: { dns: null, xray: null }, state: s.state
	});
	d.machine = { ...d.machine, ...initial };
	return { ...s, daemon: d };
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

if (scenario == 'proxy-tier') {
	let d = opts.daemon;
	let state = config.load(uci.cursor(opts.opts.confdir)).snapshot;
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
	check(index(cd, 'trust-dns tcp://8.8.8.8,tcp://1.1.1.1') >= 0, 'T2 render has direct upstreams');
	no_external_children(d);
}
else if (scenario == 'xray-failsafe') {
	let d = opts.daemon;
	d.machine = { ...d.machine, state: 'running', dns_tier: 'T1', xray_down_count: 1, xray_down_reported: false };
	let before = fs.readfile(`${replace(opts.ctx.root, /\/$/, '')}/proc/net/tcp`) ?? '';
	write(`${replace(opts.ctx.root, /\/$/, '')}/proc/net/tcp`, replace(before, /.*7968.*\n/g, ''));
	monitor.tick(d);
	while (d.busy) uloop.run(100);
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
	let expected_dns = scenario == 'immediate-retry' ? 2 : 1;
	let log_path = `${opts.ctx.root}${C.RUN_DIR}/calls.log`;
	for (let i = 0; i < 50 && (count(fs.readfile(log_path), 'resolveip ') < expected_dns || d.busy || d.immediate != null); i++)
		uloop.run(100);
	let ended = clock(true);
	let elapsed = ended[0] - started[0] + (ended[1] - started[1]) / 1000000000;
	let calls = fs.readfile(log_path) ?? '';
	check(automatic_rounds == 0 && elapsed < 5 && count(calls, 'resolveip ') == expected_dns,
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
		check(d.machine.dns_tier == 'T3' && count(fs.readfile(log_path), 'resolveip ') == 2,
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
