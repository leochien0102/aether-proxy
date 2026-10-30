'use strict';

// nftables ruleset renderer (docs/02-dataplane.md "nft 规则模板"). Pure function: snapshot and
// ctx in, text out. Traffic-only counters follow docs/10 "Dashboard", part 1.
// Reuse static rule-array sorting by identity (docs/04 "规则数据缓存"); output stays pure.

import * as C from 'aetherproxy.const';
import { ip_key, cidr_parts, range_parts } from 'aetherproxy.net';

const T = '\t';

// Sorted, de-duplicated IPv4/CIDR/range list: by start address, then wider block first (end
// descending, which equals prefix length ascending for CIDRs). 1.2.3.4 and 1.2.3.4/32 count as
// the same entry. Ranges (host sets only reach here normalised) are written as a.b.c.d-e.f.g.h.
function sort_ips(list) {
	let seen = {}, items = [];

	for (let s in list ?? []) {
		let k = ip_key(s);
		let p = cidr_parts(k);
		let start, end;

		if (p != null) {
			start = p.addr;
			end = p.addr + (1 << (32 - p.len)) - 1;
		}
		else if ((p = range_parts(k)) != null) {
			start = p.start;
			end = p.end;
		}
		else
			continue;

		// Same covered interval (e.g. a range spelling out a CIDR block) is written once.
		// The first spelling in input order wins (docs/05).
		let id = `${start}-${end}`;

		if (seen[id])
			continue;

		seen[id] = true;
		push(items, { s: k, start, end });
	}

	return map(sort(items, (a, b) => (a.start != b.start) ? (a.start < b.start ? -1 : 1) : (a.end != b.end ? (a.end > b.end ? -1 : 1) : 0)), x => x.s);
};

// Only data.load's arrays are stable across reloads. Host and restored lists may be
// rebuilt or mutated by their callers, so those continue through uncached sort_ips.
// docs/04: keep only the latest array per static set, never every historical update.
const sorted_data = {};
function sort_data(name, list) {
	let cached = sorted_data[name];
	if (cached != null && cached.input == list)
		return cached.items;
	let items = sort_ips(list);
	sorted_data[name] = { input: list, items };
	return items;
}

function sort_strings(list) {
	let seen = {}, out = [];

	for (let s in list ?? []) {
		if (seen[s])
			continue;

		seen[s] = true;
		push(out, s);
	}

	return sort(out);
};

function elements(list) {
	return length(list) ? sprintf('elements = { %s }', join(', ', list)) : '';
};

// Joins non-empty parts of a set body with "; " the way the template writes them.
function set_line(name, type, flags, list) {
	let parts = [ 'type ' + type + ';' ];

	if (flags)
		push(parts, 'flags interval; auto-merge;');

	let el = elements(list);

	if (el)
		push(parts, el);

	return sprintf('%sset %s { %s }', T, name, join(' ', parts));
};

function set_block(name, type, flags, list, comment) {
	let line = set_line(name, type, flags, list);

	return comment ? line + '  # ' + comment : line;
};

