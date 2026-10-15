'use strict';

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as state_file from 'aetherproxy.state';
import * as pipeline from 'aetherproxy.pipeline';
import * as apply from 'aetherproxy.apply';
import * as supervise from 'aetherproxy.supervise';
import * as net from 'aetherproxy.net';

let initial_state, interval_ms, next;

function system_path(ctx, path) {
	let root = ctx.root ?? '';
	return root == '' ? path : replace(root, /\/$/, '') + path;
};

function run_dir(daemon) {
	return system_path(daemon.ctx, daemon.ctx.run_dir ?? C.RUN_DIR);
};

function current_dir(daemon) {
	return `${run_dir(daemon)}/${C.DAEMON_CURRENT_DIR}`;
};

function command(ctx, name) {
	return ctx.bin_dir ? `${ctx.bin_dir}/${name}` : name;
};

function run(ctx, name, args, timeout) {
	return sys.run([ command(ctx, name), ...args ], { timeout: timeout ?? 10 });
};

function port_listening(daemon, port) {
	for (let file in [ C.PROC_NET_TCP, C.PROC_NET_TCP6 ])
		if (net.tcp_listening(fs.readfile(system_path(daemon.ctx, file)), port))
			return true;
	return false;
};

function monotonic_ms() {
	let value = clock(true);
	return value == null ? null : value[0] * 1000 + value[1] / 1000000;
};

function log_failure(daemon, step, detail) {
	log.set_run_dir(run_dir(daemon));
	log.event('error', 'START_FAILED', { step: `monitor:${step}`, detail });
};

function probe_proxy(daemon, snapshot) {
	let timeout = min(max(+(snapshot.probe.timeout ?? 10), 1), 10);
	let args = [
		'--silent', '--output', C.DEV_NULL, '--write-out', '%{http_code} %{time_total}',
		'--max-time', `${timeout}`, '-x', `http://${C.HTTP_LISTEN}:${C.HTTP_PORT}`, snapshot.probe.url
	];
	let result = run(daemon.ctx, 'curl', args, timeout);
	let parsed = match(trim(result.stdout ?? ''), /^([0-9]{3})[[:space:]]+([0-9.]+)/);
	let latency = parsed ? int(+parsed[2] * 1000 + 0.5) : null;
	return {
		ok: result.code == 0 && parsed != null && +parsed[1] == +snapshot.probe.expect_code,
		latency_ms: latency
	};
};

function probe_dns(daemon, snapshot) {
	let result = run(daemon.ctx, 'resolveip', [ '-4', '-t', '5', snapshot.dns.dns_probe_domain ], 5);
	if (result.code != 0)
		return false;
	for (let address in split(trim(result.stdout ?? ''), /[[:space:]]+/))
		if (net.ipv4(address) != null)
			return true;
	return false;
};

function observe(daemon) {
	let table = apply.nft_table_exists(daemon.ctx);
	let machine = daemon.machine;
	let xray_listening = port_listening(daemon, C.TPROXY_PORT);
	let chinadns_listening = port_listening(daemon, C.CHINADNS_PORT);
	let proxy = xray_listening ? probe_proxy(daemon, daemon.snapshot) : null;
	let dns = !machine.dns_failsafe && (machine.dns_tier == 'T2' || machine.dns_tier == 'T3')
		? probe_dns(daemon, daemon.snapshot) : null;
	// An inspection error counts as "present" for this round (04, failure semantics): rebuilding
	// would fail the same way and could export empty sets.
	if (!table.ok)
		log_failure(daemon, 'nft_table_exists', table.detail);
	return {
		now: time(),
		table_present: table.ok ? table.exists : true,
		xray_listening,
		chinadns_listening,
		proxy_ok: proxy?.ok ?? null,
		proxy_latency_ms: proxy?.latency_ms ?? null,
		dns_ok: dns
	};
};

function supervisor_for(daemon, key, name, argv) {
	let child = supervise.create({
		name,
		argv,
		run_dir: run_dir(daemon),
		backoff: [ 5, 10, 30, 60 ],
		stable_secs: 300
	});
	daemon.children[key] = child;
	child.start();
	return child;
};

function restart_child(daemon, key, name, argv, done) {
	let old = daemon.children[key];
	function start_again() {
		let child = supervisor_for(daemon, key, name, argv);
		if (child.pid() == null)
			done(`cannot start ${name}`);
		else
			done(null);
	};
	if (old != null)
		old.stop(start_again);
	else
		start_again();
};

