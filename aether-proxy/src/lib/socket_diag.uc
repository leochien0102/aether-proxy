'use strict';
// Minimal TCPv6 INET_DIAG evidence for T15.7; not a health probe or a generic
// netlink framework. The caller retains PID/starttime and FD ownership authority.
import * as socket from 'socket';
import * as C from 'aetherproxy.const';

function failure(detail) {
	return { ok: false, detail: 'socket diag: ' + detail };
};

function uint(text, offset, size, little) {
	let value = 0;
	for (let i = 0; i < size; i++)
		value = value * 256 + ord(text, offset + (little ? size - 1 - i : i));
	return value;
};

function bytes(value, size, little) {
	let out = '';
	for (let i = 0; i < size; i++) {
		let b = chr(value % 256);
		out = little ? out + b : b + out;
		value = int(value / 256);
	}
	return out;
};

function compatible(errno) {
	// errno numbers differ on Linux architectures (notably MIPS). Resolve
	// through the existing native module rather than assuming asm-generic IDs.
	return index(C.SOCKET_DIAG.compatible_errors, socket.strerror(errno)) >= 0;
};

// SOCK_DIAG_BY_FAMILY, dump TCP LISTEN with a source-port filter. The cookie
// is INET_DIAG_NOCOOKIE; every returned tuple/inode is still checked explicitly.
export function request(row, seq, little) {
	let body = chr(socket.AF_INET6) + chr(C.SOCKET_DIAG.tcp) + chr(0) + chr(0) +
		bytes(1 << C.SOCKET_DIAG.listen, 4, little) + bytes(row.port, 2, false);
	while (length(body) < 48)
		body += chr(0);
	body += bytes(0xffffffff, 4, little) + bytes(0xffffffff, 4, little);
	return bytes(16 + length(body), 4, little) + bytes(C.SOCKET_DIAG.by_family, 2, little) +
		bytes(C.SOCKET_DIAG.request_dump, 2, little) + bytes(seq, 4, little) + bytes(0, 4, little) + body;
};

function record(text, row, little) {
	if (length(text) < 72)
		return failure('short inet_diag_msg');
	let address = '';
	for (let i = 8; i < 24; i++)
		address += sprintf('%02X', ord(text, i));
	if (ord(text, 0) != socket.AF_INET6 || ord(text, 1) != C.SOCKET_DIAG.listen ||
	    uint(text, 4, 2, false) != row.port)
		return failure('family/state/port mismatch');
	if (address != row.address || `${uint(text, 68, 4, little)}` != row.inode)
		return failure('address/inode mismatch');
	// A LISTEN reply must not smuggle a connected peer tuple.
	for (let i = 24; i < 40; i++)
		if (ord(text, i) != 0)
			return failure('nonzero listener peer');
	if (uint(text, 6, 2, false) != 0)
		return failure('nonzero listener peer port');
	let v6only = null, protocol = null;
	for (let at = 72; at < length(text);) {
		if (length(text) - at < 4)
			return failure('short attribute header');
		let size = uint(text, at, 2, little), kind = uint(text, at + 2, 2, little);
		let aligned = (size + 3) & ~3;
		if (size < 4 || at + aligned > length(text))
			return failure('invalid attribute length/alignment');
		let base_kind = kind & 0x3fff;
		if (base_kind == C.SOCKET_DIAG.v6only || base_kind == C.SOCKET_DIAG.protocol) {
			if (size != 5 || kind != base_kind)
				return failure('invalid scalar attribute');
			let value = ord(text, at + 4);
			if (kind == C.SOCKET_DIAG.v6only) {
				if (v6only != null || value > 1)
					return failure('duplicate/invalid v6only attribute');
				v6only = value;
			}
			else {
				if (protocol != null || value != C.SOCKET_DIAG.tcp)
					return failure('duplicate/incorrect protocol attribute');
				protocol = value;
			}
		}
		at += aligned;
	}
	return { ok: true, v6only };
};

