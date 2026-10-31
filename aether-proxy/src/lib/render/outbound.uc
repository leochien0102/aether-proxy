'use strict';

// Node -> Xray outbound object (docs/06 "出站映射"). Pure: no fs, no sys. Kept separate from
// xray.uc so that a future routing feature can build several outbounds with the same code.
// Optional extensions use the exact Xray JSON names from docs/05 "config node".

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
	// `network`, not `method`: the latest stable Xray has no streamSettings.method and would
	// silently fall back to raw (06).
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
		put(tls, 'echConfigList', node.ech_config_list);
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
		put(rl, 'mldsa65Verify', node.reality_pqv);
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
		if (net == 'ws' && node.ws_heartbeat != null)
			t.heartbeatPeriod = node.ws_heartbeat;
		if (net == 'xhttp') {
			put(t, 'mode', node.xhttp_mode);
			if (node.xhttp_extra != null)
				t.extra = json(node.xhttp_extra);
		}
		ss[net == 'ws' ? 'wsSettings' : net + 'Settings'] = t;
		break;
	}
	case 'grpc': {
		let t = {};
		put(t, 'serviceName', node.service_name);
		// Do not use put(): false is an explicitly configured multiMode value.
		if (node.grpc_multi_mode != null)
			t.multiMode = node.grpc_multi_mode;
		ss.grpcSettings = t;
		break;
	}
	case 'raw':
		if (node.header_type == 'http')
			ss.rawSettings = { header: { type: 'http' } };
		break;
	}

	if (node.tcp_fast_open || node.tcp_mptcp) {
		ss.sockopt = {};
		if (node.tcp_fast_open)
			ss.sockopt.tcpFastOpen = true;
		if (node.tcp_mptcp)
			ss.sockopt.tcpMptcp = true;
	}

	return ss;
};

// node_ip: resolved address, or null to use the node's own address.
export function build_outbound(node, node_ip) {
	let addr = node_ip ?? node.address;
	let settings = {};

	switch (node.protocol) {
	case 'vless': {
		settings.address = addr;
		settings.port = node.port;
		settings.id = node.uuid;
		settings.encryption = node.encryption ?? 'none';
		put(settings, 'flow', node.flow);
		break;
	}
	case 'vmess':
		settings.address = addr;
		settings.port = node.port;
		settings.id = node.uuid;
		settings.security = node.method ?? 'auto';
		break;
	case 'trojan':
		settings.address = addr;
		settings.port = node.port;
		settings.password = node.password;
		break;
	case 'socks': {
		let server = { address: addr, port: node.port };
		if (node.username != null && node.username != '' && node.password != null && node.password != '')
			server.users = [ { user: node.username, pass: node.password } ];
		settings.servers = [ server ];
		break;
	}
	case 'shadowsocks':
		settings.address = addr;
		settings.port = node.port;
		settings.method = node.method;
		settings.password = node.password;
		break;
	}

	let outbound = {
		tag: PROXY_TAG,
		protocol: node.protocol,
		settings: settings,
		streamSettings: stream_settings(node)
	};
	if (node.mux) {
		outbound.mux = { enabled: true };
		// Zero and -1 are valid; omit only unset tuning values.
		if (node.mux_concurrency != null)
			outbound.mux.concurrency = node.mux_concurrency;
		if (node.mux_xudp_concurrency != null)
			outbound.mux.xudpConcurrency = node.mux_xudp_concurrency;
		put(outbound.mux, 'xudpProxyUDP443', node.mux_xudp_udp443);
	}
	return outbound;
};
