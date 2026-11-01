'use strict';

// Shared read of the dataplane proxy byte counters (docs/02 计数器, docs/10 Dashboard).
// Consumers: `stats` (T8.12a) and the monitor's B25 usage sampling (T12.3). Read-only:
// an unreadable counter is an independent null for the caller, never an event, so
// polling must not flood logd.

import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';

function byte_count(value) {
	return type(value) in [ 'int', 'double' ] && value >= 0 ? value : null;
}

// proxy_counters(ctx) -> { tx_bytes, rx_bytes } or null. `ctx` needs `bin_dir` (may be
// null). Any failure — command, table, JSON shape, missing counter — returns null.
export function proxy_counters(ctx) {
	let nft = ctx?.bin_dir ? `${ctx.bin_dir}/nft` : 'nft';
	let result = sys.run([ nft, '-j', 'list', 'counters', 'table', ...split(C.NFT_TABLE, ' ') ],
		{ timeout: C.STATS_NFT_TIMEOUT_SECS, quiet: true });
	if (result.code != 0)
		return null;
	let data;
	try {
		data = json(result.stdout);
	}
	catch (e) {
		return null; // An unsupported or malformed nft response is unavailable.
	}
	if (type(data?.nftables) != 'array')
		return null;
	let counts = {};
	for (let entry in data.nftables) {
		let c = entry?.counter;
		if (type(c) != 'object' || `${c.family} ${c.table}` != C.NFT_TABLE)
			continue;
		if (c.name == 'proxy_tx' || c.name == 'proxy_rx')
			counts[c.name] = byte_count(c.bytes);
	}
	if (counts.proxy_tx == null || counts.proxy_rx == null)
		return null;
	return { tx_bytes: counts.proxy_tx, rx_bytes: counts.proxy_rx };
};