function runtime_for(daemon, tier, node_ip, restored) {
	return {
		node_ip: node_ip ?? daemon.machine.node_ip ?? null,
		dns_tier: tier ?? daemon.machine.dns_tier,
		restored: restored ?? {}
	};
};

function render(daemon, runtime) {
	return pipeline.build({ ...daemon.opts, runtime });
};

function load_restored_sets(daemon) {
	let table = apply.nft_table_exists(daemon.ctx);
	if (!table.ok)
		return { ok: false, detail: table.detail };
	if (!table.exists)
		return { ok: true, sets: { gfw4: [], udirect4: [], uproxy4: [] } };
	return apply.sets_export(daemon.ctx);
};

function action_nft_reload(daemon, machine) {
	let restored = load_restored_sets(daemon);
	if (!restored.ok)
		return { ok: false, detail: restored.detail };
	let built = render(daemon, runtime_for(daemon, machine.dns_tier, machine.node_ip, restored.sets));
	if (!built.ok)
		return { ok: false, detail: built.detail };
	let path = `${current_dir(daemon)}/${C.ARTIFACT_FILES.nft}`;
	if (!sys.write_atomic(path, built.artifacts.nft))
		return { ok: false, detail: `cannot write ${path}: ${sys.error()}` };
	return apply.nft_load(daemon.ctx, path);
};

function action_set_tier(daemon, tier, done) {
	let built = render(daemon, runtime_for(daemon, tier, daemon.machine.node_ip, {}));
	if (!built.ok) {
		done(built.detail);
		return;
	}
	let path = `${current_dir(daemon)}/${C.ARTIFACT_FILES.chinadns}`;
	if (!sys.write_atomic(path, built.artifacts.chinadns)) {
		done(`cannot write ${path}: ${sys.error()}`);
		return;
	}
	let bin = daemon.state.components?.[C.CHINADNS_COMPONENT]?.path ??
		(daemon.ctx.bin_dir ? `${daemon.ctx.bin_dir}/${C.CHINADNS_COMPONENT}` : C.CHINADNS_COMPONENT);
	restart_child(daemon, 'dns', C.CHINADNS_COMPONENT,
		[ bin, '-C', path ], error => {
			if (error != null) {
				done(error);
				return;
			}
			let hup = apply.dnsmasq_hup(daemon.ctx);
			done(hup.ok ? null : hup.detail);
		});
};

function update_node_ip(daemon, machine, done) {
	let node_id = daemon.snapshot.main.node;
	let address = daemon.snapshot.nodes?.[node_id]?.address;
	let resolved = apply.resolve_node(daemon.ctx, address);
	if (!resolved.ok || resolved.ip == machine.node_ip) {
		done(null);
		return;
	}
	let restored = load_restored_sets(daemon);
	if (!restored.ok) {
		done(restored.detail);
		return;
	}
	let runtime = runtime_for(daemon, machine.dns_tier, resolved.ip, restored.sets);
	let built = render(daemon, runtime);
	if (!built.ok) {
		done(built.detail);
		return;
	}
	let nft_path = `${current_dir(daemon)}/${C.ARTIFACT_FILES.nft}`;
	let xray_path = `${current_dir(daemon)}/${C.ARTIFACT_FILES.xray}`;
	if (!sys.write_atomic(nft_path, built.artifacts.nft) || !sys.write_atomic(xray_path, built.artifacts.xray)) {
		done(`cannot stage node IP update: ${sys.error()}`);
		return;
	}
	let binary = daemon.state.components?.[C.XRAY_COMPONENT]?.path ??
		(daemon.ctx.bin_dir ? `${daemon.ctx.bin_dir}/${C.XRAY_COMPONENT}` : C.XRAY_COMPONENT);
	let test = sys.run([ binary, 'run', '-test', '-c', xray_path ], { timeout: 10, quiet: true });
	if (test.code != 0) {
		done(`xray run -test failed (${test.code}): ${test.stderr}`);
		return;
	}
	let loaded = apply.nft_load(daemon.ctx, nft_path);
	if (!loaded.ok) {
		done(loaded.detail);
		return;
	}
	let old_ip = machine.node_ip;
	restart_child(daemon, 'xray', C.XRAY_COMPONENT,
		[ binary, 'run', '-c', xray_path ], error => {
			if (error != null) {
				done(error);
				return;
			}
			machine.node_ip = resolved.ip;
			daemon.state.node_ip = resolved.ip;
			log.set_run_dir(run_dir(daemon));
			log.event('notice', 'NODE_IP_CHANGED', { node: node_id, old: old_ip ?? '', new: resolved.ip });
			done(null);
		});
};

