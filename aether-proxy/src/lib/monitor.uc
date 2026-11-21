'use strict';
// Observe service health, compute transitions and execute ordered recovery actions.
// Design: docs/04「monitor 循环」 and docs/03「DNS 级别（trust 组上游）」.
// Live usage publication: docs/design/b25-quota-heatmap-20261116.md §2.1 (T16.8).

import * as fs from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as state_file from 'aetherproxy.state';
import * as pipeline from 'aetherproxy.pipeline';
import * as apply from 'aetherproxy.apply';
import * as supervise from 'aetherproxy.supervise';
import * as net from 'aetherproxy.net';
import * as node_failover from 'aetherproxy.node_failover';
import * as counters from 'aetherproxy.counters';
import * as usage from 'aetherproxy.usage';
import * as xray_ready from 'aetherproxy.xray_ready';

// tick is declared up front: finish_tick schedules it before its definition (ucode does not hoist).
let initial_state, interval_ms, next, tick, node_reachable;

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

function usage_path(daemon) {
	return system_path(daemon.ctx, C.USAGE_FILE);
};

function command(ctx, name) {
	return ctx.bin_dir ? `${ctx.bin_dir}/${name}` : name;
};

// Probes fail by design while the node or a DNS tier is down; the monitor reports that
// through its own events, so a failing probe is not also a CMD_FAILED error.
function run(ctx, name, args, timeout, quiet) {
	return sys.run([ command(ctx, name), ...args ], { timeout: timeout ?? 10, quiet: quiet ?? false });
};

function port_listening(daemon, port) {
	// Xray's dual-stack listener may appear only in tcp6 even for IPv4 traffic;
	// checking tcp alone would falsely trigger fail-open (docs/04「真机验证（M2 验收，2026-10-15）」).
	for (let file in [ C.PROC_NET_TCP, C.PROC_NET_TCP6 ])
		if (net.tcp_listening(fs.readfile(system_path(daemon.ctx, file)), port))
			return true;
	return false;
};

function monotonic_ms() {
	let value = clock(true);
	return value == null ? null : value[0] * 1000 + value[1] / 1000000;
};

// A PID proves fork succeeded, not that Xray can serve traffic. Reuse startup's bounded
// readiness check for deliberate restarts, before allowing a new-route monitor sample.
function wait_xray_port(ctx, on_signal) {
	let started = monotonic_ms();
	if (started == null)
		return false;
	let deadline = started + C.DAEMON_PORT_WAIT_SECS * 1000;
	while (monotonic_ms() < deadline) {
		if (on_signal != null && on_signal())
			return false;
		if (port_listening({ ctx }, C.TPROXY_PORT))
			return true;
		uloop.run(C.DAEMON_POLL_MS);
	}
	return port_listening({ ctx }, C.TPROXY_PORT);
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
	let result = run(daemon.ctx, 'curl', args, timeout, true);
	let parsed = match(trim(result.stdout ?? ''), /^([0-9]{3})[[:space:]]+([0-9.]+)/);
	let latency = parsed ? int(+parsed[2] * 1000 + 0.5) : null;
	return {
		ok: result.code == 0 && parsed != null && +parsed[1] == +snapshot.probe.expect_code,
		latency_ms: latency
	};
};

function probe_dns(daemon, snapshot) {
	let result = run(daemon.ctx, 'resolveip', [ '-4', '-t', '5', snapshot.dns.dns_probe_domain ], 5, true);
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
	let dns = daemon.snapshot.dns.direct_dns_enabled && !machine.dns_failsafe &&
		(machine.dns_tier == 'T2' || machine.dns_tier == 'T3')
		? probe_dns(daemon, daemon.snapshot) : null;
	// An inspection error counts as "present" for this round (04, failure semantics): rebuilding
	// would fail the same way and could export empty sets.
	if (!table.ok)
		log_failure(daemon, 'nft_table_exists', table.detail);
	let observation = {
		now: time(),
		table_present: table.ok ? table.exists : true,
		xray_listening,
		chinadns_listening,
		node_id: daemon.state?.node_id,
		node_tcp_ip: daemon.state?.node_ip,
		node_reload: daemon.state?.last_reload,
		node_tcp_ok: daemon.state?.node_ip != null &&
			node_failover.participates(daemon.snapshot, daemon.state.node_id)
			? node_reachable(daemon.state.node_ip, daemon.snapshot.nodes[daemon.state.node_id].port, daemon.node_probe_socket) : null,
		proxy_ok: proxy?.ok ?? null,
		proxy_latency_ms: proxy?.latency_ms ?? null,
		dns_ok: dns
	};
	let dns_reason = dns == null ? 'proxy_healthy' : (dns ? 'healthy' : 'unhealthy');
	if (!daemon.snapshot.dns.direct_dns_enabled)
		dns_reason = 'disabled';
	else if (machine.dns_failsafe)
		dns_reason = 'failsafe';
	log.debug('monitor observation', {
		...observation,
		proxy_reason: proxy == null ? 'not_running' : (proxy.ok ? 'healthy' : 'unhealthy'),
		dns_reason
	});
	return observation;
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
		degraded_mode: daemon.state.degraded_mode ?? null,
		restored: restored ?? {}
	};
};

