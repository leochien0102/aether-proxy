'use strict';
// Isolated startup DNS resources (docs/tasks/m15 T15.6, revision 8e4d6a2).
// A real exit callback authorizes deletion. Historical/orphan PIDs are never signalled:
// uncertain residue trades availability for evidence, not for guessed ownership.
import * as fs from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as net from 'aetherproxy.net';
import * as apply from 'aetherproxy.apply';
import * as supervise from 'aetherproxy.supervise';
import * as ready from 'aetherproxy.xray_ready';
import * as chinadns from 'aetherproxy.render.chinadns';

function failure(detail, extra) {
	return { ok: false, detail, ...(extra ?? {}) };
};

function now_ms() {
	let t = clock(true);
	return t == null ? null : t[0] * 1000 + t[1] / 1000000;
};

function resource_run_dir(ctx) {
	return replace(ctx.root ?? '', /\/$/, '') + (ctx.run_dir ?? C.RUN_DIR);
};

function directory(ctx) {
	return resource_run_dir(ctx) + '/' + C.BOOTSTRAP_SUBDIR;
};

function cancelled(ctx, on_signal) {
	uloop.run(1);
	return ctx.stopping_requested || (on_signal != null && on_signal());
};

function fingerprint(path) {
	let st = fs.stat(path);
	return st == null ? null : { inode: st.inode, major: st.dev.major, minor: st.dev.minor, uid: st.uid };
};

function same_file(a, b) {
	return a != null && b != null && a.inode == b.inode && a.major == b.major && a.minor == b.minor && a.uid == b.uid;
};

// Lifecycle identity always concerns our real child, like supervise, not synthetic
// socket tables. Only ready.wait uses ctx.root's complete proc/ELF fixture.
function process_info(pid) {
	let base = `${C.PROC_DIR}/${pid}`;
	let text = fs.readfile(base + '/stat');
	if (text == null)
		return fs.error() == 'No such file or directory' ? { gone: true } : null;
	let m = match(text, /^[0-9]+ \(.*\) ([A-Z]) (.*)$/s);
	if (m == null)
		return null;
	let fields = split(trim(m[2]), /[[:space:]]+/);
	if (match(fields[18] ?? '', /^[0-9]+$/) == null)
		return null;
	let argv = fs.readfile(base + '/cmdline');
	return { pid, starttime: fields[18], gone: index([ 'Z', 'X' ], m[1]) >= 0,
		argv: argv == null ? null : split(replace(argv, /\x00$/, ''), '\x00'),
		exe: fingerprint(base + '/exe') };
};

// Pure minimal config; no ordinary lists, default upstreams, sets or handoff.
export function render(snapshot, endpoint) {
	let upstreams = join(',', chinadns.boot_upstreams(snapshot));
	return join('\n', [ `bind-addr ${endpoint.address}`, `bind-port ${endpoint.port}`,
		`china-dns ${upstreams}`, `trust-dns ${upstreams}`, 'default-tag gfw',
		'ipset-name4 null', 'ipset-name6 null', 'cache 0', '' ]);
};

function make_parent(ctx) {
	let path = directory(ctx);
	let st = fs.lstat(path);
	if (st == null) {
		let base = substr(path, 0, length(path) - length(C.BOOTSTRAP_SUBDIR));
		if (fs.error() != 'No such file or directory' || !sys.mkdir_p(base))
			return failure(`cannot prepare bootstrap parent: ${sys.error() ?? fs.error()}`);
		if (!fs.mkdir(path, 0700))
			return failure(`cannot create ${path}: ${fs.error()}`);
		st = fs.lstat(path);
	}
	if (st?.type != 'directory' || st.mode != 0700)
		return failure(`unsafe bootstrap directory ${path}`);
	return { ok: true, path };
};

function nonce() {
	let fp = fs.open(C.RANDOM_DEVICE, 'r');
	if (fp == null)
		return null;
	let bytes = fp.read(16), closed = fp.close();
	if (!closed || bytes == null || length(bytes) != 16)
		return null;
	let value = '';
	for (let i = 0; i < 16; i++)
		value += sprintf('%02x', ord(bytes, i));
	return value;
};

