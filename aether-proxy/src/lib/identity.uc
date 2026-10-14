'use strict';

// Stable subscription-node identity keys and matching (docs/06 "节点身份").

export function keys(node) {
	let protocol = `${node?.protocol ?? ''}`;
	let address = lc(`${node?.address ?? ''}`);
	let port = `${node?.port ?? ''}`;
	let transport = `${node?.transport ?? ''}`;
	let path = `${node?.path ?? ''}`;
	let host = `${node?.host ?? ''}`;
	let service = `${node?.service_name ?? ''}`;
	let security = `${node?.security ?? ''}`;
	let sni = `${node?.sni ?? ''}`;
	let credential = `${node?.uuid ?? node?.password ?? ''}`;
	let tdisc = path + '|' + host + '|' + service;

	return {
		strong: join('|', [ protocol, address, port, transport, tdisc, security, sni, credential ]),
		weak: join('|', [ protocol, address, port, transport, tdisc ])
	};
};

function normalized_node(node) {
	let copy = {};
	for (let key in node)
		copy[key] = node[key];

	let identity = keys(node);
	copy.match_strong = identity.strong;
	copy.match_weak = identity.weak;
	copy.stale = false;
	return copy;
}

// old_nodes contains nodes from one subscription only. Callers inject referential and ID
// policies so matching remains pure and deterministic in host tests.
export function match(old_nodes, new_nodes, opts) {
	if (type(old_nodes) != 'object' || type(new_nodes) != 'array')
		die('identity.match: old_nodes must be an object and new_nodes must be an array');
	if (type(opts?.referenced) != 'function' || type(opts?.new_id) != 'function')
		die('identity.match: opts.referenced and opts.new_id are required functions');

	let old_ids = [];
	for (let id in old_nodes)
		push(old_ids, id);
	old_ids = sort(old_ids);
	let old_keys = {};
	let weak_counts = {};
	for (let id in old_ids) {
		old_keys[id] = keys(old_nodes[id]);
		weak_counts[old_keys[id].weak] = (weak_counts[old_keys[id].weak] ?? 0) + 1;
	}

	let used = {};
	let assigned = {};
	let output = { assign: [], stale: [], removed: [], revived: [] };

	function assign(new_index, id, from) {
		let node = normalized_node(new_nodes[new_index]);
		assigned[new_index] = { id, node, from };
		used[id] = true;

		if (old_nodes[id]?.stale == true)
			push(output.revived, id);
	}

	// 1. Match exact strong keys first. Sorted IDs make an ambiguous old set deterministic.
	for (let i, node in new_nodes) {
		let strong = keys(node).strong;
		for (let id in old_ids) {
			if (!used[id] && old_keys[id].strong == strong) {
				assign(i, id, 'strong');
				break;
			}
		}
	}

	// 2. Weak matching is allowed only when this key is unique across all old nodes.
	for (let i, node in new_nodes) {
		if (assigned[i] != null)
			continue;

		let weak = keys(node).weak;
		if (weak_counts[weak] != 1)
			continue;

		for (let id in old_ids)
			if (!used[id] && old_keys[id].weak == weak) {
				assign(i, id, 'weak');
				break;
			}
	}

	// 3. A label is a fallback only when exactly one unmatched old node has this protocol/label.
	for (let i, node in new_nodes) {
		if (assigned[i] != null)
			continue;

		let candidates = [];
		for (let id in old_ids) {
			let old = old_nodes[id];
			if (!used[id] && old.protocol == node.protocol && old.label == node.label)
				push(candidates, id);
		}

		if (length(candidates) == 1)
			assign(i, candidates[0], 'label');
	}

	// 4. Remaining nodes receive IDs from the caller's deterministic policy.
	for (let i, node in new_nodes)
		if (assigned[i] == null)
			assign(i, opts.new_id(), 'new');

	for (let id in old_ids) {
		if (used[id])
			continue;

		if (opts.referenced(id))
			push(output.stale, id);
		else
			push(output.removed, id);
	}

	for (let i = 0; i < length(new_nodes); i++)
		push(output.assign, assigned[i]);

	return output;
};
