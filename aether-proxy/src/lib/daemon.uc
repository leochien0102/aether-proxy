'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as socket from 'socket';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as state from 'aetherproxy.state';
import * as pipeline from 'aetherproxy.pipeline';
import * as check from 'aetherproxy.cmd.check';
import * as apply from 'aetherproxy.apply';
import * as supervise from 'aetherproxy.supervise';
import * as config from 'aetherproxy.config';
import * as net from 'aetherproxy.net';
import * as monitor from 'aetherproxy.monitor';
import * as reload from 'aetherproxy.reload';
import * as uci from 'uci';

const BOOT_OPTS = {
	'--confdir': 'confdir', '--data-dir': 'data_dir', '--baseline-dir': 'baseline_dir',
	'--custom-dir': 'custom_dir', '--run-dir': 'run_dir', '--sys-root': 'sys_root', '--bin-dir': 'bin_dir'
};

function parse_options(args, allow_boot) {
	let opts = {}, positional = [];
	for (let i = 0; i < length(args); i++) {
		let a = args[i];
		if (a == '--boot' && allow_boot) {
			opts.boot = true;
			continue;
		}
		if (BOOT_OPTS[a] != null) {
			if (i + 1 >= length(args) || substr(args[i + 1], 0, 1) == '-')
				return { error: `option ${a} needs a value` };
			opts[BOOT_OPTS[a]] = args[++i];
			continue;
		}
		if (substr(a, 0, 1) == '-')
			return { error: `unknown option ${a}` };
		push(positional, a);
	}
	if (length(positional))
		return { error: `unexpected arguments: ${join(' ', positional)}` };
	return { opts };
};

function root_path(opts, absolute) {
	let root = opts.sys_root ?? '';
	return root == '' ? absolute : replace(root, /\/$/, '') + absolute;
};

function resolved_opts(opts) {
	let root = opts.sys_root ?? '';
	let copy = { ...opts };
	copy.confdir ??= root_path(opts, C.CONFIG_DIR);
	copy.run_dir ??= C.RUN_DIR;
	return copy;
};

function make_context(opts, lan_ifaces) {
	return {
		root: opts.sys_root ?? '',
		bin_dir: opts.bin_dir ?? null,
		run_dir: opts.run_dir ?? C.RUN_DIR,
		state_dir: C.STATE_DIR,
		lan_ifaces: lan_ifaces ?? []
	};
};

function run_dir(ctx) {
	return root_path({ sys_root: ctx.root }, ctx.run_dir ?? C.RUN_DIR);
};

function state_dir(ctx) {
	return root_path({ sys_root: ctx.root }, ctx.state_dir ?? C.STATE_DIR);
};

function cmd(ctx, name) {
	return ctx.bin_dir ? `${ctx.bin_dir}/${name}` : name;
};

function run_command(ctx, name, args, timeout, quiet) {
	return sys.run([ cmd(ctx, name), ...args ], { timeout: timeout ?? 10, quiet: quiet ?? false });
};

function setup_log(ctx) {
	log.set_run_dir(run_dir(ctx));
};

function event_failure(ctx, step, detail) {
	setup_log(ctx);
	log.event('error', 'START_FAILED', { step, detail });
};

function write_state(ctx, obj) {
	if (!sys.mkdir_p(run_dir(ctx))) {
		let detail = `cannot create ${run_dir(ctx)}: ${sys.error()}`;
		event_failure(ctx, 'state', detail);
		return { ok: false, detail };
	}
	if (!state.write(run_dir(ctx), obj)) {
		let detail = `cannot write state: ${state.error()}`;
		event_failure(ctx, 'state', detail);
		return { ok: false, detail };
	}
	return { ok: true };
};

function load_snapshot(opts) {
	let cfg = config.load(uci.cursor(opts.confdir));
	return cfg;
};

function monotonic_ms() {
	let now = clock(true);
	return now == null ? null : now[0] * 1000 + now[1] / 1000000;
};

function split_hostport(value) {
	let p = split(value, ':');
	return length(p) == 2 ? { host: p[0], port: +p[1] } : null;
};

