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
export const XRAY_MIN_VERSION = '26.3.27';
export const CHINADNS_MIN_VERSION = '2025.08.09';

// Paths
export const LOCK_FILE = '/var/lock/aether-proxy.lock';
export const CUSTOM_DIR = '/etc/aether-proxy/custom';
export const DATA_DIR = '/etc/aether-proxy/data';
export const KEYS_DIR = '/etc/aether-proxy/keys';
export const STATE_DIR = '/etc/aether-proxy/state';
export const STATE_FILE = 'state.json';
export const EVENTS_FILE = 'events.jsonl';
export const PROBE_FILE = 'probe.json';
export const BASELINE_DATA_DIR = '/usr/share/aether-proxy/data';
export const RUN_DIR = '/var/run/aether-proxy';
export const DOWNLOAD_DIR = '/tmp/aether-proxy-dl';
export const UPLOAD_DIR = '/tmp/aether-proxy-upload';
export const TMP_DIR = '/tmp';

// Rule data and custom list file names (docs/05 "文件", docs/08 "数据格式"), keyed by the
// name used in the render context's `data`.
export const DATA_IP_FILES = { chnroute4: 'chnroute4.txt', gfw_static4: 'gfw_static4.txt' };
export const CUSTOM_IP_FILES = { direct_ip4: 'direct_ip.txt', proxy_ip4: 'proxy_ip.txt' };
export const CUSTOM_DOMAIN_FILES = { direct_domain: 'direct_domain.txt', proxy_domain: 'proxy_domain.txt' };

// T1.4 (chinadns-ng renderer): nft set names that chinadns-ng writes resolved IPs into
// (docs/03-dns.md). Prefixed so they cannot collide with the T1.3 nft renderer's block.
export const CHINADNS_SET_CHNROUTE4 = 'chnroute4';
export const CHINADNS_SET_GFW4 = 'gfw4';
export const CHINADNS_SET_UPROXY4 = 'uproxy4';
export const CHINADNS_SET_UDIRECT4 = 'udirect4';
// Loopback address of the Xray DNS tunnel inbounds (the T1 upstreams).
export const DNS_TUNNEL_ADDR = '127.0.0.1';
// chinadns-ng cache sizing (docs/03-dns.md template)
export const CHINADNS_CACHE = 4096;
export const CHINADNS_CACHE_STALE = 3600;
export const CHINADNS_VERDICT_CACHE = 4096;

// T1.6 (Xray renderer)
export const PROXY_TAG = 'proxy';
export const DIRECT_TAG = 'direct';
export const TPROXY_IN_TAG = 'tproxy-in';
export const HTTP_IN_TAG = 'http-in';
export const DNS_IN_TAG_PREFIX = 'dns-in-';
export const HTTP_LISTEN = '127.0.0.1';
// Must equal the address chinadns-ng uses as its T1 upstream.
export const DNS_LISTEN = DNS_TUNNEL_ADDR;
export const TPROXY_LISTEN = '0.0.0.0';

// T1.3 (nft renderer)
export const DNS_PORT = 53;
// Reserved / special-purpose IPv4 ranges for the nft `reserved4` set (docs/01 "常量"). Order is render order.
export const RESERVED4 = [
	'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '192.168.0.0/16',
	'198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'
];

// T1.7 (check / render subcommands)
export const STAGING_SUBDIR = 'staging';
export const BOOT_LIST_FILE = 'boot.txt';
// Rule-data domain lists (docs/08 "数据格式"), keyed by the render context's `paths` names.
export const DATA_DOMAIN_FILES = { gfwlist: 'gfwlist.txt', chnlist: 'chnlist.txt', apple: 'apple.txt' };
// Render artifact name (as accepted by `render`) -> staged file name.
export const ARTIFACT_FILES = {
	nft: 'aether-proxy.nft',
	chinadns: 'chinadns.conf',
	dnsmasq: 'dnsmasq.conf',
	xray: 'xray.json'
};
export const XRAY_COMPONENT = 'xray';
export const CHINADNS_COMPONENT = 'chinadns-ng';
export const PRECHECK_NFT_FILE = 'precheck.nft';

// T2.2 (child process supervision)
export const PROC_DIR = '/proc';
export const SUPERVISE_TERM_GRACE_MS = 1000;

// T2.3 (system apply primitives)
export const DNSMASQ_CONFIG_DIR = '/var/etc';
export const DNSMASQ_TEMP_DIR = '/tmp/dnsmasq.d';
export const DNSMASQ_INIT = '/etc/init.d/dnsmasq';
export const DNSMASQ_FRAGMENT = 'aether-proxy.conf';
export const SETS_SAVE_FILE = 'sets.save';
export const NODE_IP_FILE = 'node-ip.json';
export const NFT_DYNAMIC_SETS = [ 'gfw4', 'udirect4', 'uproxy4' ];
export const CONFLICT_NFT_SSR = 'ss_spec';
export const CONFLICT_NFT_PASSWALL_PREFIX = 'passwall';
export const CONFLICT_PROCESSES = [ 'clash', 'mihomo' ];

