'use strict';

/* Scenario tests 6-9 for the nodes page (docs/tasks/m8.md T8.5).
 *
 * 6-8 exercise the pure model module (aether-proxy/model/nodes.js) through the
 * LuCI loader with a baseclass double; _() resolves from the real po file so
 * the assertions check the documented Chinese wording end to end. 9 holds the
 * static source checks on the view: form.GridSection, no rpc.declare, the
 * delete button is a confirmed cbi-button-remove, set-current goes through
 * ui.changes.apply, probing goes through ap.run_job, no cbi-button-reset.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { loadModule, parsePo } = require('./loader.js');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs', 'luci-static', 'resources');
const MODEL = path.join(RES, 'aether-proxy', 'model', 'nodes.js');
const VIEW = path.join(RES, 'view', 'aether-proxy', 'nodes.js');
const PO = path.join(APP, 'po', 'zh_Hans', 'aether-proxy.po');

const po = parsePo(fs.readFileSync(PO, 'utf8'));

/* The model goes through the browser-global _(); resolve it from the real po
   so the tests also fail when a translation goes missing. */
globalThis._ = (s) => po[s] ?? s;

function tr(msgid, ...args) {
	let s = po[msgid] ?? msgid;

	for (const a of args)
		s = s.replace('%s', a);

	return s;
}

function build(sections, current, subs, results) {
	const model = loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });
	return model.build(sections, current, subs, results);
}

function section(name, opts) {
	return Object.assign({ '.name': name, protocol: 'vless', address: '203.0.113.10', port: 443 }, opts);
}

const RESULTS = {
	ok: true,
	at: 1760400000,
	nodes: {
		n_ok: { ip: '203.0.113.10', ok: 3, fail: 0, min_ms: 41, median_ms: 44, error: null },
		n_fail: { ip: '198.51.100.1', ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'timeout' },
		n_partial: { ip: '198.51.100.2', ok: 1, fail: 2, min_ms: 90, median_ms: 90, error: null }
	},
	done: 3,
	total: 3,
	finished: true,
	pending: []
};

test('scenario 6: rows — name, address, summary with defaults, source, marks, allowed operations', () => {
	const sections = [
		section('n_ok', { label: 'Edge Node', transport: 'ws', security: 'tls' }),
		section('n_defaults', { protocol: 'trojan', source: 'manual' }),
		section('n_sub', { source: 's_9f8e7d6c', stale: '1' }),
		section('n_ghostsub', { source: 's_deadbeef' })
	];
	const subs = [ { '.name': 's_9f8e7d6c', name: 'Airport A' } ];

	const vm = build(sections, 'n_ok', subs, RESULTS);
	const rows = {};
	for (const r of vm.rows)
		rows[r.id] = r;

	assert.deepEqual(vm.rows.map((r) => r.id), [ 'n_ok', 'n_defaults', 'n_sub', 'n_ghostsub' ]);

	assert.equal(rows.n_ok.name, 'Edge Node');
	assert.equal(rows.n_ok.address, '203.0.113.10:443');
	assert.equal(rows.n_ok.summary, 'vless / ws / tls');
	assert.equal(rows.n_ok.source, tr('Manual'));
	assert.deepEqual(rows.n_ok.marks, [ tr('Current node') ]);
	assert.equal(rows.n_ok.can_set_current, false);
	assert.equal(rows.n_ok.can_delete, false);

	/* missing transport/security fall back to raw/none (docs/05 defaults) */
	assert.equal(rows.n_defaults.summary, 'trojan / raw / none');
	assert.equal(rows.n_defaults.can_set_current, true);
	assert.equal(rows.n_defaults.can_delete, true);

	/* a known subscription shows its name; a vanished one shows the raw section name */
	assert.equal(rows.n_sub.source, 'Airport A');
	assert.equal(rows.n_ghostsub.source, 's_deadbeef');

	/* stale is marked, subscription nodes carry the overwrite hint */
	assert.deepEqual(rows.n_sub.marks, [ tr('Stale') ]);
	assert.equal(rows.n_sub.modal_hint, po['This node comes from a subscription; edits will be overwritten at the next subscription update.']);
	assert.equal(rows.n_defaults.modal_hint, null);

	/* a node without a label falls back to its section name */
	const vm2 = build([ section('n_noname', { label: '' }) ], null, [], RESULTS);
	assert.equal(vm2.rows[0].name, 'n_noname');
});

