'use strict';

// Pure IPv4 / CIDR / domain syntax helpers shared by config.uc and data.uc (docs/12 rule 1:
// no fs, uci or system calls in here). Each validator takes a string and returns it unchanged
// when valid, or null when not.

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

