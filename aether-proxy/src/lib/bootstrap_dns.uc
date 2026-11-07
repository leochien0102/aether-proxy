'use strict';

// Explicit private endpoint A/IN queries (docs/03, T15.4). No system resolver,
// child or cache: one lookup owns its deadline, CNAME history and socket lifetime.
import * as socket from 'socket';
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as net from 'aetherproxy.net';
import * as C from 'aetherproxy.const';

const EINTR = 4;
const EAGAIN = 11;
const EALREADY = 114;
const EINPROGRESS = 115;

function failure(detail) {
	return { ok: false, detail };
}

function now_ms() {
	let t = clock(true);
	return t == null ? null : t[0] * 1000 + t[1] / 1000000;
}

// Also used before apply's retry/LKG boundary: invalid requests are not DNS failures.
export function validate(domain, endpoint, timeout_ms) {
	if (type(domain) != 'string' || net.domain(domain) == null)
		return failure('invalid domain');
	if (type(endpoint) != 'object' || endpoint.address != C.DNS_TUNNEL_ADDR)
		return failure('endpoint must be explicit IPv4 loopback');
	let port = endpoint.port;
	if (type(port) != 'int' || port < 1 || port > 65535)
		return failure('invalid endpoint port');
	if (port == C.DNS_PORT || port == C.CHINADNS_PORT || index(C.DNS_TUNNEL_PORTS, port) >= 0)
		return failure('reserved endpoint port');
	if (timeout_ms != null && (type(timeout_ms) != 'int' || timeout_ms < 1 ||
		timeout_ms > C.BOOTSTRAP_DNS_TIMEOUT_MS))
		return failure('invalid timeout');
	return { ok: true };
};

function check(s) {
	// Signal callbacks belong to the caller's existing uloop. Dispatch periodically,
	// including during parsing; polling the callback alone cannot deliver SIGTERM.
	let now = now_ms();
	if (s.on_signal != null) {
		if (now != null && now >= s.dispatch_at) {
			uloop.run(1);
			s.dispatch_at = now + 10;
		}
		if (s.on_signal()) {
			s.error = { ok: false, detail: 'cancelled', cancelled: true };
			return false;
		}
	}
	now = now_ms();
	if (now == null || now >= s.deadline) {
		s.error = failure('lookup deadline exceeded');
		return false;
	}
	return true;
}

function word(n) {
	return chr((n >> 8) & 255) + chr(n & 255);
}

function u16(data, at) {
	return ord(data, at) * 256 + ord(data, at + 1);
}

function random_id() {
	let fp = fs.open(C.RANDOM_DEVICE, 'r');
	if (fp == null)
		return failure(`open random device: ${fs.error() ?? 'unknown error'}`);
	let bytes = fp.read(2), error = fs.error();
	let closed = fp.close();
	if (bytes == null || length(bytes) != 2)
		return failure(`read random device: ${error ?? 'expected two bytes'}`);
	if (!closed)
		return failure(`close random device: ${fs.error() ?? 'unknown error'}`);
	return { ok: true, id: u16(bytes, 0) };
}

function query(domain, id) {
	let q = '';
	for (let label in split(domain, '.'))
		q += chr(length(label)) + label;
	return word(id) + word(0x100) + word(1) + word(0) + word(0) + word(0) +
		q + chr(0) + word(1) + word(1);
}

// Track visited offsets, not only backwards pointers: accept legal shared suffixes
// while bounding arbitrary cycles and expansion. next is the consumed wire extent.
function name_at(s, data, at) {
	let seen = {}, labels = [], next = null, size = 1, pointers = 0;
	while (at < length(data) && check(s)) {
		if (seen[at])
			return null;
		seen[at] = true;
		let n = ord(data, at++);
		if (n == 0)
			return { name: lc(join('.', labels)), next: next ?? at };
		if ((n & 192) == 192) {
			if (at >= length(data) || ++pointers > C.BOOTSTRAP_DNS_MAX_POINTERS)
				return null;
			let target = ((n & 63) << 8) | ord(data, at++);
			next ??= at;
			at = target;
			continue;
		}
		if (n > 63 || at + n > length(data))
			return null;
		size += n + 1;
		if (size > 255)
			return null;
		let label = substr(data, at, n);
		// A literal dot inside a wire label must not compare equal to two labels.
		if (index(label, '.') >= 0 || net.domain(label) == null)
			return null;
		push(labels, label);
		at += n;
	}
	return null;
}

