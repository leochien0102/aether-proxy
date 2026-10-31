'use strict';

// Declarative field table: the machine-readable version of docs/05-config.md.
// Pure data (docs/12 rule 1). Every field in 05 appears here, in 05's order; that order is
// also the key order of the normalized snapshot. Adding a field requires editing 05 first.
//
// Field descriptor keys:
//   name      UCI option name
//   type      bool | int | string | json_object (UCI string) | enum | path | domain | url | address | list
//   default   value used when the option is unset or empty (null = no default)
//   enum      allowed values (type enum)
//   min, max  inclusive bounds (type int)
//   item      list element type: ipv4 | ip_or_cidr | ip_or_range | mac | upstream | china_dns | trust_dns
//             | hostport | url | ifname | string
//   min_items, max_items   list length bounds
//   required  unset is an error: true, or (node only) a list of the protocols for which it is
//             required; with `protocols` set, true means "for those protocols"
//   protocols node only: the field belongs to these protocols; a default or a
//             requirement applies only to a node using one of them
//   transports, securities  node only: owning transport/security layer (renderer gates output)
//   omit_unset  leave absent optional extensions out of the snapshot for byte compatibility
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

// Xray 26.9.30 fingerprint names (review B-F1). TLS additionally allows unsafe;
// REALITY excludes unsafe and hellogolang. Names are case-insensitive in Xray.
export const FINGERPRINTS = [
	'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq',
	'random', 'randomized', 'randomizednoalpn', 'hellogolang',
	'hellofirefox_120', 'hellofirefox_148', 'hellochrome_120', 'hellochrome_131', 'hellochrome_133',
	'helloios_13', 'helloios_14', 'helloedge_106', 'hellosafari_26_3', 'hello360_11_0', 'helloqq_11_1',
	'hellorandomized', 'hellorandomizedalpn', 'hellorandomizednoalpn',
	'hellofirefox_auto', 'hellofirefox_55', 'hellofirefox_56', 'hellofirefox_63', 'hellofirefox_65',
	'hellofirefox_99', 'hellofirefox_102', 'hellofirefox_105',
	'hellochrome_auto', 'hellochrome_58', 'hellochrome_62', 'hellochrome_70', 'hellochrome_72',
	'hellochrome_83', 'hellochrome_87', 'hellochrome_96', 'hellochrome_100', 'hellochrome_102',
	'hellochrome_106_shuffle', 'helloios_auto', 'helloios_11_1', 'helloios_12_1',
	'helloandroid_11_okhttp', 'helloedge_85', 'helloedge_auto', 'hellosafari_16_0', 'hellosafari_auto',
	'hello360_auto', 'hello360_7_5', 'helloqq_auto', 'hellochrome_100_psk', 'hellochrome_112_psk_shuf',
	'hellochrome_114_padding_psk_shuf', 'hellochrome_115_pq', 'hellochrome_115_pq_psk', 'hellochrome_120_pq'
];
export const XHTTP_MODES = [ 'auto', 'packet-up', 'stream-up', 'stream-one' ];

// Section-name patterns (docs/05).
export const SUBSCRIPTION_NAME_RE = /^s_[0-9a-f]{8}$/;
export const NODE_NAME_RE = /^n_[0-9a-f]{32}$/;

const main = [
	{ name: 'enabled', type: 'bool', default: false },
	{ name: 'mode', type: 'enum', enum: [ 'gfw', 'bypass_cn', 'global' ], default: 'bypass_cn' },
	{ name: 'node', type: 'string', default: null },
	{ name: 'lan_ifaces', type: 'list', item: 'ifname', min_items: 1, default: [ 'br-lan' ] },
	{ name: 'unlisted_policy', type: 'enum', enum: [ 'follow', 'direct' ], default: 'follow' },
	{ name: 'quic_block', type: 'bool', default: true },
	{ name: 'dns_hijack', type: 'bool', default: true },
	{ name: 'ipv6_filter', type: 'bool', default: true },
	{ name: 'filter_https_rr', type: 'bool', default: true },
	{ name: 'fail_open', type: 'bool', default: true },
	{ name: 'degrade_gfw', type: 'bool', default: true },
	{ name: 'sniffing', type: 'bool', default: true },
	{ name: 'log_level', type: 'enum', enum: [ 'error', 'warn', 'notice', 'info', 'debug' ], default: 'notice' },
	{ name: 'xray_log_level', type: 'enum', enum: [ 'error', 'warning', 'info', 'debug' ], default: 'warning' },
	{ name: 'boot_wait_timeout', type: 'int', min: 0, max: 600, default: 120 },
	{ name: 'boot_check_targets', type: 'list', item: 'hostport', default: [ '223.5.5.5:53', '114.114.114.114:53' ] },
	{ name: 'xray_bin', type: 'path', default: null },
	{ name: 'chinadns_bin', type: 'path', default: null }
];

const dns = [
	{ name: 'china_dns', type: 'list', item: 'china_dns', default: [ 'wan', '114.114.114.114' ] },
	{ name: 'trust_dns', type: 'list', item: 'trust_dns', min_items: 1, max_items: 2,
	  default: [ '8.8.8.8', '1.1.1.1' ] },
	{ name: 'direct_dns_enabled', type: 'bool', default: false },
	{ name: 'direct_dns', type: 'list', item: 'upstream', default: [ 'tcp://9.9.9.9' ] },
	{ name: 'allow_china_fallback', type: 'bool', default: true },
	{ name: 'dns_probe_domain', type: 'domain', default: 'www.google.com' },
	{ name: 'dnsmasq_instance', type: 'string', default: null }
];