function render(daemon, runtime) {
	// Recovery is not a config apply: disk may already contain an unvalidated next generation.
	// Keep data, paths and the WAN observation paired with the running snapshot.
	if (daemon.applied_context == null)
		return { ok: false, detail: 'missing applied render context' };
	return pipeline.render(daemon.applied_context, runtime);
};

function load_restored_sets(daemon) {
	let table = apply.nft_table_exists(daemon.ctx);
	if (!table.ok)
		return { ok: false, detail: table.detail };
	if (!table.exists)
		return { ...apply.sets_load(daemon.ctx), from_save: true };
	return apply.sets_export(daemon.ctx);
};

// docs/04「动态集合的导出与恢复」: sets.save is removed only after nft accepts the rebuilt
// table, so a failed rebuild stays retryable. Every rebuild path goes through here.
function load_nft(daemon, path, restored) {
	let loaded = apply.nft_load(daemon.ctx, path);
	if (loaded.ok && restored.from_save)
		apply.sets_remove(daemon.ctx);
	return loaded;
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
	return load_nft(daemon, path, restored);
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
			// Clear dnsmasq's cache too: polluted fallback answers must not outlive a tier change
			// after chinadns-ng has restarted (docs/03「DNS 级别（trust 组上游）」).
			let hup = apply.dnsmasq_hup(daemon.ctx);
			done(hup.ok ? null : hup.detail);
		});
};

// poll() returns an entry even on timeout, when SO_ERROR can still be zero.
export function connect_poll_ready(polled, sock) {
	let revents = polled?.[0]?.[1] ?? 0;
	return revents != 0 && sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0;
};

// A nonblocking connect tests only TCP reachability, not the proxy protocol. Waiting
// for nc's stdin/peer EOF can misclassify a connected but silent node as unreachable.
node_reachable = function(ip, port, socket_api) {
	socket_api ??= socket;
	let sock = socket_api.create(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);
	if (sock == null)
		return false;
	let connected = sock.connect(ip, port);
	if (!connected) {
		let code = socket_api.error(true);
		if (code == 115 || code == 114) {
			let polled = socket_api.poll(C.NODE_PROBE_TIMEOUT_SECS * 1000,
				[ sock, socket.POLLOUT | socket.POLLERR | socket.POLLHUP | socket.POLLNVAL, 1 ]);
			connected = connect_poll_ready(polled, sock);
		}
	}
	sock.close();
	return connected;
};

// Atomic bounded rewrites avoid partial JSON lines; both files live only under run_dir.
function write_node_probe(daemon, record) {
	let path = `${run_dir(daemon)}/${C.NODE_PROBE_LOG}`;
	let previous = '', detail = null;
	if (fs.stat(path) != null) {
		previous = fs.readfile(path);
		if (previous == null)
			detail = fs.error() ?? 'cannot read probe log';
	}
	else {
		let error = fs.error();
		if (error != null && error != 'No such file or directory')
			detail = error;
	}
	let line = sprintf('%J\n', record);
	if (detail == null && length(previous) + length(line) > C.NODE_PROBE_LOG_MAX) {
		if (!fs.rename(path, path + '.1'))
			detail = fs.error() ?? 'cannot rotate probe log';
		else
			previous = '';
	}
	if (detail == null && !sys.write_atomic(path, previous + line))
		detail = sys.error();
	if (detail != null && !daemon.node_probe_warned) {
		daemon.node_probe_warned = true;
		log.set_run_dir(run_dir(daemon));
		log.event('warn', 'FS_FAILED', { op: 'node-probe', path, detail });
	}
};

