'use strict';

/* B25 quota heatmap, docs/tasks/m16.md T16.5 and quota design §4–8.
 * Real model + view with shared LuCI DOM doubles; assert persistent controls,
 * calendar arithmetic, request mappings and failure isolation. */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { loadModule, parsePo, element, contentChildren, htmlWriteMark, htmlWritesSince } = require('./loader.js');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs', 'luci-static', 'resources');
const MODEL = path.join(RES, 'aether-proxy', 'model', 'overview.js');
const VIEW = path.join(RES, 'view', 'aether-proxy', 'overview.js');
const PO = path.join(APP, 'po', 'zh_Hans', 'aether-proxy.po');

const po = parsePo(fs.readFileSync(PO, 'utf8'));

/* The model goes through the browser-global _(); resolve it from the real po
   so the assertions check the documented Chinese wording end to end. */
globalThis._ = (s) => po[s] ?? s;

globalThis.E = element;

function tr(msgid, ...args) {
	let s = po[msgid] ?? msgid;

	for (const a of args)
		s = s.replace('%s', a);

	return s;
}

function conflictsModel() {
	return loadModule(path.join(RES, 'aether-proxy', 'model', 'conflicts.js'),
		{ baseclass: { extend: (o) => o } }, { window: {}, document: {} });
}

function logsModel() {
	return loadModule(path.join(RES, 'aether-proxy', 'model', 'logs.js'), {
		baseclass: { extend: (o) => o }, 'aether-proxy.model.conflicts': conflictsModel()
	}, { window: {}, document: {} });
}

function dashboardModel() {
	return loadModule(MODEL, {
		baseclass: { extend: (o) => o }, 'aether-proxy.model.logs': logsModel(),
		'aether-proxy.model.conflicts': conflictsModel()
	}, { window: {}, document: {} });
}

/* Load view/aether-proxy/overview.js like the other page tests, with an rpc
   double that records every call and answers from `replies` (method → value
   or function of the params). `state.heatmap` is what UCI reports for
   stats.heatmap_enabled and can be flipped between refreshes. */