const host = [
	{ name: 'enabled', type: 'bool', default: true },
	{ name: 'name', type: 'string', default: null },
	{ name: 'ip', type: 'list', item: 'ip_or_range', default: [] },
	{ name: 'mac', type: 'list', item: 'mac', default: [] },
	{ name: 'policy', type: 'enum', enum: [ 'follow', 'direct', 'bypass_cn', 'gfw', 'proxy' ], default: 'follow' },
	{ name: 'udp', type: 'bool', default: false }
];

const sub = [
	{ name: 'user_agent', type: 'string', default: C.PROG + '/' + C.VERSION },
	{ name: 'fetch_via', type: 'enum', enum: [ 'auto', 'direct', 'proxy' ], default: 'auto' },
	{ name: 'interval_hours', type: 'int', min: 0, default: 24 }
];

const subscription = [
	{ name: 'enabled', type: 'bool', default: true },
	{ name: 'name', type: 'string', default: null },
	{ name: 'url', type: 'url', required: true, default: null },
	// Null means inherit from sub; config.normalize materializes the effective values (docs/05).
	{ name: 'user_agent', type: 'string', default: null },
	{ name: 'fetch_via', type: 'enum', enum: [ 'auto', 'direct', 'proxy' ], default: null },
	{ name: 'interval_hours', type: 'int', min: 0, default: null }
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
	{ name: 'protocol', type: 'enum', enum: [ 'vless', 'vmess', 'trojan', 'shadowsocks', 'socks' ],
	  required: true, default: null },
	{ name: 'address', type: 'address', required: true, default: null },
	{ name: 'port', type: 'int', min: 1, max: 65535, required: true, default: null },
	{ name: 'uuid', type: 'string', protocols: [ 'vless', 'vmess' ], required: true, default: null },
	{ name: 'username', type: 'string', protocols: [ 'socks' ], default: null, omit_unset: true },
	{ name: 'password', type: 'string', protocols: [ 'trojan', 'shadowsocks', 'socks' ],
	  required: [ 'trojan', 'shadowsocks' ], default: null },
	// ss: required and checked against SS_METHODS; vmess: the `security` value, default auto.
	{ name: 'method', type: 'string', protocols: [ 'shadowsocks', 'vmess' ], required: [ 'shadowsocks' ], default: null, proto_default: { vmess: 'auto' } },
	{ name: 'flow', type: 'enum', enum: [ 'xtls-rprx-vision', 'xtls-rprx-vision-udp443' ],
	  protocols: [ 'vless' ], default: null },
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
	{ name: 'reality_spx', type: 'string', default: null },
	// docs/05 extensions have no materialized defaults: absent must stay absent (T9.14).
	// Inactive-layer values are kept and not rendered; ECH/PQV are opaque strings (docs/05).
	{ name: 'reality_pqv', type: 'string', securities: [ 'reality' ], default: null, omit_unset: true },
	{ name: 'ech_config_list', type: 'string', securities: [ 'tls' ], default: null, omit_unset: true },
	{ name: 'grpc_multi_mode', type: 'bool', transports: [ 'grpc' ], default: null, omit_unset: true },
	{ name: 'ws_heartbeat', type: 'int', min: 1, max: 3600,
	  transports: [ 'ws' ], default: null, omit_unset: true },
	{ name: 'xhttp_extra', type: 'json_object', transports: [ 'xhttp' ], default: null, omit_unset: true },
	{ name: 'mux', type: 'bool', default: null, omit_unset: true },
	{ name: 'mux_concurrency', type: 'int', min: -1, max: 1024, default: null, omit_unset: true },
	{ name: 'mux_xudp_concurrency', type: 'int', min: -1, max: 1024, default: null, omit_unset: true },
	{ name: 'mux_xudp_udp443', type: 'enum', enum: [ 'reject', 'allow', 'skip' ],
	  default: null, omit_unset: true },
	{ name: 'tcp_fast_open', type: 'bool', default: null, omit_unset: true },
	{ name: 'tcp_mptcp', type: 'bool', default: null, omit_unset: true }
];

const update = [
	// Default channel first, mirrors appended by the user (05, 08 "发布仓库").
	{ name: 'channel_urls', type: 'list', item: 'url', default: [ C.CHANNEL_DEFAULT_URL ] },
	{ name: 'data_auto', type: 'bool', default: true },
	{ name: 'data_hour', type: 'int', min: 0, max: 23, default: 4 },
	// Randomized by uci-defaults at install time; consumers treat null as 30 (docs/05).
	{ name: 'data_minute', type: 'int', min: 0, max: 59, default: null },
	{ name: 'xray_auto', type: 'enum', enum: [ 'off', 'notify', 'auto' ], default: 'notify' },
];

// TODO(design): 05 gives no ranges for the probe numbers; all must be >= 1, with no upper
// bound. expect_code is limited to valid HTTP status codes.
const probe = [
	{ name: 'url', type: 'url', default: 'https://www.gstatic.com/generate_204' },
	{ name: 'expect_code', type: 'int', min: 100, max: 599, default: 204 },
	{ name: 'timeout', type: 'int', min: 1, max: 30, default: 5 },
	{ name: 'fail_threshold', type: 'int', min: 1, default: 3 },
	{ name: 'recover_threshold', type: 'int', min: 1, default: 2 },
	{ name: 'node_timeout', type: 'int', min: 1, default: 3 },
	{ name: 'node_concurrency', type: 'int', min: 1, default: 8 }
];

// Named singleton sections map to the section name; the rest are per-type collections.
export const SCHEMA = { main, dns, update, probe, sub, host, subscription, node };