function update_node_ip(daemon, machine, done) {
	let node_id = daemon.snapshot.main.node;
	let address = daemon.snapshot.nodes?.[node_id]?.address;
	let before = machine.node_ip, ts = time();
	let resolved = apply.resolve_node(daemon.ctx, address);
	let raw = substr(resolved.raw ?? '', 0, C.NODE_PROBE_RAW_MAX);
	// Same-IP and resolution failures do not probe TCP; null must not imply reachability.
	let reachable = null, action = 'keep';
	// All exits, including staging/restart errors, record exactly one refresh outcome.
	function finish(error) {
		write_node_probe(daemon, {
			ts, address, attempts: resolved.attempts, raw, ip: resolved.ip ?? null,
			source: resolved.source ?? null, elapsed_ms: resolved.elapsed_ms,
			tier: machine.dns_tier, node_ip_before: before, reachable, action
		});
		done(error);
	};
	if (!resolved.ok || resolved.ip == machine.node_ip) {
		if (resolved.ok) {
			machine.node_probe_failures = 0;
			machine.node_probe_retry_at = null;
		}
		finish(null);
		return;
	}
	let port = daemon.snapshot.nodes[node_id].port;
	// Reject stale DNS answers before exporting sets or touching active artifacts.
	reachable = node_reachable(resolved.ip, port);
	if (!reachable) {
		action = 'unreachable';
		machine.node_probe_failures = min(machine.node_probe_failures + 1, length(C.NODE_PROBE_RETRY_SECS));
		machine.node_probe_retry_at = machine.last_node_refresh_attempt +
			C.NODE_PROBE_RETRY_SECS[machine.node_probe_failures - 1];
		log.set_run_dir(run_dir(daemon));
		log.event('warn', 'NODE_IP_UNREACHABLE', {
			node: node_id, address, ip: resolved.ip, port, source: resolved.source, raw
		});
		finish(null);
		return;
	}
	let restored = load_restored_sets(daemon);
	if (!restored.ok) {
		finish(restored.detail);
		return;
	}
	let runtime = runtime_for(daemon, machine.dns_tier, resolved.ip, restored.sets);
	let built = render(daemon, runtime);
	if (!built.ok) {
		finish(built.detail);
		return;
	}
	let nft_path = `${current_dir(daemon)}/${C.ARTIFACT_FILES.nft}`;
	let xray_path = `${current_dir(daemon)}/${C.ARTIFACT_FILES.xray}`;
	if (!sys.write_atomic(nft_path, built.artifacts.nft) || !sys.write_atomic(xray_path, built.artifacts.xray)) {
		finish(`cannot stage node IP update: ${sys.error()}`);
		return;
	}
	let binary = daemon.state.components?.[C.XRAY_COMPONENT]?.path ??
		(daemon.ctx.bin_dir ? `${daemon.ctx.bin_dir}/${C.XRAY_COMPONENT}` : C.XRAY_COMPONENT);
	let test = sys.run([ binary, 'run', '-test', '-c', xray_path ], { timeout: 10, quiet: true });
	if (test.code != 0) {
		finish(`xray run -test failed (${test.code}): ${test.stderr}`);
		return;
	}
	let loaded = load_nft(daemon, nft_path, restored);
	if (!loaded.ok) {
		finish(loaded.detail);
		return;
	}
	let old_ip = machine.node_ip;
	restart_child(daemon, 'xray', C.XRAY_COMPONENT,
		[ binary, 'run', '-c', xray_path ], error => {
			if (error != null) {
				finish(error);
				return;
			}
			// This action already owns busy and the monitor lock, so pumping uloop while
			// waiting cannot observe our own restart as an unrelated Xray outage.
			let ready = xray_ready.published(daemon.ctx, daemon.children.xray);
			if (!ready.ok) {
				finish(ready.detail);
				return;
			}
			action = 'switch';
			machine.node_probe_failures = 0;
			machine.node_probe_retry_at = null;
			machine.node_ip = resolved.ip;
			daemon.state.node_ip = resolved.ip;
			// TCP acceptance alone is insufficient: publish only after Xray is ready.
			if (resolved.source != 'lkg') {
				let saved = apply.update_lkg(daemon.ctx, { [address]: resolved.ip });
				if (!saved.ok)
					log.event('error', 'FS_FAILED', { op: 'update_lkg', path: saved.path, detail: saved.detail });
			}
			log.set_run_dir(run_dir(daemon));
			log.event('notice', 'NODE_IP_CHANGED', {
				node: node_id, old: old_ip ?? '', new: resolved.ip, source: resolved.source, raw
			});
			finish(null);
		});
};