function connect_target(target, timeout_ms) {
	let sock = socket.create(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);
	if (sock == null)
		return false;
	let started = monotonic_ms();
	if (started == null) {
		sock.close();
		return false;
	}
	let connected = sock.connect(target.host, target.port);
	if (connected) {
		sock.close();
		return true;
	}
	let code = socket.error(true);
	if (code != 115 && code != 114 && index(lc(socket.error() ?? ''), 'progress') < 0) {
		sock.close();
		return false;
	}
	let left = timeout_ms;
	while (left > 0) {
		let polled = socket.poll(left, [ sock, socket.POLLOUT | socket.POLLERR | socket.POLLHUP | socket.POLLNVAL, 1 ]);
		if (polled == null) {
			sock.close();
			return false;
		}
		if (length(polled)) {
			let error = sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR);
			sock.close();
			return error == 0;
		}
		let now = monotonic_ms();
		if (now == null)
			break;
		left = timeout_ms - (now - started);
	}
	sock.close();
	return false;
};

function network_ready(ctx, snapshot, timeout_ms) {
	if (timeout_ms <= 0)
		return false;
	let route_timeout = min(5, max(1, int((timeout_ms + 999) / 1000)));
	let route = run_command(ctx, 'ip', [ '-4', 'route', 'show', 'default' ], route_timeout);
	if (route.code != 0 || trim(route.stdout) == '')
		return false;
	let deadline = monotonic_ms() + timeout_ms;
	for (let value in snapshot.main.boot_check_targets ?? []) {
		let target = split_hostport(value);
		let remaining = deadline - monotonic_ms();
		if (remaining <= 0)
			break;
		if (target != null && connect_target(target, min(3000, remaining)))
			return true;
	}
	return false;
};

function wait_network(ctx, opts, snapshot, on_signal) {
	let started = monotonic_ms();
	if (started == null)
		return false;
	let timeout = max(+(snapshot.main.boot_wait_timeout ?? 0), 0) * 1000;
	let deadline = started + timeout;
	let saved = write_state(ctx, { state: 'starting', dns_tier: 'T2', dns_failsafe: false,
		waiting_network: true, node_id: snapshot.main.node, node_ip: null, since: time() });
	if (!saved.ok)
		return { ok: false, detail: saved.detail };
	while (true) {
		if (on_signal())
			return { ok: false, interrupted: true };
		let now = monotonic_ms();
		if (now == null || now >= deadline)
			break;
		if (network_ready(ctx, snapshot, deadline - now))
			return { ok: true };
		now = monotonic_ms();
		if (now == null || now >= deadline)
			break;
		let duration = min(5000, int(deadline - now));
		uloop.run(duration);
	}
	setup_log(ctx);
	log.event('warn', 'NET_WAIT_TIMEOUT', { waited: timeout / 1000 });
	return { ok: true, timed_out: true };
};

function ensure_clean_dir(ctx, path) {
	let rm = sys.run([ 'rm', '-rf', path ], { timeout: 10 });
	if (rm.code != 0)
		return { ok: false, detail: `rm -rf ${path} failed (${rm.code}): ${rm.stderr}` };
	if (!sys.mkdir_p(path))
		return { ok: false, detail: `cannot create ${path}: ${sys.error()}` };
	return { ok: true };
};

function write_artifacts(dir, artifacts) {
	for (let name, filename in C.ARTIFACT_FILES) {
		let path = `${dir}/${filename}`;
		if (!sys.write_atomic(path, artifacts[name]))
			return { ok: false, detail: `cannot write ${path}: ${sys.error()}`, artifact: name };
	}
	return { ok: true };
};

function validate_render(ctx, snapshot, staging, components) {
	let nft = run_command(ctx, 'nft', [ '-c', '-f', `${staging}/${C.ARTIFACT_FILES.nft}` ], 10, true);
	if (nft.code != 0)
		return { ok: false, code: 'RENDER_INVALID', artifact: 'nft', detail: `nft -c -f failed (${nft.code}): ${nft.stderr}` };
	let xray = sys.run([ components[C.XRAY_COMPONENT].path, 'run', '-test', '-c', `${staging}/${C.ARTIFACT_FILES.xray}` ], { timeout: 10, quiet: true });
	if (xray.code != 0)
		return { ok: false, code: 'RENDER_INVALID', artifact: 'xray', detail: `xray run -test failed (${xray.code}): ${xray.stderr}` };
	return { ok: true };
};