function save_record(handle) {
	let text = sprintf('%.J\n', handle.record);
	let path = handle.path + '/' + C.BOOTSTRAP_RECORD;
	if (!sys.write_atomic(path, text) || fs.readfile(path) != text)
		return failure(`cannot publish bootstrap identity ${path}: ${sys.error() ?? fs.error()}`);
	return { ok: true };
};

function remove_owned(handle, inspect_only) {
	if (!same_file(fingerprint(handle.path), handle.record.directory))
		return failure(`bootstrap directory identity changed: ${handle.path}`);
	let config = handle.path + '/' + C.BOOTSTRAP_CONFIG;
	if (fs.lstat(config) != null && fs.readfile(config) != handle.record.config_text)
		return failure(`modified bootstrap config retained: ${config}`);
	let pidfile = handle.path + '/' + C.BOOTSTRAP_CHILD + '.pid';
	if (fs.lstat(pidfile)?.type == 'file' &&
	    trim(fs.readfile(pidfile) ?? '') != `${handle.record.process?.pid}`)
		return failure(`inconsistent bootstrap PID file retained: ${pidfile}`);
	let names = fs.lsdir(handle.path);
	if (names == null)
		return failure(`cannot enumerate ${handle.path}: ${fs.error()}`);
	let allowed = handle.record.files;
	// Atomic-write residues belong to this recorded writer only; no recursive rm.
	for (let name in names) {
		let ordinary = index(allowed, name) >= 0;
		let temporary = false;
		for (let base in allowed)
			if (name == `${base}.tmp.${handle.record.parent.pid}`)
				temporary = true;
		let st = fs.lstat(`${handle.path}/${name}`);
		if ((!ordinary && !temporary) || st?.type != 'file' || st.mode != 0600)
			return failure(`unowned bootstrap entry retained: ${handle.path}/${name}`);
	}
	if (inspect_only)
		return { ok: true };
	// Keep the identity until all other entries have been removed successfully.
	for (let name in names) {
		if (name == C.BOOTSTRAP_RECORD)
			continue;
		if (!fs.unlink(`${handle.path}/${name}`))
			return failure(`cannot remove ${handle.path}/${name}: ${fs.error()}`);
	}
	let record = handle.path + '/' + C.BOOTSTRAP_RECORD;
	if (fs.lstat(record) != null && !fs.unlink(record))
		return failure(`cannot remove ${record}: ${fs.error()}`);
	if (!fs.rmdir(handle.path))
		return failure(`cannot remove ${handle.path}: ${fs.error()}`);
	handle.cleaned = true;
	return { ok: true };
};

export function stop(handle) {
	if (handle == null || handle.cleaned)
		return { ok: true };
	if (handle.child != null) {
		if (!handle.stop_requested) {
			handle.stop_requested = true;
			handle.child.stop(() => { handle.reaped = true; });
		}
		let now = now_ms();
		let deadline = now == null ? null : now + C.BOOTSTRAP_STOP_MS;
		while (!handle.reaped && now != null && now < deadline) {
			uloop.run(min(C.DAEMON_POLL_MS, max(1, int(deadline - now))));
			now = now_ms();
		}
		if (!handle.reaped)
			return failure(`bootstrap exit unconfirmed; retained ${handle.path}`, { cleanup_failed: true });
	}
	let removed = remove_owned(handle);
	if (removed.ok)
		handle.child = null;
	return removed.ok ? removed : { ...removed, cleanup_failed: true };
};

function validate_record(path, record) {
	if (type(record) != 'object' || record.version != 1 || record.path != path)
		return false;
	if (type(record.parent?.pid) != 'int' || type(record.boot_id) != 'string')
		return false;
	if (match(record.boot_id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) == null)
		return false;
	if (record.parent.pid <= 0 || match(record.parent.starttime ?? '', /^[0-9]+$/) == null)
		return false;
	if (type(record.parent.argv) != 'array' || type(record.parent.exe?.inode) != 'int')
		return false;
	if (type(record.config_text) != 'string' || type(record.engine?.inode) != 'int')
		return false;
	let expected = [ C.BOOTSTRAP_CONFIG, C.BOOTSTRAP_RECORD, C.BOOTSTRAP_CHILD + '.pid' ];
	if (type(record.files) != 'array' || sprintf('%J', record.files) != sprintf('%J', expected))
		return false;
	if (!same_file(fingerprint(path), record.directory) ||
	    type(record.argv) != 'array' || length(record.argv) != 3)
		return false;
	return record.argv[1] == '-C' && record.argv[2] == path + '/' + C.BOOTSTRAP_CONFIG &&
		type(record.argv[0]) == 'string' && record.argv[0] != '';
};