// T2.4 (daemon lifecycle)
export const CONFIG_DIR = '/etc/config';
export const PROC_NET_TCP = '/proc/net/tcp';
export const PROC_NET_TCP6 = '/proc/net/tcp6';
export const SYS_CLASS_NET = '/sys/class/net';
export const DAEMON_CURRENT_DIR = 'current';
export const DAEMON_PREVIOUS_DIR = 'previous';
export const DAEMON_PORT_WAIT_SECS = 5;
export const DAEMON_POLL_MS = 100;
export const DAEMON_MONITOR_MS = 30000;

// T2.5 (monitor state machine and cadence)
export const MONITOR_RUNNING_INTERVAL_MS = 30000;
export const MONITOR_OTHER_INTERVAL_MS = 10000;
export const MONITOR_FAILSAFE_ROUNDS = 2;
export const MONITOR_DNS_FAILURES = 2;
export const MONITOR_T3_RETRY_SECS = 300;
export const MONITOR_NODE_REFRESH_SECS = 600;
export const DEV_NULL = '/dev/null';

// T2.9 (startup retry backoff)
export const START_RETRY_DELAYS = [ 30, 60, 300 ];

// T5.3 (subscription update)
export const SUB_LOCK_FILE = '/var/lock/aether-proxy-sub.lock';
export const SUB_WORK_SUBDIR = 'sub-work';
export const SUB_TEMP_PACKAGE = 'aetherproxy_sub';
export const SUB_STATE_FILE = 'sub.json';
export const PROG_INIT = '/etc/init.d/aether-proxy';
export const SUB_DELTA_SUBDIR = '.delta';
export const SUB_RENDER_SUBDIR = 'render';
export const RANDOM_DEVICE = '/dev/urandom';
export const SUB_SNAPSHOT_PACKAGE = 'aetherproxy_sub_snapshot';
export const SUB_SNAPSHOT_SUBDIR = 'snapshot';

// T6.2 (background jobs)
export const JOBS_SUBDIR = 'jobs';
export const JOB_FILE_SUFFIX = '.json';
export const JOB_RETENTION_SECS = 3600;
export const JOB_TIMEOUT_SECS = 600;
export const JOB_LOCK_PREFIX = '/var/lock/aether-proxy-job-';
export const JOB_LOCK_SUFFIX = '.lock';
export const JOB_ID_RE = /^j_[0-9]+_[0-9]+$/;
export const PROG_EXEC = '/usr/bin/aether-proxy';

// T6.3 (daemon subscription scheduler)
export const SCHEDULE_INTERVAL_MS = 60000;
export const SCHEDULE_HOUR_SECS = 3600;
export const SCHEDULE_MAX_JITTER = 0.1;
export const SCHEDULE_RANDOM_RANGE = 4294967296;
export const SCHEDULE_TEST_INTERVAL_ENV = 'AETHER_PROXY_TEST_SCHEDULE_INTERVAL_MS';
export const SCHEDULE_TEST_HOUR_ENV = 'AETHER_PROXY_TEST_SCHEDULE_HOUR_SECS';

// T7.6 (daemon update scheduler)
export const UPDATE_SCHEDULE_FILE = 'update-schedule.json';