function run_action(daemon, machine, name, done) {
	if (name == 'nft_reload') {
		let r = action_nft_reload(daemon, machine);
		done(r.ok ? null : r.detail);
		return;
	}
	if (name == 'nft_flush_prerouting') {
		let r = apply.nft_flush_prerouting(daemon.ctx);
		done(r.ok ? null : r.detail);
		return;
	}
	if (name == 'dnsmasq_remove') {
		let r = apply.dnsmasq_remove(daemon.ctx);
		done(r.ok ? null : r.detail);
		return;
	}
	if (name == 'dnsmasq_install') {
		let r = render(daemon, runtime_for(daemon, machine.dns_tier, machine.node_ip, {}));
		if (!r.ok) {
			done(r.detail);
			return;
		}
		let installed = apply.dnsmasq_install(daemon.ctx, r.artifacts.dnsmasq);
		done(installed.ok ? null : installed.detail);
		return;
	}
	if (match(name, /^set_tier:/)) {
		action_set_tier(daemon, substr(name, length('set_tier:')), done);
		return;
	}
	if (name == 'refresh_node_ip') {
		update_node_ip(daemon, machine, done);
		return;
	}
	done(`unknown monitor action ${name}`);
};

function run_actions(daemon, machine, actions, index, done) {
	if (index >= length(actions)) {
		done(null);
		return;
	}
	run_action(daemon, machine, actions[index], error => {
		if (error != null) {
			done(`${actions[index]}: ${error}`);
			return;
		}
		run_actions(daemon, machine, actions, index + 1, done);
	});
};

function persist_state(daemon, machine) {
	let updated = {
		...daemon.state,
		state: machine.state,
		dns_tier: machine.dns_tier,
		dns_failsafe: machine.dns_failsafe,
		node_ip: machine.node_ip,
		since: machine.since,
		last_probe: machine.last_probe,
		monitor: machine
	};
	if (!state_file.write(run_dir(daemon), updated)) {
		log_failure(daemon, 'state_write', state_file.error());
		return false;
	}
	daemon.state = updated;
	return true;
};

function finish_tick(daemon, machine, transition, lock, started, error) {
	if (error == null) {
		daemon.machine = machine;
		for (let item in transition.events)
			log.event(item.level, item.code, item.args);
		persist_state(daemon, machine);
	}
	else
		log_failure(daemon, 'actions', error);
	let elapsed = monotonic_ms();
	if (elapsed != null && elapsed - started > 30000)
		daemon.skip_next = true;
	if (lock != null) {
		if (!lock.lock('u'))
			log_failure(daemon, 'unlock', fs.error() ?? 'unknown error');
		lock.close();
	}
	daemon.busy = false;
	if (daemon.interval != null)
		daemon.interval.set(interval_ms(daemon.machine));
};

function tick(daemon) {
	if (daemon.busy)
		return;
	if (daemon.skip_next) {
		daemon.skip_next = false;
		return;
	}
	let started = monotonic_ms();
	if (started == null)
		return;
	let lock_path = system_path(daemon.ctx, C.LOCK_FILE);
	let lock = sys.lock(lock_path);
	if (lock == null) {
		log.set_run_dir(run_dir(daemon));
		log.event('warn', 'BUSY', { holder: 'monitor' });
		return;
	}
	daemon.busy = true;
	let obs = observe(daemon);
	let transition = next(daemon.machine, obs, daemon.snapshot);
	run_actions(daemon, transition.state, transition.actions, 0,
		error => finish_tick(daemon, transition.state, transition, lock, started, error));
};

function create_daemon(daemon) {
	return {
		...daemon,
		machine: initial_state(daemon.state, time()),
		busy: false,
		skip_next: false,
		interval: null
	};
};

