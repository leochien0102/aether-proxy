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