// T7.3 (signed update checks)
export const UPDATE_FILE = 'updates.json';
export const UPDATE_PACKAGES = [ 'xray-core', 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn' ];
export const UPDATE_MANIFEST_MAX = 1048576;
export const UPDATE_DOWNLOAD_MAX_SECS = 30;
export const UPDATE_COMMAND_TIMEOUT_SECS = 35;
export const UPDATE_SPACE_RESERVE = 1048576;
export const UPDATE_RELEASE_FILE = '/etc/openwrt_release';

// T7.4 (signed package installation)
export const UPDATE_XRAY_WAIT_SECS = 60;
export const UPDATE_SERVICE_WAIT_SECS = 120;
export const UPDATE_PACKAGE_POLL_SECS = 1;
export const UPDATE_PORT_WAIT_SECS = 5;
export const UPDATE_TEST_WAIT_ENV = 'AETHER_PROXY_TEST_UPDATE_WAIT_SECS';
export const UPDATE_TEST_POLL_ENV = 'AETHER_PROXY_TEST_UPDATE_POLL_SECS';
export const UPDATE_INIT = '/etc/init.d/aether-proxy';
// procd `service signal` takes the service (init script) name and a numeric signal; SIGUSR2
// is 12 on every OpenWrt target we build (aarch64, x86_64).
export const UPDATE_SERVICE_NAME = 'aether-proxy';
export const UPDATE_SIGUSR2 = 12;

// T7.5 (signed rule-data updates).
export const DATA_UPDATE_ITEMS = [ 'gfwlist', 'chnlist', 'apple', 'chnroute4', 'gfw_static4' ];
export const UPDATE_DATA_MIN_PERCENT = 90;

// Default update channel (05 `channel_urls`, 08 "发布仓库").
export const CHANNEL_DEFAULT_URL = 'https://github.com/leochien0102/aether-proxy-channel/releases/download/channel-stable/';

// Event levels, most severe first (docs/09); `events --level` and the rpcd plugin validate against it.
export const EVENT_LEVELS = [ 'error', 'warn', 'notice', 'info', 'debug' ];

// T8.2 (`log`, `node import`, `custom`; docs/10 "`log`、`node import`、`custom`", 2026-10-16).
export const LOGREAD_TIMEOUT_SECS = 10;
export const LOG_SOURCES = [ 'all', 'aether-proxy', 'xray', 'dns' ];
export const LOG_LINES_DEFAULT = 200;
export const LOG_LINES_MAX = 2000;
export const CUSTOM_MAX_BYTES = 65536;
export const CUSTOM_INVALID_MAX = 20;
export const CUSTOM_RELOAD_TIMEOUT_SECS = 30;
// Custom list names as used by `custom get|set` and the rpcd `list_file`/`save_file` methods.
export const CUSTOM_LIST_NAMES = [ 'direct_domain', 'proxy_domain', 'direct_ip', 'proxy_ip' ];

// T8.4 (`status` notices and the overview page; docs/10 「概览页」, 2026-10-16).
// The xray-core entry of UPDATE_PACKAGES is the one muted by update.xray_auto == 'off'.
export const XRAY_CORE_PACKAGE = 'xray-core';
// Global-scope IPv6 detection for the IPV6_PRESENT notice (docs/03 「IPv4-only 的泄漏处理」).
export const IF_INET6_PATH = '/proc/net/if_inet6';
export const IPV6_SCOPE_GLOBAL = '00';

// T8.8 (docs/10 "规则与 DNS 页"): inventory covers the same five supported update items.
export const DATA_STATUS_NAMES = DATA_UPDATE_ITEMS;

// T8.9a (docs/04 "components" versions): informational queries have a bounded wait.
export const COMPONENT_VERSION_TIMEOUT_SECS = 5;

// T8.12a (docs/10 "Dashboard"): read-only traffic and connection snapshots.
export const PROC_NET_ROUTE = '/proc/net/route';
export const PROC_NET_DEV = '/proc/net/dev';
export const CONNTRACK_COUNT = '/proc/sys/net/netfilter/nf_conntrack_count';
export const STATS_NFT_TIMEOUT_SECS = 5;

// T8.12b: procd service signal uses the numeric SIGUSR1 value.
export const PROBE_SIGUSR1 = 10;

// T8.16 (docs/08 "检查"): default command search path when PATH is empty or unset.
export const UPDATE_DEFAULT_PATH = '/usr/sbin:/usr/bin:/sbin:/bin';

// T8.17 (docs/10 command table): check scratch directories never share daemon staging.
export const CHECK_DIR_PREFIX = 'check.';

// T8.23 (docs/08 package verification): allow procd's 30s stop plus cleanup and start/check.
export const UPDATE_RESTART_TIMEOUT_SECS = 90;

// T10.4 (docs/10 "概览页真机修正"): live component inventory budget, per binary.
export const COMPONENTS_TIMEOUT_SECS = 3;

// T9.5 (docs/03 bootstrap resolution and per-address LKG cache).
export const NODE_RESOLVE_ATTEMPTS = 3;
export const NODE_RESOLVE_TIMEOUT_SECS = 3;
export const NODE_LKG_MAX = 64;

// T9.6 (docs/08 "缓存过期"): package database mtimes invalidate discovery results.
export const OPKG_STATUS_PATH = '/usr/lib/opkg/status';
export const APK_INSTALLED_PATH = '/lib/apk/db/installed';

// T9.7 (docs/09 child output rate limiting).
export const CHILD_LOG_FILTER = '/usr/share/aether-proxy/logfilter.awk';
export const CHILD_LOG_FIFO_SUFFIX = '.log.fifo';
export const CHILD_LOG_FILTER_TEST_ENV = 'AETHER_PROXY_TEST_LOGFILTER';

// T9.10 (docs/07 "真实延迟", docs/10 "切换节点"). Order defines the default site.
export const PROBE_SITES = [
	{ name: 'google', label: 'Google', url: 'https://www.gstatic.com/generate_204' },
	{ name: 'cloudflare', label: 'Cloudflare', url: 'https://cp.cloudflare.com/generate_204' },
	{ name: 'apple', label: 'Apple', url: 'https://captive.apple.com/hotspot-detect.html' },
	{ name: 'youtube', label: 'YouTube', url: 'https://www.youtube.com/generate_204' },
	{ name: 'github', label: 'GitHub', url: 'https://github.com/robots.txt' }
];
export const PROBE_SITE_RE = /^[a-z0-9]{1,16}$/;
export const PROBE_URL_GRACE_SECS = 5;
export const NODE_USE_TIMEOUT_SECS = 10;

// T9.16 (docs/08 "回滚一起回滚"): backend first, then UI and its translation.
export const UPDATE_ROLLBACK_COMPANIONS = [ 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn' ];

// T9.23 (docs/03 "运营商下发的 DNS"). Lookup failure is a quiet, normal boot condition.
export const WAN_DNS_FALLBACK = '223.5.5.5';
export const WAN_DNS_TIMEOUT_SECS = 3;
export const WAN_DNS_RELOAD_TIMEOUT_SECS = 10;