initial_state = (service, now) => {
	return {
		state: service?.state ?? 'starting',
		dns_tier: service?.dns_tier ?? 'T2',
		dns_failsafe: service?.dns_failsafe == true,
		xray_down_count: 0,
		xray_down_reported: false,
		chinadns_down_count: 0,
		chinadns_down_reported: service?.dns_failsafe == true,
		proxy_fail_count: 0,
		proxy_ok_count: 0,
		dns_fail_count: 0,
		t3_since: null,
		last_t2_retry: null,
		t2_retry_pending: false,
		last_node_refresh: now,
		node_ip: service?.node_ip ?? null,
		last_probe: service?.last_probe ?? null,
		since: service?.since ?? now
	};
};

// Pure transition function. Observations are one point-in-time sample; actions remain
// ordered so the executor can apply fail-open and DNS changes without hidden side effects.
next = (state, obs, cfg) => {
	let old = state ?? {};
	let previous_service_state = old.state ?? 'starting';
	let now = obs.now;
	let out = {
		state: old.state ?? 'starting',
		dns_tier: old.dns_tier ?? 'T2',
		dns_failsafe: old.dns_failsafe == true,
		xray_down_count: old.xray_down_count ?? 0,
		xray_down_reported: old.xray_down_reported == true,
		chinadns_down_count: old.chinadns_down_count ?? 0,
		chinadns_down_reported: old.chinadns_down_reported == true,
		proxy_fail_count: old.proxy_fail_count ?? 0,
		proxy_ok_count: old.proxy_ok_count ?? 0,
		dns_fail_count: old.dns_fail_count ?? 0,
		t3_since: old.t3_since ?? null,
		last_t2_retry: old.last_t2_retry ?? null,
		t2_retry_pending: old.t2_retry_pending == true,
		last_node_refresh: old.last_node_refresh ?? now,
		node_ip: old.node_ip ?? null,
		last_probe: old.last_probe ?? null,
		since: old.since ?? now
	};
	let actions = [], events = [];

	function action(name) {
		push(actions, name);
	};

	function event(level, code, args) {
		push(events, { level, code, args: args ?? {} });
	};

	function tier(to, reason) {
		let from = out.dns_tier;
		if (from == to)
			return;
		out.dns_tier = to;
		action(`set_tier:${to}`);
		event(to == 'T1' ? 'notice' : 'warn', 'DNS_TIER_CHANGED', { from, to, reason });
		if (to == 'T3') {
			out.dns_fail_count = 0;
			out.t3_since = now;
			out.last_t2_retry = now;
			out.t2_retry_pending = false;
		}
		else if (to == 'T2') {
			out.dns_fail_count = 0;
			out.t3_since = null;
		}
		else {
			out.dns_fail_count = 0;
			out.t3_since = null;
			out.t2_retry_pending = false;
		}
	};

	// 1. Restore a missing table first; do not recreate interception while fail-open is active.
	if (obs.table_present == false && out.state != 'failsafe') {
		action('nft_reload');
		event('warn', 'NFT_TABLE_RESTORED', {});
	}

	// 2. A single missing sample is tolerated; only a crossing to round two emits a down event.
	if (obs.xray_listening == false) {
		out.xray_down_count = min(out.xray_down_count + 1, C.MONITOR_FAILSAFE_ROUNDS);
		if (out.xray_down_count >= C.MONITOR_FAILSAFE_ROUNDS && !out.xray_down_reported) {
			out.xray_down_reported = true;
			if (cfg.main.fail_open == true) {
				out.state = 'failsafe';
				action('nft_flush_prerouting');
				tier('T2', 'xray_down');
				event('error', 'XRAY_DOWN_FAILOPEN', { port: C.TPROXY_PORT });
			}
			else {
				if (out.state != 'failsafe')
					out.state = 'degraded';
				tier('T2', 'xray_down');
				event('error', 'XRAY_DOWN', { port: C.TPROXY_PORT });
			}
		}
	}
	else if (obs.xray_listening == true) {
		out.xray_down_count = 0;
		if (out.xray_down_reported) {
			out.xray_down_reported = false;
			out.state = 'degraded';
			action('nft_reload');
			event('notice', 'XRAY_RECOVERED', { port: C.TPROXY_PORT });
		}
	}

	// 3. DNS handoff is independent from the proxy health state and has its own two-round guard.
	if (obs.chinadns_listening == false) {
		out.chinadns_down_count = min(out.chinadns_down_count + 1, C.MONITOR_FAILSAFE_ROUNDS);
		if (out.chinadns_down_count >= C.MONITOR_FAILSAFE_ROUNDS && !out.dns_failsafe) {
			out.dns_failsafe = true;
			out.chinadns_down_reported = true;
			action('dnsmasq_remove');
			event('error', 'DNS_DOWN_FAILSAFE', {});
		}
	}
	else if (obs.chinadns_listening == true) {
		out.chinadns_down_count = 0;
		if (out.dns_failsafe) {
			out.dns_failsafe = false;
			out.chinadns_down_reported = false;
			action('dnsmasq_install');
			event('notice', 'DNS_RECOVERED', {});
		}
	}

	// 4. Proxy health hysteresis. `null` means Xray is unavailable so no HTTP probe was made.
	let fail_threshold = max(+(cfg.probe.fail_threshold ?? 1), 1);
	let recover_threshold = max(+(cfg.probe.recover_threshold ?? 1), 1);
	if (obs.proxy_ok === true) {
		out.proxy_ok_count = min(out.proxy_ok_count + 1, recover_threshold);
		out.proxy_fail_count = 0;
		out.last_probe = { ok: true, latency_ms: obs.proxy_latency_ms ?? null, at: now };
		if (out.proxy_ok_count >= recover_threshold && out.state != 'running' && out.state != 'failsafe') {
			out.state = 'running';
			out.since = now;
			tier('T1', 'proxy_healthy');
			event('notice', 'PROXY_HEALTHY', { latency_ms: obs.proxy_latency_ms ?? null, fails: 0 });
		}
	}
	else if (obs.proxy_ok === false) {
		out.proxy_fail_count = min(out.proxy_fail_count + 1, fail_threshold);
		out.proxy_ok_count = 0;
		out.last_probe = { ok: false, latency_ms: obs.proxy_latency_ms ?? null, at: now };
		if (out.proxy_fail_count >= fail_threshold && out.state != 'degraded' && out.state != 'failsafe') {
			out.state = 'degraded';
			out.since = now;
			tier('T2', 'proxy_unhealthy');
			event('warn', 'PROXY_UNHEALTHY', { latency_ms: obs.proxy_latency_ms ?? null, fails: out.proxy_fail_count });
		}
	}

	// 5. DNS checks run only while a DNS tier is in direct mode. A T3 retry probes T2 on
	// the following observation; one failed T2 retry returns immediately to T3 per docs/03.
	if (!out.dns_failsafe && (out.dns_tier == 'T2' || out.dns_tier == 'T3')) {
		if (out.dns_tier == 'T2' && out.t2_retry_pending) {
			if (obs.dns_ok === true) {
				out.t2_retry_pending = false;
				out.dns_fail_count = 0;
			}
			else if (obs.dns_ok === false && cfg.dns.allow_china_fallback == true) {
				tier('T3', 't2_retry_failed');
			}
		}
		else if (out.dns_tier == 'T2' && obs.dns_ok === false) {
			out.dns_fail_count = min(out.dns_fail_count + 1, C.MONITOR_DNS_FAILURES);
			if (out.dns_fail_count >= C.MONITOR_DNS_FAILURES && cfg.dns.allow_china_fallback == true)
				tier('T3', 'dns_probe_failed');
		}
		else if (out.dns_tier == 'T2' && obs.dns_ok === true) {
			out.dns_fail_count = 0;
		}
		else if (out.dns_tier == 'T3' && obs.now - (out.last_t2_retry ?? out.t3_since ?? now) >= C.MONITOR_T3_RETRY_SECS) {
			out.last_t2_retry = now;
			out.t2_retry_pending = true;
			tier('T2', 'periodic_retry');
			out.last_t2_retry = now;
			out.t2_retry_pending = true;
		}
	}

	// 6. Domain-based nodes are refreshed at most once every ten minutes.
	if (out.last_node_refresh == null)
		out.last_node_refresh = now;
	else if (obs.now - out.last_node_refresh >= C.MONITOR_NODE_REFRESH_SECS) {
		out.last_node_refresh = now;
		action('refresh_node_ip');
	}
	if (out.state != previous_service_state)
		out.since = now;

	return { state: out, actions, events };
};

interval_ms = machine => {
	return machine?.state == 'running' ? C.MONITOR_RUNNING_INTERVAL_MS : C.MONITOR_OTHER_INTERVAL_MS;
};

export { create_daemon, initial_state, interval_ms, next, tick };