function publish_staging(ctx, staging, current) {
	let previous = `${run_dir(ctx)}/${C.DAEMON_PREVIOUS_DIR}`;
	let clear = sys.run([ 'rm', '-rf', previous ], { timeout: 10 });
	if (clear.code != 0)
		return { ok: false, detail: `rm -rf ${previous} failed (${clear.code}): ${clear.stderr}` };
	let exists = fs.stat(current) != null;
	if (exists && !fs.rename(current, previous))
		return { ok: false, detail: `rename ${current} to ${previous}: ${fs.error() ?? 'unknown error'}` };
	if (!fs.rename(staging, current)) {
		let detail = `rename ${staging} to ${current}: ${fs.error() ?? 'unknown error'}`;
		if (exists && !fs.rename(previous, current))
			detail += `; rollback rename failed: ${fs.error() ?? 'unknown error'}`;
		return { ok: false, detail };
	}
	return { ok: true };
};

function hash_artifacts(ctx, current) {
	let hashes = {};
	for (let name, filename in C.ARTIFACT_FILES) {
		let r = sys.run([ 'sha256sum', `${current}/${filename}` ], { timeout: 10 });
		if (r.code != 0)
			return { ok: false, detail: `sha256sum ${filename} failed (${r.code}): ${r.stderr}` };
		let m = match(trim(r.stdout), /^([0-9a-fA-F]{64})\s/);
		if (m == null)
			return { ok: false, detail: `cannot parse sha256sum output for ${filename}` };
		hashes[name] = lc(m[1]);
	}
	return { ok: true, hashes };
};

function port_listening(opts) {
	for (let file in [ C.PROC_NET_TCP, C.PROC_NET_TCP6 ])
		if (net.tcp_listening(fs.readfile(root_path(opts, file)), C.TPROXY_PORT))
			return true;
	return false;
};

function wait_xray_port(ctx, opts, on_signal) {
	let started = monotonic_ms();
	if (started == null)
		return false;
	let deadline = started + C.DAEMON_PORT_WAIT_SECS * 1000;
	while (monotonic_ms() < deadline) {
		if (on_signal())
			return false;
		if (port_listening(opts))
			return true;
		uloop.run(C.DAEMON_POLL_MS);
	}
	return port_listening(opts);
};

function child_options(ctx, name, argv) {
	return supervise.create({ name, argv, run_dir: run_dir(ctx), backoff: [ 5, 10, 30, 60 ], stable_secs: 300 });
};

function pid_path(ctx, name) {
	return `${run_dir(ctx)}/${name}.pid`;
};

function remove_pidfiles(ctx) {
	for (let name in [ C.XRAY_COMPONENT, C.CHINADNS_COMPONENT ]) {
		let path = pid_path(ctx, name);
		if (fs.stat(path) != null && !fs.unlink(path))
			event_failure(ctx, 'cleanup', `cannot unlink ${path}: ${fs.error() ?? 'unknown error'}`);
	}
};

function has_output(text) {
	let value = trim(text ?? '');
	return value != '' && value != '__EMPTY__';
};