// Encode at the nft syntax boundary, independently of live interface existence.
// Backslashes must be escaped first so the quote escape is not escaped a second time.
// Config validation rejects control bytes until nft's hex-escape contract is verified.
function quote_string(value) {
	return '"' + replace(replace(value, /\\/g, '\\\\'), /"/g, '\\"') + '"';
};

function quote_list(list) {
	return join(', ', map(list, quote_string));
};

// Default and device modes share every destination rule, including user proxy exceptions.
function mode_chain(name, mode) {
	let out = [
		`${T}chain ${name} {`,
		`${T}${T}ip daddr @proxy_ip4 goto proxy`,
		`${T}${T}ip daddr @uproxy4 goto proxy`
	];

	if (mode == 'gfw') {
		push(out, `${T}${T}ip daddr @gfw4 goto proxy`);
		push(out, `${T}${T}ip daddr @gfw_static4 goto proxy`);
	}
	else if (mode == 'bypass_cn') {
		push(out, `${T}${T}ip daddr @chnroute4 return`);
		push(out, `${T}${T}goto proxy`);
	}
	else if (mode == 'global') {
		push(out, `${T}${T}goto proxy`);
	}

	push(out, `${T}}`);
	push(out, '');
	return out;
};

export function render(snapshot, ctx) {
	ctx = ctx ?? {};

	let main = snapshot?.main ?? {};
	let data = ctx.data ?? {};
	let restored = ctx.runtime?.restored ?? {};
	let node_ip = ctx.runtime?.node_ip;
	let degraded = ctx.runtime?.degraded_mode == 'gfw';

	let mark = split(C.FWMARK, '/')[0];
	let quic = main.quic_block == true;
	let hijack = main.dns_hijack == true;
	let lan = quote_list(sort_strings(main.lan_ifaces));

	// Host policy sets. Disabled hosts are not rendered.
	let host = {
		direct: { ip: [], mac: [] }, proxy: { ip: [], mac: [] },
		follow: { ip: [], mac: [] }, udp: { ip: [], mac: [] }
	};

	for (let h in snapshot?.hosts ?? []) {
		if (h.enabled == false)
			continue;

		if (h.policy in [ 'bypass_cn', 'gfw' ])
			host[h.policy] ??= { ip: [], mac: [] };

		let pol = host[h.policy] ?? host.follow;

		push(pol.ip, ...(h.ip ?? []));
		push(pol.mac, ...(h.mac ?? []));

		if (h.udp == true) {
			push(host.udp.ip, ...(h.ip ?? []));
			push(host.udp.mac, ...(h.mac ?? []));
		}
	}

	// Fixed precedence, independent of UCI order; absent overrides add no output bytes.
	let host_modes = filter([ 'bypass_cn', 'gfw' ], p => host[p] != null);
	// During degradation both device modes reference GFW; never emit an unused bypass chain.
	let chain_modes = degraded && length(host_modes) > 0 ? [ 'gfw' ] : host_modes;
	let out = [];

	push(out, sprintf('table %s', C.NFT_TABLE));
	push(out, sprintf('delete table %s', C.NFT_TABLE));
	push(out, '');
	push(out, sprintf('table %s {', C.NFT_TABLE));

	push(out, set_block('reserved4', 'ipv4_addr', true, C.RESERVED4));
	push(out, set_block('node_ip4', 'ipv4_addr', true, node_ip ? [ node_ip ] : []));
	push(out, set_block('chnroute4', 'ipv4_addr', true, sort_data('chnroute4', data.chnroute4)));
	push(out, set_block('gfw_static4', 'ipv4_addr', true, sort_data('gfw_static4', data.gfw_static4)));
	push(out, set_block('direct_ip4', 'ipv4_addr', true, sort_data('direct_ip4', data.direct_ip4)));
	push(out, set_block('proxy_ip4', 'ipv4_addr', true, sort_data('proxy_ip4', data.proxy_ip4)));
	push(out, set_block('gfw4', 'ipv4_addr', true, sort_ips(restored.gfw4), 'chinadns-ng add-taggfw-ip'));
	push(out, set_block('udirect4', 'ipv4_addr', true, sort_ips(restored.udirect4), 'chinadns-ng group-ipset'));
	push(out, set_block('uproxy4', 'ipv4_addr', true, sort_ips(restored.uproxy4), 'chinadns-ng group-ipset'));
	push(out, '');

	for (let p in [ 'direct', 'proxy', 'follow', ...host_modes, 'udp' ]) {
		push(out, set_block(`host_${p}4`, 'ipv4_addr', true, sort_ips(host[p].ip)));
		push(out, set_block(`host_${p}_mac`, 'ether_addr', false, sort_strings(host[p].mac)));
	}

	push(out, '');
	// Count node traffic independently of LAN policy, including UDP and degraded startup.
	push(out, `${T}counter proxy_tx {}`);
	push(out, `${T}counter proxy_rx {}`);
	push(out, `${T}chain traffic_out {`);
	push(out, `${T}${T}type filter hook output priority filter; policy accept;`);
	push(out, `${T}${T}ip daddr @node_ip4 counter name proxy_tx`);
	push(out, `${T}}`);
	push(out, `${T}chain traffic_in {`);
	push(out, `${T}${T}type filter hook input priority filter - 2; policy accept;`);
	push(out, `${T}${T}ip saddr @node_ip4 counter name proxy_rx`);
	push(out, `${T}}`);
	push(out, `${T}chain prerouting {`);
	push(out, `${T}${T}type filter hook prerouting priority mangle; policy accept;`);
	push(out, `${T}${T}iifname != { ${lan} } return`);
	// The inet table also sees IPv6; v1 is IPv4-only, so let it pass before any tproxy ip rule.
	push(out, `${T}${T}meta nfproto != ipv4 return`);
	push(out, `${T}${T}meta l4proto != { tcp, udp } return`);
	push(out, `${T}${T}meta l4proto tcp socket transparent 1 meta mark set meta mark | ${mark} accept`);
	push(out, `${T}${T}fib daddr type local return`);

	if (hijack)
		push(out, `${T}${T}th dport ${C.DNS_PORT} return`);

	push(out, `${T}${T}ip daddr @reserved4 return`);
	push(out, `${T}${T}ip daddr @node_ip4 return`);
	push(out, `${T}${T}ip daddr @direct_ip4 return`);
	push(out, `${T}${T}ip daddr @udirect4 return`);
	push(out, `${T}${T}jump host_policy`);
	push(out, `${T}}`);
	push(out, '');

	push(out, `${T}chain host_policy {`);
	push(out, `${T}${T}ip saddr @host_direct4 return`);
	push(out, `${T}${T}ether saddr @host_direct_mac return`);
	push(out, `${T}${T}ip saddr @host_proxy4 goto proxy`);
	push(out, `${T}${T}ether saddr @host_proxy_mac goto proxy`);

	for (let p in host_modes) {
		let target = degraded ? 'gfw' : p;
		push(out, `${T}${T}ip saddr @host_${p}4 goto mode_${target}`);
		push(out, `${T}${T}ether saddr @host_${p}_mac goto mode_${target}`);
	}

	push(out, `${T}${T}ip saddr @host_follow4 goto by_mode`);
	push(out, `${T}${T}ether saddr @host_follow_mac goto by_mode`);

	if (main.unlisted_policy == 'follow')
		push(out, `${T}${T}goto by_mode`);

	push(out, `${T}}`);
	push(out, '');

	push(out, ...mode_chain('by_mode', degraded && main.mode == 'bypass_cn' ? 'gfw' : main.mode));

	for (let p in chain_modes)
		push(out, ...mode_chain('mode_' + p, p));

	let tp = `meta mark set meta mark | ${mark} tproxy ip to :${C.TPROXY_PORT} accept`;

	push(out, `${T}chain proxy {`);
	push(out, `${T}${T}meta l4proto tcp ${tp}`);
	push(out, `${T}${T}meta l4proto udp ip saddr @host_udp4 ${tp}`);
	push(out, `${T}${T}meta l4proto udp ether saddr @host_udp_mac ${tp}`);

	if (quic)
		push(out, `${T}${T}udp dport 443 meta mark set meta mark | ${C.QUIC_MARK}`);

	push(out, `${T}}`);
	push(out, '');

	if (quic) {
		push(out, `${T}# reject is not always usable in the prerouting hook (kernel dependent): mark there, reject in forward`);
		push(out, `${T}chain quic_reject {`);
		push(out, `${T}${T}type filter hook forward priority filter - 1; policy accept;`);
		push(out, `${T}${T}meta mark & ${C.QUIC_MARK} == ${C.QUIC_MARK} reject`);
		push(out, `${T}}`);
		push(out, '');
	}

	let guarded = [ C.TPROXY_PORT, C.HTTP_PORT, ...C.DNS_TUNNEL_PORTS, C.CHINADNS_PORT ];

	push(out, `${T}# Internal ports are reachable only through TPROXY; direct connections from LAN/WAN are dropped`);
	push(out, `${T}chain input_guard {`);
	push(out, `${T}${T}type filter hook input priority filter - 1; policy accept;`);
	push(out, `${T}${T}iifname "lo" accept`);
	push(out, `${T}${T}fib daddr type local th dport { ${join(', ', guarded)} } drop`);
	push(out, `${T}}`);

	if (hijack) {
		push(out, '');
		push(out, `${T}chain dns_hijack {`);
		push(out, `${T}${T}type nat hook prerouting priority dstnat - 5; policy accept;`);
		push(out, `${T}${T}iifname != { ${lan} } return`);
		push(out, `${T}${T}ip saddr @host_direct4 return`);
		push(out, `${T}${T}ether saddr @host_direct_mac return`);
		push(out, `${T}${T}fib daddr type local return`);
		push(out, `${T}${T}meta l4proto { tcp, udp } th dport ${C.DNS_PORT} redirect to :${C.DNS_PORT}`);
		push(out, `${T}}`);
	}

	push(out, '}');

	return join('\n', out) + '\n';
};