// T16.17: config preserves UCI insertion order. Never sort by ID or latency.
function failover_candidate(daemon, machine) {
	for (let id, node in daemon.snapshot.nodes) {
		if (id == daemon.state.node_id || !node_failover.participates(daemon.snapshot, id))
			continue;
		let attempted = machine.failover_candidates[id];
		let attempt_at = time();
		if (attempted != null && attempt_at - attempted < C.NODE_FAILOVER_CANDIDATE_SECS)
			continue;
		machine.failover_candidates[id] = attempt_at;
		let resolved = apply.resolve_node(daemon.ctx, node.address);
		if (resolved.ok && node_reachable(resolved.ip, node.port))
			return { id, address: node.address, ...resolved };
	}
	return null;
};

function action_failover(daemon, machine, done) {
	// An earlier refresh in this action list may have repaired the route. Three failures
	// of the previous IP must never evict a freshly installed, reachable IP.
	if (machine.node_ip != machine.failover_ip) {
		machine.failover_ip = machine.node_ip;
		machine.failover_failures = 0;
		machine.failover_latched = false;
		done(null);
		return;
	}
	let from = daemon.state.node_id, ts = time(), before = machine.node_ip;
	let reason = 'node_tcp_failed_3';
	let candidate = failover_candidate(daemon, machine);
	let changed = null;
	if (candidate != null && daemon.reload != null) {
		let snapshot = { ...daemon.snapshot, main: { ...daemon.snapshot.main, node: candidate.id } };
		// Reuse frozen data and reload's validation/rollback, without reading or writing UCI.
		// Both snapshots name the already-resolved node so reload cannot resolve a different IP.
		let live = { ...daemon, snapshot, applied_context: { ...daemon.applied_context, snapshot },
			state: { ...daemon.state, dns_tier: machine.dns_tier, node_ip: candidate.ip } };
		changed = daemon.reload(live, null, { mode: machine.degraded_mode });
		if (changed.last_reload != null)
			daemon.state.last_reload = changed.last_reload;
	}
	let success = changed?.ok == true && !changed.stop;
	machine.failover_until = time() + C.NODE_FAILOVER_COOLDOWN_SECS;
	if (success) {
		daemon.state = changed.state;
		daemon.snapshot = changed.snapshot;
		daemon.applied_context = changed.applied_context;
		daemon.ctx.service_node = candidate.id;
		machine.node_ip = changed.state.node_ip;
		machine.failover_ip = changed.state.node_ip;
		machine.failover_node_id = candidate.id;
		machine.failover_failures = 0;
		machine.failover_latched = false;
		machine.last_node_refresh = time();
		machine.last_node_refresh_attempt = time();
		machine.node_probe_failures = 0;
		machine.node_probe_retry_at = null;
		if (candidate.source != 'lkg') {
			let saved = apply.update_lkg(daemon.ctx, { [candidate.address]: candidate.ip });
			if (!saved.ok)
				log.event('error', 'FS_FAILED', { op: 'update_lkg', path: saved.path, detail: saved.detail });
		}
		log.event('notice', 'NODE_FAILOVER', { from, to: candidate.id, ip: candidate.ip, reason });
	}
	else {
		reason = candidate == null ? 'no_reachable_candidate' : (changed?.detail ?? 'missing reload handler');
		if (type(reason) != 'string')
			reason = sprintf('%.J', reason);
		log.event('warn', 'NODE_FAILOVER_FAILED', { reason });
	}
	write_node_probe(daemon, {
		ts, address: candidate?.address ?? null, attempts: candidate?.attempts ?? 0,
		raw: substr(candidate?.raw ?? '', 0, C.NODE_PROBE_RAW_MAX),
		ip: candidate?.ip ?? null, source: candidate?.source ?? null,
		elapsed_ms: candidate?.elapsed_ms ?? 0, tier: machine.dns_tier,
		node_ip_before: before, reachable: candidate != null, action: 'failover',
		from, to: success ? candidate.id : null, reason, ok: success
	});
	// A failed attempt completes this fault episode, not an action-error retry loop.
	done(null);
};