// Never signal historical PIDs, even if all observable identity fields match.
// A prepared record without PID is intentionally not evidence of no live child.
export function recover(ctx, inspect_only) {
	for (let handle in ctx.bootstrap_handles ?? []) {
		let stopped = stop(handle);
		if (!stopped.ok)
			return stopped;
	}
	ctx.bootstrap_handles = [];
	let parent = directory(ctx);
	if (fs.lstat(parent) == null)
		return fs.error() == 'No such file or directory' ? { ok: true } : failure(`cannot stat ${parent}: ${fs.error()}`);
	if (fs.lstat(parent)?.type != 'directory' || fs.lstat(parent)?.mode != 0700)
		return failure(`unsafe bootstrap parent ${parent}`);
	let boot_id = trim(fs.readfile(C.BOOTSTRAP_BOOT_ID) ?? '');
	if (boot_id == '')
		return failure('cannot verify bootstrap boot identity');
	let names = fs.lsdir(parent);
	if (names == null)
		return failure(`cannot enumerate ${parent}: ${fs.error()}`);
	for (let name in names) {
		let path = parent + '/' + name;
		if (match(name, /^[0-9a-f]{32}$/) == null || fs.lstat(path)?.type != 'directory' || fs.lstat(path)?.mode != 0700)
			return failure(`unknown bootstrap residue retained: ${path}`);
		let record_stat = fs.lstat(path + '/' + C.BOOTSTRAP_RECORD);
		if (record_stat?.type != 'file' || record_stat.mode != 0600)
			return failure(`missing or unsafe bootstrap record retained: ${path}`);
		let record;
		try { record = json(fs.readfile(path + '/' + C.BOOTSTRAP_RECORD) ?? 'null'); }
		catch (e) { return failure(`corrupt bootstrap identity retained: ${path}: ${e}`); }
		if (!validate_record(path, record))
			return failure(`incomplete bootstrap identity retained: ${path}`);
		if (type(record.process?.pid) != 'int' || record.process.pid <= 0 ||
		    match(record.process.starttime ?? '', /^[0-9]+$/) == null ||
		    type(record.process.exe?.inode) != 'int' || type(record.process.argv) != 'array')
			return failure(`bootstrap PID publication uncertain; retained ${path}`);
		let observed = process_info(record.process.pid);
		if (observed == null)
			return failure(`bootstrap lifecycle unreadable; retained ${path}`);
		let old_boot = boot_id != record.boot_id;
		let gone = observed.gone || old_boot || observed.starttime != record.process.starttime;
		if (!gone)
			return failure(`bootstrap old lifecycle still executing; retained ${path}`);
		// Even an inconsistent/reused PID must not cause deletion of a config it
		// demonstrably still uses. Retain ambiguous evidence instead of guessing.
		if (!observed.gone && index(observed.argv ?? [], record.argv[2]) >= 0)
			return failure(`bootstrap config still in use with inconsistent identity: ${path}`);
		let removed = remove_owned({ path, record }, inspect_only);
		if (!removed.ok)
			return removed;
	}
	return { ok: true };
};

function candidate() {
	let udp = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (udp == null)
		return failure('cannot allocate private UDP socket');
	let bound = udp.bind({ address: C.DNS_TUNNEL_ADDR, port: 0 });
	let endpoint = bound ? udp.sockname() : null;
	let tcp = socket.create(socket.AF_INET, socket.SOCK_STREAM);
	let tcp_bound = endpoint != null && tcp != null && tcp.bind({ address: C.DNS_TUNNEL_ADDR, port: endpoint.port });
	let error = tcp_bound ? null : socket.error(true);
	let closed = udp.close();
	if (tcp != null && !tcp.close())
		closed = false;
	if (!closed)
		return failure('cannot close private allocation sockets', { fatal: true });
	if (!tcp_bound)
		return failure('cannot allocate private UDP/TCP candidate',
			{ retry_candidate: error == C.BOOTSTRAP_EADDRINUSE, fatal: error != C.BOOTSTRAP_EADDRINUSE });
	let excluded = [ C.DNS_PORT, C.CHINADNS_PORT, C.TPROXY_PORT, C.HTTP_PORT, ...C.DNS_TUNNEL_PORTS ];
	return index(excluded, endpoint.port) >= 0 ? failure('kernel selected reserved port', { retry_candidate: true }) :
		{ ok: true, endpoint: { address: C.DNS_TUNNEL_ADDR, port: endpoint.port } };
};

