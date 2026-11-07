'use strict';

// Pure IPv4 / CIDR / domain syntax helpers shared by config.uc and data.uc (docs/12 rule 1:
// no fs, uci or system calls in here). Validators return a string unchanged when valid,
// or null when not; parsers return the documented parts instead.

export function valid_octet(s) {
	return match(s, /^(0|[1-9][0-9]{0,2})$/) != null && +s <= 255;
};

export function ipv4(s) {
	let p = split(s, '.');

	if (length(p) != 4)
		return null;

	for (let o in p)
		if (!valid_octet(o))
			return null;

	return s;
};

// docs/05 trust_dns allows only a fixed port-53 IPv4 target, not the broader
// chinadns upstream grammar. Share parsing so validation and both renderers agree.
export function trust_dns_parts(s) {
	if (type(s) != 'string')
		return null;

	let protocol = 'tcp';
	let address = s;
	let prefix = match(s, /^(tcp|udp):\/\//);
	if (prefix != null) {
		protocol = prefix[1];
		address = substr(s, length(prefix[0]));
	}

	return ipv4(address) != null ? { protocol, address } : null;
};

// IPv4 or a.b.c.d/len. Host bits must be zero (nft interval sets reject a prefix with
// host bits; failing here is the conservative choice).
export function ip_or_cidr(s) {
	let p = split(s, '/');

	if (length(p) == 1)
		return ipv4(s);

	if (length(p) != 2 || ipv4(p[0]) == null || match(p[1], /^(0|[1-9][0-9]?)$/) == null)
		return null;

	let len = +p[1];

	if (len > 32)
		return null;

	let o = map(split(p[0], '.'), x => +x);
	let addr = (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3];
	let mask = len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF;

	return (addr & ~mask & 0xFFFFFFFF) == 0 ? s : null;
};

// start-end range of two IPv4 addresses (no whitespace, start <= end). Returns the normalised
// string (start == end collapses to the single address) or null. Only host `ip` accepts
// ranges (docs/05 `config host`); ip_or_cidr() deliberately stays range-free so the dynamic
// set export/restore paths are unaffected.
function addr_number(a) {
	let o = map(split(a, '.'), x => +x);
	return o[0] * 16777216 + o[1] * 65536 + o[2] * 256 + o[3];
};

export function range_parts(s) {
	if (type(s) != 'string')
		return null;

	let p = split(s, '-');

	if (length(p) != 2 || ipv4(p[0]) == null || ipv4(p[1]) == null)
		return null;

	let a = addr_number(p[0]), b = addr_number(p[1]);

	return a <= b ? { start: a, end: b, from: p[0], to: p[1] } : null;
};

export function ip_or_range(s) {
	if (type(s) == 'string' && index(s, '-') >= 0) {
		let r = range_parts(s);

		if (r == null)
			return null;

		return r.start == r.end ? r.from : `${r.from}-${r.to}`;
	}

	return ip_or_cidr(s);
};

export function domain(s) {
	if (length(s) < 1 || length(s) > 253)
		return null;

	for (let label in split(s, '.'))
		if (length(label) > 63 || match(label, /^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$/) == null)
			return null;

	return s;
};

export function ip_key(s) {
	// 1.2.3.4 and 1.2.3.4/32 select the same host.
	return replace(s, /\/32$/, '');
};

// Splits a string accepted by ip_or_cidr() into { addr, len } where addr is the network
// address as an integer; a bare address has len 32. Returns null when invalid.
export function cidr_parts(s) {
	if (ip_or_cidr(s) == null)
		return null;

	let p = split(s, '/');
	let o = map(split(p[0], '.'), x => +x);

	return {
		addr: (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3],
		len: length(p) == 2 ? +p[1] : 32
	};
};

// Ranges Xray treats as private for its "no plaintext VLESS/Trojan to public addresses" rule
// (infra/conf/xray.go requiresTransportSecurity, v26.9.30). Domains are never treated as
// private here: Xray's private-domain list lives in geodata, so we stay conservative.
const PRIVATE4 = [ '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16' ];

export function private_ipv4(s) {
	let a = cidr_parts(s);

	if (a == null || a.len != 32)
		return false;

	for (let r in PRIVATE4) {
		let n = cidr_parts(r);
		let mask = (0xFFFFFFFF << (32 - n.len)) & 0xFFFFFFFF;

		if ((a.addr & mask) == n.addr)
			return true;
	}

	return false;
};

function ipv4_number(s) {
	let octets = map(split(s, '.'), value => +value);
	return octets[0] * 16777216 + octets[1] * 65536 + octets[2] * 256 + octets[3];
};

function ipv4_string(value) {
	let a = int(value / 16777216);
	value -= a * 16777216;
	let b = int(value / 65536);
	value -= b * 65536;
	let c = int(value / 256);
	let d = value - c * 256;
	return `${a}.${b}.${c}.${d}`;
};

// Convert an inclusive IPv4 range to its minimal, non-overlapping CIDR cover.
export function range_to_cidrs(a, b) {
	if (type(a) != 'string' || type(b) != 'string' || ipv4(a) == null || ipv4(b) == null)
		return null;

	let first = ipv4_number(a), last = ipv4_number(b);
	if (first > last)
		return null;

	let out = [], current = first;
	while (current <= last) {
		let host_bits = 0, block = 1;
		while (host_bits < 32) {
			let bigger = block * 2;
			if (current % bigger != 0 || current + bigger - 1 > last)
				break;
			block = bigger;
			host_bits++;
		}
		push(out, host_bits == 0 ? ipv4_string(current) : `${ipv4_string(current)}/${32 - host_bits}`);
		current += block;
	}

	return out;
};

// Canonical network-order hex, also used for proc socket address comparisons.
export function address_hex(address) {
	if (type(address) != 'string')
		return null;
	if (ipv4(address) != null)
		return join('', map(split(address, '.'), n => sprintf('%02X', +n)));
	let halves = split(address, '::');
	if (length(halves) > 2)
		return null;
	let left = halves[0] == '' ? [] : split(halves[0], ':');
	let right = length(halves) == 2 && halves[1] != '' ? split(halves[1], ':') : [];
	let missing = 8 - length(left) - length(right);
	if (missing < 0 || (length(halves) == 1 && missing != 0) ||
	    (length(halves) == 2 && missing == 0))
		return null;
	let words = [ ...left ];
	for (let i = 0; i < missing; i++)
		push(words, '0');
	push(words, ...right);
	for (let word in words)
		if (match(word, /^[0-9a-fA-F]{1,4}$/) == null)
			return null;
	return join('', map(words, word => sprintf('%04X', hex(word))));
};

function proc_address_hex(address, little_endian) {
	let network = '';
	for (let i = 0; i < length(address); i += 8) {
		if (!little_endian)
			network += substr(address, i, 8);
		else
			for (let j = 6; j >= 0; j -= 2)
				network += substr(address, i + j, 2);
	}
	return uc(network);
};

// Linux prints each address as native-endian 32-bit words; the caller supplies
// the verified ABI order. A pure parser must neither probe it nor default to the
// host runner's order, and accepting both directions would accept wrong addresses.
export function socket_rows(text, ipv6, little_endian) {
	if (type(little_endian) != 'bool')
		return { ok: false, detail: 'socket table byte order must be an explicit boolean' };
	if (type(text) != 'string')
		return { ok: false, detail: 'unreadable socket table' };
	let rows = [];
	for (let line in split(text, '\n')) {
		let value = trim(line);
		if (value == '' || match(value, /^(sl|local_address)[[:space:]]/) != null)
			continue;
		let f = split(value, /[[:space:]]+/);
		let local = split(f[1] ?? '', ':');
		let addr = local[0];
		if (length(f) < 10 || match(f[0], /^[0-9]+:$/) == null ||
		    match(addr, /^[0-9a-fA-F]+$/) == null || length(addr) != (ipv6 ? 32 : 8))
			return { ok: false, detail: 'malformed socket table row' };
		let remote = split(f[2], ':');
		if (match(local[1] ?? '', /^[0-9a-fA-F]{4}$/) == null ||
		    match(f[3], /^[0-9a-fA-F]{2}$/) == null || match(f[9], /^[0-9]+$/) == null)
			return { ok: false, detail: 'malformed socket state/port/inode' };
		if (length(remote[0]) != length(addr) || match(remote[0], /^[0-9a-fA-F]+$/) == null ||
		    match(remote[1] ?? '', /^[0-9a-fA-F]{4}$/) == null)
			return { ok: false, detail: 'malformed remote socket endpoint' };
		if (match(f[4], /^[0-9a-fA-F]{8}:[0-9a-fA-F]{8}$/) == null ||
		    match(f[5], /^[0-9a-fA-F]{2}:[0-9a-fA-F]{8}$/) == null ||
		    match(f[6], /^[0-9a-fA-F]{8}$/) == null)
			return { ok: false, detail: 'malformed socket queue/timer fields' };
		if (match(f[7], /^[0-9]+$/) == null || match(f[8], /^[0-9]+$/) == null)
			return { ok: false, detail: 'malformed socket uid/timeout fields' };
		push(rows, {
			address: proc_address_hex(addr, little_endian), port: hex(local[1]),
			remote_address: proc_address_hex(remote[0], little_endian), remote_port: hex(remote[1]),
			state: uc(f[3]), inode: f[9], ipv6
		});
	}
	return { ok: true, rows };
};

// True if a /proc/net/tcp or /proc/net/tcp6 text has a socket in LISTEN (0A) on port.
// Both files matter: Go (Xray) binds a wildcard address as one dual-stack IPv6 socket,
// so a listener on 0.0.0.0 shows up only in tcp6.
export function tcp_listening(text, port) {
	if (text == null)
		return false;
	let wanted = sprintf('%04X', port);
	for (let line in split(text, '\n')) {
		let fields = split(trim(line), /[[:space:]]+/);
		if (length(fields) >= 4 && uc(split(fields[1], ':')[1] ?? '') == wanted && fields[3] == '0A')
			return true;
	}
	return false;
};