function loadView({ replies = {}, state = { heatmap: '0' } } = {}) {
	const calls = [];
	const requests = [];
	const ap = {
		confirm: async () => true,
		call: (method, params) => {
			calls.push(method);
			requests.push({ method, params });
			const reply = replies[method];
			return Promise.resolve(typeof reply == 'function' ? reply(params) : (reply ?? {}));
		},
		poll: () => ({ stop() {} })
	};
	const uci = {
		load: () => Promise.resolve(),
		unload: () => {},
		sections: (config, type, cb) => {},
		get: (config, sid, option) => sid == 'stats' && option == 'heatmap_enabled' ? state.heatmap : undefined,
		set: () => {},
		save: () => Promise.resolve(),
		changes: async () => ({})
	};
	const view = loadModule(VIEW, {
		view: { extend: (o) => o },
		uci, ui: {
			createHandlerFn: (ctx, fn) => (typeof fn == 'function' ? (...args) => fn.call(ctx, ...args) : null),
			changes: { apply: () => {} },
			addNotification: () => { throw new Error('heatmap must not notify'); }
		},
		dom: { content: (el, node) => contentChildren(el, node) },
		'aether-proxy.common': ap,
		'aether-proxy.model.overview': dashboardModel()
	}, { window: {
		setTimeout: () => 0, clearTimeout: () => {},
		localStorage: { getItem: () => null, setItem: () => {} },
		addEventListener() {}, removeEventListener() {}
	}, document: { addEventListener() {}, removeEventListener() {} } });
	return { view, calls, requests, state };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/* 'YYYY-MM-DD' → unix ms, for date-arithmetic assertions. */
function parse_local(date) {
	const [ y, m, d ] = date.split('-').map(Number);
	return Date.UTC(y, m - 1, d);
}

function findAll(node, tag, out = []) {
	if (!node || typeof node != 'object')
		return out;
	if (node.tag == tag)
		out.push(node);
	for (const child of node.children ?? [])
		findAll(child, tag, out);
	return out;
}

/* One week of sample data around 2026-10-26 (a Monday) .. 2026-11-01. */
function weekReply() {
	return {
		ok: true, enabled: true, updated_at: 1790000000,
		days: [
			{ date: '2026-10-26', tx: 999999, rx: 0, observed: 86400, healthy: 86400 },
			{ date: '2026-10-28', tx: 500, rx: 0, observed: 86400, healthy: 0 },
			{ date: '2026-10-29', tx: 0, rx: 0, observed: 0, healthy: 0 }
		]
	};
}

test('heatmap: switch is only the exact UCI value 1', () => {
	const model = dashboardModel();
	assert.equal(model.heatmap_enabled('1'), true);
	assert.equal(model.heatmap_enabled('0'), false);
	assert.equal(model.heatmap_enabled(''), false);
	assert.equal(model.heatmap_enabled('2'), false);
	assert.equal(model.heatmap_enabled('true'), false);
	assert.equal(model.heatmap_enabled(null), false);
	assert.equal(model.heatmap_enabled(undefined), false);
	assert.equal(model.heatmap_enabled(1), false);
});

test('heatmap: today is the local calendar date of the timestamp', () => {
	const model = dashboardModel();
	/* Built with local constructors and read back with local getters, so the
	   expectation holds in every test-host timezone. */
	const d = new Date(2026, 9, 26, 23, 59, 59);
	assert.equal(model.heatmap_today(d.getTime()), '2026-10-26');
	const e = new Date(2026, 0, 1, 0, 0, 0);
	assert.equal(model.heatmap_today(e.getTime()), '2026-01-01');
});

test('heatmap: reply mapping — error and off', () => {
	const model = dashboardModel();

	assert.equal(model.heatmap_view(null, '2026-11-01').state, 'error');
	assert.equal(model.heatmap_view(null, '2026-11-01').text, tr('Reading the usage history failed (%s)', 'RPC_FAILED'));

	let vm = model.heatmap_view({ ok: false, code: 'TIMEOUT' }, '2026-11-01');
	assert.equal(vm.state, 'error');
	assert.equal(vm.text, tr('Reading the usage history failed (%s)', 'TIMEOUT'));

	vm = model.heatmap_view({ ok: true, enabled: false, days: [
		{ date: '2026-11-01', tx: 1, rx: 1, observed: 60, healthy: 60 }
	] }, '2026-11-01');
	assert.deepEqual(vm, { state: 'off' }, 'the disabled reply hides the card');
});

test('heatmap: the grid is 6×15 = 90 cells — the last 90 days ending today, no leading blank', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-08-04', tx: 1, rx: 0, observed: 60, healthy: 60 },
		...weekReply().days,
		{ date: '2026-11-01', tx: 100, rx: 0, observed: 60, healthy: 60 }
	] }, '2026-11-01');

	assert.equal(vm.state, 'ok');
	assert.equal(vm.cells.length, 90, '6 rows × 15 columns of cells');
	assert.equal(vm.cells[0].date, '2026-08-04',
		'the window opens on the 89th day before today — no leading blank cell');
	assert.equal(vm.cells[88], null, '2026-10-31 has no entry in this sample and stays blank');
	/* Row-major layout: index 89 is row 5 (floor(89/15)), column 14 (89%15) —
	   the bottom-right corner holds today. */
	assert.equal(model.heatmap_columns, 15);
	assert.equal(Math.floor(89 / model.heatmap_columns), 5);
	assert.equal(89 % model.heatmap_columns, 14);
	assert.equal(vm.cells[89].date, '2026-11-01', 'today is the bottom-right cell');
});

test('heatmap: no history still yields the full grid of blank cells', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [] }, '2026-11-01');

	assert.equal(vm.state, 'ok');
	assert.equal(vm.cells.length, 90);
	assert.ok(vm.cells.every((cell) => cell === null), 'every cell is blank');
});

