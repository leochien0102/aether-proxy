'use strict';

// Parses supported subscription URI formats without performing I/O (docs/06 "URI 格式").
// Optional sharing parameters follow docs/05 "config node" (T9.14).

import * as config from 'aetherproxy.config';

function skipped(reason) {
	return { skip: reason };
}

function url_decode(value) {
	let out = '';

	for (let i = 0; i < length(value); i++) {
		let c = substr(value, i, 1);

		if (c != '%') {
			out += c;
			continue;
		}

		if (i + 2 >= length(value))
			return null;

		let byte = hexdec(lc(substr(value, i + 1, 2)));

		if (byte == null)
			return null;

		out += byte;
		i += 2;
	}

	return out;
}

function decode_base64(value) {
	let input = replace(value, /[[:space:]]/g, '');

	if (!length(input) || match(input, /^[A-Za-z0-9+\/_-]*={0,2}$/) == null)
		return null;

	let core = replace(input, /=+$/, '');
	let padding = length(input) - length(core);
	let remainder = length(core) % 4;

	if (remainder == 1)
		return null;

	let needed = (4 - remainder) % 4;

	if (padding && padding != needed)
		return null;

	let normalized = replace(replace(core, /-/g, '+'), /_/g, '/');
	if (needed == 1)
		normalized += '=';
	else if (needed == 2)
		normalized += '==';

	return b64dec(normalized);
}

function split_once(value, delimiter) {
	let at = index(value, delimiter);

	if (at < 0)
		return [ value, null ];

	return [ substr(value, 0, at), substr(value, at + length(delimiter)) ];
}

function last_index(value, needle) {
	// The pinned ucode reports a match at offset zero as not found.
	let at = rindex(' ' + value, needle);
	return at < 0 ? -1 : at - 1;
}

function parse_query(query) {
	let options = {};

	if (query == null || query == '')
		return options;

	for (let part in split(query, '&')) {
		if (part == '')
			continue;

		let pair = split_once(part, '=');
		let key = url_decode(pair[0]);
		let value = url_decode(pair[1] ?? '');

		if (key == null || value == null || key == '')
			return null;
		if (index(keys(options), key) >= 0) {
			// TODO(design): docs/06 does not define repeated query-key precedence; reject duplicates.
			return null;
		}

		options[key] = value;
	}

	return options;
}

function parse_fragment(text) {
	let parts = split_once(text, '#');
	let label = parts[1] == null ? null : url_decode(parts[1]);

	if (parts[1] != null && label == null)
		return null;

	return { body: parts[0], label };
}

function parse_authority(authority) {
	if (substr(authority, 0, 1) == '[')
		return { skip: 'ipv6_address' };

	let parts = split_once(authority, ':');
	if (parts[1] == null)
		return null;
	if (index(parts[1], ':') >= 0)
		return { skip: 'ipv6_address' };

	let address = url_decode(parts[0]);
	if (address == null || address == '')
		return null;
	if (match(parts[1], /^[0-9]+$/) == null)
		return null;

	let port = +parts[1];
	if (port < 1 || port > 65535)
		return null;

	return { address, port };
}

function transport(value) {
	switch (value) {
	case 'tcp': return 'raw';
	case 'ws':
	case 'grpc':
	case 'httpupgrade':
	case 'xhttp': return value;
	case 'splithttp': return 'xhttp';
	}

	return null;
}

function copy_common(node, options, default_security) {
	let net = options.type == null ? 'raw' : transport(options.type);
	if (net == null)
		return skipped('unsupported_transport');

	let security = options.security ?? default_security;
	if (index([ 'none', 'tls', 'reality' ], security) < 0)
		return skipped('unsupported_security');

	node.transport = net;
	node.security = security;

	let mappings = {
		sni: 'sni', fp: 'fingerprint', pbk: 'reality_pbk', sid: 'reality_sid', spx: 'reality_spx',
		host: 'host', path: 'path', serviceName: 'service_name',
		headerType: 'header_type', pcs: 'pinned_cert_sha256', vcn: 'verify_name', flow: 'flow',
		ech: 'ech_config_list', pqv: 'reality_pqv'
	};
	for (let key, field in mappings)
		if (options[key] != null)
			node[field] = options[key];

	// `mode` belongs to two transports; never leak grpc's gun/multi into xhttp_mode.
	if (net == 'grpc' && options.mode != null) {
		// Only multi/gun are accepted; anything else skips the link (docs/05).
		if (index([ 'multi', 'gun' ], options.mode) < 0)
			return skipped('invalid_value');
		node.grpc_multi_mode = options.mode == 'multi' ? '1' : '0';
	}
	else if (net == 'xhttp' && options.mode != null)
		node.xhttp_mode = options.mode;

	if (net == 'xhttp' && options.extra != null) {
		if (!config.is_json_object(options.extra))
			return skipped('invalid_value');
		node.xhttp_extra = options.extra;
	}

	if (options.alpn != null && options.alpn != '')
		node.alpn = split(options.alpn, ',');

	return null;
}

