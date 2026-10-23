'use strict';

// Direct IPv4 DNS diagnostics (docs/03 "直连境外 DNS（可选）"). No service,
// resolver, subprocess or cache is involved; each attempt owns one socket/deadline.
import * as socket from 'socket';
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as net from 'aetherproxy.net';

// Linux socket errno ABI, also used by probe.uc; not exported by socket 2025.07.18.
const EINTR = 4;
const EAGAIN = 11;
const EALREADY = 114;
const EINPROGRESS = 115;

function now_ms() {
	let t = clock(true);
	return t == null ? null : t[0] * 1000 + t[1] / 1000000;
}

function within_deadline(deadline) {
	let now = now_ms();
	return now != null && now < deadline;
}

function random_id() {
	let fp = fs.open(C.RANDOM_DEVICE, 'r');
	if (fp == null)
		die(`open ${C.RANDOM_DEVICE}: ${fs.error() ?? 'unknown error'}`);
	let bytes = fp.read(2);
	let read_error = fs.error();
	let closed = fp.close();
	if (bytes == null || length(bytes) != 2)
		die(`read ${C.RANDOM_DEVICE}: ${read_error ?? 'expected two random bytes'}`);
	if (!closed)
		die(`close ${C.RANDOM_DEVICE}: ${fs.error() ?? 'unknown error'}`);
	return ord(bytes, 0) * 256 + ord(bytes, 1);
}

function word(n) {
	return chr((n >> 8) & 255) + chr(n & 255);
}

function uint16(data, offset) {
	return ord(data, offset) * 256 + ord(data, offset + 1);
}

