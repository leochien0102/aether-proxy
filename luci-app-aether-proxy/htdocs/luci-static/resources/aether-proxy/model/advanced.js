'use strict';
'require baseclass';

/*
 * Pure view model for the advanced page (docs/10 「高级页」, docs/tasks/m8.md
 * T8.11b).
 *
 * validate() mirrors the authoritative command-line rules one to one so the
 * page precheck reaches the same conclusion as `aether-proxy check` (docs/10
 * 访问控制页「保存前校验」: the command line stays authoritative). The
 * reference implementations are aether-proxy/src/lib/schema.uc (types and
 * inclusive bounds) and aether-proxy/src/lib/config.uc (int, hostport, url,
 * path, non-empty string). Each helper below names the function it mirrors.
 *
 * description() and the *_choices() functions carry the wording required by
 * docs/10 「高级页」; keeping it here instead of the view makes it testable
 * without a browser. Nothing here issues requests or touches the DOM, and
 * every msgid must have an entry in po/zh_Hans/aether-proxy.po.
 */

/* schema.uc: integer fields and their inclusive bounds. A missing max means
   "no upper bound"; the CLI still caps the digit count at 9 (see int_error). */
const INT_BOUNDS = {
	boot_wait_timeout: { min: 0, max: 600 },
	expect_code: { min: 99, max: 599 },
	timeout: { min: 1 },
	fail_threshold: { min: 1 },
	recover_threshold: { min: 1 },
	node_timeout: { min: 1 },
	node_concurrency: { min: 1 }
};

/* schema.uc: bool fields. LuCI Flag values are always the strings '0'/'1'. */
const BOOL_FIELDS = [ 'quic_block', 'dns_hijack', 'ipv6_filter', 'filter_https_rr',
	'fail_open', 'sniffing' ];

const LOG_LEVELS = [ 'error', 'warn', 'notice', 'info', 'debug' ];
const XRAY_LOG_LEVELS = [ 'error', 'warning', 'info', 'debug' ];

/* schema.uc defaults for the fields that have one. xray_bin, chinadns_bin and
   dnsmasq_instance default to "unset", so they are absent here. Values are the
   strings (or string arrays) LuCI widgets expect. */
const DEFAULTS = {
	lan_ifaces: [ 'br-lan' ],
	quic_block: '1', dns_hijack: '1', ipv6_filter: '1', filter_https_rr: '1',
	fail_open: '1', sniffing: '1',
	log_level: 'notice', xray_log_level: 'warning',
	boot_wait_timeout: '120', boot_check_targets: [ '223.5.5.5:53', '114.114.114.114:53' ],
	url: 'https://www.gstatic.com/generate_204',
	expect_code: '204', timeout: '5', fail_threshold: '3', recover_threshold: '2',
	node_timeout: '3', node_concurrency: '8'
};

const LOG_LABELS = {
	error: _('Error'), warn: _('Warning'), notice: _('Notice'), info: _('Info'),
	warning: _('Warning'), debug: _('Debug')
};

/* docs/10 「高级页」: one sentence per switch, taken from docs/05. The three
   switches that need an extra "when disabled" clause carry it in the same
   string (fail_open, dns_hijack, ipv6_filter). */
const FIELD_TEXT = {
	lan_ifaces: _('Which inbound interfaces to intercept; usually br-lan.'),
	quic_block: _('Reject UDP 443 to proxied destinations (except game-mode hosts).'),
	dns_hijack: _('Hijack LAN port 53 to the router (direct hosts are excepted). When disabled, devices with their own DNS servers bypass the routing rules.'),
	ipv6_filter: _('All AAAA queries return an empty answer so devices use IPv4 only. IPv6 address assignment on the LAN is not affected.'),
	filter_https_rr: _('Filter HTTPS RR records (qtype 65).'),
	fail_open: _('Remove the interception rules while Xray is down so traffic goes direct. When disabled, proxied traffic is interrupted while Xray is unavailable instead of falling back to direct.'),
	sniffing: _('Xray inbound sniffing for http/tls/quic with routeOnly=false (the node connects by domain).'),
	url: _('URL polled by the health check; must start with http:// or https:// and contain no whitespace.'),
	boot_wait_timeout: _('Seconds to wait for the network at boot; 0 disables the wait.'),
	boot_check_targets: _('IPv4 address and port probed while waiting for the network, written as address:port.'),
	expect_code: _('HTTP status code the health check expects.'),
	timeout: _('Health check timeout in seconds.'),
	fail_threshold: _('Consecutive failures before the node is marked unhealthy.'),
	recover_threshold: _('Consecutive successes before the node is marked healthy again.'),
	node_timeout: _('TCP reachability probe timeout per node, in seconds.'),
	node_concurrency: _('How many nodes to probe at the same time.'),
	xray_bin: _('Absolute path to the Xray binary without whitespace; leave empty to search the standard locations.'),
	chinadns_bin: _('Absolute path to the chinadns-ng binary without whitespace; leave empty to search the standard locations.'),
	dnsmasq_instance: _('Name of the dnsmasq instance to use; leave empty to detect it automatically.')
};