function occupied(endpoint) {
	let conflict = false;
	for (let kind in [ socket.SOCK_DGRAM, socket.SOCK_STREAM ]) {
		let sock = socket.create(socket.AF_INET, kind);
		if (sock == null)
			return failure('cannot inspect private port competition');
		let bound = sock.bind(endpoint);
		let error = bound ? null : socket.error(true);
		if (!sock.close())
			return failure('cannot close port competition socket');
		if (!bound && error != C.BOOTSTRAP_EADDRINUSE)
			return failure(`private port bind failed (${error})`);
		conflict ||= !bound;
	}
	return { ok: true, occupied: conflict };
};

function prepare(ctx, snapshot, engine, endpoint) {
	let parent = make_parent(ctx), id = nonce();
	if (!parent.ok || id == null)
		return failure(parent.detail ?? 'cannot obtain private generation entropy', { fatal: true });
	let path = parent.path + '/' + id;
	if (!fs.mkdir(path, 0700))
		return failure(`cannot create ${path}: ${fs.error()}`, { fatal: true });
	let self = +fs.readlink(C.PROC_DIR + '/self');
	let config_text = render(snapshot, endpoint);
	let files = [ C.BOOTSTRAP_CONFIG, C.BOOTSTRAP_RECORD, C.BOOTSTRAP_CHILD + '.pid' ];
	let handle = { path, endpoint, child: null, reaped: false, cleaned: false,
		owned_paths: map(files, name => path + '/' + name),
		record: { version: 1, path, files, directory: fingerprint(path), parent: process_info(self),
			engine: fingerprint(engine), config_text,
			boot_id: trim(fs.readfile(C.BOOTSTRAP_BOOT_ID) ?? ''),
			argv: [ engine, '-C', path + '/' + C.BOOTSTRAP_CONFIG ], process: null } };
	// Register before any subsequent failure/dispatch. A failed prepared write is
	// still recoverable by this live handle, never by an invented historical PID.
	ctx.bootstrap_handles ??= [];
	push(ctx.bootstrap_handles, handle);
	if (handle.record.parent?.starttime == null || handle.record.engine == null || handle.record.boot_id == '' ||
	    !sys.write_atomic(handle.record.argv[2], config_text))
		return failure(`cannot prepare bootstrap configuration: ${sys.error() ?? fs.error()}`, { handle, fatal: true });
	let saved = save_record(handle);
	return saved.ok ? { ok: true, handle } : { ...saved, handle, fatal: true };
};

function unwind(handle, result) {
	let stopped = stop(handle);
	return stopped.ok ? result : { ...stopped, fatal: true, cleanup_failed: true };
};

