'use strict';

// nftables ruleset renderer (docs/02-dataplane.md "nft 规则模板"). Pure function: snapshot and
// ctx in, text out.

import * as C from 'aetherproxy.const';
import { ip_key, cidr_parts } from 'aetherproxy.net';

const T = '\t';

// Sorted, de-duplicated IPv4/CIDR list (numeric order, then prefix length). 1.2.3.4 and
// 1.2.3.4/32 count as the same entry.
function sort_ips(list) {
	let seen = {}, items = [];

	for (let s in list ?? []) {
		let k = ip_key(s);
		let p = cidr_parts(k);

		if (seen[k] || p == null)
			continue;

		seen[k] = true;
		push(items, { s: k, addr: p.addr, len: p.len });
	}

	return map(sort(items, (a, b) => (a.addr != b.addr) ? (a.addr < b.addr ? -1 : 1) : (a.len - b.len)), x => x.s);
};

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

function quote_list(list) {
	return join(', ', map(list, x => '"' + x + '"'));
};

export function render(snapshot, ctx) {
	ctx = ctx ?? {};

	let main = snapshot?.main ?? {};
	let data = ctx.data ?? {};
	let restored = ctx.runtime?.restored ?? {};
	let node_ip = ctx.runtime?.node_ip;

	let mark = split(C.FWMARK, '/')[0];
	let quic = main.quic_block == true;
	let hijack = main.dns_hijack == true;
	let lan = quote_list(sort_strings(main.lan_ifaces));

	// Host policy sets. Disabled hosts are not rendered.
	let host = { direct: { ip: [], mac: [] }, proxy: { ip: [], mac: [] }, follow: { ip: [], mac: [] }, udp: { ip: [], mac: [] } };

	for (let h in snapshot?.hosts ?? []) {
		if (h.enabled == false)
			continue;

		let pol = host[h.policy] ?? host.follow;

		push(pol.ip, ...(h.ip ?? []));
		push(pol.mac, ...(h.mac ?? []));

		if (h.udp == true) {
			push(host.udp.ip, ...(h.ip ?? []));
			push(host.udp.mac, ...(h.mac ?? []));
		}
	}

	let out = [];

	push(out, sprintf('table %s', C.NFT_TABLE));
	push(out, sprintf('delete table %s', C.NFT_TABLE));
	push(out, '');
	push(out, sprintf('table %s {', C.NFT_TABLE));

	push(out, set_block('reserved4', 'ipv4_addr', true, C.RESERVED4));
	push(out, set_block('node_ip4', 'ipv4_addr', true, node_ip ? [ node_ip ] : []));
	push(out, set_block('chnroute4', 'ipv4_addr', true, sort_ips(data.chnroute4)));
	push(out, set_block('gfw_static4', 'ipv4_addr', true, sort_ips(data.gfw_static4)));
	push(out, set_block('direct_ip4', 'ipv4_addr', true, sort_ips(data.direct_ip4)));
	push(out, set_block('proxy_ip4', 'ipv4_addr', true, sort_ips(data.proxy_ip4)));
	push(out, set_block('gfw4', 'ipv4_addr', false, sort_ips(restored.gfw4), 'chinadns-ng add-taggfw-ip'));
	push(out, set_block('udirect4', 'ipv4_addr', false, sort_ips(restored.udirect4), 'chinadns-ng group-ipset'));
	push(out, set_block('uproxy4', 'ipv4_addr', false, sort_ips(restored.uproxy4), 'chinadns-ng group-ipset'));
	push(out, '');

	for (let p in [ 'direct', 'proxy', 'follow', 'udp' ]) {
		push(out, set_block(`host_${p}4`, 'ipv4_addr', true, sort_ips(host[p].ip)));
		push(out, set_block(`host_${p}_mac`, 'ether_addr', false, sort_strings(host[p].mac)));
	}

	push(out, '');
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
	push(out, `${T}${T}ip saddr @host_follow4 goto by_mode`);
	push(out, `${T}${T}ether saddr @host_follow_mac goto by_mode`);

	if (main.unlisted_policy == 'follow')
		push(out, `${T}${T}goto by_mode`);

	push(out, `${T}}`);
	push(out, '');

	push(out, `${T}chain by_mode {`);
	push(out, `${T}${T}ip daddr @proxy_ip4 goto proxy`);
	push(out, `${T}${T}ip daddr @uproxy4 goto proxy`);

	if (main.mode == 'gfw') {
		push(out, `${T}${T}ip daddr @gfw4 goto proxy`);
		push(out, `${T}${T}ip daddr @gfw_static4 goto proxy`);
	}
	else if (main.mode == 'bypass_cn') {
		push(out, `${T}${T}ip daddr @chnroute4 return`);
		push(out, `${T}${T}goto proxy`);
	}
	else if (main.mode == 'global') {
		push(out, `${T}${T}goto proxy`);
	}

	push(out, `${T}}`);
	push(out, '');

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
