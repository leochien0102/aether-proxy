'use strict';

// T8.5 driver (docs/07 「实现细节」, docs/tasks/m8.md T8.5 scenarios 1-2): runs
// the incremental probe recording path in-process — lib/cmd/probe.uc
// new_recorder()/keep_old_nodes() plus the lib/probe.uc per-node callback —
// against real loopback sockets and a TEST-NET address. The test wraps the
// production callback and snapshots probe.json after every single write, so
// the file contents between writes can be asserted without timing races.
// Invoked from tests/probe/run.sh with: driver.uc <run-dir> <open-port> <closed-port>

import * as fs from 'fs';
import * as probe from 'aetherproxy.probe';
import * as cmd from 'aetherproxy.cmd.probe';

const RUN = ARGV[0];
const PATH = RUN + '/probe.json';
const OPEN_PORT = int(ARGV[1]);
const CLOSED_PORT = int(ARGV[2]);

const N1 = 'n_00000000000000000000000000000001';
const N2 = 'n_00000000000000000000000000000002';
const N3 = 'n_00000000000000000000000000000003';

let pass = 0, fail = 0;

function ok(name) {
	pass++;
	print(`PASS  ${name}\n`);
}

function bad(name, detail) {
	fail++;
	print(`FAIL  ${name}${detail != null ? `: ${detail}` : ''}\n`);
}

function check(name, cond, detail) {
	cond ? ok(name) : bad(name, detail);
}

function show(v) {
	return sprintf('%J', v ?? null);
}

function deep_eq(a, b) {
	let ta = type(a);

	if (ta != type(b))
		return false;

	if (ta == 'array') {
		if (length(a) != length(b))
			return false;
		for (let i = 0; i < length(a); i++)
			if (!deep_eq(a[i], b[i]))
				return false;
		return true;
	}

	if (ta == 'object') {
		let ka = sort(keys(a));
		let kb = sort(keys(b));

		if (join('|', ka) != join('|', kb))
			return false;

		for (let k in ka)
			if (!deep_eq(a[k], b[k]))
				return false;

		return true;
	}

	return a === b;
}

function ensure_dir(path) {
	if (fs.stat(path) != null)
		return true;
	return fs.mkdir(path);
}

function read_snap() {
	let text = fs.readfile(PATH);

	if (text == null)
		return null;

	return json(text);
}

function snap_keys_ok(name, snap) {
	check(`${name}: snapshot parses as a JSON object`, type(snap) == 'object', show(snap));
	if (type(snap) == 'object')
		check(`${name}: snapshot carries at/nodes/done/total/finished/pending`,
			deep_eq(sort(keys(snap)), [ 'at', 'done', 'finished', 'nodes', 'pending', 'total' ]),
			show(sort(keys(snap))));
}

function node(address, port) {
	return { protocol: 'trojan', address, port, password: 'driver-password', security: 'tls' };
}

// --- scenario 1: one write per finished node, done 0 -> 1 -> 2 -> 3, last write finished ---
function scenario_1() {
	fs.unlink(PATH);

	let nodes = {};
	nodes[N1] = node('127.0.0.1', OPEN_PORT);
	nodes[N2] = node('127.0.0.1', CLOSED_PORT);
	nodes[N3] = node('192.0.2.1', 65000);

	let ids = [ N1, N2, N3 ];
	let snaps = [];
	let order = [];

	let rec = cmd.new_recorder(PATH, ids, {}, time());
	let underlying = rec.on_node_done;

	// The recorder writes the initial state (done 0, everything pending) at
	// construction; snapshot it like every later write.
	push(snaps, read_snap());

	probe.probe_nodes(nodes, ids, 1, 8, null, function(id, summary) {
		underlying(id, summary);
		push(order, id);
		push(snaps, read_snap());
	});

	let final = rec.finish();
	push(snaps, read_snap());

	check('1. every node completed exactly once', deep_eq(sort(order), sort(ids)), show(order));
	// 192.0.2.1 (TEST-NET-1) is not routed here, so the third node is the slow one;
	// both loopback nodes finish first.
	check('1. the TEST-NET node completes last', order[length(order) - 1] == N3, show(order));
	check('1. five writes: start, three nodes, final', length(snaps) == 5, show(length(snaps)));

	snap_keys_ok('1. start write', snaps[0]);
	check('1. start write: done 0, total 3, not finished', snaps[0]?.done == 0 && snaps[0]?.total == 3 && snaps[0]?.finished == false, show(snaps[0]));
	check('1. start write: pending holds all three nodes', deep_eq(snaps[0]?.pending, ids), show(snaps[0]?.pending));
	check('1. start write: nodes empty (nothing kept)', deep_eq(snaps[0]?.nodes, {}), show(snaps[0]?.nodes));

	for (let i = 1; i < 4; i++) {
		let prev = snaps[i - 1];
		let cur = snaps[i];

		snap_keys_ok(`1. write ${i}`, cur);
		check(`1. write ${i}: done increments to ${i}`, cur?.done == i, show(cur?.done));
		check(`1. write ${i}: pending shrinks by exactly one, holding the unfinished nodes`,
			deep_eq(cur?.pending, filter(prev?.pending, id => id != order[i - 1])), show(cur?.pending));
		check(`1. write ${i}: not finished yet`, cur?.finished == false, show(cur?.finished));
		check(`1. write ${i}: the finished node's result is in nodes`, type(cur?.nodes?.[order[i - 1]]) == 'object', show(cur?.nodes));
		check(`1. write ${i}: total stays 3`, cur?.total == 3, show(cur?.total));
	}

	check('1. the slow node finished last with ok == 0', snaps[3]?.nodes?.[N3]?.ok == 0, show(snaps[3]?.nodes?.[N3]));
	check('1. the slow node failed by timeout or unreachable',
		index([ 'timeout', 'unreachable' ], snaps[3]?.nodes?.[N3]?.error) >= 0, show(snaps[3]?.nodes?.[N3]?.error));

	snap_keys_ok('1. final write', snaps[4]);
	check('1. final write: finished true', snaps[4]?.finished == true, show(snaps[4]));
	check('1. final write: pending empty', deep_eq(snaps[4]?.pending, []), show(snaps[4]?.pending));
	check('1. final write: done == total == 3', snaps[4]?.done == 3 && snaps[4]?.total == 3, show(snaps[4]));
	check('1. final write: at is the completion time, later than the start time',
		type(snaps[4]?.at) == 'int' && type(snaps[0]?.at) == 'int' && snaps[4]?.at > snaps[0]?.at,
		`${show(snaps[0]?.at)} -> ${show(snaps[4]?.at)}`);

	check('1. loopback listener node: 3/3 connected', snaps[4]?.nodes?.[N1]?.ok == 3 && snaps[4]?.nodes?.[N1]?.fail == 0, show(snaps[4]?.nodes?.[N1]));
	check('1. closed loopback port: 0/3 connected, refused',
		snaps[4]?.nodes?.[N2]?.ok == 0 && snaps[4]?.nodes?.[N2]?.error == 'refused', show(snaps[4]?.nodes?.[N2]));
}