// Same steps as the daemon's stop (04), for when the daemon could not run them itself.
function apply_cleanup(ctx) {
	let failures = [];
	let table = apply.nft_table_exists(ctx);
	if (!table.ok)
		push(failures, `nft_table_exists: ${table.detail}`);
	else if (table.exists) {
		// Save the dynamic sets before the table goes (stop step 2), so a crashed or
		// SIGKILLed daemon's sets survive. A failed export is logged by apply but must not
		// keep the rest of the cleanup from running.
		let exported = apply.sets_export(ctx);
		if (exported.ok)
			apply.sets_save(ctx, exported.sets);
		let r = apply.nft_delete(ctx);
		if (!r.ok)
			push(failures, `nft_delete: ${r.detail}`);
	}
	let rule = run_command(ctx, 'ip', [ 'rule', 'show' ], 5);
	let route = run_command(ctx, 'ip', [ '-4', 'route', 'show', 'table', `${C.ROUTE_TABLE}` ], 5);
	if (rule.code != 0 || route.code != 0) {
		// Query failure is logged by sys.run(); still attempt the idempotent deletion path.
		let removed = apply.route_del(ctx);
		if (!removed.ok)
			push(failures, `route_del: ${removed.detail}`);
	}
	else if (has_output(rule.stdout) || has_output(route.stdout)) {
		let removed = apply.route_del(ctx);
		if (!removed.ok)
			push(failures, `route_del: ${removed.detail}`);
	}
	let dnsmasq = apply.dnsmasq_remove(ctx);
	if (!dnsmasq.ok)
		push(failures, `dnsmasq_remove: ${dnsmasq.detail}`);
	for (let name in [ C.XRAY_COMPONENT, C.CHINADNS_COMPONENT ]) {
		let r = supervise.kill_stale(run_dir(ctx), name, run_dir(ctx));
		if (!r.ok)
			push(failures, `kill_stale ${name}: ${r.detail}`);
	}
	remove_pidfiles(ctx);
	return failures;
};

function lan_ifaces_from_config(opts) {
	let loaded = config.load(uci.cursor(opts.confdir));
	return loaded.ok ? (loaded.snapshot.main.lan_ifaces ?? []) : [];
};

function cleanup_run(parsed_opts) {
	let opts = resolved_opts(parsed_opts);
	let ctx = make_context(opts, lan_ifaces_from_config(opts));
	setup_log(ctx);
	let lock_path = root_path(opts, C.LOCK_FILE);
	let lock = sys.lock(lock_path);
	if (lock == null) {
		log.event('warn', 'BUSY', { holder: 'daemon' });
		return { ok: false, code: 3, detail: `BUSY: ${sys.error()}` };
	}
	let failures = apply_cleanup(ctx);
	let saved = write_state(ctx, { state: 'stopped', since: time(), dns_tier: 'T2', dns_failsafe: false });
	if (!saved.ok)
		push(failures, saved.detail);
	lock.close();
	return length(failures) ? { ok: false, code: 1, detail: join('; ', failures) } : { ok: true, code: 0 };
};

function read_lan_ifaces(opts, snapshot) {
	return snapshot.main.lan_ifaces ?? [];
};