export function start(ctx, snapshot, engine, on_signal) {
	log.set_run_dir(resource_run_dir(ctx));
	let residue = recover(ctx);
	if (!residue.ok)
		return { ...residue, fatal: true, cleanup_failed: true };
	let started = now_ms();
	if (started == null)
		return failure('monotonic bootstrap clock unavailable', { fatal: true });
	let deadline = started + C.BOOTSTRAP_START_MS;
	for (let attempt = 0; attempt < C.BOOTSTRAP_CANDIDATES; attempt++) {
		if (cancelled(ctx, on_signal))
			return failure('bootstrap cancelled', { cancelled: true });
		if (now_ms() == null || now_ms() >= deadline)
			break;
		let selected = candidate();
		if (!selected.ok) {
			if (selected.retry_candidate)
				continue;
			return { ...selected, fatal: true };
		}
		let prepared = prepare(ctx, snapshot, engine, selected.endpoint);
		let h = prepared.handle;
		if (!prepared.ok)
			return h == null ? prepared : unwind(h, prepared);
		if (cancelled(ctx, on_signal) || now_ms() >= deadline)
			return unwind(h, failure('bootstrap cancelled or start deadline expired',
				{ cancelled: ctx.stopping_requested || (on_signal != null && on_signal()) }));
		h.child = supervise.create({ name: C.BOOTSTRAP_CHILD, argv: h.record.argv,
			run_dir: h.path, backoff: [ 0 ], respawn: false, inherit_output: true });
		h.child.start();
		let pid = h.child.pid();
		if (pid == null || h.child.error() != null)
			return unwind(h, failure(h.child.error() ?? 'bootstrap fork failed', { fatal: true }));
		let process = process_info(pid);
		if (process == null || process.gone || process.exe == null || process.argv == null) {
			let ended = stop(h);
			if (!ended.ok)
				return { ...ended, fatal: true, cleanup_failed: true };
			let competition = occupied(h.endpoint);
			if (!competition.ok)
				return { ...competition, fatal: true };
			if (competition.occupied)
				continue;
			return failure('bootstrap exited before identity publication', { fatal: true });
		}
		h.record.process = process;
		let saved = save_record(h);
		if (!saved.ok)
			return unwind(h, { ...saved, fatal: true });
		let left = int(deadline - now_ms());
		let requirements = map([ 'udp', 'tcp' ], protocol => ({ ...h.endpoint, protocol, role: 'bootstrap' }));
		let listening = left < 1 ? failure('bootstrap start deadline expired') :
			ready.wait(ctx, h.child, requirements, on_signal, { timeout_ms: left, label: 'bootstrap' });
		if (listening.ok) {
			let executing = process_info(pid);
			if (executing == null || executing.gone || executing.exe == null ||
			    executing.argv == null || executing.starttime != process.starttime)
				return unwind(h, failure('bootstrap changed lifecycle after readiness', { fatal: true }));
			h.record.process = executing;
			let updated = save_record(h);
			if (!updated.ok)
				return unwind(h, { ...updated, fatal: true });
			if (cancelled(ctx, on_signal))
				return unwind(h, failure('bootstrap cancelled', { cancelled: true }));
			return { ok: true, handle: h, endpoint: h.endpoint };
		}
		let failed_early = h.child.exited();
		let stopped = stop(h);
		if (!stopped.ok)
			return { ...stopped, fatal: true, cleanup_failed: true };
		if (listening.cancelled || cancelled(ctx, on_signal))
			return failure('bootstrap cancelled', { cancelled: true });
		// EADDRINUSE from a fresh bind after our child was really reaped is
		// positive competition evidence. No other start failure gets a new child.
		let competition = occupied(h.endpoint);
		if (!competition.ok)
			return { ...competition, fatal: true };
		if (!competition.occupied)
			return { ...listening, fatal: failed_early };
	}
	return failure('private candidate/start budget exhausted');
};

export function resolve(ctx, snapshot, engine, on_signal) {
	let address = snapshot.nodes?.[snapshot.main.node]?.address;
	if (cancelled(ctx, on_signal))
		return failure('bootstrap cancelled', { cancelled: true });
	if (net.ipv4(address) != null)
		return apply.resolve_node_explicit(ctx, address, null, on_signal);
	let begun = start(ctx, snapshot, engine, on_signal);
	if (!begun.ok) {
		if (begun.cancelled || begun.fatal || begun.cleanup_failed)
			return begun;
		if (cancelled(ctx, on_signal))
			return failure('bootstrap cancelled', { cancelled: true });
		return apply.resolve_node_failed(ctx, address);
	}
	let pid = begun.handle.child.pid(), generation = begun.handle.record.process.starttime;
	let lost = false;
	function query_cancelled() {
		let observed = process_info(pid);
		lost ||= observed == null || observed.gone || observed.starttime != generation ||
			begun.handle.child.pid() != pid;
		return lost || ctx.stopping_requested || (on_signal != null && on_signal());
	};
	// The endpoint must not silently become somebody else's resolver between B1
	// retries after our child exits. Abort this attempt, never query an impostor.
	let result = apply.resolve_node_explicit(ctx, address, begun.endpoint, query_cancelled);
	query_cancelled();
	let stopped = stop(begun.handle);
	if (!stopped.ok)
		return { ...stopped, fatal: true, cleanup_failed: true };
	if (cancelled(ctx, on_signal))
		return failure('bootstrap cancelled', { cancelled: true });
	if (lost)
		return failure('private child lost during resolution', { fatal: true });
	return result;
};
