'use strict';

// UCI -> normalized snapshot (docs/05, docs/12 "配置快照").
//
// read_raw(cursor, package_name) copies raw sections from a UCI cursor into plain objects;
// load(cursor) normalizes them. Everything else (normalize and the validators) is pure
// (docs/12 rule 1) and takes those plain objects, so it can be tested without UCI.

import * as C from 'aetherproxy.const';
import { ipv4, ip_or_cidr, domain, ip_key, private_ipv4 } from 'aetherproxy.net';
import { SCHEMA, SS_METHODS, SUBSCRIPTION_NAME_RE, NODE_NAME_RE } from 'aetherproxy.schema';

// ------------------------------------------------------------------ syntax validators
// Each takes a string and returns the normalized value, or null when the syntax is invalid.

function mac(s) {
	if (match(s, /^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$/) == null)
		return null;

	return lc(replace(s, '-', ':'));
}

function address(s) {
	// All digits and dots can only be meant as an IPv4 address.
	if (match(s, /^[0-9.]+$/) != null)
		return ipv4(s);

	return domain(s);
}

function port_ok(s) {
	return match(s, /^[0-9]{1,5}$/) != null && +s >= 1 && +s <= 65535;
}

function hostport(s) {
	let p = split(s, ':');

	return (length(p) == 2 && ipv4(p[0]) != null && port_ok(p[1])) ? s : null;
}

// chinadns-ng upstream: [udp|tcp|tls://][host@]ipv4[#port] (docs/03).
function upstream(s) {
	let rest = s;
	let i = index(rest, '://');

	if (i >= 0) {
		if (!(substr(rest, 0, i) in [ 'udp', 'tcp', 'tls' ]))
			return null;

		rest = substr(rest, i + 3);
	}

	i = index(rest, '#');

	if (i >= 0) {
		if (!port_ok(substr(rest, i + 1)))
			return null;

		rest = substr(rest, 0, i);
	}

	i = index(rest, '@');

	if (i >= 0) {
		if (domain(substr(rest, 0, i)) == null)
			return null;

		rest = substr(rest, i + 1);
	}

	return ipv4(rest) != null ? s : null;
}