function start_sequence(ctx, opts, signal_pending) {
	let locked = sys.lock(root_path(opts, C.LOCK_FILE));
	if (locked == null) {
		setup_log(ctx);
		log.event('warn', 'BUSY', { holder: 'daemon' });
		return { ok: false, code: 3, step: 'lock', detail: sys.error(), lock_busy: true };
	}

	let cfg = pipeline.build(opts);
	if (!cfg.ok) {
		locked.close();
		return { ok: false, code: cfg.exit ?? 2, step: 'config', detail: `${cfg.code}: ${cfg.detail}`, errors: cfg.errors, untouched: true };
	}
	let snapshot = cfg.snapshot;
	ctx.service_mode = snapshot.main.mode;
	ctx.service_node = snapshot.main.node;
	ctx.lan_ifaces = read_lan_ifaces(opts, snapshot);
	let staging = `${run_dir(ctx)}/${C.STAGING_SUBDIR}`;
	if (!sys.mkdir_p(run_dir(ctx))) {
		locked.close();
		return { ok: false, code: 1, step: 'precheck', detail: `cannot create run dir: ${sys.error()}`, untouched: true };
	}
	if (!sys.mkdir_p(staging)) {
		locked.close();
		return { ok: false, code: 1, step: 'precheck', detail: `cannot create ${staging}: ${sys.error()}`, untouched: true };
	}
	let pre = check.precheck(snapshot, staging, { sys_root: ctx.root, bin_dir: ctx.bin_dir });
	let failed_pre = filter(pre.items, item => !item.ok);
	for (let name in [ C.XRAY_COMPONENT, C.CHINADNS_COMPONENT ])
		if (!pre.components[name]?.found)
			push(failed_pre, { item: `component:${name}`, ok: false, detail: `${name} missing` });
	if (length(failed_pre)) {
		locked.close();
		setup_log(ctx);
		let missing = map(failed_pre, item => item.item);
		log.event('error', 'PRECHECK_FAILED', { missing });
		return { ok: false, code: 1, step: 'precheck', detail: join(',', missing), missing, untouched: true };
	}

	let conflicts = apply.conflicts(ctx);
	if (!conflicts.ok || length(conflicts.conflicts)) {
		locked.close();
		let missing = map(conflicts.conflicts ?? [], name => `conflict:${name}`);
		if (!conflicts.ok)
			push(missing, `conflict-check:${conflicts.detail}`);
		setup_log(ctx);
		log.event('error', 'PRECHECK_FAILED', { missing });
		return { ok: false, code: 1, step: 'precheck', detail: join(',', missing), missing, untouched: true };
	}

	if (opts.boot) {
		let waiting = wait_network(ctx, opts, snapshot, signal_pending);
		if (!waiting.ok) {
			locked.close();
			return waiting.interrupted
				? { ok: false, code: 1, step: 'signal', detail: 'shutdown requested while waiting for network', interrupted: true }
				: { ok: false, code: 1, step: 'wait_network', detail: waiting.detail };
		}
	}

	let initial_runtime = { node_ip: null, dns_tier: 'T2', restored: {} };
	let initial = pipeline.build({ ...opts, runtime: initial_runtime });
	if (!initial.ok) {
		locked.close();
		return { ok: false, code: initial.exit ?? 1, step: 'render', detail: initial.detail };
	}
	let prepared = ensure_clean_dir(ctx, staging);
	if (!prepared.ok) {
		locked.close();
		return { ok: false, code: 1, step: 'render', detail: prepared.detail };
	}
	let written = write_artifacts(staging, initial.artifacts);
	if (!written.ok) {
		locked.close();
		return { ok: false, code: 1, step: 'render', detail: written.detail, artifact: written.artifact };
	}
	let valid = validate_render(ctx, snapshot, staging, pre.components);
	if (!valid.ok) {
		locked.close();
		if (valid.code == 'PRECHECK_FAILED')
			log.event('error', 'PRECHECK_FAILED', { missing: valid.missing });
		return { ok: false, code: 1, step: 'render', detail: valid.detail, artifact: valid.artifact };
	}

	// TODO(design): 04 says clean crash residue before startup, but also forbids system changes
	// when render validation fails; clean after validation to preserve the no-change failure path.
	let cleanup_failures = apply_cleanup(ctx);
	if (length(cleanup_failures)) {
		locked.close();
		return { ok: false, code: 1, step: 'cleanup', detail: join('; ', cleanup_failures) };
	}

	let current = `${run_dir(ctx)}/${C.DAEMON_CURRENT_DIR}`;
	let published = publish_staging(ctx, staging, current);
	if (!published.ok) {
		locked.close();
		return { ok: false, code: 1, step: 'publish', detail: published.detail };
	}
	let hashed = hash_artifacts(ctx, current);
	if (!hashed.ok) {
		locked.close();
		return { ok: false, code: 1, step: 'hash', detail: hashed.detail };
	}

	let children = { xray: null, dns: null };
	let dns_path = pre.components[C.CHINADNS_COMPONENT].path;
	children.dns = child_options(ctx, C.CHINADNS_COMPONENT, [ dns_path, '-C', `${current}/${C.ARTIFACT_FILES.chinadns}` ]);
	children.dns.start();
	if (children.dns.pid() == null) {
		locked.close();
		return { ok: false, code: 1, step: 'chinadns_start', detail: 'chinadns-ng process could not be started', children };
	}

	let dnsmasq = apply.dnsmasq_install(ctx, initial.artifacts.dnsmasq);
	if (!dnsmasq.ok) {
		locked.close();
		return { ok: false, code: 1, step: 'dnsmasq_install', detail: dnsmasq.detail, children };
	}

	let domains = [];
	for (let id, node in snapshot.nodes)
		if (node.address && net.ipv4(node.address) == null)
			push(domains, node.address);
	let boot_list = apply.write_boot_list(ctx, domains);
	if (!boot_list.ok) {
		locked.close();
		return { ok: false, code: 1, step: 'write_boot_list', detail: boot_list.detail, children };
	}
	let node_id = snapshot.main.node;
	let address = snapshot.nodes?.[node_id]?.address;
	let resolution = apply.resolve_node(ctx, address);
	let node_ip = resolution.ok ? resolution.ip : null;
	let degraded = !resolution.ok;

	if (!degraded) {
		let runtime = { node_ip, dns_tier: 'T2', restored: {} };
		let resolved = pipeline.build({ ...opts, runtime });
		if (!resolved.ok) {
			locked.close();
			return { ok: false, code: 1, step: 'xray_render', detail: resolved.detail, children };
		}
		let xray_file = `${current}/${C.ARTIFACT_FILES.xray}`;
		if (!sys.write_atomic(xray_file, resolved.artifacts.xray)) {
			locked.close();
			return { ok: false, code: 1, step: 'xray_render', detail: sys.error(), children };
		}
		let test = sys.run([ pre.components[C.XRAY_COMPONENT].path, 'run', '-test', '-c', xray_file ], { timeout: 10, quiet: true });
		if (test.code != 0) {
			locked.close();
			return { ok: false, code: 1, step: 'xray_test', detail: `xray run -test failed (${test.code}): ${test.stderr}`, children };
		}
	}

	if (!degraded) {
		children.xray = child_options(ctx, C.XRAY_COMPONENT,
			[ pre.components[C.XRAY_COMPONENT].path, 'run', '-c', `${current}/${C.ARTIFACT_FILES.xray}` ]);
		children.xray.start();
		if (children.xray.pid() == null) {
			locked.close();
			return { ok: false, code: 1, step: 'xray_start', detail: 'xray process could not be started', children };
		}
		if (!wait_xray_port(ctx, opts, signal_pending)) {
			locked.close();
			return { ok: false, code: 1, step: 'xray_listen', detail: 'xray did not listen on the TPROXY port within 5 seconds', children, interrupted: signal_pending() };
		}
	}

	if (!degraded) {
		let saved_sets = apply.sets_load(ctx);
		if (!saved_sets.ok) {
			locked.close();
			return { ok: false, code: 1, step: 'sets_load', detail: saved_sets.detail, children };
		}
		let dataplane = pipeline.build({ ...opts, runtime: { node_ip, dns_tier: 'T2', restored: saved_sets.sets } });
		if (!dataplane.ok) {
			locked.close();
			return { ok: false, code: 1, step: 'nft_render', detail: dataplane.detail, children };
		}
		let nft_file = `${current}/${C.ARTIFACT_FILES.nft}`;
		if (!sys.write_atomic(nft_file, dataplane.artifacts.nft)) {
			locked.close();
			return { ok: false, code: 1, step: 'nft_render', detail: sys.error(), children };
		}
		let nft = apply.nft_load(ctx, nft_file);
		if (!nft.ok) {
			locked.close();
			return { ok: false, code: 1, step: 'nft_load', detail: nft.detail, children };
		}
		let route = apply.route_add(ctx);
		if (!route.ok) {
			locked.close();
			return { ok: false, code: 1, step: 'route_add', detail: route.detail, children };
		}
		hashed = hash_artifacts(ctx, current);
		if (!hashed.ok) {
			locked.close();
			return { ok: false, code: 1, step: 'hash', detail: hashed.detail, children };
		}
	}

	let initial_state = {
		state: degraded ? 'degraded' : 'starting', dns_tier: 'T2', dns_failsafe: false,
		node_id, node_ip, since: time(), waiting_network: false,
		last_error: degraded ? 'NODE_RESOLVE_FAILED' : null,
		components: {
			[C.XRAY_COMPONENT]: { path: pre.components[C.XRAY_COMPONENT].path },
			[C.CHINADNS_COMPONENT]: { path: pre.components[C.CHINADNS_COMPONENT].path }
		},
		render_hash: hashed.hashes
	};
	let state_result = write_state(ctx, initial_state);
	if (!state_result.ok)
		return { ok: false, code: 1, step: 'state', detail: state_result.detail, children };
	setup_log(ctx);
	log.event('notice', 'SERVICE_STARTED', { mode: snapshot.main.mode, node: node_id });
	// uloop.process children inherit open descriptors across exec; unlock explicitly so their
	// inherited references cannot extend the startup flock into the monitor phase.
	if (!locked.lock('u')) {
		let detail = `cannot release startup lock: ${fs.error() ?? 'unknown error'}`;
		locked.close();
		return { ok: false, code: 1, step: 'lock_release', detail, children };
	}
	locked.close();
	return { ok: true, children, state: initial_state, snapshot };
};