// --- scenario 2: partial run keeps configured nodes' old results, drops vanished ones ---
function scenario_2() {
	fs.unlink(PATH);

	let old = { at: 1234, nodes: {} };
	let old_n1 = { ip: '203.0.113.1', ok: 2, fail: 1, min_ms: 10, median_ms: 12, error: null };
	let old_n2 = { ip: '198.51.100.2', ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'timeout' };
	old.nodes[N1] = old_n1;
	old.nodes[N2] = old_n2;
	old.nodes['n_ffffffffffffffffffffffffffffffff'] = { ip: '203.0.113.9', ok: 1, fail: 2, min_ms: 5, median_ms: 6, error: null };

	if (!ensure_dir(RUN))
		bad('2. run dir writable', fs.error() ?? 'unknown error');
	if (!fs.writefile(PATH, sprintf('%.J', old) + '\n'))
		bad('2. old probe.json written', fs.error() ?? 'unknown error');

	// The configuration contains N1 and N2, but not the vanished n_ff... node.
	let configured = {};
	configured[N1] = node('127.0.0.1', OPEN_PORT);
	configured[N2] = node('127.0.0.1', OPEN_PORT);

	let kept = cmd.keep_old_nodes(cmd.read_results(PATH), configured);

	check('2. keep_old_nodes keeps the configured nodes', deep_eq(sort(keys(kept)), sort([ N1, N2 ])), show(keys(kept)));
	check('2. vanished nodes are dropped from the start', kept?.['n_ffffffffffffffffffffffffffffffff'] == null, show(keys(kept)));
	check('2. old results are kept verbatim', deep_eq(kept?.[N1], old_n1) && deep_eq(kept?.[N2], old_n2), show(kept));

	// Probe only N2; N1 is not part of this run.
	let snaps = [];
	let rec = cmd.new_recorder(PATH, [ N2 ], kept, time());
	let underlying = rec.on_node_done;

	// Snapshot the initial write as well (done 0, old results already in place).
	push(snaps, read_snap());

	probe.probe_nodes(configured, [ N2 ], 1, 8, null, function(id, summary) {
		underlying(id, summary);
		push(snaps, read_snap());
	});

	let final = rec.finish();
	push(snaps, read_snap());

	check('2. start write: done 0, total 1, pending [N2]', snaps[0]?.done == 0 && snaps[0]?.total == 1 && deep_eq(snaps[0]?.pending, [ N2 ]), show(snaps[0]));
	check('2. start write: old results already visible for the unprobed node',
		deep_eq(snaps[0]?.nodes?.[N1], old_n1), show(snaps[0]?.nodes?.[N1]));
	check('2. start write: the vanished node is not in nodes',
		snaps[0]?.nodes?.['n_ffffffffffffffffffffffffffffffff'] == null, show(keys(snaps[0]?.nodes)));
	snap_keys_ok('2. final write', snaps[2]);
	check('2. final write: finished true, done 1', snaps[2]?.finished == true && snaps[2]?.done == 1 && snaps[2]?.total == 1, show(snaps[2]));
	check('2. final write: pending empty', deep_eq(snaps[2]?.pending, []), show(snaps[2]?.pending));
	check('2. final write: the probed node has a fresh result (3/3)',
		snaps[2]?.nodes?.[N2]?.ok == 3 && snaps[2]?.nodes?.[N2]?.fail == 0, show(snaps[2]?.nodes?.[N2]));
	check('2. final write: the unprobed node still carries the old result verbatim',
		deep_eq(snaps[2]?.nodes?.[N1], old_n1), show(snaps[2]?.nodes?.[N1]));
	check('2. finish reports no write failure', final?.error == null, show(final?.error));
}

if (!ensure_dir(RUN))
	bad('run dir writable', fs.error() ?? 'unknown error');

scenario_1();
scenario_2();

print(`\n${pass} passed, ${fail} failed\n`);
exit(fail == 0 ? 0 : 1);