function url(s) {
	return match(s, /^https?:\/\/[^\/?#[:space:]]+[^[:space:]]*$/) != null ? s : null;
}

function abs_path(s) {
	return (substr(s, 0, 1) == '/' && match(s, /[[:space:]]/) == null) ? s : null;
}

function nonempty(s) {
	return length(s) ? s : null;
}

const ITEM_CHECK = {
	ipv4, ip_or_cidr, mac, upstream, hostport, url, string: nonempty
};

const SCALAR_CHECK = {
	string: nonempty, domain, url, address, path: abs_path
};

const INVALID_CODE = {
	ipv4: 'invalid_ipv4', ip_or_cidr: 'invalid_cidr', mac: 'invalid_mac', upstream: 'invalid_upstream',
	hostport: 'invalid_hostport', url: 'invalid_url', string: 'invalid_value',
	domain: 'invalid_domain', address: 'invalid_address', path: 'invalid_path'
};

// Pure shared predicate: malformed JSON becomes a validation error, never an exception.
export function is_json_object(value) {
	try {
		return type(json(value)) == 'object';
	}
	catch (e) {
		// The caller reports invalid_value (config errors or URI skip reason).
		return false;
	}
};

// ------------------------------------------------------------------ field normalization

function applies(f, proto) {
	return f.protocols == null || (proto != null && index(f.protocols, proto) >= 0);
}

function is_required(f, proto) {
	if (f.required == true)
		return applies(f, proto);

	return type(f.required) == 'array' && proto != null && index(f.required, proto) >= 0;
}

function default_of(f, proto) {
	if (!applies(f, proto))
		return f.type == 'list' ? [] : null;

	if (proto != null && f.proto_default?.[proto] != null)
		return f.proto_default[proto];

	// Copy lists so a snapshot never aliases the schema.
	return f.type == 'list' ? slice(f.default) : f.default;
}

// Returns the normalized value for one field; appends to `errors` on failure (the returned
// value is then only a placeholder). `proto` is the node protocol, or null.
function normalize_field(f, raw, field, proto, errors) {
	let v = raw[f.name];

	if (f.type == 'list') {
		let items = (v == null) ? [] : (type(v) == 'array' ? v : [ v ]);

		if (!length(items)) {
			if (is_required(f, proto))
				push(errors, { field, code: 'required', detail: `${f.name} is required` });

			return default_of(f, proto);
		}

		let out = [];

		for (let i, item in items) {
			let n = ITEM_CHECK[f.item](item);

			if (n == null) {
				push(errors, { field, code: INVALID_CODE[f.item], detail: `item ${i}: "${item}" is not valid` });
				continue;
			}

			push(out, n);
		}

		if (f.max_items != null && length(items) > f.max_items)
			push(errors, { field, code: 'too_many', detail: `at most ${f.max_items} entries allowed, got ${length(items)}` });
		else if (f.min_items != null && length(items) < f.min_items)
			push(errors, { field, code: 'too_few', detail: `at least ${f.min_items} entries required` });

		return out;
	}

	if (type(v) == 'array') {
		push(errors, { field, code: 'invalid_value', detail: 'a single value is expected, got a list' });
		return default_of(f, proto);
	}

	if (v == '')
		v = null;

	if (v == null) {
		if (is_required(f, proto))
			push(errors, { field, code: 'required', detail: `${f.name} is required` });

		return default_of(f, proto);
	}

	switch (f.type) {
	case 'bool':
		if (v == '1' || v == '0')
			return v == '1';

		push(errors, { field, code: 'invalid_bool', detail: `"${v}" is not 0 or 1` });
		return default_of(f, proto);

	case 'int':
		if (match(v, /^-?[0-9]{1,9}$/) == null) {
			push(errors, { field, code: 'invalid_int', detail: `"${v}" is not an integer` });
			return default_of(f, proto);
		}

		if ((f.min != null && +v < f.min) || (f.max != null && +v > f.max))
			push(errors, { field, code: 'out_of_range',
				detail: `${v} is outside ${f.min ?? '-inf'}..${f.max ?? 'inf'}` });

		return +v;

	case 'json_object':
		// Keep the UCI string intact; only the outbound renderer decodes the object.
		if (is_json_object(v))
			return v;

		push(errors, { field, code: 'invalid_value', detail: 'must be a JSON object' });
		return null;

	case 'enum':
		if (index(f.enum, v) >= 0)
			return v;

		push(errors, { field, code: 'invalid_enum', detail: `"${v}" is not one of ${join('|', f.enum)}` });
		return default_of(f, proto);

	default:
		let n = SCALAR_CHECK[f.type](v);

		if (n == null) {
			push(errors, { field, code: INVALID_CODE[f.type], detail: `"${v}" is not valid` });
			return default_of(f, proto);
		}

		return n;
	}
}

// Normalizes one section. `fields` is a schema table, `raw` the section's options.
function normalize_section(fields, raw, prefix, errors) {
	let out = {};
	let proto = null;

	// The node protocol decides which fields apply, so resolve it first.
	for (let f in fields)
		if (f.name == 'protocol') {
			let probe_errors = [];
			let p = normalize_field(f, raw, prefix + '.protocol', null, probe_errors);
			proto = (length(probe_errors) == 0) ? p : null;
		}

	for (let f in fields) {
		let value = normalize_field(f, raw, `${prefix}.${f.name}`, proto, errors);
		if (value != null || !f.omit_unset)
			out[f.name] = value;
	}

	// Fields required because another field has a given value (reality needs pbk and sni).
	for (let f in fields) {
		let rw = f.requires_when;

		if (rw != null && out[rw.field] == rw.value && out[f.name] == null)
			push(errors, { field: `${prefix}.${f.name}`, code: 'required',
				detail: `${f.name} is required when ${rw.field}=${rw.value}` });
	}

	return out;
}

// ------------------------------------------------------------------ cross-field rules

// Records the first host that uses `key`; reports once per value when another host repeats it.
function note_value(seen, reported, key, value, i, field, errors) {
	let j = seen[key];

	if (j != null && j != i && !reported[field + key]) {
		push(errors, { field, code: 'duplicate', detail: `${value} also in host[${j}]` });
		reported[field + key] = true;
	}

	seen[key] ??= i;
}

// 02 "冲突校验": the same IP, CIDR or MAC in two different host sections is an error.
// TODO(design): applies to disabled hosts too (02 says "两个 host 段中" without exempting them);
// nested CIDRs are allowed (02), only identical entries conflict.
function unset(v) {
	return v == null || v == '' || (type(v) == 'array' && !length(v));
}

// `raw_hosts` is consulted for "is ip/mac set" so that an invalid entry (dropped from the
// snapshot) does not also produce a spurious "required" error.
function check_hosts(hosts, raw_hosts, errors) {
	let seen_ip = {}, seen_mac = {};

	for (let i, h in hosts) {
		let at = `host[${i}]`;

		if (unset(raw_hosts[i].ip) && unset(raw_hosts[i].mac))
			push(errors, { field: at + '.ip', code: 'required', detail: 'at least one of ip and mac must be set' });

		if (h.policy == 'direct' && h.udp)
			push(errors, { field: at + '.udp', code: 'conflict', detail: 'udp (game mode) cannot be set when policy is direct' });

		let reported = {};

		for (let v in h.ip)
			note_value(seen_ip, reported, ip_key(v), v, i, at + '.ip', errors);

		for (let v in h.mac)
			note_value(seen_mac, reported, v, v, i, at + '.mac', errors);
	}
}

// 05 校验规则 6 beyond the schema's own required/requires_when checks.
function check_node(n, at, errors) {
	if (n.mux && n.flow == 'xtls-rprx-vision')
		push(errors, { field: at + '.mux', code: 'conflict', detail: 'Mux is incompatible with xtls-rprx-vision' });

	if (n.protocol == 'shadowsocks' && n.method != null && index(SS_METHODS, n.method) < 0)
		push(errors, { field: at + '.method', code: 'unsupported_method',
			detail: `"${n.method}" is not a supported shadowsocks method` });

	// The format rules below mirror what Xray v26.9.30 rejects at startup (docs/05 rule 6).
	if (n.reality_pbk != null && !match(n.reality_pbk, /^[A-Za-z0-9_-]{43}$/))
		push(errors, { field: at + '.reality_pbk', code: 'invalid_reality_key',
			detail: 'must be a 32-byte key in unpadded base64url (43 characters)' });

	if (n.reality_sid != null && !match(n.reality_sid, /^([0-9a-fA-F][0-9a-fA-F]){0,8}$/))
		push(errors, { field: at + '.reality_sid', code: 'invalid_short_id',
			detail: 'must be hex with an even length of at most 16 characters' });

	if (n.pinned_cert_sha256 != null) {
		for (let v in split(n.pinned_cert_sha256, ',')) {
			v = trim(v);

			if (v != '' && !match(replace(v, /:/g, ''), /^[0-9a-fA-F]{64}$/)) {
				push(errors, { field: at + '.pinned_cert_sha256', code: 'invalid_cert_hash',
					detail: `"${v}" is not a SHA-256 hex digest` });
				break;
			}
		}
	}

	let plaintext = (n.protocol == 'vless' && (n.encryption == null || n.encryption == 'none'))
		|| n.protocol == 'trojan';

	if (plaintext && n.security == 'none' && !private_ipv4(n.address))
		push(errors, { field: at + '.security', code: 'insecure_transport',
			detail: `${n.protocol} without TLS/REALITY is only allowed to a private IPv4 address` });
}

// Validates one already-decoded node without reading UCI or mutating the input.
export function validate_node(node) {
	let errors = [];

	if (type(node) != 'object')
		return [ { field: 'node', code: 'invalid_value', detail: 'node must be an object' } ];

	let normalized = normalize_section(SCHEMA.node, node, 'node', errors);
	check_node(normalized, 'node', errors);

	return errors;
};

function check_main(snap, errors, warnings) {
	let m = snap.main;

	if (!m.enabled)
		return;

	if (m.node == null) {
		push(errors, { field: 'main.node', code: 'required', detail: 'node must be set when enabled=1' });
		return;
	}

	let n = snap.nodes[m.node];

	if (n == null) {
		push(errors, { field: 'main.node', code: 'unknown_node', detail: `node ${m.node} does not exist` });
		return;
	}

	// 05 rule 1 says both "must be a non-stale node" and "a stale node may be used, with a
	// warning"; the second reading is implemented. TODO(design): resolve the contradiction.
	if (n.stale)
		push(warnings, { field: 'main.node', code: 'NODE_STALE_IN_USE', detail: `node ${m.node} is stale` });
}

// ------------------------------------------------------------------ public API

// Keep singleton names in one place for normalization and both raw readers (docs/05, docs/06).
const SINGLETON_SECTIONS = [ 'main', 'dns', 'update', 'probe', 'sub' ];

// raw: { main, dns, update, probe, sub: option objects (or null when the section is absent),
//        hosts: [option objects in file order],
//        subscriptions: { name: options }, nodes: { name: options } }
// Pure. Result: { ok, snapshot | errors, warnings }.
// TODO(design): 12 shows only { ok, snapshot } / { ok, errors }; `warnings` (event code
// NODE_STALE_IN_USE etc.) is added so a caller can log them, since config.uc must not.
export function normalize(raw) {
	let errors = [], warnings = [];
	let snap = {};

	for (let s in SINGLETON_SECTIONS)
		snap[s] = normalize_section(SCHEMA[s], raw[s] ?? {}, s, errors);

	snap.hosts = [];

	for (let i, h in raw.hosts ?? [])
		push(snap.hosts, normalize_section(SCHEMA.host, h, `host[${i}]`, errors));

	for (let kind in [ 'subscription', 'node' ]) {
		let coll = kind + 's';
		let re = (kind == 'node') ? NODE_NAME_RE : SUBSCRIPTION_NAME_RE;
		let src = raw[coll] ?? {};

		snap[coll] = {};

		// Sorted by section name so the snapshot is deterministic (docs/12 rule 6).
		for (let name in sort(keys(src))) {
			if (match(name, re) == null)
				push(errors, { field: `${kind}.${name}`, code: 'invalid_name',
					detail: `section name must match ${kind == 'node' ? 'n_<32 hex>' : 's_<8 hex>'}` });

			let section = normalize_section(SCHEMA[kind], src[name], `${kind}.${name}`, errors);
			if (kind == 'subscription')
				// Resolve inheritance once, after validation. Nullish coalescing preserves explicit 0.
				for (let field, value in snap.sub)
					section[field] ??= value;
			snap[coll][name] = section;
		}
	}

	check_hosts(snap.hosts, raw.hosts ?? [], errors);

	for (let name, n in snap.nodes)
		check_node(n, `node.${name}`, errors);

	check_main(snap, errors, warnings);

	if (length(errors))
		return { ok: false, errors: errors, warnings: warnings };

	return { ok: true, snapshot: snap, warnings: warnings };
};

function strip(section) {
	let o = {};

	for (let k in keys(section))
		if (substr(k, 0, 1) != '.')
			o[k] = section[k];

	return o;
}

// The subscription writer uses an isolated package name to avoid pending LuCI deltas (docs/06).
// Share the section inventory so newly supported sections cannot disappear on that path.
export function read_raw(cursor, package_name) {
	let raw = { hosts: [], subscriptions: {}, nodes: {} };

	for (let s in SINGLETON_SECTIONS) {
		let sec = cursor.get_all(package_name, s);

		raw[s] = sec ? strip(sec) : null;
	}

	cursor.foreach(package_name, 'host', s => { push(raw.hosts, strip(s)); });
	cursor.foreach(package_name, 'subscription', s => { raw.subscriptions[s['.name']] = strip(s); });
	cursor.foreach(package_name, 'node', s => { raw.nodes[s['.name']] = strip(s); });

	return raw;
};

// Reads /etc/config/aetherproxy (or the cursor's confdir) and returns normalize()'s result.
// TODO(design): `lan_ifaces` existence (05 rule 5) is a precheck that needs the live system
// and is not done here.
export function load(cursor) {
	return normalize(read_raw(cursor, C.UCI_PACKAGE));
};