function insecure_warning(options, label) {
	let value = options.allowInsecure ?? options.insecure;

	if (value != '1' && lc(value ?? '') != 'true')
		return [];

	return [ { code: 'NODE_INSECURE_IGNORED', args: { label } } ];
}

function validation_skip(node) {
	let errors = config.validate_node(node);

	for (let error in errors) {
		if (error.code == 'required')
			return 'missing_field';
		if (error.code == 'insecure_transport')
			return 'insecure_transport';
		if (error.code == 'unsupported_method')
			return 'unsupported_security';
		if (index([ 'invalid_reality_key', 'invalid_short_id', 'invalid_cert_hash' ], error.code) >= 0)
			return 'invalid_value';
	}

	return length(errors) ? 'malformed' : null;
}

function finish_node(node, warnings) {
	let reason = validation_skip(node);
	if (reason != null)
		return skipped(reason);

	let result = { node };
	if (length(warnings))
		result.warnings = warnings;

	return result;
}

function split_userpass(decoded) {
	let pair = split_once(decoded, ':');
	if (pair[1] == null || pair[0] == '')
		return null;

	return { method: lc(pair[0]), password: pair[1] };
}

function parse_userpass(value) {
	let literal = url_decode(value);
	if (literal == null)
		return null;
	if (index(literal, ':') >= 0)
		return split_userpass(literal);

	let decoded = decode_base64(value);
	return decoded == null ? null : split_userpass(decoded);
}

function parse_vmess(payload, label) {
	let decoded = decode_base64(payload);
	if (decoded == null)
		return skipped('malformed');

	let data = json(decoded);
	if (type(data) != 'object')
		return skipped('malformed');

	if (data.aid != null && `${data.aid}` != '0')
		return skipped('vmess_alterid');

	let address = data.add == null ? null : `${data.add}`;
	let port = data.port == null ? null : `${data.port}`;
	if (address == null || port == null || match(port, /^[0-9]+$/) == null)
		return skipped('malformed');

	let security = data.tls == 'tls' ? 'tls' : (data.tls == '' || data.tls == null ? 'none' : null);
	if (security == null)
		return skipped('unsupported_security');

	let net = transport(data.net ?? 'tcp');
	if (net == null)
		return skipped('unsupported_transport');

	let node = {
		protocol: 'vmess', address, port: +port,
		uuid: data.id == null ? null : `${data.id}`,
		method: `${data.scy ?? 'auto'}`, transport: net, security
	};
	if (data.ps != null && data.ps != '')
		node.label = `${data.ps}`;
	else if (label != null && label != '')
		node.label = label;

	if (data.type != null && data.type != '')
		node.header_type = `${data.type}`;
	if (data.host != null && data.host != '')
		node.host = `${data.host}`;
	if (data.path != null && data.path != '')
		node.path = `${data.path}`;
	if (data.sni != null && data.sni != '')
		node.sni = `${data.sni}`;
	if (data.fp != null && data.fp != '')
		node.fingerprint = `${data.fp}`;
	if (data.alpn != null && data.alpn != '')
		node.alpn = split(`${data.alpn}`, ',');

	return finish_node(node, []);
}

function parse_ss(payload, label) {
	let fragment = parse_fragment(payload);
	if (fragment == null)
		return skipped('malformed');

	let query_parts = split_once(fragment.body, '?');
	let options = parse_query(query_parts[1]);
	if (options == null)
		return skipped('malformed');
	if (options.plugin != null)
		return skipped('ss_plugin');

	let authority, credentials;
	let at = index(query_parts[0], '@');
	if (at >= 0) {
		credentials = parse_userpass(substr(query_parts[0], 0, at));
		authority = substr(query_parts[0], at + 1);
	}
	else {
		let decoded = decode_base64(query_parts[0]);
		if (decoded == null)
			return skipped('malformed');
		let split_at = last_index(decoded, '@');
		if (split_at < 0)
			return skipped('malformed');
		credentials = split_userpass(substr(decoded, 0, split_at));
		authority = substr(decoded, split_at + 1);
	}

	if (credentials == null)
		return skipped('malformed');

	authority = replace(authority, /\/$/, '');
	let endpoint = parse_authority(authority);
	if (endpoint?.skip != null)
		return skipped(endpoint.skip);
	if (endpoint == null)
		return skipped('malformed');

	let node = {
		protocol: 'shadowsocks', address: endpoint.address, port: endpoint.port,
		method: credentials.method, password: credentials.password, transport: 'raw', security: 'none'
	};
	let name = fragment.label ?? label;
	if (name != null && name != '')
		node.label = name;

	return finish_node(node, []);
}