test('scenario 7: probe column — pending, latency, the five errors, unprobed; progress text', () => {
	const sections = [
		section('n_ok', {}),
		section('n_fail', { error: 'timeout' }),
		section('n_pending', {}),
		section('n_unprobed', {}),
		section('n_resolve', {}),
		section('n_refused', {}),
		section('n_unreachable', {}),
		section('n_other', {})
	];
	const results = {
		ok: true, at: 1760400000, done: 2, total: 8, finished: false,
		nodes: {
			n_ok: { ip: '203.0.113.10', ok: 3, fail: 0, min_ms: 41, median_ms: 44, error: null },
			n_fail: { ip: '198.51.100.1', ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'timeout' },
			n_resolve: { ip: null, ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'resolve_failed' },
			n_refused: { ip: '198.51.100.4', ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'refused' },
			n_unreachable: { ip: '198.51.100.5', ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'unreachable' },
			n_other: { ip: '198.51.100.6', ok: 0, fail: 3, min_ms: null, median_ms: null, error: 'other' }
		},
		pending: [ 'n_pending' ]
	};

	const vm = build(sections, null, [], results);
	const rows = {};
	for (const r of vm.rows)
		rows[r.id] = r;

	/* a node in pending reads 「检测中」 even when it has a stale result */
	const r_pending_again = build([ section('n_ok', {}) ], null, [], { ...results, pending: [ 'n_ok' ] });
	assert.equal(r_pending_again.rows[0].probe, tr('Probing…'));

	assert.equal(rows.n_ok.probe, tr('%s ms (%s/3)', 44, 3));
	assert.equal(rows.n_fail.probe, tr('Timed out'));
	assert.equal(rows.n_pending.probe, tr('Probing…'));
	assert.equal(rows.n_unprobed.probe, tr('Not probed'));
	assert.equal(rows.n_resolve.probe, tr('Resolve failed'));
	assert.equal(rows.n_refused.probe, tr('Connection refused'));
	assert.equal(rows.n_unreachable.probe, tr('Unreachable'));
	assert.equal(rows.n_other.probe, tr('Other error'));

	/* progress: done/total while running, gone once finished */
	const model = loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });
	assert.equal(vm.progress, tr('Probing %s/%s', 2, 8));
	assert.equal(model.progress(RESULTS), null);
	assert.equal(model.progress(null), null);
	assert.equal(build(sections, null, [], RESULTS).progress, null);

	/* no results at all: 未检测, no progress */
	const vm2 = build(sections, null, [], null);
	assert.equal(vm2.rows[0].probe, tr('Not probed'));
	assert.equal(vm2.progress, null);

	/* ok > 0 with a partial count shows latency and count */
	const vm3 = build([ section('n_partial', {}) ], null, [], RESULTS);
	assert.equal(vm3.rows[0].probe, tr('%s ms (%s/3)', 90, 1));
});

test('T10.19 scenario 3: local pending overrides unread, failed and stale results only for selected IDs', () => {
	const model = loadModule(MODEL, { baseclass: { extend: o => o } }, {});
	for (const results of [undefined, { ok: false, code: 'TIMEOUT' }, RESULTS]) {
		assert.equal(model.probe_column('n_ok', results, ['n_ok']), tr('Probing…'));
		assert.equal(model.probe_column('n_fail', results, ['n_ok']),
			model.probe_column('n_fail', results));
		const rows = model.build([section('n_ok'), section('n_fail')], null, [], results, ['n_ok']).rows;
		assert.equal(rows[0].probe, tr('Probing…'));
		assert.equal(rows[1].probe, model.probe_column('n_fail', results));
	}
});

test('scenario 8: import — split keeps line numbers, the three reply kinds are tallied', () => {
	const model = loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });

	const lines = model.split_import('\n  vless://a@h:1#One  \n\n\tvmess://YmFzZTY0\n   \ntrojan://pw@h:2#Three\r\nss://YWVz@h:3#Four\n');
	assert.deepEqual(lines, [
		{ line: 2, uri: 'vless://a@h:1#One' },
		{ line: 4, uri: 'vmess://YmFzZTY0' },
		{ line: 6, uri: 'trojan://pw@h:2#Three' },
		{ line: 7, uri: 'ss://YWVz@h:3#Four' }
	]);

	const sum = model.summarize_import(lines, [
		{ ok: true, node: 'n_new', duplicate: false },
		{ ok: true, node: 'n_dup', duplicate: true },
		{ ok: false, code: 'CONFIG_INVALID', detail: 'malformed' },
		{ ok: true, node: 'n_new2', duplicate: false }
	]);
	assert.equal(sum.added, 2);
	assert.equal(sum.existing, 1);
	assert.deepEqual(sum.failed, [ { line: 6, code: 'CONFIG_INVALID', detail: 'malformed' } ]);
	assert.equal(sum.text, po['Imported: %s new, %s already present, %s failed.'].replace('%s', 2).replace('%s', 1).replace('%s', 1));

	/* a failed RPC call (no reply object at all is impossible via ap.call, but a
	   failure object without code/detail must not throw) */
	const sum2 = model.summarize_import([ lines[0] ], [ { ok: false, code: 'RPC_FAILED', detail: 'boom' } ]);
	assert.equal(sum2.added, 0);
	assert.deepEqual(sum2.failed, [ { line: 2, code: 'RPC_FAILED', detail: 'boom' } ]);

	/* job failure text for the view notification */
	assert.equal(model.job_failure_text({ ok: false, code: 'USAGE', detail: 'x' }),
		po['The probe job failed: %s (%s).'].replace('%s', 'USAGE').replace('%s', 'x'));
	assert.equal(model.job_failure_text({ state: 'failed', error: 'CMD_FAILED', exit: 1 }),
		po['The probe job failed: %s (%s).'].replace('%s', 'CMD_FAILED').replace('%s', 'exit 1'));
	assert.equal(model.job_failure_text({ state: 'ok', exit: 0 }), null);
});

