'use strict';

// Full Xray configuration (docs/06 "Xray 配置渲染"). Pure function of snapshot + ctx.

import * as C from 'aetherproxy.const';
import { build_outbound } from 'aetherproxy.render.outbound';
import { trust_dns_parts } from 'aetherproxy.net';

export function build(snapshot, ctx) {
	let main = snapshot.main ?? {};
	let dns = snapshot.dns ?? {};
	let node = snapshot.nodes?.[main.node];
	let node_ip = ctx?.runtime?.node_ip ?? null;
	let trust = dns.trust_dns ?? [];

	let tproxy = {
		tag: C.TPROXY_IN_TAG, listen: C.TPROXY_LISTEN, port: C.TPROXY_PORT, protocol: 'tunnel',
		// Field names as the latest stable Xray knows them (06): newer releases map them to rewrite*/allowedNetwork.
		settings: { network: 'tcp,udp', followRedirect: true },
		streamSettings: { sockopt: { tproxy: 'tproxy' } },
		sniffing: { enabled: main.sniffing == true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false }
	};
	let inbounds = [ tproxy ];
	let tags = [ C.TPROXY_IN_TAG ];

	// TODO(design): docs/06 does not say what to emit when trust_dns is empty (config.uc's
	// defaults normally prevent it); the DNS inbounds are skipped rather than pointing nowhere.
	for (let i = 0; i < length(C.DNS_TUNNEL_PORTS) && length(trust) > 0; i++) {
		let tag = C.DNS_IN_TAG_PREFIX + i;
		// TODO(design): docs/03 does not define the second target for a one-item list.
		// Preserve the historical mirror of the first address; chinadns uses only the first port.
		let target = trust_dns_parts(trust[i] ?? trust[0]);

		push(inbounds, {
			tag: tag, listen: C.DNS_LISTEN, port: C.DNS_TUNNEL_PORTS[i], protocol: 'tunnel',
			// docs/03: chinadns selects the protocol; both go through the proxy outbound.
			settings: { address: target.address, port: 53, network: 'tcp,udp' }
		});
		push(tags, tag);
	}

	push(inbounds, { tag: C.HTTP_IN_TAG, listen: C.HTTP_LISTEN, port: C.HTTP_PORT, protocol: 'http', settings: {} });
	push(tags, C.HTTP_IN_TAG);

	let outbounds = [];

	// A missing node means "do not start Xray" (docs/06); rendering still must not throw.
	if (node != null)
		push(outbounds, build_outbound(node, node_ip));

	push(outbounds, { tag: C.DIRECT_TAG, protocol: 'freedom' });

	return {
		log: { loglevel: main.xray_log_level ?? 'warning', access: 'none' },
		inbounds: inbounds,
		outbounds: outbounds,
		routing: {
			domainStrategy: 'AsIs',
			rules: [ { type: 'field', inboundTag: tags, outboundTag: C.PROXY_TAG } ]
		}
	};
};

export function render(snapshot, ctx) {
	return sprintf('%.2J', build(snapshot, ctx)) + '\n';
};
