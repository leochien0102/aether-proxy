'use strict';

// Declarative field table: the machine-readable version of docs/05-config.md.
// Pure data (docs/12 rule 1). Every field in 05 appears here, in 05's order; that order is
// also the key order of the normalized snapshot. Adding a field requires editing 05 first.
//
// Field descriptor keys:
//   name      UCI option name
//   type      bool | int | string | enum | path | domain | url | address | list
//   default   value used when the option is unset or empty (null = no default)
//   enum      allowed values (type enum)
//   min, max  inclusive bounds (type int)
//   item      element type of a list: ipv4 | ip_or_cidr | mac | upstream | hostport | url | string
//   min_items, max_items   list length bounds
//   required  unset is an error: true, or (node only) a list of the protocols for which it is
//             required; with `protocols` set, true means "for those protocols"
//   protocols node only: the field belongs to these protocols; a default or a
//             requirement applies only to a node using one of them
//   proto_default  node only: per-protocol default, wins over `default`
//   requires_when  node only: { field, value } the field is required when the other one has this value

import * as C from 'aetherproxy.const';

// TODO(design): docs/06 says the supported shadowsocks method list is "a constant for the
// target Xray version" but does not give it. This is the AEAD / AEAD-2022 set from Xray's
// shadowsocks documentation; "none"/"plain" are deliberately excluded.
export const SS_METHODS = [
	'aes-128-gcm', 'aes-256-gcm', 'chacha20-poly1305', 'chacha20-ietf-poly1305',
	'xchacha20-poly1305', 'xchacha20-ietf-poly1305',
	'2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305'
];

// Section-name patterns (docs/05).
export const SUBSCRIPTION_NAME_RE = /^s_[0-9a-f]{8}$/;
export const NODE_NAME_RE = /^n_[0-9a-f]{32}$/;

const main = [
	{ name: 'enabled', type: 'bool', default: false },
	{ name: 'mode', type: 'enum', enum: [ 'gfw', 'bypass_cn', 'global' ], default: 'bypass_cn' },
	{ name: 'node', type: 'string', default: null },
	{ name: 'lan_ifaces', type: 'list', item: 'string', default: [ 'br-lan' ] },
	{ name: 'unlisted_policy', type: 'enum', enum: [ 'follow', 'direct' ], default: 'follow' },
	{ name: 'quic_block', type: 'bool', default: true },
	{ name: 'dns_hijack', type: 'bool', default: true },
	{ name: 'ipv6_filter', type: 'bool', default: true },
	{ name: 'filter_https_rr', type: 'bool', default: true },
	{ name: 'fail_open', type: 'bool', default: true },
	{ name: 'sniffing', type: 'bool', default: true },
	{ name: 'log_level', type: 'enum', enum: [ 'error', 'warn', 'notice', 'info', 'debug' ], default: 'notice' },
	{ name: 'xray_log_level', type: 'enum', enum: [ 'error', 'warning', 'info', 'debug' ], default: 'warning' },
	{ name: 'boot_wait_timeout', type: 'int', min: 0, max: 600, default: 120 },
	{ name: 'boot_check_targets', type: 'list', item: 'hostport', default: [ '223.5.5.5:53', '119.29.29.29:53' ] },
	{ name: 'xray_bin', type: 'path', default: null },
	{ name: 'chinadns_bin', type: 'path', default: null }
];

const dns = [
	{ name: 'china_dns', type: 'list', item: 'upstream', default: [ '223.5.5.5', '119.29.29.29' ] },
	{ name: 'trust_dns', type: 'list', item: 'ipv4', min_items: 1, max_items: 2, default: [ '8.8.8.8', '1.1.1.1' ] },
	{ name: 'direct_dns', type: 'list', item: 'upstream', default: [ 'tcp://8.8.8.8', 'tcp://1.1.1.1' ] },
	{ name: 'allow_china_fallback', type: 'bool', default: true },
	{ name: 'dns_probe_domain', type: 'domain', default: 'www.google.com' },
	{ name: 'dnsmasq_instance', type: 'string', default: null }
];

const host = [
	{ name: 'enabled', type: 'bool', default: true },
	{ name: 'name', type: 'string', default: null },
	{ name: 'ip', type: 'list', item: 'ip_or_cidr', default: [] },
	{ name: 'mac', type: 'list', item: 'mac', default: [] },
	{ name: 'policy', type: 'enum', enum: [ 'follow', 'direct', 'proxy' ], default: 'follow' },
	{ name: 'udp', type: 'bool', default: false }
];