function parse_standard(line, scheme, payload) {
	let fragment = parse_fragment(payload);
	if (fragment == null)
		return skipped('malformed');

	let query_parts = split_once(fragment.body, '?');
	let options = parse_query(query_parts[1]);
	if (options == null)
		return skipped('malformed');

	let authority_parts = split_once(query_parts[0], '@');
	if (authority_parts[1] == null)
		return skipped('malformed');
	let user = url_decode(authority_parts[0]);
	if (user == null)
		return skipped('malformed');

	let endpoint = parse_authority(authority_parts[1]);
	if (endpoint?.skip != null)
		return skipped(endpoint.skip);
	if (endpoint == null)
		return skipped('malformed');

	let node = { protocol: scheme, address: endpoint.address, port: endpoint.port };
	if (scheme == 'vless')
		node.uuid = user;
	else
		node.password = user;

	let label = fragment.label;
	if (label != null && label != '')
		node.label = label;

	let reason = copy_common(node, options, scheme == 'trojan' ? 'tls' : 'none');
	if (reason != null)
		return reason;
	if (scheme == 'vless')
		node.encryption = options.encryption ?? 'none';

	return finish_node(node, insecure_warning(options, label));
}

export function parse_line(line) {
	line = trim(line ?? '');
	if (line == '')
		return skipped('malformed');

	let scheme_parts = split_once(line, '://');
	if (scheme_parts[1] == null)
		return skipped('malformed');
	let scheme = lc(scheme_parts[0]);
	let payload = scheme_parts[1];

	if (scheme == 'vmess') {
		let fragment = parse_fragment(payload);
		if (fragment == null)
			return skipped('malformed');
		return parse_vmess(fragment.body, fragment.label);
	}
	if (scheme == 'ss')
		return parse_ss(payload, null);
	if (scheme == 'vless' || scheme == 'trojan')
		return parse_standard(line, scheme, payload);

	return skipped('unsupported_scheme');
};

function decode_subscription(text) {
	let body = trim(text ?? '');
	if (body == '')
		return null;

	let first = null;
	for (let line in split(body, '\n')) {
		line = trim(line);
		if (line != '') {
			first = line;
			break;
		}
	}
	if (first == null)
		return null;
	if (index(first, '://') >= 0)
		return replace(body, /\r\n/g, '\n');

	return decode_base64(body);
}

function increment(counts, reason) {
	counts[reason] = (counts[reason] ?? 0) + 1;
}

export function parse_body(text) {
	let raw = replace(trim(text ?? ''), /\r\n/g, '\n');
	if (substr(raw, 0, 8) == 'proxies:' || index(raw, '\nproxies:') >= 0)
		return { ok: false, nodes: [], skipped: {}, warnings: [], error: 'SUB_FORMAT_UNSUPPORTED' };

	let body = decode_subscription(text);
	if (body == null)
		return { ok: false, nodes: [], skipped: {}, warnings: [], error: 'SUB_DECODE_FAILED' };

	body = replace(body, /\r\n/g, '\n');
	if (substr(body, 0, 8) == 'proxies:' || index(body, '\nproxies:') >= 0)
		return { ok: false, nodes: [], skipped: {}, warnings: [], error: 'SUB_FORMAT_UNSUPPORTED' };

	let nodes = [], skipped_counts = {}, warnings = [];
	for (let line in split(body, '\n')) {
		line = trim(line);
		if (line == '')
			continue;

		let result = parse_line(line);
		if (result.node != null) {
			// Strong-key deduplication happens later, in sub.plan (06 step 1).
			push(nodes, result.node);
			for (let warning in (result.warnings ?? []))
				push(warnings, warning);
		}
		else if (result.skip != null) {
			increment(skipped_counts, result.skip);
		}
	}

	let skipped = {};
	for (let reason in sort(keys(skipped_counts)))
		skipped[reason] = skipped_counts[reason];

	if (!length(nodes))
		return { ok: false, nodes, skipped, warnings, error: 'SUB_NO_VALID_NODES' };

	return { ok: true, nodes, skipped, warnings, error: null };
};