test('heatmap: days without entries stay blank, wherever they fall in the grid', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view(weekReply(), '2026-11-01');

	/* Data spans 2026-10-26..10-29, i.e. cell indices 83..86 of the 90-day
	   window that starts on 2026-08-04. */
	assert.equal(vm.cells[83].date, '2026-10-26');
	assert.equal(vm.cells[84], null, '2026-10-27 has no entry and stays blank');
	assert.equal(vm.cells[85].date, '2026-10-28');
	assert.equal(vm.cells[86].date, '2026-10-29');
	assert.equal(vm.cells[87], null);
	assert.equal(vm.cells[88], null, 'past days without data are blank, not zero-filled');
	assert.equal(vm.cells[89], null, '2026-11-01 itself has no entry and stays blank');
});

test('heatmap: short and long histories both render the full 90-day window', () => {
	const model = dashboardModel();
	const day = (i) => {
		const d = new Date(Date.UTC(2026, 7, 4) + i * 86400000);
		const part = (n) => String(n).padStart(2, '0');
		return d.getUTCFullYear() + '-' + part(d.getUTCMonth() + 1) + '-' + part(d.getUTCDate());
	};
	const entries = (n) => Array.from({ length: n }, (_, i) =>
		({ date: day(i), tx: 1, rx: 0, observed: 60, healthy: 60 }));

	/* 3 days and 90 consecutive days give the same full grid: the window never
	   shrinks to the data span (docs/tasks/m12.md T12.7). */
	for (const days of [ 3, 90 ]) {
		const vm = model.heatmap_view({ ok: true, enabled: true, days: entries(days) }, '2026-11-01');
		assert.equal(vm.cells.length, 90);
	}
	const full = model.heatmap_view({ ok: true, enabled: true, days: entries(90) }, '2026-11-01');
	assert.equal(full.cells[0].date, '2026-08-04', 'the first cell is a date, not a leading blank');
	assert.equal(full.cells[89].date, '2026-11-01');
	assert.ok(full.cells.every(Boolean), 'a full 90-day history fills every cell');

	/* The cells are consecutive calendar days ending today — the grid is
	   continuous dates, not aligned to weeks (2026-08-04 is a Tuesday). */
	for (let i = 1; i < full.cells.length; i++)
		assert.equal((parse_local(full.cells[i].date) - parse_local(full.cells[i - 1].date)) / 86400000, 1,
			`${full.cells[i - 1].date} -> ${full.cells[i].date} is consecutive`);

	/* Entries older than the fixed window drop off. */
	const sparse = [ day(0), day(1), ...Array.from({ length: 20 }, (_, i) => day(160 + i)) ];
	const capped = model.heatmap_view({ ok: true, enabled: true,
		days: sparse.map((date) => ({ date, tx: 1, rx: 0, observed: 60, healthy: 60 })) }, day(179));
	assert.equal(capped.cells.length, 90);
	assert.ok(capped.cells.filter(Boolean).every((cell) => cell.date >= day(90)),
		'entries older than the shown 90 days drop off');
});

test('heatmap: future dates never render, invalid entries are skipped', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-11-01', tx: 5, rx: 0, observed: 60, healthy: 60 },
		{ date: '2026-11-02', tx: 5, rx: 0, observed: 60, healthy: 60 },
		{ date: '2026-02-30', tx: 5, rx: 0, observed: 60, healthy: 60 },
		{ date: '2026-13-01', tx: 5, rx: 0, observed: 60, healthy: 60 },
		{ date: 'not-a-date', tx: 5, rx: 0, observed: 60, healthy: 60 },
		{ tx: 5, rx: 0, observed: 60, healthy: 60 },
		null
	] }, '2026-11-01');

	assert.equal(vm.state, 'ok');
	const cells = vm.cells.filter(Boolean);
	assert.deepEqual(cells.map((cell) => cell.date), [ '2026-11-01' ],
		'only the past valid date is drawn');
});


function entry(date, total, observed = 86400, healthy = 70800) {
	return { date, tx: total / 2, rx: total / 2, observed, healthy };
}

function history(days = [], bytes = null) {
	return { ok: true, enabled: true, days, quota: { bytes, set_at: null } };
}