function target(upstream) {
	let parts = match(upstream, /^((tcp|udp):\/\/)?([0-9.]+)(#([0-9]+))?$/);
	if (parts == null || net.ipv4(parts[3]) == null)
		return null;
	let port = parts[5] == null ? C.DNS_PORT : +parts[5];
	if (port < 1 || port > 65535)
		return null;
	// TODO(design): host@IP is valid configuration but unspecified for diagnostics;
	// report unsupported rather than resolve a host or silently discard its meaning.
	return { tcp: parts[2] == 'tcp', address: parts[3], port };
}

function question(domain) {
	let data = '';
	for (let label in split(domain, '.'))
		data += chr(length(label)) + label;
	return data + chr(0) + word(1) + word(1);
}

// Resolve compressed names with a decreasing-pointer rule: RFC1035 pointers refer
// backwards. A hop budget also bounds acyclic chains; parsing shares the socket's
// original deadline, including expansion of question, owner and CNAME names.
function read_name(data, offset, deadline) {
	let labels = [];
	let next = null;
	let limit = offset;
	let size = 0;
	let pointers = 0;
	while (offset < length(data)) {
		if (!within_deadline(deadline))
			return null;
		let n = ord(data, offset++);
		if (n == 0)
			return { name: lc(join('.', labels)), next: next ?? offset };
		if ((n & 192) == 192) {
			if (offset >= length(data))
				return null;
			let pointer = ((n & 63) << 8) | ord(data, offset++);
			if (pointer >= limit || ++pointers > C.DNS_TEST_MAX_NAME_POINTERS)
				return null;
			next ??= offset;
			limit = pointer;
			offset = pointer;
			continue;
		}
		if (n > 63 || offset + n > length(data))
			return null;
		size += n + 1;
		if (size > 254)
			return null;
		push(labels, substr(data, offset, n));
		offset += n;
	}
	return null;
}

// TODO(design): success is not defined at wire level. Conservatively require a
// complete A/IN answer for the requested name (possibly via CNAME); NODATA fails.
function valid_answer(data, id, domain, deadline) {
	if (!within_deadline(deadline) || length(data) < 12 || uint16(data, 0) != id)
		return false;
	let flags = uint16(data, 2);
	// Only complete, successful standard responses to exactly our A/IN question count.
	if ((flags & 0xFA0F) != 0x8000 || uint16(data, 4) != 1)
		return false;
	let q = read_name(data, 12, deadline);
	if (q == null || q.name != lc(domain) || q.next + 4 > length(data))
		return false;
	if (uint16(data, q.next) != 1 || uint16(data, q.next + 2) != 1)
		return false;
	let offset = q.next + 4;
	let answers = [];
	let count = uint16(data, 6) + uint16(data, 8) + uint16(data, 10);
	for (let i = 0; i < count; i++) {
		if (!within_deadline(deadline))
			return false;
		let owner = read_name(data, offset, deadline);
		if (owner == null || owner.next + 10 > length(data))
			return false;
		let kind = uint16(data, owner.next);
		let klass = uint16(data, owner.next + 2);
		let size = uint16(data, owner.next + 8);
		offset = owner.next + 10;
		if (offset + size > length(data))
			return false;
		if (i < uint16(data, 6) && klass == 1) {
			if (kind == 1 && size == 4)
				push(answers, { owner: owner.name, address: true });
			else if (kind == 5) {
				let alias = read_name(data, offset, deadline);
				if (alias == null || alias.next != offset + size)
					return false;
				push(answers, { owner: owner.name, alias: alias.name });
			}
		}
		offset += size;
	}
	if (offset != length(data))
		return false;
	let name = lc(domain);
	for (let hop = 0; hop <= length(answers); hop++) {
		if (!within_deadline(deadline))
			return false;
		let alias = null;
		for (let answer in answers) {
			if (!within_deadline(deadline))
				return false;
			if (answer.owner != name)
				continue;
			if (answer.address)
				return true;
			alias = answer.alias;
		}
		if (alias == null)
			return false;
		name = alias;
	}
	return false;
}

function wait_ready(sock, flags, deadline) {
	while (true) {
		let now = now_ms();
		if (now == null || now >= deadline)
			return false;
		let remaining = int(deadline - now);
		let ready = socket.poll(remaining > 0 ? remaining : 1,
			[ sock, flags | socket.POLLERR | socket.POLLHUP ]);
		if (ready == null) {
			if (socket.error(true) == EINTR)
				continue;
			return false;
		}
		now = now_ms();
		if (now == null || now >= deadline)
			return false;
		if (ready[0][1] != 0)
			return true;
	}
}

function connect(sock, upstream, deadline) {
	if (sock.connect(upstream.address, upstream.port))
		return true;
	let error = socket.error(true);
	if (error != EINPROGRESS && error != EALREADY && error != EINTR)
		return false;
	return wait_ready(sock, socket.POLLOUT, deadline)
		&& sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0;
}

function send_query(sock, data, tcp, deadline) {
	let sent = 0;
	while (sent < length(data)) {
		if (!wait_ready(sock, socket.POLLOUT, deadline))
			return false;
		let n = sock.send(substr(data, sent));
		if (n == null) {
			if (index([ EINTR, EAGAIN ], socket.error(true)) >= 0)
				continue;
			return false;
		}
		if (n == 0 || (!tcp && n != length(data)))
			return false;
		sent += n;
	}
	return true;
}

function receive_answer(sock, tcp, deadline, id, domain) {
	let data = '';
	let wanted = 2;
	let framed = false;
	while (wait_ready(sock, socket.POLLIN, deadline)) {
		let chunk = sock.recv(tcp ? wanted - length(data) : 65535);
		if (chunk == null) {
			if (index([ EINTR, EAGAIN ], socket.error(true)) >= 0)
				continue;
			return false;
		}
		if (!tcp) {
			// Ignore other transactions without renewing the deadline. A matching
			// negative/malformed response ends this attempt, rather than waiting 2s.
			if (length(chunk) >= 2 && uint16(chunk, 0) == id)
				return valid_answer(chunk, id, domain, deadline);
			continue;
		}
		if (length(chunk) == 0)
			return false;
		data += chunk;
		if (length(data) != wanted)
			continue;
		if (framed)
			return valid_answer(data, id, domain, deadline);
		wanted = uint16(data, 0);
		if (wanted < 12)
			return false;
		data = '';
		framed = true;
	}
	return false;
}

function attempt(upstream, domain) {
	let start = now_ms();
	if (start == null)
		return null;
	let deadline = start + C.DNS_TEST_TIMEOUT_MS;
	// Entropy errors propagate to the caller; do not turn an fs failure into a
	// DNS timeout, reuse an ID, or leak an already-created socket on that path.
	let id = random_id();
	let sock = socket.create(socket.AF_INET,
		(upstream.tcp ? socket.SOCK_STREAM : socket.SOCK_DGRAM) | socket.SOCK_NONBLOCK);
	if (sock == null)
		return null;
	let data = word(id) + word(0x0100) + word(1) + word(0) + word(0) + word(0) + question(domain);
	if (upstream.tcp)
		data = word(length(data)) + data;
	let ok = connect(sock, upstream, deadline) && send_query(sock, data, upstream.tcp, deadline)
		&& receive_answer(sock, upstream.tcp, deadline, id, domain);
	let end = now_ms();
	sock.close();
	return ok && end != null && end < deadline ? int(end - start + 0.5) : null;
}

function measure(upstream, domain) {
	let samples = [];
	if (upstream != null)
		for (let i = 0; i < C.DNS_TEST_ATTEMPTS; i++) {
			let ms = attempt(upstream, domain);
			if (ms != null)
				push(samples, ms);
		}
	samples = sort(samples, (a, b) => a - b);
	let size = length(samples);
	let median = size ? samples[size >> 1] : null;
	// TODO(design): with two successes use the arithmetic mean of the middle
	// samples, retaining .5 ms rather than inventing an undocumented rounding rule.
	if (size && size % 2 == 0)
		median = (samples[(size >> 1) - 1] + median) / 2;
	return { domain, ok: size, total: C.DNS_TEST_ATTEMPTS, latency_ms: median };
}

export function run(snapshot) {
	let address = snapshot.nodes?.[snapshot.main.node]?.address;
	let domain = address != null && net.ipv4(address) == null
		? address : C.DNS_TEST_FALLBACK_DOMAIN;
	let results = [];
	for (let upstream in snapshot.dns.direct_dns) {
		let parsed = target(upstream);
		push(results, { upstream, unblocked: measure(parsed, domain),
			blocked: measure(parsed, snapshot.dns.dns_probe_domain), unsupported: parsed == null });
	}
	return results;
};