function run_action(daemon, machine, name, done) {
	if (name == 'failover') {
		action_failover(daemon, machine, done);
		return;
	}
	if (name == 'set_degraded_mode') {
		// Inject the reload entry to avoid a module cycle (reload already uses monitor's
		// readiness check). It stages, validates and rolls back exactly like user reloads.
		if (daemon.reload == null) {
			done('missing degradation reload handler');
			return;
		}
		let live = { ...daemon, state: { ...daemon.state, dns_tier: machine.dns_tier, node_ip: machine.node_ip } };
		let changed = daemon.reload(live, null, { mode: machine.degraded_mode });
		// A failed runtime-only reload still has a completion record (T10.71).
		if (changed.last_reload != null)
			daemon.state.last_reload = changed.last_reload;
		if (!changed.ok || changed.stop) {
			done(changed.detail ?? 'service stop requested during degradation reload');
			return;
		}
		daemon.state = changed.state;
		daemon.snapshot = changed.snapshot;
		daemon.applied_context = changed.applied_context;
		machine.node_ip = changed.state.node_ip;
		machine.degraded_mode = changed.state.degraded_mode;
		machine.degraded_since = changed.state.degraded_since;
		done(null);
		return;
	}
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
	if (daemon.ctx.stopping_requested || index >= length(actions)) {
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
	if (daemon.ctx.stopping_requested)
		return true;
	let updated = {
		...daemon.state,
		state: machine.state,
		dns_tier: machine.dns_tier,
		dns_failsafe: machine.dns_failsafe,
		node_ip: machine.node_ip,
		degraded_mode: machine.degraded_mode,
		degraded_since: machine.degraded_since,
		since: machine.since,
		started_at: machine.started_at,
		last_probe: machine.last_probe,
		monitor: machine
	};
	// T16.8 (§2.1): reuse this tick's tmpfs publication, not a flash checkpoint.
	// Delete a previously enabled snapshot too when the switch has been closed.
	delete updated[C.USAGE_TODAY_FIELD];
	if (daemon.snapshot?.stats?.heatmap_enabled === true && daemon.usage?.day != null) {
		let live = daemon.usage;
		updated[C.USAGE_TODAY_FIELD] = {
			date: live.day, tx: live.tx, rx: live.rx,
			observed: live.observed, healthy: live.healthy, at: time()
		};
	}
	if (!state_file.write(run_dir(daemon), updated)) {
		log_failure(daemon, 'state_write', state_file.error());
		return false;
	}
	daemon.state = updated;
	return true;
};

function finish_tick(daemon, machine, transition, lock, started, error) {
	if (daemon.ctx.stopping_requested) {
		// The in-flight action has settled; leave both published and in-memory stop fields alone.
		if (error != null)
			log.event('error', 'CMD_FAILED', { cmd: 'monitor:actions', rc: 1, stderr: error });
	}
	else if (error == null) {
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
	// A readiness check may have nested uloop.run() inside this completion callback.
	// Wake the lifecycle owner too, not only the inner loop which dispatched TERM.
	if (daemon.ctx.stopping_requested)
		uloop.end();
	if (daemon.interval != null && !daemon.ctx.stopping_requested) {
		daemon.interval.set(interval_ms(daemon.machine));
		// Re-observe only after the T2 restart and unlock; the previous sample used the
		// old DNS upstream. A transition edge, not residence in T2, prevents a busy loop.
		// One-shot timer, never a shortened period: a tick that is skipped (lock held by a
		// user command, or still busy) would otherwise leave the interval at 1 ms and spin,
		// logging BUSY every millisecond (found in T8.19 review, 2026-10-19).
		let entered_t2 = error == null && index(transition.actions, 'set_tier:T2') >= 0;
		if (entered_t2 && daemon.immediate == null)
			daemon.immediate = uloop.timer(1, () => { daemon.immediate = null; tick(daemon); });
	}
};

// B25 usage persistence (docs/b25-heatmap.md §5, T12.4): merge this run's days over the
// previously persisted history and rewrite usage.json atomically with mode 0600. Called
// when a sample crosses the local date and by the daemon's clean-stop path; a closed
// switch must not touch the file at all. A failed write keeps the memory state and
// never blocks the monitor — the next crossing or stop retries. Defined before its
// caller: ucode does not hoist declarations (see tick above).
function flush_usage(daemon) {
	if (daemon?.snapshot?.stats?.heatmap_enabled !== true)
		return;
	let path = usage_path(daemon);
	// T16.2: reload before every flush; quota may have changed through the CLI.
	let loaded = usage.load(path);
	let warned_read = false;
	// Preserve the existing once-only read warning and retry cache. Do not log the
	// same failed flush twice when its read already reported the filesystem problem.
	if (loaded.error != null && !daemon.usage_warned) {
		daemon.usage_warned = true;
		warned_read = true;
		log.set_run_dir(run_dir(daemon));
		log.event('warn', 'FS_FAILED', { op: loaded.op, path, detail: loaded.error });
	}
	if (daemon.usage_days == null)
		daemon.usage_days = loaded.days;
	let days = usage.collect(daemon.usage, daemon.usage_days);
	if (days == null)
		return;
	let written = usage.write(path, days, time(), loaded.document ?? {});
	if (!written.ok) {
		log.set_run_dir(run_dir(daemon));
		if (!warned_read)
			log.event('warn', 'FS_FAILED', { op: 'write', path, detail: written.error });
		return;
	}
	daemon.usage_days = days;
};

// B25 usage sampling (docs/b25-heatmap.md §4, T12.3): only a `true` switch samples, and
// a closed switch must not even run the nft counter query. Data lives in memory between
// the persistence points (a crossed local date and the clean stop, T12.4); an abnormal
// exit loses the unflushed portion of the live day by design.
function sample_usage(daemon, obs) {
	if (daemon.snapshot?.stats?.heatmap_enabled !== true)
		return;
	// Try once at the first enabled sample, including after a runtime enable.
	if (daemon.usage_ready !== true) {
		daemon.usage_ready = true;
		let path = usage_path(daemon);
		let loaded = usage.load(path);
		if (loaded.error != null) {
			daemon.usage_warned = true;
			log.set_run_dir(run_dir(daemon));
			log.event('warn', 'FS_FAILED', { op: 'read', path, detail: loaded.error });
		}
		else {
			let now = time(), today = usage.local_date(now);
			let seeded = usage.seed(daemon.usage, loaded.days[today], today, now);
			if (seeded != null) {
				daemon.usage = seeded;
				daemon.usage_days = loaded.days;
			}
		}
	}
	let live_day = daemon.usage.day;
	let now_ms = monotonic_ms();
	let elapsed = daemon.usage_mono_ms == null || now_ms == null
		? 0 : max((now_ms - daemon.usage_mono_ms) / 1000, 0);
	daemon.usage_mono_ms = now_ms;
	let read = counters.proxy_counters(daemon.ctx);
	usage.sample(daemon.usage, {
		tx: read?.tx_bytes ?? null,
		rx: read?.rx_bytes ?? null,
		now: time(),
		elapsed,
		cap: interval_ms(daemon.machine) / 1000 * C.USAGE_ELAPSED_FACTOR,
		state: daemon.machine.state,
		proxy_ok: obs.proxy_ok
	});
	// The sampler finalized the old day on the crossing (docs §5): get the merged
	// history on disk before the new day grows.
	if (live_day != null && daemon.usage.day != live_day)
		flush_usage(daemon);
};

tick = function(daemon) {
	if (daemon.busy || daemon.ctx.stopping_requested)
		return;
	if (daemon.skip_next) {
		daemon.skip_next = false;
		return;
	}
	let started = monotonic_ms();
	if (started == null)
		return;
	let lock_path = system_path(daemon.ctx, C.LOCK_FILE);
	// Monitor mutates the same runtime resources as user actions; skip a busy round rather
	// than block behind them (docs/04「monitor 循环」).
	let lock = sys.lock(lock_path);
	if (lock == null) {
		log.set_run_dir(run_dir(daemon));
		log.event('warn', 'BUSY', { holder: 'monitor' });
		return;
	}
	daemon.busy = true;
	let obs = observe(daemon);
	// Synchronous probes cannot dispatch TERM. Yield before deriving or starting actions,
	// so a pending stop publishes its snapshot at the first dispatch point after the probe.
	uloop.run(1);
	if (daemon.ctx.stopping_requested) {
		finish_tick(daemon, daemon.machine, { actions: [], events: [] }, lock, started, null);
		return;
	}
	sample_usage(daemon, obs);
	let transition = next(daemon.machine, obs, daemon.snapshot);
	run_actions(daemon, transition.state, transition.actions, 0,
		error => finish_tick(daemon, transition.state, transition, lock, started, error));
};

function create_daemon(daemon) {
	daemon = {
		...daemon,
		machine: initial_state(daemon.state, time()),
		busy: false,
		skip_next: false,
		interval: null,
		usage: usage.create(),
		usage_ready: false,
		usage_mono_ms: null,
		usage_days: null,
		usage_warned: false
	};
	return daemon;
};

initial_state = (service, now) => {
	return {
		state: service?.state ?? 'starting',
		dns_tier: service?.dns_tier ?? 'T2',
		dns_failsafe: service?.dns_failsafe == true,
		table_missing_count: 0,
		xray_down_count: 0,
		xray_down_reported: false,
		chinadns_down_count: 0,
		chinadns_down_reported: service?.dns_failsafe == true,
		ever_healthy: service?.state == 'running',
		proxy_fail_count: 0,
		proxy_ok_count: 0,
		dns_fail_count: 0,
		t3_since: null,
		last_t2_retry: null,
		t2_retry_pending: false,
		last_node_refresh: now,
		last_node_refresh_attempt: null,
		node_probe_failures: 0,
		node_probe_retry_at: null,
		failover_node_id: service?.node_id ?? null,
		failover_ip: service?.node_ip ?? null,
		failover_failures: 0,
		failover_latched: false,
		failover_until: 0,
		failover_candidates: {},
		node_ip: service?.node_ip ?? null,
		degraded_mode: service?.degraded_mode ?? null,
		degraded_since: service?.degraded_since ?? null,
		last_probe: service?.last_probe ?? null,
		// Unlike since, this identifies the daemon lifetime, not the latest transition.
		started_at: service?.started_at ?? now,
		since: service?.since ?? now
	};
};

// Pure transition function. Observations are one point-in-time sample; actions remain
// ordered so the executor can apply fail-open and DNS changes without hidden side effects.
next = (state, obs, cfg) => {
	let old = state ?? {};
	let direct_enabled = cfg.dns.direct_dns_enabled == true;
	let fallback_tier = direct_enabled ? 'T2' : (cfg.dns.allow_china_fallback ? 'T3' : 'T1');
	let previous_service_state = old.state ?? 'starting';
	let now = obs.now;
	let out = {
		state: old.state ?? 'starting',
		dns_tier: old.dns_tier ?? (direct_enabled ? 'T2' : 'T1'),
		dns_failsafe: old.dns_failsafe == true,
		table_missing_count: old.table_missing_count ?? 0,
		xray_down_count: old.xray_down_count ?? 0,
		xray_down_reported: old.xray_down_reported == true,
		chinadns_down_count: old.chinadns_down_count ?? 0,
		chinadns_down_reported: old.chinadns_down_reported == true,
		ever_healthy: old.ever_healthy == true || old.state == 'running',
		proxy_fail_count: old.proxy_fail_count ?? 0,
		proxy_ok_count: old.proxy_ok_count ?? 0,
		dns_fail_count: old.dns_fail_count ?? 0,
		t3_since: old.t3_since ?? null,
		last_t2_retry: old.last_t2_retry ?? null,
		t2_retry_pending: old.t2_retry_pending == true,
		last_node_refresh: old.last_node_refresh ?? now,
		last_node_refresh_attempt: old.last_node_refresh_attempt ?? null,
		node_probe_failures: old.node_probe_failures ?? 0,
		node_probe_retry_at: old.node_probe_retry_at ?? null,
		failover_node_id: old.failover_node_id ?? null,
		failover_ip: old.failover_ip ?? null,
		failover_failures: old.failover_failures ?? 0,
		failover_latched: old.failover_latched == true,
		failover_until: old.failover_until ?? 0,
		failover_candidates: { ...(old.failover_candidates ?? {}) },
		node_ip: old.node_ip ?? null,
		degraded_mode: old.degraded_mode ?? null,
		degraded_since: old.degraded_since ?? null,
		last_probe: old.last_probe ?? null,
		started_at: old.started_at,
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

	// Live disable during T2 (docs/03): stop using the disabled upstream at once, keep
	// health history, and choose only T1/T3.
	if (!direct_enabled && out.dns_tier == 'T2')
		tier(out.state == 'running' || out.state == 'starting' ? 'T1' : fallback_tier, 'direct_dns_disabled');

	// 1. Debounce a missing ruleset so transient observation gaps do not trigger a reload.
	if (obs.table_present == false) {
		out.table_missing_count = min(out.table_missing_count + 1, C.MONITOR_FAILSAFE_ROUNDS);
		if (out.table_missing_count >= C.MONITOR_FAILSAFE_ROUNDS && out.state != 'failsafe') {
			action('nft_reload');
			event('warn', 'NFT_TABLE_RESTORED', {});
		}
	}
	else if (obs.table_present == true) {
		out.table_missing_count = 0;
	}

	// 2. A single missing sample is tolerated; only a crossing to round two emits a down event.
	if (obs.xray_listening == false) {
		out.xray_down_count = min(out.xray_down_count + 1, C.MONITOR_FAILSAFE_ROUNDS);
		if (out.xray_down_count >= C.MONITOR_FAILSAFE_ROUNDS && !out.xray_down_reported) {
			out.xray_down_reported = true;
			if (cfg.main.fail_open == true) {
				out.state = 'failsafe';
				action('nft_flush_prerouting');
				tier(fallback_tier, 'xray_down');
				event('error', 'XRAY_DOWN_FAILOPEN', { port: C.TPROXY_PORT });
			}
			else {
				if (out.state != 'failsafe')
					out.state = 'degraded';
				tier(fallback_tier, 'xray_down');
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
		// Warmup has no healthy route to protect against flapping. Once healthy, keep
		// the configured recovery hysteresis even after leaving `starting`/entering T3.
		let recovered = !out.ever_healthy || out.proxy_ok_count >= recover_threshold;
		if (recovered && out.state != 'running' && out.state != 'failsafe') {
			out.ever_healthy = true;
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
			tier(fallback_tier, 'proxy_unhealthy');
			event('warn', 'PROXY_UNHEALTHY', { latency_ms: obs.proxy_latency_ms ?? null, fails: out.proxy_fail_count });
		}
	}

	// 5. DNS checks run only while a DNS tier is in direct mode. A T3 retry probes T2 on
	// the following observation; one failed T2 retry returns immediately to T3 per docs/03.
	if (direct_enabled && !out.dns_failsafe && (out.dns_tier == 'T2' || out.dns_tier == 'T3')) {
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
		}
	}

	// 6. Refresh on the unhealthy edge as well as periodically. Share the attempt
	// timestamp so a periodic refresh and a flapping health edge cannot double-run.
	let unhealthy = length(filter(events, e => e.code == 'PROXY_UNHEALTHY')) > 0;
	let refresh_due = now - out.last_node_refresh >= C.MONITOR_NODE_REFRESH_SECS;
	let refresh_allowed = out.last_node_refresh_attempt == null ||
		now - out.last_node_refresh_attempt >= C.NODE_REFRESH_MIN_GAP_SECS;
	let retry_due = out.node_probe_retry_at != null && now >= out.node_probe_retry_at;
	// Health edges retain T16.12 priority (60s debounce), even during longer backoff.
	// Periodic cadence starts a fresh failure series; fast retries alone retain it.
	if ((unhealthy || refresh_due || retry_due) && refresh_allowed) {
		if (refresh_due) {
			out.node_probe_failures = 0;
			out.node_probe_retry_at = null;
		}
		else if (retry_due)
			out.node_probe_retry_at = null;
		out.last_node_refresh = now;
		out.last_node_refresh_attempt = now;
		action('refresh_node_ip');
	}
	if (out.state != previous_service_state)
		out.since = now;

	// Last action: no later failure may discard an already applied mode transition.
	// Test the sustained health verdict, not just its edge: a failed transaction retries
	// next round, and a never-healthy startup can already be in `degraded` (docs/02).
	let target = out.degraded_mode;
	let has_targets = cfg.main.mode == 'bypass_cn' ||
		length(filter(cfg.hosts ?? [], h => h.enabled != false && h.policy == 'bypass_cn')) > 0;
	if (cfg.main.degrade_gfw == false || out.state == 'running')
		target = null;
	else if (cfg.main.degrade_gfw != false && obs.xray_listening == true && out.state != 'failsafe') {
		if (out.proxy_fail_count >= fail_threshold && has_targets)
			target = 'gfw';
	}
	if (target != out.degraded_mode) {
		out.degraded_mode = target;
		out.degraded_since = target == null ? null : now;
		action('set_degraded_mode');
	}

	// T16.17: TCP samples of the live IP alone arm failover, never HTTP or DNS candidates.
	// Automatic switches update the tracked ID themselves; a different reload target is manual.
	if (obs.node_id != null && obs.node_id != out.failover_node_id) {
		out.failover_node_id = obs.node_id;
		out.failover_failures = 0;
		out.failover_latched = false;
		if (obs.node_reload?.ok && obs.node_reload.target_node == obs.node_id)
			out.failover_until = max(out.failover_until, obs.node_reload.at + C.NODE_FAILOVER_COOLDOWN_SECS);
	}
	if (obs.node_tcp_ip != null && obs.node_tcp_ip != out.failover_ip) {
		out.failover_ip = obs.node_tcp_ip;
		out.failover_failures = 0;
		out.failover_latched = false;
	}
	let participating = node_failover.participates(cfg, obs.node_id);
	if (!participating || obs.node_tcp_ok === true) {
		out.failover_failures = 0;
		out.failover_latched = false;
	}
	else if (obs.node_tcp_ok === false) {
		out.failover_failures = min(out.failover_failures + 1, C.NODE_FAILOVER_FAILURES);
		if (out.failover_failures >= C.NODE_FAILOVER_FAILURES && !out.failover_latched &&
		    now >= out.failover_until) {
			out.failover_latched = true;
			// Last: no later action failure may discard an already applied switch.
			action('failover');
		}
	}

	return { state: out, actions, events };
};

interval_ms = machine => {
	return machine?.state == 'running' ? C.MONITOR_RUNNING_INTERVAL_MS : C.MONITOR_OTHER_INTERVAL_MS;
};

export { create_daemon, flush_usage, initial_state, interval_ms, next, node_reachable, tick, wait_xray_port };
