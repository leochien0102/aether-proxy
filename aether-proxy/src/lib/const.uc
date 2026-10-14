'use strict';

// Single source of truth for ports, marks, table names and paths (docs/01-architecture.md).
// Nothing else in the code base may spell these out as literals.

// The package Makefile replaces the placeholder with "PKG_VERSION-PKG_RELEASE" at
// install time. The comparison literal is split so that sed does not rewrite it too.
const RAW_VERSION = '@@VERSION@@';
export const VERSION = (RAW_VERSION == '@@' + 'VERSION@@') ? '0.0.0-dev' : RAW_VERSION;

// Names. Hyphenated form for files/tags, plain form for identifiers (docs/README.md "naming").
export const PROG = 'aether-proxy';
export const SYSLOG_TAG = 'aether-proxy';
export const SYSLOG_TAG_XRAY = 'aether-proxy-xray';
export const SYSLOG_TAG_DNS = 'aether-proxy-dns';
export const UCI_PACKAGE = 'aetherproxy';

// Dataplane
export const NFT_TABLE = 'inet aetherproxy';
export const TPROXY_PORT = 31080;
export const HTTP_PORT = 31081;
export const DNS_TUNNEL_PORTS = [ 31082, 31083 ];
export const CHINADNS_PORT = 31053;
export const FWMARK = '0x00080000/0x00080000';
export const QUIC_MARK = '0x00100000';
export const ROUTE_TABLE = 233;
export const RULE_PREF = 900;

// Minimum component versions
export const XRAY_MIN_VERSION = '26.9.30';
export const CHINADNS_MIN_VERSION = '2025.08.09';

// Paths
export const LOCK_FILE = '/var/lock/aether-proxy.lock';
export const CUSTOM_DIR = '/etc/aether-proxy/custom';
export const DATA_DIR = '/etc/aether-proxy/data';
export const KEYS_DIR = '/etc/aether-proxy/keys';
export const STATE_DIR = '/etc/aether-proxy/state';
export const BASELINE_DATA_DIR = '/usr/share/aether-proxy/data';
export const BIN_DIR = '/usr/share/aether-proxy/bin';
export const RUN_DIR = '/var/run/aether-proxy';
export const DOWNLOAD_DIR = '/tmp/aether-proxy-dl';
export const UPLOAD_DIR = '/tmp/aether-proxy-upload';
export const TMP_DIR = '/tmp';

// Rule data and custom list file names (docs/05 "文件", docs/08 "数据格式"), keyed by the
// name used in the render context's `data`.
export const DATA_IP_FILES = { chnroute4: 'chnroute4.txt', gfw_static4: 'gfw_static4.txt' };
export const CUSTOM_IP_FILES = { direct_ip4: 'direct_ip.txt', proxy_ip4: 'proxy_ip.txt' };
export const CUSTOM_DOMAIN_FILES = { direct_domain: 'direct_domain.txt', proxy_domain: 'proxy_domain.txt' };

// T1.3 (nft renderer)
export const DNS_PORT = 53;
// Reserved / special-purpose IPv4 ranges for the nft `reserved4` set (docs/01 "常量"). Order is render order.
export const RESERVED4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '192.168.0.0/16',
	'198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'
];