function cell(date, total, bytes) {
	return dashboardModel().heatmap_view(history([ entry(date, total) ], bytes), date).cells[89];
}

test('T16.5 model: six quota levels use left-closed boundaries', () => {
	const ratios = [ 0, 0.249, 0.25, 0.499, 0.5, 0.749, 0.75, 0.999, 1, 2.4 ];
	assert.deepEqual(ratios.map((r) => cell('2026-11-16', r * 1e9, 30e9).level),
		[ 0, 1, 2, 2, 3, 3, 4, 4, 5, 5 ]);
	assert.equal(cell('2026-11-16', 2.4e9, 30e9).ratio, 2.4, 'over quota is not clipped');
});

test('T16.5 model: daily quota uses February 28, November 30, December 31 days', () => {
	for (const [date, days] of [ [ '2026-02-16', 28 ], [ '2026-11-16', 30 ], [ '2026-12-16', 31 ],
		[ '2028-02-16', 29 ] ]) {
		const c = cell(date, 1e9, 100e9);
		assert.equal(c.ratio, 1e9 / (100e9 / days));
	}
	const cross = dashboardModel().heatmap_view(history([
		entry('2026-11-30', 1e9), entry('2026-12-01', 1e9)
	], 100e9), '2026-12-01').cells.slice(-2);
	assert.equal(cross[0].ratio, 1e9 / (100e9 / 30));
	assert.equal(cross[1].ratio, 1e9 / (100e9 / 31));
});

test('T16.5 model: relative fallback uses 1+floor capped at four, handles absent quota and all-zero window', () => {
	const days = [ entry('2026-11-14', 0), entry('2026-11-15', Math.expm1(1)),
		entry('2026-11-16', Math.expm1(4)) ];
	for (const quota of [ undefined, null, { bytes: null } ]) {
		const vm = dashboardModel().heatmap_view({ ...history(days), quota }, '2026-11-16');
		assert.deepEqual(vm.cells.slice(-3).map((c) => c.level), [ 0, 2, 4 ]);
		assert.equal(vm.cells[89].tip.split('\n').length, 4);
	}
	const zero = dashboardModel().heatmap_view(history([entry('2026-11-16', 0)]), '2026-11-16');
	assert.equal(zero.cells[89].level, 0);
	assert.ok(zero.cells[89].tip, 'recorded zero has a tooltip');
	assert.equal(zero.cells[88], null, 'absent record stays blank');
});

test('T16.5 model: tooltip five lines and observed zero never changes traffic colour', () => {
	const vm = dashboardModel().heatmap_view(history([
		entry('2026-11-16', 2e9, 86400, 70800)
	], 30e9), '2026-11-16');
	assert.deepEqual(vm.cells[89].tip.split('\n'), [ '2026-11-16',
		tr('Proxy traffic %s', '1.9 GB'), tr('Healthy share %s', '82% (70800/86400 ' + tr('seconds') + ')'),
		tr('Observed %s', tr('%s days', 1)), tr('Daily quota share %s', '200%') ]);
	const unobserved = dashboardModel().heatmap_view(history([
		entry('2026-11-16', 2e9, 0, 0)
	], 30e9), '2026-11-16').cells[89];
	assert.equal(unobserved.level, 5);
	assert.equal(unobserved.tip.split('\n')[2], tr('Healthy share %s', '—'));
	assert.equal('health' in unobserved, false, 'health has no visual encoding');
});

async function mounted(replies = {}, heatmap = '1') {
	const h = loadView({ replies: { stats_history: history(), ...replies }, state: { heatmap } });
	h.root = h.view.render(await h.view.load());
	await h.view.initialRequest;
	await tick();
	return h;
}

test('T16.5 view: disabled has original traffic structure, no heatmap and no history RPC', async () => {
	const { view, calls, root } = await mounted({}, '0');
	assert.deepEqual(view.content.children,
		[ view.noticeContent, view.runtimeContent, view.trafficContainer, view.componentSection ]);
	assert.equal(calls.includes('stats_history'), false);
	assert.equal(calls.includes('stats_quota'), false);
	assert.equal(findAll(root, 'div').some((n) => n.attrs.class === 'ap-heat-wrap'), false);
	assert.equal(view.heatmapContainer.children.length, 0);
	assert.deepEqual(view.trafficBody.children.map((n) => n.tag), [ 'h3', 'table', 'div' ]);
});