/* docs/09 「logd 容量」: only the debug choice carries this hint. */
const DEBUG_HINT = _('Debug logs fill the 64 KB logd buffer quickly; increase the buffer under System → Logs and switch back to notice when done.');

/* config.uc int_error: the exact integer syntax plus the schema bounds. */
function int_error(bounds, value) {
	if (typeof value != 'string' || !/^-?[0-9]{1,9}$/.test(value))
		return _('Enter an integer.');

	const n = Number(value);

	if ((bounds.min != null && n < bounds.min) || (bounds.max != null && n > bounds.max))
		return bounds.max != null ?
			_('Enter a value between %s and %s.').replace('%s', bounds.min).replace('%s', bounds.max) :
			_('Enter a value of at least %s.').replace('%s', bounds.min);

	return true;
}

/* net.uc valid_octet + ipv4. */
function ipv4(s) {
	const p = String(s ?? '').split('.');

	if (p.length != 4)
		return false;

	return p.every((o) => /^(0|[1-9][0-9]{0,2})$/.test(o) && Number(o) <= 255);
}

/* config.uc port_ok. */
function port_ok(s) {
	return /^[0-9]{1,5}$/.test(s) && Number(s) >= 1 && Number(s) <= 65535;
}

/* config.uc hostport: exactly "IPv4:port". */
function hostport(s) {
	const p = String(s ?? '').split(':');

	return p.length == 2 && ipv4(p[0]) && port_ok(p[1]);
}

/* config.uc abs_path: leading slash and no whitespace anywhere. */
function abs_path(s) {
	return typeof s == 'string' && s.charAt(0) == '/' && !/\s/.test(s);
}

/* config.uc url, same rule as the update page (docs/10 更新页). */
function url_ok(s) {
	return typeof s == 'string' && /^https?:\/\/[^\/?#\s]+[^\s]*$/.test(s);
}

/* config.uc normalize_field: a list option may arrive as an array (DynamicList,
   DeviceSelect multiple) or as a single scalar. */
function list_ok(value, check) {
	const items = Array.isArray(value) ? value : [ value ];

	return items.every(check);
}

function validate(field, value) {
	/* Absent options fall back to the schema default, so they are never an
	   error (docs/10 「高级页」: 留空的可选字段不报错). */
	if (value == null || value === '')
		return true;

	if (Object.prototype.hasOwnProperty.call(INT_BOUNDS, field))
		return int_error(INT_BOUNDS[field], value);

	if (BOOL_FIELDS.includes(field))
		return value === '0' || value === '1' ? true : _('Enter 0 or 1.');

	if (field == 'lan_ifaces') {
		const items = Array.isArray(value) ? value : [ value ];

		return (items.length > 0 && items.every((s) => typeof s == 'string' && s.length > 0)) ?
			true : _('Select at least one interface.');
	}

	switch (field) {
	case 'boot_check_targets':
		return list_ok(value, hostport) ?
			true : _('Every entry must be an IPv4 address and a port (1-65535), like 223.5.5.5:53.');
	case 'xray_bin':
	case 'chinadns_bin':
		return abs_path(value) ? true : _('Enter an absolute path without whitespace.');
	case 'dnsmasq_instance':
		return typeof value == 'string' && value.length > 0 ?
			true : _('Enter a non-empty instance name.');
	case 'url':
		return url_ok(value) ? true : _('Enter an HTTP or HTTPS URL without whitespace.');
	case 'log_level':
		return LOG_LEVELS.includes(value) ? true : _('Select a log level.');
	case 'xray_log_level':
		return XRAY_LOG_LEVELS.includes(value) ? true : _('Select a log level.');
	default:
		return true;
	}
}

return baseclass.extend({
	validate: validate,

	default: function(field) {
		return DEFAULTS[field] ?? null;
	},

	description: function(field) {
		return FIELD_TEXT[field] ?? null;
	},

	/* RichListValue choices; only the debug entry carries the logd hint, so
	   the hint appears exactly when debug is selected. */
	log_level_choices: function() {
		return LOG_LEVELS.map((value) => ({
			value: value,
			label: LOG_LABELS[value],
			description: value == 'debug' ? DEBUG_HINT : null
		}));
	},

	xray_log_level_choices: function() {
		return XRAY_LOG_LEVELS.map((value) => ({ value: value, label: LOG_LABELS[value] }));
	}
});
