'use strict';
// Reference-driven planned-start gate, independent of monitor health (docs/04,
// T15.5). Only published artifacts and the fixed child generation authorize ready.
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as socket from 'socket';
import * as C from 'aetherproxy.const';
import * as net from 'aetherproxy.net';

function failure(detail) {
	return { ok: false, detail };
};

function networks(inbound) {
	return type(inbound?.settings) == 'object' && type(inbound.settings.network) == 'string'
		? split(inbound.settings.network, ',') : [];
};

function valid_inbound(inbound) {
	return inbound?.protocol == 'tunnel' && net.address_hex(inbound.listen) != null &&
		type(inbound.port) == 'int' && inbound.port > 0 && inbound.port <= 65535;
};

// xray_artifact is the exact JSON text read from published current, never a UCI
// snapshot. Tags identify roles, while addresses/ports come from the artifact.
export function requirements(chinadns_text, xray_artifact) {
	if (type(chinadns_text) != 'string' || type(xray_artifact) != 'string')
		return failure('missing published DNS/Xray artifact');
	let xray;
	try { xray = json(xray_artifact); }
	catch (e) { return failure(`invalid Xray JSON: ${e}`); }
	if (type(xray) != 'object' || type(xray.inbounds) != 'array')
		return failure('missing Xray inbounds');
	for (let inbound in xray.inbounds)
		if (type(inbound) != 'object' || type(inbound.tag) != 'string')
			return failure('invalid Xray inbound');
	let tproxy = filter(xray.inbounds, inbound => inbound.tag == C.TPROXY_IN_TAG);
	if (length(tproxy) != 1 || !valid_inbound(tproxy[0]) || index(networks(tproxy[0]), 'tcp') < 0)
		return failure('missing or invalid TPROXY inbound');
	let required = [ { address: tproxy[0].listen, port: tproxy[0].port, protocol: 'tcp', role: 'tproxy' } ];
	let tunnels = filter(xray.inbounds, inbound => index(inbound.tag ?? '', C.DNS_IN_TAG_PREFIX) == 0);
	for (let inbound in tunnels)
		if (!valid_inbound(inbound))
			return failure('invalid DNS tunnel inbound');
	let upstream_lines = 0;
	for (let line in split(chinadns_text, '\n')) {
		let value = trim(replace(line, /[[:space:]]+#.*$/, ''));
		let upstream = match(value, /^(china-dns|trust-dns|group-upstream)[[:space:]]+(.+)$/);
		if (upstream == null) {
			if (match(value, /^(china-dns|trust-dns|group-upstream)($|[[:space:]])/) != null)
				return failure('empty DNS upstream directive');
			continue;
		}
		upstream_lines++;
		for (let item in split(upstream[2], ',')) {
			let tuple = match(trim(item), /^((tcp|udp|tls):\/\/)?([^@]+@)?([0-9.]+)(#([0-9]+))?$/);
			if (tuple == null)
				return failure(`invalid DNS upstream: ${item}`);
			let protocol = tuple[2] ?? 'udp';
			let address = tuple[4];
			let default_port = protocol == 'tls' ? C.XRAY_READY_TLS_DEFAULT_PORT : C.XRAY_READY_DNS_DEFAULT_PORT;
			let port = +(tuple[6] ?? default_port);
			if (net.ipv4(address) == null || port < 1 || port > 65535)
				return failure(`invalid DNS endpoint: ${item}`);
			let candidates = filter(tunnels, inbound => inbound.port == port && inbound.listen == address);
			// Fixed known endpoints must fail even when a broken artifact removed the
			// corresponding tunnel. Dynamic test endpoints are recognized by the artifact.
			let known = address == C.DNS_TUNNEL_ADDR && index(C.DNS_TUNNEL_PORTS, port) >= 0;
			if (!known && !length(candidates))
				continue;
			let matching = filter(candidates, inbound => inbound.listen == address &&
				index(networks(inbound), protocol) >= 0);
			if (length(matching) != 1)
				return failure(`DNS reference has no matching tunnel: ${item}`);
			let duplicate = filter(required, r => r.address == address && r.port == port && r.protocol == protocol);
			if (!length(duplicate))
				push(required, { address, port, protocol, role: 'dns' });
		}
	}
	return upstream_lines > 0 ? { ok: true, required } : failure('DNS artifact has no upstream directives');
};

function now_ms() {
	let t = clock(true);
	return t == null ? null : t[0] * 1000 + t[1] / 1000000;
};

function proc_path(ctx, pid) {
	return replace(ctx.root ?? '', /\/$/, '') + C.PROC_DIR + '/' + pid;
};

function identity(path) {
	let text = fs.readfile(path + '/stat');
	let parsed = type(text) == 'string' ? match(text, /^[0-9]+ \(.*\) ([A-Z]) (.*)$/s) : null;
	if (parsed == null || index([ 'Z', 'X' ], parsed[1]) >= 0)
		return null;
	let fields = split(trim(parsed[2]), /[[:space:]]+/);
	return match(fields[18] ?? '', /^[0-9]+$/) != null ? fields[18] : null;
};

function cancelled(ctx, on_signal) {
	// Dispatch signals even when every required socket is already present. A queued
	// SIGTERM must beat ready, including at the deadline boundary.
	uloop.run(1);
	return ctx.stopping_requested || (on_signal != null && on_signal());
};

function inodes(path) {
	let names = fs.lsdir(path + '/fd');
	if (names == null)
		return null;
	let owned = {};
	for (let name in names) {
		let target = fs.readlink(path + '/fd/' + name);
		if (target == null)
			return null;
		let parsed = match(target, /^socket:\[([0-9]+)\]$/);
		if (parsed != null)
			owned[parsed[1]] = true;
	}
	return owned;
};

// Native Linux/OpenWrt assumes the process ABI and kernel use the same byte order;
// cross-endian emulation is outside this contract. Keep all I/O out of net's parser.
function native_byte_order(ctx) {
	let path = replace(ctx.root ?? '', /\/$/, '') + C.XRAY_READY_ELF_FILE;
	let file = fs.open(path, 'r');
	if (file == null)
		return failure(`cannot open ELF identity ${path}: ${fs.error() ?? 'unknown error'}`);
	let header = file.read(16);
	let read_error = header == null ? (fs.error() ?? 'unknown error') : null;
	// Close before validating, so short/bad headers and read errors share one FD
	// cleanup boundary. A failed close cannot be treated as a verified identity.
	if (!file.close())
		return failure(`cannot close ELF identity ${path}: ${fs.error() ?? 'unknown error'}`);
	if (header == null)
		return failure(`cannot read ELF identity ${path}: ${read_error}`);
	if (length(header) != 16)
		return failure('short ELF identification');
	if (substr(header, 0, 4) != chr(127) + 'ELF')
		return failure('invalid ELF magic');
	if (index([ 1, 2 ], ord(header, 4)) < 0)
		return failure('invalid ELF class');
	if (ord(header, 6) != 1)
		return failure('invalid ELF version');
	let data = ord(header, 5);
	if (index([ 1, 2 ], data) < 0)
		return failure('invalid ELF data encoding');
	return { ok: true, little_endian: data == 1 };
};

function table_snapshot(path, little_endian) {
	let rows = [];
	for (let protocol in [ 'tcp', 'udp' ])
		for (let suffix in [ '', '6' ]) {
			let parsed = net.socket_rows(fs.readfile(`${path}/net/${protocol}${suffix}`),
				suffix == '6', little_endian);
			if (!parsed.ok)
				return parsed;
			for (let row in parsed.rows)
				push(rows, { ...row, protocol });
		}
	return { ok: true, rows };
};

function tcp4_reachable(ctx, requirement, deadline) {
	// A fixture must never borrow a host listener to prove IPv6 dual-stack behavior.
	if ((ctx.root ?? '') != '')
		return false;
	let address = requirement.address == '0.0.0.0' ? C.DNS_TUNNEL_ADDR : requirement.address;
	// Current artifacts use wildcard TPROXY or loopback DNS. An unexpected artifact
	// must not turn the permitted local confirmation into a remote network probe.
	if (match(address, /^127\./) == null)
		return false;
	let sock = socket.create(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);
	if (sock == null)
		return false;
	let connected = sock.connect(address, requirement.port);
	if (!connected) {
		let remaining = max(0, min(C.DAEMON_POLL_MS, int(deadline - now_ms())));
		let result = socket.poll(remaining, [ sock, socket.POLLOUT | socket.POLLERR ]);
		connected = result != null && result[0][1] != 0 && sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0;
	}
	let closed = sock.close();
	return connected && closed;
};

function competing_tcp4(rows, candidate, requirement) {
	let wanted = net.address_hex(requirement.address == '0.0.0.0' ? C.DNS_TUNNEL_ADDR : requirement.address);
	for (let row in rows) {
		if (row.inode == candidate.inode || row.port != requirement.port ||
		    row.protocol != 'tcp' || row.state != '0A')
			continue;
		if (!row.ipv6 && (row.address == wanted || row.address == '00000000'))
			return true;
		if (row.ipv6 && (row.address == '00000000000000000000000000000000' ||
		    row.address == '00000000000000000000FFFF' + wanted))
			return true;
	}
	return false;
};

function satisfied(ctx, requirement, rows, owned, deadline) {
	let wanted = net.address_hex(requirement.address);
	for (let row in rows) {
		if (!owned[row.inode] || row.port != requirement.port || row.protocol != requirement.protocol)
			continue;
		if (row.protocol == 'tcp' && row.state != '0A')
			continue;
		if (row.protocol == 'udp' && index([ '07', '01' ], row.state) < 0)
			continue;
		let wildcard = row.ipv6 ? '00000000000000000000000000000000' : '00000000';
		if (length(wanted) == length(row.address)) {
			if (row.address == wanted || row.address == wildcard)
				return true;
		}
		else if (length(wanted) == 8 && row.ipv6) {
			if (row.address == '00000000000000000000FFFF' + wanted)
				return true;
			// Otherwise a v6-only child plus somebody else's IPv4 listener could
			// make the local connect succeed without proving this inode is dual-stack.
			if (row.address == wildcard && row.protocol == 'tcp' &&
			    !competing_tcp4(rows, row, requirement) && tcp4_reachable(ctx, requirement, deadline))
				return true;
		}
	}
	return false;
};

export function wait(ctx, child, required, on_signal) {
	let start = now_ms(), pid = child?.pid();
	if (start == null || type(pid) != 'int' || pid <= 0 || type(required) != 'array' || !length(required))
		return failure('invalid child or readiness requirements');
	let path = proc_path(ctx, pid), generation = identity(path);
	let deadline = start + C.DAEMON_PORT_WAIT_SECS * 1000;
	if (cancelled(ctx, on_signal))
		return { ok: false, cancelled: true, detail: 'Xray readiness cancelled' };
	let byte_order = native_byte_order(ctx);
	if (cancelled(ctx, on_signal))
		return { ok: false, cancelled: true, detail: 'Xray readiness cancelled' };
	if (now_ms() >= deadline)
		return failure('Xray required sockets not ready within 5 seconds');
	if (!byte_order.ok)
		return byte_order;
	while (true) {
		if (cancelled(ctx, on_signal))
			return { ok: false, cancelled: true, detail: 'Xray readiness cancelled' };
		let observed = identity(path);
		if (child.pid() != pid || (generation != null && observed != generation))
			return failure('Xray child exited or changed generation');
		// An initially unreadable rooted proc fixture is not-ready, never a reason
		// to borrow host proc. Once verified, loss/change of identity is terminal.
		generation ??= observed;
		let owned = inodes(path), tables = table_snapshot(path, byte_order.little_endian);
		let ready = generation != null && owned != null && tables.ok;
		if (ready)
			for (let requirement in required)
				if (!satisfied(ctx, requirement, tables.rows, owned, deadline))
					ready = false;
		if (cancelled(ctx, on_signal))
			return { ok: false, cancelled: true, detail: 'Xray readiness cancelled' };
		if (child.pid() != pid || (generation != null && identity(path) != generation))
			return failure('Xray child exited or changed generation');
		if (now_ms() >= deadline)
			return failure('Xray required sockets not ready within 5 seconds');
		if (ready)
			return { ok: true };
		uloop.run(min(C.DAEMON_POLL_MS, max(1, int(deadline - now_ms()))));
	}
};

// Every caller (including rollback) reads current afresh; no requirement cache can
// accidentally cross generations. ctx.root applies equally to artifacts and proc.
export function published(ctx, child, on_signal) {
	let dir = replace(ctx.root ?? '', /\/$/, '') + (ctx.run_dir ?? C.RUN_DIR) + '/' + C.DAEMON_CURRENT_DIR;
	let result = requirements(fs.readfile(`${dir}/${C.ARTIFACT_FILES.chinadns}`),
		fs.readfile(`${dir}/${C.ARTIFACT_FILES.xray}`));
	return result.ok ? wait(ctx, child, result.required, on_signal) : result;
};