function header(s, data, id, domain) {
	if (!check(s) || length(data) < 12 || u16(data, 0) != id)
		return failure('short header or wrong transaction');
	let flags = u16(data, 2);
	if (!(flags & 0x8000) || (flags & 0x7800) || u16(data, 4) != 1)
		return failure('invalid response header');
	let q = name_at(s, data, 12);
	if (q == null || q.name != lc(domain) || q.next + 4 > length(data))
		return failure('question name mismatch or malformed');
	if (u16(data, q.next) != 1 || u16(data, q.next + 2) != 1)
		return failure('question must be A/IN');
	if (flags & 15)
		return failure(`DNS RCODE ${flags & 15}`);
	return { ok: true, tc: !!(flags & 0x200), offset: q.next + 4 };
}

function records(s, data, offset) {
	let answers = [], an = u16(data, 6);
	let count = an + u16(data, 8) + u16(data, 10);
	for (let i = 0; i < count; i++) {
		if (!check(s))
			return s.error;
		let owner = name_at(s, data, offset);
		if (owner == null || owner.next + 10 > length(data))
			return failure('malformed RR owner/header');
		let kind = u16(data, owner.next), klass = u16(data, owner.next + 2);
		let size = u16(data, owner.next + 8);
		offset = owner.next + 10;
		let end = offset + size, rr = { owner: owner.name };
		if (end > length(data))
			return failure('RR exceeds message');
		// Validate known name-bearing RDATA even outside ANSWER. Opaque unknown
		// RDATA has no compression semantics and is bounded by RDLENGTH alone.
		if (kind == 1) {
			if (size != 4)
				return failure('invalid A length');
			rr.ip = join('.', map([ 0, 1, 2, 3 ], n => ord(data, offset + n)));
		}
		else if (kind == 5 || kind == 2 || kind == 12) {
			let target = name_at(s, data, offset);
			if (target == null || target.next != end)
				return failure('malformed name RDATA');
			if (kind == 5)
				rr.alias = target.name;
		}
		else if (kind == 6 || kind == 15 || kind == 33) {
			let skip = kind == 15 ? 2 : (kind == 33 ? 6 : 0);
			let first = offset + skip < end ? name_at(s, data, offset + skip) : null;
			let last = first;
			if (kind == 6 && first != null)
				last = name_at(s, data, first.next);
			if (last == null || last.next + (kind == 6 ? 20 : 0) != end)
				return failure('malformed structured RDATA');
		}
		if (i < an && klass == 1)
			push(answers, rr);
		offset = end;
	}
	if (offset != length(data))
		return failure('trailing bytes or section count mismatch');
	return { ok: true, answers };
}

function associated(s, answers, domain) {
	let name = domain, followed = false;
	while (check(s)) {
		let alias = null;
		for (let rr in answers) {
			if (!check(s))
				return s.error;
			if (rr.owner != name)
				continue;
			if (rr.ip != null)
				return { ok: true, ip: rr.ip };
			if (rr.alias != null)
				alias = rr.alias;
		}
		if (alias == null)
			return followed ? { ok: true, next: name } : failure('NODATA');
		if (s.names[alias] || ++s.hops > C.BOOTSTRAP_DNS_MAX_CNAME)
			return failure('CNAME cycle or hop limit');
		if (net.domain(alias) == null)
			return failure('invalid CNAME target');
		s.names[alias] = true;
		name = alias;
		followed = true;
	}
	return s.error;
}

function wait_ready(s, sock, flags) {
	while (check(s)) {
		let ms = int(s.deadline - now_ms());
		ms = ms < 1 ? 1 : (ms > C.BOOTSTRAP_DNS_POLL_MS ? C.BOOTSTRAP_DNS_POLL_MS : ms);
		let ready = socket.poll(ms, [ sock, flags | socket.POLLERR | socket.POLLHUP ]);
		if (!check(s))
			return false;
		if (ready == null) {
			if (socket.error(true) == EINTR)
				continue;
			return false;
		}
		if (ready[0][1])
			return true;
	}
	return false;
}

function connect(s, sock, endpoint) {
	if (sock.connect(endpoint.address, endpoint.port))
		return true;
	let error = socket.error(true);
	if (index([ EINTR, EINPROGRESS, EALREADY ], error) < 0)
		return false;
	return wait_ready(s, sock, socket.POLLOUT) && sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0;
}

