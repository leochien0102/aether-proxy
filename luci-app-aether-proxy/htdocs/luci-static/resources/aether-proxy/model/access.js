'use strict';
'require baseclass';

/*
 * Pure view model for the access control page (docs/10 「访问控制页」,
 * docs/tasks/m8.md T8.7).
 *
 * validate() mirrors the authoritative command-line host rules one to one, so
 * the page precheck agrees with `aether-proxy check` (docs/10: 最终仍以命令行
 * 的校验为准). The reference implementation lives in
 * aether-proxy/src/lib/config.uc (check_hosts, note_value, unset, mac) and
 * aether-proxy/src/lib/net.uc (ipv4, ip_or_cidr, ip_key, cidr_parts); every
 * helper below states which function it mirrors. The page only implements the
 * host rules 1-4 of docs/10 「访问控制页」 — schema-level checks (enums, bools)
 * cannot go wrong through the dropdowns and stay with the command line.
 *
 * mac_candidates() turns the hosts object of LuCI's network.getHostHints()
 * into deduplicated combobox choices; policy_text()/unlisted_text() provide
 * the Chinese wording. Nothing in this module issues requests or touches the
 * DOM; every msgid used here must have an entry in
 * po/zh_Hans/aether-proxy.po.
 */

/* Replaces each %s with the corresponding extra argument, in order. */
function fmt(s) {
	for (let i = 1; i < arguments.length; i++)
		s = s.replace('%s', arguments[i]);

	return s;
}

/* lib/net.uc valid_octet + ipv4: four dot-separated octets 0-255 without
   leading zeros. */
function ipv4(s) {
	const p = String(s ?? '').split('.');

	if (p.length != 4)
		return null;

	for (const o of p) {
		if (!/^(0|[1-9][0-9]{0,2})$/.test(o) || Number(o) > 255)
			return null;
	}

	return s;
}

/* Anchored full-string match. A plain regex test would also accept a trailing
   newline ($ matches before it in JavaScript), which lib/net.uc rejects. */
function fullmatch(s, re) {
	const m = re.exec(s);

	return (m != null && m[0] === s) ? m : null;
}

/* lib/config.uc mac(): six pairs of hex digits separated by colons or dashes
   (mixing them is allowed), normalized to the lowercase colon form (docs/05
   「config host」: mac 统一转为小写冒号格式). */
const MAC_RE = /^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$/;

function normalize_mac(s) {
	s = String(s ?? '');

	return fullmatch(s, MAC_RE) ? s.replace(/-/g, ':').toLowerCase() : null;
}

/* lib/net.uc ip_or_cidr: an IPv4 address or a.b.c.d/len with a prefix of
   0-32 and zero host bits (nft interval sets reject a prefix with host bits;
   failing here is the conservative choice). */
function ip_or_cidr_ok(s) {
	const p = String(s ?? '').split('/');

	if (p.length == 1)
		return ipv4(s) != null;

	if (p.length != 2 || ipv4(p[0]) == null || !/^(0|[1-9][0-9]?)$/.test(p[1]))
		return false;

	const len = Number(p[1]);

	if (len > 32)
		return false;

	const o = p[0].split('.').map((x) => Number(x));
	const addr = ((o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]) >>> 0;
	const mask = (len == 0) ? 0 : ((0xFFFFFFFF << (32 - len)) >>> 0);

	return (((addr & (~mask >>> 0)) >>> 0) == 0);
}

/* lib/net.uc ip_key: 1.2.3.4 and 1.2.3.4/32 select the same host. */
function ip_key(s) {
	return String(s).replace(/\/32$/, '');
}

/* lib/net.uc cidr_parts: the network address as an unsigned 32-bit integer
   plus the prefix length; a bare address has len 32. Only called with values
   that passed ip_or_cidr_ok(). */
function cidr_parts(s) {
	const p = String(s).split('/');
	const o = p[0].split('.').map((x) => Number(x));

	return {
		addr: ((o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]) >>> 0,
		len: (p.length == 2) ? Number(p[1]) : 32
	};
}

/* lib/config.uc unset(): an option counts as unset when it is absent, an
   empty string or an empty list. */
function unset(v) {
	return v == null || v == '' || (Array.isArray(v) && v.length == 0);
}

/* A list option arrives as an array; a scalar (option instead of list) counts
   as a one-element list, like lib/config.uc normalize_field. */
function list_items(v) {
	if (v == null)
		return [];

	return Array.isArray(v) ? v : [ v ];
}

/* lib/config.uc normalize_field: a missing or empty scalar falls back to the
   schema default, so a host without a policy is a follow host. */
function policy_of(h) {
	return (h.policy == null || h.policy === '') ? 'follow' : String(h.policy);
}

