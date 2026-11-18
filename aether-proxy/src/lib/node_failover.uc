'use strict';
// Shared explicit-list semantics for config, subscription refresh and monitoring (docs/05).

import { NODE_FAILOVER_MAX_NODES } from 'aetherproxy.const';

// Accept UCI's scalar/list shapes. Retain the first occurrence of each nonblank ID.
export function normalize(value) {
	let out = [];
	for (let id in (type(value) == 'array' ? value : [ value ])) {
		if (type(id) != 'string' || trim(id) == '' || index(out, id) >= 0)
			continue;
		push(out, id);
		if (length(out) == NODE_FAILOVER_MAX_NODES)
			break;
	}
	return out;
};

export function participates(cfg, id) {
	let node = cfg.nodes?.[id];
	return cfg.sub?.failover === true && node != null && node.disabled !== true &&
		index(cfg.main?.failover_nodes ?? [], id) >= 0;
};

// A subscription with no old nodes has no selection to carry forward.
export function subscription_state(ids, selected) {
	let count = 0;
	for (let id in ids)
		if (index(selected, id) >= 0)
			count++;
	return count == 0 ? 'none' : count == length(ids) ? 'all' : 'some';
};