test('T16.5 view: two columns, caption-grid without legend, 15-column responsive theme CSS', async () => {
	const { view } = await mounted();
	const [heading, columns] = view.trafficBody.children;
	assert.equal(heading.textContent, tr('Traffic and connections'));
	assert.equal(columns.attrs.class, 'ap-traffic-columns');
	assert.deepEqual(columns.children, [ view.heatmapContainer, view.trafficLive ]);
	assert.deepEqual(view.trafficLive.children.map((n) => n.tag), [ 'table', 'div' ]);
	assert.equal(view.heatmapContainer.children[0].attrs.class, 'ap-heat-caption');
	assert.equal(view.heatmapContainer.children[2], view.heatmapGridNode);
	assert.equal(view.heatmapContainer.children.length, 4);
	assert.equal(view.heatmapContainer.children[0].children[0].textContent, tr('Last 90 days · Redder = more usage'));
	assert.equal(findAll(view.heatmapContainer, 'button').length, 0);
	assert.equal(view.heatmapGridNode.children.length, 90);
	assert.ok(view.heatmapCells.every((n) => n.className === 'ap-heat-cell ap-heat-void'));
	assert.ok(view.heatmapCells.every((n) => n.attrs.title === undefined));
	assert.equal(view.quotaSelect.children.length, 7);
	const css = view.heatmapStyle.textContent;
	for (const pattern of [ /repeat\(15, minmax\(0, 1fr\)\)/, /gap:3px; width:100%/,
		/aspect-ratio:1; border-radius:20%/, /overflow-x:auto/, /flex:0 0 35%; max-width:35%/, /flex:1 1 65%/, /max-width:400px/, /379\.5px/,
		/gap:1.5em; align-items:center; flex-wrap:nowrap/, /max-width:719px/,
		/flex-direction:column/, /prefers-color-scheme: dark/ ])
		assert.match(css, pattern);
	for (const color of [ '#eef1f4', '#1c2228', '#dbe7f3', '#1f2a33', '#9ec9e8', '#2c4a63',
		'#74b3d8', '#4b8ab5', '#f2c14e', '#b08a2e', '#ef8c3c', '#c66a25', '#d9463f', '#d0453b' ])
		assert.ok(css.includes(color), color);
	assert.doesNotMatch(css, /legend|swatch|ap-rel-|box-shadow|::after|repeat\(30/);
});

test('T16.5 view: initial quota selects unlimited, every preset or filled custom GB', async () => {
	for (const [bytes, selection, input] of [ [null, 'none', ''], [50e9, '50', '50'],
		[100e9, '100', '100'], [200e9, '200', '200'], [500e9, '500', '500'],
		[1e12, '1000', '1000'], [123e9, 'custom', '123'] ]) {
		const { view } = await mounted({ stats_history: history([], bytes) });
		assert.equal(view.quotaSelect.value, selection);
		assert.equal(view.quotaInput.value, input);
		assert.equal(view.quotaCustom.hidden, selection !== 'custom');
	}
});

test('T16.5 view: polling preserves caption, dropdown, custom input, grid and table identities', async (t) => {
	t.mock.method(Date, 'now', () => new Date(2026, 10, 16, 12).getTime());
	let bytes = 30e9;
	let total = 1e8;
	const { view, calls } = await mounted({ stats_history: () => history([ entry('2026-11-16', total) ], bytes) });
	const nodes = [ view.heatmapContainer.children[0], view.quotaSelect, view.quotaInput, view.quotaControl,
		view.heatmapGridNode, view.heatmapCells[89], view.trafficTable, view.trafficValues.proxy.tx ];
	view.quotaSelect.value = 'custom';
	view.quotaSelect.attrs.change();
	view.quotaInput.value = '321';
	const oldTip = view.heatmapCells[89].attrs.title;
	total = 2e9;
	const mark = htmlWriteMark();
	await view.fetchRefresh();
	const after = [ view.heatmapContainer.children[0], view.quotaSelect, view.quotaInput, view.quotaControl,
		view.heatmapGridNode, view.heatmapCells[89], view.trafficTable, view.trafficValues.proxy.tx ];
	nodes.forEach((node, i) => assert.equal(after[i], node, 'strict node identity at index ' + i));
	assert.equal(view.quotaSelect.value, 'custom');
	assert.equal(view.quotaInput.value, '321', 'editing text is not overwritten');
	assert.equal(view.heatmapCells[89].className, 'ap-heat-cell ap-heat-l5');
	assert.notEqual(view.heatmapCells[89].attrs.title, oldTip);
	assert.equal(calls.filter((m) => m === 'stats_history').length, 2, 'each refresh reads history');
	assert.ok(htmlWritesSince(mark).every((s) => !s.includes('2026-11-16') && !s.includes('200%')),
		'dynamic tooltip never takes the HTML path');
});

test('T16.5 view: presets, custom endpoints and clear only write quota and recolour', async (t) => {
	t.mock.method(Date, 'now', () => new Date(2026, 10, 16, 12).getTime());
	const { view, requests, calls } = await mounted({
		stats_history: history([ entry('2026-11-16', 2e9) ]),
		stats_quota: (p) => ({ ok: true, quota: { bytes: p.action === 'clear' ? null : p.bytes } })
	});
	const select = view.quotaSelect, control = view.quotaControl;
	const caption = view.heatmapContainer.children[0], input = view.quotaInput;
	const grid = view.heatmapGridNode, cells = [...view.heatmapCells];
	calls.length = 0;
	for (const gb of [ 50, 100, 200, 500, 1000 ]) {
		select.value = String(gb);
		await select.attrs.change();
		assert.deepEqual(requests.at(-1), { method: 'stats_quota', params: { action: 'set', bytes: gb * 1e9 } });
	}
	select.value = 'custom';
	const count = calls.length;
	select.attrs.change();
	assert.equal(calls.length, count, 'opening custom does not save');
	assert.equal(view.quotaCustom.hidden, false);
	for (const gb of [ 1, 123, 100000 ]) {
		select.value = 'custom';
		select.attrs.change();
		view.quotaInput.value = String(gb);
		await view.quotaInput.attrs.keydown({ key: 'Enter', preventDefault() {} });
		assert.deepEqual(requests.at(-1).params, { action: 'set', bytes: gb * 1e9 });
	}
	assert.equal(view.heatmapCells[89].className, 'ap-heat-cell ap-heat-l1');
	select.value = 'none';
	await select.attrs.change();
	assert.deepEqual(requests.at(-1).params, { action: 'clear' });
	assert.equal(view.heatmapCells[89].className, 'ap-heat-cell ap-heat-l4');
	assert.ok(calls.every((m) => m === 'stats_quota'), 'no page refresh, service or UCI RPC');
	assert.equal(view.quotaSelect, select);
	assert.equal(view.quotaControl, control);
	assert.equal(view.heatmapContainer.children[0], caption);
	assert.equal(view.quotaInput, input);
	assert.equal(view.heatmapGridNode, grid);
	cells.forEach((node, i) => assert.equal(view.heatmapCells[i], node));
});

test('T16.5 view: invalid custom and failed write keep selection, input and previous colours', async (t) => {
	t.mock.method(Date, 'now', () => new Date(2026, 10, 16, 12).getTime());
	const { view, calls } = await mounted({ stats_history: history([entry('2026-11-16', 4e9)], 100e9),
		stats_quota: { ok: false, code: 'FS_FAILED', detail: '<img src=x onerror=bad>' } });
	view.quotaSelect.value = 'custom';
	view.quotaSelect.attrs.change();
	const before = view.heatmapCells.map((n) => n.className);
	calls.length = 0;
	for (const bad of [ '', '0', '1.5', '1e2', '-1', '100001', 'oops' ]) {
		view.quotaSelect.value = 'custom';
		view.quotaSelect.attrs.change();
		view.quotaInput.value = bad;
		await view.quotaInput.attrs.keydown({ key: 'Enter', preventDefault() {} });
		assert.equal(view.quotaErrorNode.textContent, tr('Saving quota failed (%s)', 'USAGE'));
		assert.equal(view.quotaSelect.value, '100');
		assert.equal(view.quotaCustom.hidden, true);
		assert.deepEqual(view.heatmapCells.map((n) => n.className), before);
	}
	assert.deepEqual(calls, [], 'validation failure never writes');
	assert.equal(view.quotaSelect.value, '100');
	view.quotaSelect.value = 'custom';
	view.quotaSelect.attrs.change();
	view.quotaInput.value = '123';
	await view.quotaInput.attrs.keydown({ key: 'Enter', preventDefault() {} });
	assert.equal(view.quotaErrorNode.textContent, tr('Saving quota failed (%s)', 'FS_FAILED'));
	assert.equal(view.quotaErrorNode.hidden, false);
	assert.equal(view.quotaSelect.value, 'custom');
	assert.equal(view.quotaInput.value, '123');
	assert.equal(view.heatmapCells[89].className, 'ap-heat-cell ap-heat-l5', 'recorded over-quota colour survives');
	assert.deepEqual(view.heatmapCells.map((n) => n.className), before);
	assert.equal(view.heatmapGood.quota, 100e9);
	assert.equal(view.quotaInput.disabled, false);
});

test('T16.5 view: history failure keeps last grid, shows error below grid and warns once', async (t) => {
	t.mock.method(Date, 'now', () => new Date(2026, 10, 1, 12).getTime());
	let fail = false;
	const warns = [];
	t.mock.method(console, 'warn', (...args) => warns.push(args));
	const { view } = await mounted({ stats_history: () => fail ? { ok: false, code: 'TIMEOUT' } : weekReply() });
	const grid = view.heatmapGridNode;
	const tips = view.heatmapCells.map((n) => n.attrs.title);
	fail = true;
	await view.fetchRefresh();
	await view.fetchRefresh();
	assert.equal(view.heatmapGridNode, grid);
	assert.deepEqual(view.heatmapCells.map((n) => n.attrs.title), tips);
	assert.equal(view.heatmapContainer.children.at(-1), view.historyErrorNode);
	assert.equal(view.heatmapContainer.children.at(-2), view.heatmapGridNode);
	assert.equal(view.historyErrorNode.textContent, tr('Reading the usage history failed (%s)', 'TIMEOUT'));
	assert.equal(warns.length, 1);
	const fresh = await mounted({ stats_history: { ok: false, code: 'RPC_FAILED' } });
	assert.equal(fresh.view.heatmapCells.length, 90);
	assert.equal(fresh.view.historyErrorNode.hidden, false);
});

test('T16.5 view: switch changes and backend disabled hide heatmap without replacing live values', async () => {
	const h = await mounted({}, '0');
	const table = h.view.trafficTable;
	h.state.heatmap = '1';
	await h.view.fetchRefresh();
	assert.equal(h.view.heatmapCells.length, 90);
	assert.equal(h.view.trafficTable, table);
	h.state.heatmap = '0';
	h.calls.length = 0;
	await h.view.fetchRefresh();
	assert.equal(h.calls.includes('stats_history'), false);
	assert.equal(h.view.heatmapContainer.children.length, 0);
	assert.equal(h.view.trafficBody.children[1], table);
	const off = await mounted({ stats_history: { ok: true, enabled: false, days: [] } });
	assert.equal(off.view.heatmapContainer.children.length, 0);
	assert.deepEqual(off.view.trafficBody.children.map((n) => n.tag), ['h3', 'table', 'div']);
});


test('T16.5 view: older in-flight history cannot overwrite a successful quota write', async () => {
	let resolve;
	let pending = false;
	const h = await mounted({
		stats_history: () => pending ? new Promise((done) => { resolve = done; }) : history([], 100e9),
		stats_quota: (p) => ({ ok: true, quota: { bytes: p.bytes } })
	});
	pending = true;
	const reading = h.view.loadHeatmap();
	h.view.quotaSelect.value = '50';
	await h.view.quotaSelect.attrs.change();
	assert.equal(h.view.heatmapGood.quota, 50e9);
	resolve(history([], 100e9));
	await reading;
	assert.equal(h.view.heatmapGood.quota, 50e9);
	assert.equal(h.view.quotaSelect.value, '50');
});


test('T16.5 view: first slow history reply preserves an already edited custom input', async () => {
	let resolve;
	const h = loadView({ replies: { stats_history: () => new Promise((done) => { resolve = done; }) },
		state: { heatmap: '1' } });
	h.view.render(await h.view.load());
	await tick();
	assert.equal(typeof resolve, 'function');
	h.view.quotaSelect.value = 'custom';
	h.view.quotaSelect.attrs.change();
	h.view.quotaInput.value = '17';
	resolve(history([], 100e9));
	await h.view.initialRequest;
	assert.equal(h.view.quotaSelect.value, 'custom');
	assert.equal(h.view.quotaInput.value, '17');
	assert.equal(h.calls.includes('stats_quota'), false);
});


test('T16.5 view: Escape restores preset or custom without RPC and blur commits once', async () => {
	for (const bytes of [100e9, 123e9]) {
		const { view, requests } = await mounted({ stats_history: history([], bytes),
			stats_quota: (p) => ({ ok: true, quota: { bytes: p.bytes } }) });
		const control = view.quotaControl;
		view.quotaSelect.value = 'custom';
		view.quotaSelect.attrs.change();
		view.quotaInput.value = '999';
		const count = requests.length;
		view.quotaInput.attrs.keydown({ key: 'Escape', preventDefault() {} });
		await view.quotaInput.attrs.blur();
		assert.equal(requests.length, count, 'Escape and subsequent blur send no RPC');
		assert.equal(view.quotaSelect.value, bytes === 100e9 ? '100' : 'custom');
		assert.equal(view.quotaInput.value, String(bytes / 1e9));
		assert.equal(view.quotaErrorNode.textContent, tr('Saving quota failed (%s)', 'CANCELLED'));
		view.quotaSelect.value = 'custom';
		view.quotaSelect.attrs.change();
		view.quotaInput.value = '456';
		await view.quotaInput.attrs.blur();
		await view.quotaInput.attrs.blur();
		assert.equal(requests.length, count + 1, 'blur submits once, repeated blur is a no-op');
		assert.deepEqual(requests.at(-1).params, { action: 'set', bytes: 456e9 });
		assert.equal(view.quotaControl, control);
	}
});

test('T16.5 model: relative levels follow floor across the whole range, never red', () => {
	for (const ratio of [0.01, 0.24, 0.26, 0.49, 0.51, 0.74, 0.76, 0.99, 1]) {
		const total = Math.expm1(ratio * 10);
		const vm = dashboardModel().heatmap_view(history([
			entry('2026-11-15', total), entry('2026-11-16', Math.expm1(10))
		]), '2026-11-16');
		assert.equal(vm.cells[88].level, Math.min(4, 1 + Math.floor(4 * Math.log1p(total) / 10)));
		assert.ok(vm.cells.filter(Boolean).every((c) => c.level <= 4));
	}
});

test('T16.5 view: rejected quota RPC preserves input, colours and enabled controls', async () => {
	const { view } = await mounted({ stats_history: history([], 100e9),
		stats_quota: () => Promise.reject(new Error('offline')) });
	view.quotaSelect.value = 'custom';
	view.quotaSelect.attrs.change();
	view.quotaInput.value = '456';
	await view.quotaInput.attrs.blur();
	assert.equal(view.quotaInput.value, '456');
	assert.equal(view.heatmapGood.quota, 100e9);
	assert.equal(view.quotaInput.disabled, false);
	assert.equal(view.quotaErrorNode.textContent, tr('Saving quota failed (%s)', 'offline'));
});