/* lib/config.uc normalize_field for bool: only the string '1' (or a real
   boolean, as sent by tests) turns the game mode on. */
function udp_on(h) {
	return h.udp === '1' || h.udp === true || h.udp === 1;
}

/* docs/05: enabled defaults to 1; only an explicit 0/false disables. */
function enabled_of(h) {
	return !(h.enabled === '0' || h.enabled === false || h.enabled === 0);
}

/* Error texts carry the section's name, or its 1-based position when the name
   is missing (docs/tasks/m8.md T8.7 scenario 1). */
function host_label(h, i) {
	return (h.name == null || h.name === '') ? '#' + (i + 1) : String(h.name);
}

/* lib/config.uc note_value(): the first section claiming a value wins
   (seen[key] keeps its first index); a later section repeating it produces
   exactly one error per value, and a repeat inside the same section does not
   count (j == i). */
function note_value(seen, reported, key, raw, i, field, labels, errors) {
	const j = seen[key];

	if (j != null && j != i && !reported[field + ':' + key]) {
		errors.push({
			host: labels[i], other: labels[j], field: field, code: 'duplicate', value: raw,
			text: fmt(_('Host %s: %s is also used by host %s.', 'aether-proxy'), labels[i], raw, labels[j])
		});

		reported[field + ':' + key] = true;
	}

	if (seen[key] == null)
		seen[key] = i;
}

/* docs/02 冲突校验: one range overlaps another when the range with the
   smaller prefix contains the other one. */
function range_overlap(a, b) {
	const lo = (a.len <= b.len) ? a : b;
	const hi = (a.len <= b.len) ? b : a;
	const mask = (lo.len == 0) ? 0 : ((0xFFFFFFFF << (32 - lo.len)) >>> 0);

	return (((hi.addr & mask) >>> 0) == lo.addr);
}

function ranges_overlap(as, bs) {
	for (const a of as) {
		for (const b of bs) {
			if (range_overlap(a.parts, b.parts))
				return true;
		}
	}

	return false;
}

const POLICIES = [ 'follow', 'direct', 'proxy' ];

/* Own-property check: the lookup tables above must not answer for inherited
   names (an unknown policy straight from UCI could be any string, e.g.
   "toString"). */
function has_own(obj, key) {
	return Object.prototype.hasOwnProperty.call(obj, key);
}

/* The first known IPv4 of a hint: the ipaddrs list is the shape of the
   luci-rpc getHostHints reply; the legacy ipv4 field is what the LuCI Hosts
   class also accepts. */
function first_ipv4(h) {
	if (h == null)
		return null;

	const list = Array.isArray(h.ipaddrs) ? h.ipaddrs : (h.ipv4 != null ? [ h.ipv4 ] : []);

	for (const a of list) {
		if (ipv4(a) != null)
			return String(a);
	}

	return null;
}

