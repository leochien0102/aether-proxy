'use strict';

// chinadns-ng config renderer (docs/03-dns.md "chinadns-ng 配置模板"). Pure function.

import * as C from 'aetherproxy.const';
import { trust_dns_parts } from 'aetherproxy.net';
import { expand_china_dns } from 'aetherproxy.config';

// "inet aetherproxy" + "gfw4" -> "inet@aetherproxy@gfw4" (chinadns-ng's nft set syntax)
function nft_set(name) {
	return replace(C.NFT_TABLE, ' ', '@') + '@' + name;
}

// Upstreams of the trust group for a DNS tier (docs/03 "DNS 级别").
function trust_upstreams(dns, tier, china) {
	if (tier == 'T1') {
		// One tunnel port per configured trust_dns entry, at least one, at most two.
		let n = length(dns?.trust_dns ?? []);
		if (n < 1)
			n = 1;
		if (n > length(C.DNS_TUNNEL_PORTS))
			n = length(C.DNS_TUNNEL_PORTS);
		let out = [];
		for (let i = 0; i < n; i++) {
			let protocol = trust_dns_parts(dns?.trust_dns?.[i])?.protocol ?? 'tcp';
			// Send UDP to local Xray too, never directly to the remote DNS (docs/03).
			push(out, sprintf('%s://%s#%d', protocol, C.DNS_TUNNEL_ADDR, C.DNS_TUNNEL_PORTS[i]));
		}
		return out;
	}
	if (tier == 'T3')
		return china;
	return dns?.direct_dns ?? [];
}

export function render(snapshot, ctx) {
	let main = snapshot?.main ?? {};
	let dns = snapshot?.dns ?? {};
	let paths = ctx?.paths ?? {};
	// The monitor starts every run at T2 (docs/03 "切换规则"), so that is the default
	// when the context carries no tier.
	let tier = ctx?.runtime?.dns_tier ?? 'T2';
	// Production snapshots are already expanded by pipeline.read. Raw fixture snapshots
	// use context.json's wan_dns, never live network I/O, keeping rendering deterministic.
	let china = expand_china_dns(dns.china_dns, ctx?.wan_dns);
	let direct = dns.direct_dns ?? [];
	let trust = trust_upstreams(dns, tier, china);
	// DNS still follows main.mode; device GFW overrides only need its IP set populated (docs/03).
	let host_gfw = length(filter(snapshot?.hosts ?? [], h => h.enabled != false && h.policy == 'gfw')) > 0;
	let out = [];

	// A line that needs a path is skipped when the caller did not supply it.
	// TODO(design): 03 does not say what to do when ctx.paths lacks an entry; omitting the line is the conservative choice.
	function put_path(key, value) {
		if (value != null && value != '')
			push(out, key + ' ' + value);
	}

	push(out, 'bind-addr 127.0.0.1');
	push(out, 'bind-port ' + C.CHINADNS_PORT);
	push(out, 'china-dns ' + join(',', china));
	push(out, 'trust-dns ' + join(',', trust));
	push(out, 'ipset-name4 ' + nft_set(C.CHINADNS_SET_CHNROUTE4));
	push(out, 'ipset-name6 null');

	if (main.mode == 'gfw') {
		put_path('gfwlist-file', paths.gfwlist);
		push(out, 'default-tag chn');
	}
	else if (main.mode == 'bypass_cn') {
		put_path('gfwlist-file', paths.gfwlist);
		let lists = filter([ paths.chnlist, paths.apple ], p => p != null && p != '');
		if (length(lists))
			push(out, 'chnlist-file ' + join(',', lists));
		push(out, 'default-tag none');
	}
	else {
		// global
		if (host_gfw)
			put_path('gfwlist-file', paths.gfwlist);
		put_path('chnlist-file', paths.apple);
		push(out, 'default-tag gfw');
	}

	if (main.mode == 'gfw' || host_gfw)
		push(out, 'add-taggfw-ip ' + nft_set(C.CHINADNS_SET_GFW4) + ',null');

	// Custom groups: declaration order = priority, low to high.
	push(out, 'group uproxy');
	put_path('group-dnl', paths.proxy_domain);
	push(out, 'group-upstream ' + join(',', trust));
	push(out, 'group-ipset ' + nft_set(C.CHINADNS_SET_UPROXY4) + ',null');
	push(out, 'group udirect');
	put_path('group-dnl', paths.direct_domain);
	push(out, 'group-upstream ' + join(',', china));
	push(out, 'group-ipset ' + nft_set(C.CHINADNS_SET_UDIRECT4) + ',null');
	push(out, 'group boot');
	put_path('group-dnl', paths.boot_list);
	push(out, 'group-upstream ' + join(',', direct));

	if (main.ipv6_filter)
		push(out, 'no-ipv6');
	if (main.filter_https_rr)
		push(out, 'filter-qtype 65');
	push(out, 'cache ' + C.CHINADNS_CACHE);
	push(out, 'cache-stale ' + C.CHINADNS_CACHE_STALE);
	push(out, 'verdict-cache ' + C.CHINADNS_VERDICT_CACHE);

	return join('\n', out) + '\n';
};