test('scenario 9: static view checks — GridSection, no rpc.declare, confirmed remove, ui.changes.apply, ap.run_job, no cbi-button-reset', () => {
	const src = fs.readFileSync(VIEW, 'utf8');

	/* the view goes through ap and the model, never through rpc */
	assert.doesNotMatch(src, /rpc\s*\.\s*declare/);
	assert.match(src, /'require aether-proxy\.common as ap'/);
	assert.match(src, /'require aether-proxy\.model\.nodes as model'/);

	/* the grid section with its per-row actions */
	assert.match(src, /form\.GridSection/);
	assert.match(src, /renderRowActions/);
	assert.match(src, /cbi-button-remove/);
	assert.match(src, /await ap\.confirm\(/);
	assert.match(src, /cbi-button-remove/);

	/* set as current stages the UCI change and applies with rollback */
	assert.match(src, /uci\.set\('aetherproxy', 'main', 'node', section_id\)/);
	assert.match(src, /uci\.save\(\)/);
	assert.match(src, /ui\.changes\.apply\(/);

	/* probing is a background job; results refresh through probe_results */
	assert.match(src, /ap\.run_job\(/);
	assert.match(src, /ap\.call\('probe_results'\)/);
	assert.match(src, /ap\.call\('node_import'/);

	/* per docs/10 「UI 规则」: never cbi-button-reset */
	assert.doesNotMatch(src, /cbi-button-reset/);
});

/* Regression (M10 full regression, 2026-10-20): the row buttons were bound with
 * ui.createHandlerFn(self, 'handleProbeOne' / 'handleSetCurrent', section_id), but the
 * handlers took (ev, section_id). LuCI passes the bound arguments first and the event
 * last, so 「检测」 sent the event object as the node list (rpcd: USAGE) and 「设为当前」
 * would have written it into main.node. The double below follows luci-base ui.js:
 * fn.apply(ctx, [...bound, ev]) with ev.currentTarget taken after the bound arguments. */
function luciCreateHandlerFn(ctx, fn, ...bound) {
	if (typeof fn == 'string')
		fn = ctx[fn];
	if (typeof fn != 'function')
		return null;
	return function(...rest) {
		const target = [ ...bound, ...rest ][bound.length].currentTarget;
		target.disabled = true;
		return Promise.resolve(fn.apply(ctx, [ ...bound, ...rest ])).finally(() => { target.disabled = false; });
	};
}

function loadNodesView(calls) {
	const modelMod = loadModule(MODEL, { baseclass: { extend: (o) => o } },
		{ window: {}, document: { addEventListener() {}, removeEventListener() {} } });
	const view = loadModule(VIEW, {
		view: { extend: (o) => o },
		form: {},
		uci: {
			sections: () => [],
			get: () => undefined,
			set: (...args) => calls.push([ 'uci.set', ...args ]),
			save: () => { calls.push([ 'uci.save' ]); return Promise.resolve(); }
		},
		ui: {
			createHandlerFn: luciCreateHandlerFn,
			changes: { apply: (...args) => { calls.push([ 'apply', ...args ]); } },
			addNotification: (...args) => calls.push([ 'notify', ...args ])
		},
		dom: { content: () => {} },
		'aether-proxy.common': {
			call: (method) => { calls.push([ 'call', method ]); return Promise.resolve({ ok: true, nodes: {} }); },
			run_job: (kind, args) => { calls.push([ 'run_job', kind, args ]); return Promise.resolve({ state: 'ok' }); }
		},
		'aether-proxy.model.nodes': modelMod
	}, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });
	view.probeButtons = [];
	view.probeCells = {};
	view.progressEl = {};
	return view;
}

test('row 「检测」 click sends only that node id to probe_nodes', async () => {
	const calls = [];
	const view = loadNodesView(calls);
	const click = luciCreateHandlerFn(view, 'handleProbeOne', 'n_0123456789abcdef0123456789abcdef');

	await click({ currentTarget: {} });

	assert.deepEqual(calls.find((c) => c[0] == 'run_job'),
		[ 'run_job', 'probe_nodes', [ 'n_0123456789abcdef0123456789abcdef' ] ]);
});

test('row 「设为当前」 click writes the node id into main.node, saves and applies with rollback', async () => {
	const calls = [];
	const view = loadNodesView(calls);
	const click = luciCreateHandlerFn(view, 'handleSetCurrent', 'n_0123456789abcdef0123456789abcdef');

	await click({ currentTarget: {} });

	assert.deepEqual(calls, [
		[ 'uci.set', 'aetherproxy', 'main', 'node', 'n_0123456789abcdef0123456789abcdef' ],
		[ 'uci.save' ],
		[ 'apply', true ]
	]);
});