return baseclass.extend({
	/* Rules 1-4 of docs/10 「访问控制页」, in the wording of docs/05 校验
	   规则 2, evaluated on the raw uci.sections('aetherproxy', 'host') shape:
	   1. at least one of ip and mac (judged on the raw values, so an invalid
	      entry does not additionally produce a required error — that is how
	      lib/config.uc check_hosts consults raw_hosts);
	   2. policy=direct forbids the game mode;
	   3. the same IPv4/CIDR (x and x/32 collide) or MAC (case- and
	      separator-insensitive) must not appear in two host sections;
	      disabled sections take part, repeats inside one section do not;
	   4. entry syntax: IPv4 or CIDR (prefix 0-32, zero host bits) and MAC.
	   Only entries that pass rule 4 take part in rules 3 and the overlap
	   hints, mirroring the command line where invalid list items are dropped
	   before check_hosts runs. Returns { errors, warnings }; warnings are the
	   non-blocking nesting hints and never make a configuration invalid. */
	validate: function(hosts) {
		const sections = Array.isArray(hosts) ? hosts : [];
		const labels = [];
		const entries = [];
		const errors = [];

		for (let i = 0; i < sections.length; i++) {
			const h = (sections[i] != null && typeof sections[i] == 'object') ? sections[i] : {};
			const label = host_label(h, i);

			labels.push(label);

			/* rule 1 */
			if (unset(h.ip) && unset(h.mac))
				errors.push({
					host: label, field: 'ip', code: 'required',
					text: fmt(_('Host %s: fill in at least one of IP and MAC.', 'aether-proxy'), label)
				});

			/* rule 2 (docs/02: udp 只在 policy ≠ direct 时有效) */
			if (policy_of(h) == 'direct' && udp_on(h))
				errors.push({
					host: label, field: 'udp', code: 'conflict',
					text: fmt(_('Host %s: game mode (UDP) cannot be enabled when the policy is direct.', 'aether-proxy'), label)
				});

			/* rule 4 */
			const ips = [];
			const macs = [];

			for (const raw of list_items(h.ip)) {
				if (!ip_or_cidr_ok(raw)) {
					errors.push({
						host: label, field: 'ip', code: 'invalid_cidr', value: raw,
						text: fmt(_('Host %s: %s is not a valid IPv4 address or CIDR.', 'aether-proxy'), label, raw)
					});

					continue;
				}

				ips.push({ raw: String(raw), key: ip_key(raw), parts: cidr_parts(raw) });
			}

			for (const raw of list_items(h.mac)) {
				const mac = normalize_mac(raw);

				if (mac == null) {
					errors.push({
						host: label, field: 'mac', code: 'invalid_mac', value: raw,
						text: fmt(_('Host %s: %s is not a valid MAC address.', 'aether-proxy'), label, raw)
					});

					continue;
				}

				macs.push({ raw: String(raw), key: mac });
			}

			entries.push({ enabled: enabled_of(h), policy: policy_of(h), ips: ips, macs: macs });
		}

		/* rule 3 */
		const seen_ip = {};
		const seen_mac = {};

		for (let i = 0; i < entries.length; i++) {
			const reported = {};

			for (const e of entries[i].ips)
				note_value(seen_ip, reported, e.key, e.raw, i, 'ip', labels, errors);

			for (const e of entries[i].macs)
				note_value(seen_mac, reported, e.key, e.raw, i, 'mac', labels, errors);
		}

		/* docs/02 冲突校验: nesting CIDRs are allowed and take effect in the
		   order direct → proxy → follow, so the page only warns (02: 并在
		   LuCI 中提示). Same-policy pairs cannot differ in precedence and
		   unknown policies are rejected by the command line anyway, so they
		   do not warn.
		   TODO(design): docs/02 and docs/10 do not say whether disabled
		   sections hint. They are skipped here because the nft renderer does
		   not render disabled hosts (docs/02 主机策略模型), so no runtime
		   overlap can exist for them. */
		const warnings = [];

		for (let i = 0; i < entries.length; i++) {
			for (let j = i + 1; j < entries.length; j++) {
				const a = entries[i];
				const b = entries[j];

				if (!a.enabled || !b.enabled || a.policy == b.policy)
					continue;

				if (POLICIES.indexOf(a.policy) < 0 || POLICIES.indexOf(b.policy) < 0)
					continue;

				if (!ranges_overlap(a.ips, b.ips))
					continue;

				warnings.push({
					a: labels[i], b: labels[j],
					text: fmt(_('Hosts %s and %s overlap; direct → proxy → follow applies in this order.', 'aether-proxy'), labels[i], labels[j])
				});
			}
		}

		return { errors: errors, warnings: warnings };
	},

	/* docs/10 访问控制页: the MAC combobox offers the hosts known from DHCP
	   leases and the neighbor table as candidates, displayed as
	   「MAC（主机名，IP）」 with missing parts left out. Hint keys are
	   normalized to the lowercase colon form and duplicate keys after that
	   are dropped (the first hint wins); candidates without a syntactically
	   valid MAC cannot be entered anyway and are skipped. Sorted by MAC. */
	mac_candidates: function(hints) {
		const known = (hints != null && hints.hosts != null && typeof hints.hosts == 'object') ? hints.hosts : {};
		const seen = {};
		const out = [];

		for (const [raw, h] of Object.entries(known)) {
			const mac = normalize_mac(raw);

			if (mac == null || seen[mac])
				continue;

			seen[mac] = true;

			const name = (h != null && h.name != null && h.name !== '') ? String(h.name) : null;
			const ip = first_ipv4(h);
			const detail = [ name, ip ].filter((x) => x != null).join(_(', ', 'aether-proxy'));

			out.push({
				mac: mac,
				label: (detail === '') ? mac : fmt(_('%s (%s)', 'aether-proxy'), mac, detail)
			});
		}

		out.sort((a, b) => (a.mac < b.mac) ? -1 : (a.mac > b.mac) ? 1 : 0);

		return out;
	},

	/* docs/10 访问控制页: follow 跟随 / direct 直连 / proxy 代理; an unknown
	   value is shown verbatim. */
	policy_text: function(policy) {
		const texts = { follow: _('Follow', 'aether-proxy'), direct: _('Direct', 'aether-proxy'), proxy: _('Proxy', 'aether-proxy') };

		return has_own(texts, policy) ? texts[policy] : String(policy);
	},

	/* docs/10 访问控制页: 「跟随全局模式」/「直连」; an unknown value is
	   shown verbatim. */
	unlisted_text: function(v) {
		const texts = { follow: _('Follow global mode', 'aether-proxy'), direct: _('Direct', 'aether-proxy') };

		return has_own(texts, v) ? texts[v] : String(v);
	}
});
