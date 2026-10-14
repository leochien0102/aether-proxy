'use strict';

// Node -> Xray outbound object (docs/06 "出站映射"). Pure: no fs, no sys. Kept separate from
// xray.uc so that a future routing feature can build several outbounds with the same code.

import { PROXY_TAG } from 'aetherproxy.const';
import { ipv4 } from 'aetherproxy.net';

// Insert only non-empty values: optional fields are omitted rather than written as null/"".
function put(obj, key, val) {
	if (val == null || val == '' || (type(val) == 'array' && length(val) == 0))
		return;

	obj[key] = val;
};

// The node's own address when it is a domain name, else null. Used as the default for
// SNI / Host, because the outbound address may be replaced by a resolved IP.
function origin_domain(node) {
	return (node.address != null && ipv4(node.address) == null) ? node.address : null;
};

function stream_settings(node) {
	let net = node.transport ?? 'raw';
	let ss = { network: net };
	let domain = origin_domain(node);

	switch (node.security) {
	case 'tls':
		ss.security = 'tls';
		let tls = {};
		put(tls, 'serverName', node.sni ?? domain);
		put(tls, 'alpn', node.alpn);
		put(tls, 'fingerprint', node.fingerprint);
		put(tls, 'pinnedPeerCertSha256', node.pinned_cert_sha256);
		put(tls, 'verifyPeerCertByName', node.verify_name);
		ss.tlsSettings = tls;
		break;
	case 'reality':
		ss.security = 'reality';
		let rl = {};
		put(rl, 'serverName', node.sni);
		rl.fingerprint = node.fingerprint ?? 'chrome';
		put(rl, 'publicKey', node.reality_pbk);
		put(rl, 'shortId', node.reality_sid);
		put(rl, 'spiderX', node.reality_spx);
		ss.realitySettings = rl;
		break;
	}

	switch (net) {
	case 'ws':
	case 'httpupgrade':
	case 'xhttp': {
		let t = {};
		put(t, 'path', node.path);
		put(t, 'host', node.host ?? domain);
		if (net == 'xhttp')
			put(t, 'mode', node.xhttp_mode);
		ss[net == 'ws' ? 'wsSettings' : net + 'Settings'] = t;
		break;
	}
	case 'grpc': {
		let t = {};
		put(t, 'serviceName', node.service_name);
		ss.grpcSettings = t;
		break;
	}
	case 'raw':
		if (node.header_type == 'http')
			ss.rawSettings = { header: { type: 'http' } };
		break;
	}

	return ss;
};

// node_ip: resolved address, or null to use the node's own address.
export function build_outbound(node, node_ip) {
	let addr = node_ip ?? node.address;
	let settings = {};

	switch (node.protocol) {
	case 'vless': {
		let user = { id: node.uuid, encryption: node.encryption ?? 'none' };
		put(user, 'flow', node.flow);
		settings.vnext = [ { address: addr, port: node.port, users: [ user ] } ];
		break;
	}
	case 'vmess':
		settings.vnext = [ {
			address: addr, port: node.port,
			users: [ { id: node.uuid, security: node.method ?? 'auto' } ]
		} ];
		break;
	case 'trojan':
		settings.servers = [ { address: addr, port: node.port, password: node.password } ];
		break;
	case 'shadowsocks':
		settings.servers = [ { address: addr, port: node.port, method: node.method, password: node.password } ];
		break;
	}

	return {
		tag: PROXY_TAG,
		protocol: node.protocol,
		settings: settings,
		streamSettings: stream_settings(node)
	};
};