function stop_children(ctx, children) {
	let waiting = 0;
	for (let key in [ 'xray', 'dns' ])
		if (children?.[key] != null)
			waiting++;
	if (waiting == 0)
		return;
	let remaining = waiting;
	for (let key in [ 'xray', 'dns' ])
		if (children?.[key] != null)
			children[key].stop(() => {
				remaining--;
				if (remaining == 0)
					uloop.end();
			});
	if (remaining > 0)
		uloop.run();
};

function shutdown(ctx, children, normal_stop) {
	let failures = [];
	// TODO(design): 04 releases the startup lock in monitor mode but does not specify whether a
	// signal-driven stop waits for a one-shot command's lock or must clean immediately; shutdown
	// proceeds to honor the required best-effort cleanup order.
	if (ctx.monitor != null) {
		ctx.monitor.cancel();
		ctx.monitor = null;
	}
	let table = apply.nft_table_exists(ctx);
	if (table.ok && table.exists) {
		let exported = apply.sets_export(ctx);
		if (exported.ok) {
			let saved = apply.sets_save(ctx, exported.sets);
			if (!saved.ok)
				push(failures, `sets_save: ${saved.detail}`);
		}
		else
			push(failures, `sets_export: ${exported.detail}`);
	}
	else if (!table.ok)
		push(failures, `nft_table_exists: ${table.detail}`);
	let deleted = table.ok && table.exists ? apply.nft_delete(ctx) : { ok: true };
	if (!deleted.ok) push(failures, `nft_delete: ${deleted.detail}`);
	let routed = apply.route_del(ctx);
	if (!routed.ok) push(failures, `route_del: ${routed.detail}`);
	let dnsmasq = apply.dnsmasq_remove(ctx);
	if (!dnsmasq.ok) push(failures, `dnsmasq_remove: ${dnsmasq.detail}`);
	stop_children(ctx, children);
	remove_pidfiles(ctx);
	let saved = write_state(ctx, { state: 'stopped', dns_tier: 'T2', dns_failsafe: false, since: time() });
	if (!saved.ok)
		push(failures, saved.detail);
	if (normal_stop) {
		setup_log(ctx);
		log.event('notice', 'SERVICE_STOPPED', { mode: ctx.service_mode ?? '', node: ctx.service_node ?? '' });
	}
	return failures;
};