function send_all(s, sock, data, tcp) {
	let at = 0;
	while (at < length(data) && wait_ready(s, sock, socket.POLLOUT)) {
		let n = sock.send(substr(data, at));
		if (n == null) {
			if (index([ EINTR, EAGAIN ], socket.error(true)) >= 0)
				continue;
			return false;
		}
		if (n == 0 || (!tcp && n != length(data)))
			return false;
		at += n;
	}
	return at == length(data);
}

function receive(s, sock, tcp, id) {
	let data = '', wanted = 2, framed = false;
	while (wait_ready(s, sock, socket.POLLIN)) {
		let chunk = sock.recv(tcp ? wanted - length(data) : 65535);
		if (chunk == null) {
			if (index([ EINTR, EAGAIN ], socket.error(true)) >= 0)
				continue;
			return failure('receive failed');
		}
		if (!tcp) {
			// An unidentifiable short datagram is malformed; identifiable stale IDs
			// can be ignored, but neither kind is ever a source of an IPv4 address.
			if (length(chunk) >= 2 && u16(chunk, 0) != id)
				continue;
			return { ok: true, data: chunk };
		}
		if (!length(chunk))
			return failure('TCP EOF before complete frame');
		data += chunk;
		if (length(data) < wanted)
			continue;
		if (framed) {
			// Never accept a short length prefix by silently dropping queued body bytes.
			let extra = sock.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT);
			if (extra != null && length(extra))
				return failure('TCP bytes exceed frame length');
			if (extra == null && index([ EINTR, EAGAIN ], socket.error(true)) < 0)
				return failure('TCP frame boundary check failed');
			return { ok: true, data };
		}
		wanted = u16(data, 0);
		if (wanted < 12)
			return failure('invalid TCP frame length');
		data = '';
		framed = true;
	}
	return s.error ?? failure('receive wait failed');
}

function exchange(s, endpoint, domain, id, tcp) {
	let sock = socket.create(socket.AF_INET,
		(tcp ? socket.SOCK_STREAM : socket.SOCK_DGRAM) | socket.SOCK_NONBLOCK);
	if (sock == null)
		return failure('socket creation failed');
	let response;
	// A single ownership scope closes sockets on normal errors and exceptions alike.
	try {
		let data = query(domain, id);
		if (tcp)
			data = word(length(data)) + data;
		response = connect(s, sock, endpoint) && send_all(s, sock, data, tcp)
			? receive(s, sock, tcp, id) : failure('connect/send failed');
	}
	catch (e) {
		sock.close();
		die(e);
	}
	if (!sock.close())
		return failure(`socket close failed: ${socket.error() ?? 'unknown error'}`);
	return s.error ?? response;
}

export function lookup(domain, endpoint, on_signal, timeout_ms) {
	let valid = validate(domain, endpoint, timeout_ms);
	if (!valid.ok)
		return valid;
	if (on_signal != null && type(on_signal) != 'function')
		return failure('invalid signal callback');
	let start = now_ms();
	if (start == null)
		return failure('monotonic clock unavailable');
	let s = { deadline: start + (timeout_ms ?? C.BOOTSTRAP_DNS_TIMEOUT_MS), on_signal,
		dispatch_at: start, names: { [lc(domain)]: true }, hops: 0 };
	domain = lc(domain);
	for (let questions = 0; questions < C.BOOTSTRAP_DNS_MAX_QUESTIONS && check(s); questions++) {
		let entropy = random_id();
		if (!entropy.ok)
			return entropy;
		let response = exchange(s, endpoint, domain, entropy.id, false);
		if (!response.ok)
			return response;
		let h = header(s, response.data, entropy.id, domain);
		if (h.ok && h.tc) {
			response = exchange(s, endpoint, domain, entropy.id, true);
			if (!response.ok)
				return response;
			h = header(s, response.data, entropy.id, domain);
			if (h.ok && h.tc)
				return failure('TCP response still truncated');
		}
		if (!h.ok)
			return s.error ?? h;
		let parsed = records(s, response.data, h.offset);
		if (!parsed.ok)
			return s.error ?? parsed;
		let found = associated(s, parsed.answers, domain);
		if (!check(s))
			return s.error;
		if (!found.ok || found.ip != null)
			return found;
		domain = found.next;
	}
	return s.error ?? failure('question limit exceeded');
};