const subscription = [
	{ name: 'enabled', type: 'bool', default: true },
	{ name: 'name', type: 'string', default: null },
	// TODO(design): 05 gives no default for `url` and does not say it is required; a
	// subscription without one cannot be fetched, so it is rejected.
	{ name: 'url', type: 'url', required: true, default: null },
	{ name: 'user_agent', type: 'string', default: C.PROG + '/' + C.VERSION },
	{ name: 'fetch_via', type: 'enum', enum: [ 'auto', 'direct', 'proxy' ], default: 'auto' },
	{ name: 'interval_hours', type: 'int', min: 0, default: 24 }
];

// TODO(design): 05 does not mark which node fields are required beyond the per-protocol
// rules (05 "校验规则" 6). `protocol`, `address` and `port` are required here because a
// node cannot be rendered without them. Defaults for `source` (null), `stale` (false) and
// `security` (none) are likewise not in 05.
const node = [
	{ name: 'label', type: 'string', default: null },
	{ name: 'source', type: 'string', default: null },
	{ name: 'stale', type: 'bool', default: false },
	{ name: 'match_strong', type: 'string', default: null },
	{ name: 'match_weak', type: 'string', default: null },
	{ name: 'protocol', type: 'enum', enum: [ 'vless', 'vmess', 'trojan', 'shadowsocks' ], required: true, default: null },
	{ name: 'address', type: 'address', required: true, default: null },
	{ name: 'port', type: 'int', min: 1, max: 65535, required: true, default: null },
	{ name: 'uuid', type: 'string', protocols: [ 'vless', 'vmess' ], required: true, default: null },
	{ name: 'password', type: 'string', protocols: [ 'trojan', 'shadowsocks' ], required: true, default: null },
	// ss: required and checked against SS_METHODS; vmess: the `security` value, default auto.
	{ name: 'method', type: 'string', protocols: [ 'shadowsocks', 'vmess' ], required: [ 'shadowsocks' ], default: null, proto_default: { vmess: 'auto' } },
	{ name: 'flow', type: 'string', protocols: [ 'vless' ], default: null },
	{ name: 'encryption', type: 'string', protocols: [ 'vless' ], default: null, proto_default: { vless: 'none' } },
	{ name: 'transport', type: 'enum', enum: [ 'raw', 'ws', 'grpc', 'httpupgrade', 'xhttp' ], default: 'raw' },
	{ name: 'host', type: 'string', default: null },
	{ name: 'path', type: 'string', default: null },
	{ name: 'service_name', type: 'string', default: null },
	{ name: 'xhttp_mode', type: 'string', default: null },
	{ name: 'header_type', type: 'string', default: null },
	{ name: 'security', type: 'enum', enum: [ 'none', 'tls', 'reality' ], default: 'none' },
	{ name: 'sni', type: 'string', default: null, requires_when: { field: 'security', value: 'reality' } },
	{ name: 'alpn', type: 'list', item: 'string', default: [] },
	{ name: 'fingerprint', type: 'string', default: null },
	{ name: 'pinned_cert_sha256', type: 'string', default: null },
	{ name: 'verify_name', type: 'string', default: null },
	{ name: 'reality_pbk', type: 'string', default: null, requires_when: { field: 'security', value: 'reality' } },
	{ name: 'reality_sid', type: 'string', default: null },
	{ name: 'reality_spx', type: 'string', default: null }
];

const update = [
	// TODO(design): 05 says "project release URL + optional mirrors" without giving the URL
	// (D3/D4 undecided), so the default is an empty list.
	{ name: 'channel_urls', type: 'list', item: 'url', default: [] },
	{ name: 'data_auto', type: 'bool', default: true },
	{ name: 'data_hour', type: 'int', min: 0, max: 23, default: 4 },
	{ name: 'xray_auto', type: 'enum', enum: [ 'off', 'notify', 'auto' ], default: 'notify' },
	{ name: 'chinadns_auto', type: 'enum', enum: [ 'off', 'notify' ], default: 'notify' }
];

// TODO(design): 05 gives no ranges for the probe numbers; all must be >= 1, with no upper
// bound. expect_code is limited to valid HTTP status codes.
const probe = [
	{ name: 'url', type: 'url', default: 'https://www.gstatic.com/generate_204' },
	{ name: 'expect_code', type: 'int', min: 100, max: 599, default: 204 },
	{ name: 'timeout', type: 'int', min: 1, default: 5 },
	{ name: 'fail_threshold', type: 'int', min: 1, default: 3 },
	{ name: 'recover_threshold', type: 'int', min: 1, default: 2 },
	{ name: 'node_timeout', type: 'int', min: 1, default: 3 },
	{ name: 'node_concurrency', type: 'int', min: 1, default: 8 }
];

// Named singleton sections map to the section name; the rest are per-type collections.
export const SCHEMA = { main, dns, update, probe, host, subscription, node };