// Pure incremental decoder shared by the real transport and wire-fault tests.
// No result (including missing attribute) is authorized before a clean DONE.
export function consume(state, text, row, seq, little) {
	if (type(little) != 'bool' || type(text) != 'string' || length(text) < 16 || state.done)
		return failure('invalid datagram/state/byte order');
	for (let at = 0; at < length(text);) {
		if (length(text) - at < 16 || state.done)
			return failure('short header or data after DONE');
		let size = uint(text, at, 4, little), aligned = (size + 3) & ~3;
		let kind = uint(text, at + 4, 2, little), flags = uint(text, at + 6, 2, little);
		if (size < 16 || at + aligned > length(text))
			return failure('invalid message length/alignment');
		if (uint(text, at + 8, 4, little) != seq)
			return failure('sequence mismatch');
		// nlmsg_pid may be the requesting port ID, not zero. This private socket
		// has one request, and its explicit sequence associates the whole dump.
		if (flags & C.SOCKET_DIAG.dump_intr)
			return failure('interrupted dump');
		let payload = substr(text, at + 16, size - 16);
		if (kind == C.SOCKET_DIAG.error) {
			let original = request(row, seq, little);
			if (length(payload) < 20 || substr(payload, 4, 16) != substr(original, 0, 16))
				return failure('invalid error request association');
			// NLM_F_CAPPED permits only the echoed header. Otherwise require the
			// echoed tuple as well; malformed errors are not capability evidence.
			let echoed_size = (flags & C.SOCKET_DIAG.capped) ? 20 : 76;
			if (length(payload) != echoed_size ||
			    (!(flags & C.SOCKET_DIAG.capped) && substr(payload, 4, 72) != original))
				return failure('invalid error request body/extensions');
			let code = uint(payload, 0, 4, little);
			let errno = code > 0x7fffffff ? 0x100000000 - code : 0;
			if (!errno || !compatible(errno) || state.seen)
				return failure('netlink error/ack');
			state.done = true;
			state.fallback = true;
		}
		else if (kind == C.SOCKET_DIAG.done) {
			if (!(flags & C.SOCKET_DIAG.multi) || length(payload) != 4 || uint(payload, 0, 4, little) != 0)
				return failure('invalid dump completion');
			if (!state.seen)
				return failure('no matching socket record');
			state.done = true;
		}
		else if (kind == C.SOCKET_DIAG.by_family) {
			if (!(flags & C.SOCKET_DIAG.multi) || state.seen)
				return failure('non-multipart/duplicate socket record');
			let parsed = record(payload, row, little);
			if (!parsed.ok)
				return parsed;
			state.seen = true;
			state.v6only = parsed.v6only;
		}
		else
			return failure('unexpected message type');
		at += aligned;
	}
	return { ok: true };
};

function now_ms() {
	let t = clock(true);
	return t[0] * 1000 + t[1] / 1000000;
};

function exchange(sock, row, little, deadline, stopped) {
	let seq = 1; // One request on a fresh private socket; no shared sequence space.
	let wire = request(row, seq, little);
	if (stopped() || now_ms() >= deadline)
		return failure('cancelled or budget exhausted');
	if (sock.send(wire) != length(wire)) {
		let errno = socket.error(true);
		return compatible(errno) ? { ok: true, fallback: true } : failure(`send failed (${errno})`);
	}
	let state = {};
	while (!state.done) {
		if (stopped())
			return failure('cancelled');
		let left = int(deadline - now_ms());
		if (left <= 0)
			return failure('budget exhausted');
		let polled = socket.poll(min(C.DAEMON_POLL_MS, left), [ sock, socket.POLLIN ]);
		if (polled == null)
			return failure('poll failed');
		if (stopped())
			return failure('cancelled');
		if (!polled[0][1])
			continue;
		let msg = sock.recvmsg(C.SOCKET_DIAG.max_datagram, 0);
		if (msg == null)
			return failure('receive failed');
		if (msg.flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC) || msg.length != length(msg.data))
			return failure('truncated datagram');
		let parsed = consume(state, msg.data, row, seq, little);
		if (!parsed.ok)
			return parsed;
	}
	return { ok: true, fallback: state.fallback || state.v6only == null, dual_stack: state.v6only == 0 };
};

export function query(ctx, row, little, deadline, stopped) {
	// Rooted proc fixtures cannot borrow host kernel evidence or active connects.
	if ((ctx.root ?? '') != '')
		return failure('rooted fixture has no native diag evidence');
	if (stopped() || now_ms() >= deadline)
		return failure('cancelled or budget exhausted');
	let sock = socket.create(C.SOCKET_DIAG.family, socket.SOCK_RAW | socket.SOCK_NONBLOCK | socket.SOCK_CLOEXEC,
		C.SOCKET_DIAG.netlink_protocol);
	if (sock == null) {
		let errno = socket.error(true);
		return compatible(errno) ? { ok: true, fallback: true } : failure(`create failed (${errno})`);
	}
	let result = exchange(sock, row, little, deadline, stopped);
	if (!sock.close())
		return failure('close failed');
	return result;
};