function run(args) {
	let parsed = parse_options(args, true);
	if (parsed.error) {
		warn(`daemon: ${parsed.error}\n`);
		return 2;
	}
	let opts = resolved_opts(parsed.opts);
	let ctx = make_context(opts, []);
	setup_log(ctx);
	if (!uloop.init()) {
		event_failure(ctx, 'uloop_init', 'cannot initialize uloop');
		return 1;
	}
	let signal = null, stopping = false;
	let signals = {};
	let monitor_daemon = null;
	let tick = () => monitor_daemon == null ? null : monitor.tick(monitor_daemon);
	let on_signal = () => signal == 'stop';
	for (let item in [ [ 'SIGTERM', 'stop' ], [ 'SIGINT', 'stop' ], [ 'SIGHUP', 'reload' ], [ 'SIGUSR1', 'tick' ] ]) {
		let name = item[0], kind = item[1];
		signals[kind + name] = uloop.signal(name, () => {
			if (signal == null)
				signal = kind;
			uloop.end();
		});
	}

	let result = start_sequence(ctx, opts, on_signal);
	let exit_code = 0;
	let current_children = result.children ?? { xray: null, dns: null };
	if (!result.ok) {
		if (result.lock_busy) {
			exit_code = 3;
		}
		else if (result.interrupted) {
			let rollback = shutdown(ctx, current_children, signal == 'stop');
			if (length(rollback))
				event_failure(ctx, 'stop', join('; ', rollback));
			exit_code = 0;
		}
		else if (!result.untouched) {
			let rollback = shutdown(ctx, current_children, false);
			if (length(rollback))
				result.detail += `; rollback: ${join('; ', rollback)}`;
			let failed_state = write_state(ctx, {
				state: 'error', dns_tier: 'T2', dns_failsafe: false, since: time(),
				last_error: 'START_FAILED', failed_step: result.step
			});
			if (!failed_state.ok)
				result.detail += `; ${failed_state.detail}`;
			setup_log(ctx);
			log.event('error', 'START_FAILED', { step: result.step, detail: result.detail });
			exit_code = result.code ?? 1;
		}
		else {
			if (result.step == 'config') {
				setup_log(ctx);
				let first = result.errors?.[0] ?? {};
				log.event('error', 'CONFIG_INVALID', { field: first.field ?? '-', reason: first.code ?? result.detail });
			}
			exit_code = result.code ?? 1;
		}
	}
	else {
		ctx.service_mode = result.snapshot.main.mode;
		ctx.service_node = result.snapshot.main.node;
		monitor_daemon = monitor.create_daemon({ ctx, opts, snapshot: result.snapshot, children: current_children, state: result.state });
		tick = () => monitor.tick(monitor_daemon);
		ctx.monitor = uloop.interval(monitor.interval_ms(monitor_daemon.machine), tick);
		monitor_daemon.interval = ctx.monitor;
		while (signal != 'stop') {
			if (signal == 'tick') {
				// T2.5 fills in the first observation pass.
				tick();
				signal = null;
				continue;
			}
			if (signal == 'reload') {
				signal = null;
				while (monitor_daemon?.busy)
					uloop.run(C.DAEMON_POLL_MS);
				// The monitor owns the live runtime (tier, node IP) and may have re-rendered current/
				// since startup, so plan against what is on disk, not the startup render_hash.
				let live = hash_artifacts(ctx, `${run_dir(ctx)}/${C.DAEMON_CURRENT_DIR}`);
				let base = { ...monitor_daemon.state, dns_tier: monitor_daemon.machine.dns_tier,
					node_ip: monitor_daemon.machine.node_ip ?? monitor_daemon.state.node_ip };
				if (live.ok)
					base.render_hash = live.hashes;
				let changed = reload.run({ ctx, opts, snapshot: monitor_daemon.snapshot, state: base, children: current_children });
				if (changed.stop) {
					stopping = true;
					let stop_errors = shutdown(ctx, current_children, true);
					if (length(stop_errors))
						event_failure(ctx, 'reload_stop', join('; ', stop_errors));
					exit_code = 0;
					signal = 'stop';
					break;
				}
				if (changed.ok) {
					result.snapshot = changed.snapshot;
					result.state = changed.state;
					ctx.service_mode = result.snapshot.main.mode;
					ctx.service_node = result.snapshot.main.node;
					monitor_daemon.snapshot = changed.snapshot;
					monitor_daemon.state = changed.state;
					monitor_daemon.machine.node_ip = changed.state.node_ip;
				}
				continue;
			}
			signal = null;
			uloop.run();
		}
		if (signal == 'stop' && !stopping) {
			while (monitor_daemon?.busy)
				uloop.run(C.DAEMON_POLL_MS);
			stopping = true;
			let stop_errors = shutdown(ctx, current_children, true);
			if (length(stop_errors))
				event_failure(ctx, 'stop', join('; ', stop_errors));
		}
	}
	for (let key, handler in signals)
		if (handler != null)
			handler.delete();
	uloop.done();
	return exit_code;
};

export { run, cleanup_run, parse_options };
