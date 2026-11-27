'use strict';

/* B25 quota heatmap, docs/tasks/m16.md T16.7 and quota design §4–8.
 * Real model + view with shared LuCI DOM doubles; assert persistent controls,
 * calendar arithmetic, request mappings and failure isolation. */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { loadModule, parsePo, contentChildren, htmlWriteMark, htmlWritesSince } = require('./loader.js');
const { modalElement: element, modalDocument } = require('./modal-dom');

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
	// Each fixture is a fresh page, not focus moving out of the previous test.
	modalDocument.activeElement = null;
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
	}, document: modalDocument });
	return { view, calls, requests, state };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
async function leaveQuota(view, relatedTarget = null) {
	// DOM focusout does not return the asynchronous quota RPC promise. Drain
	// its handlers just as the original tests awaited commitQuotaInput().
	view.quotaCustom.attrs.focusout({ relatedTarget });
	await tick();
}

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

test('T16.6 model: the grid is 5×18 = 90 cells — the last 90 days ending today, no leading blank', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-08-04', tx: 1, rx: 0, observed: 60, healthy: 60 },
		...weekReply().days,
		{ date: '2026-11-01', tx: 100, rx: 0, observed: 60, healthy: 60 }
	] }, '2026-11-01');

	assert.equal(vm.state, 'ok');
	assert.equal(vm.cells.length, 90, '5 rows × 18 columns of cells');
	assert.equal(vm.cells[0].date, '2026-08-04',
		'the window opens on the 89th day before today — no leading blank cell');
	assert.equal(vm.cells[88], null, '2026-10-31 has no entry in this sample and stays blank');
	/* Zero-based row-major layout: index 89 is row 4, column 17 —
	   the fifth row's bottom-right corner holds today. */
	assert.equal(model.heatmap_columns, 18);
	assert.equal(Math.floor(89 / model.heatmap_columns), 4);
	assert.equal(89 % model.heatmap_columns, 17);
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

test('T16.7 model: eight equally spaced positive days split into four equal quantile levels', () => {
	const days = Array.from({ length: 8 }, (_, i) => entry('2026-11-' + (i + 10), (i + 1) * 1e6));
	for (const quota of [ undefined, null, { bytes: null } ]) {
		const vm = dashboardModel().heatmap_view({ ...history(days), quota }, '2026-11-17');
		assert.deepEqual(vm.cells.slice(-8).map((c) => c.level), [ 1, 1, 2, 2, 3, 3, 4, 4 ]);
		assert.equal(vm.cells[89].tip.split('\n').length, 4, 'relative tooltip still omits quota share');
	}
});

test('T16.7 model: n=0 keeps recorded zero at level zero and missing dates blank', () => {
	const vm = dashboardModel().heatmap_view(history([
		entry('2026-11-14', 0), entry('2026-11-16', 0)
	]), '2026-11-16');
	assert.deepEqual(vm.cells.filter(Boolean).map((c) => c.level), [ 0, 0 ]);
	assert.ok(vm.cells[89].tip, 'recorded zero has a tooltip');
	assert.equal(vm.cells[88], null, 'absent record stays blank');
});

test('T16.7 model: n=1 is level one; n=2 unequal days are levels one and three', () => {
	assert.equal(cell('2026-11-16', 1e9, null).level, 1);
	const vm = dashboardModel().heatmap_view(history([
		entry('2026-11-13', 0), entry('2026-11-14', 1e6), entry('2026-11-16', 1e9)
	]), '2026-11-16');
	assert.deepEqual(vm.cells.slice(-4).map((c) => c && c.level), [ 0, 1, null, 3 ],
		'zero and missing days do not count toward n or the strictly-lower rank');
});

test('T16.7 model: equal totals share the strictly-lower rank, all equal days stay level one', () => {
	const totals = [ 7, 7, 7, 7, 7, 7, 7, 7 ];
	const levels = (values) => dashboardModel().heatmap_view(history(values.map((total, i) =>
		entry('2026-11-' + (i + 10), total))), '2026-11-17').cells.filter(Boolean).map((c) => c.level);
	assert.deepEqual(levels(totals), [ 1, 1, 1, 1, 1, 1, 1, 1 ]);
	assert.deepEqual(levels([ 1, 1, 2, 2, 2, 3, 3, 4 ]), [ 1, 1, 2, 2, 2, 3, 3, 4 ],
		'ties use the first rank, not their index or the number of distinct lower totals');
});

test('T16.7 model: out-of-window entries affect neither n nor the strictly-lower rank', () => {
	const days = [ entry('2026-08-19', 10), entry('2026-11-16', 20) ];
	const model = dashboardModel();
	const baseline = model.heatmap_view(history(days), '2026-11-16');
	const vm = model.heatmap_view(history([
		entry('2026-08-18', 1), entry('2026-08-17', 1e12), ...days,
		entry('2026-11-17', 1)
	]), '2026-11-16');
	assert.deepEqual(vm, baseline, 'older and future entries must not change cells, levels or tooltips');
	assert.equal(vm.cells[0].date, '2026-08-19', 'first window date still participates');
	assert.deepEqual(vm.cells.filter(Boolean).map((c) => c.level), [ 1, 3 ]);
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

test('T16.6 view: fitted top-aligned columns, quota-first caption and 18-column responsive CSS', async () => {
	const { view } = await mounted();
	const [heading, columns] = view.trafficBody.children;
	assert.equal(heading.textContent, tr('Traffic and connections'));
	assert.equal(columns.attrs.class, 'ap-traffic-columns');
	assert.deepEqual(columns.children, [ view.heatmapContainer, view.trafficLive ]);
	assert.deepEqual(view.trafficLive.children.map((n) => n.tag), [ 'table', 'div' ]);
	assert.equal(view.heatmapContainer.children[0].attrs.class, 'ap-heat-caption');
	assert.equal(view.heatmapContainer.children[2], view.heatmapGridNode);
	assert.equal(view.heatmapContainer.children.length, 4);
	const caption = view.heatmapContainer.children[0];
	assert.deepEqual(caption.children.map((n) => n.tag), [ 'label', 'span' ]);
	assert.equal(caption.children[0].children.at(-1), view.quotaControl);
	assert.equal(caption.children[0].textContent.startsWith(tr('Monthly quota')), true);
	assert.equal(caption.children[1].textContent, tr('Last 90 days · Redder = more usage'));
	const clearActions = findAll(view.heatmapContainer, 'button');
	assert.equal(clearActions.length, 1, 'only the new draft-clear action, no quota submit button');
	assert.equal(clearActions[0].getAttribute('aria-label'), tr('Clear input'));
	assert.equal(clearActions[0].hidden, true);
	assert.equal(clearActions[0].disabled, true);
	assert.equal(clearActions[0].tabIndex, -1);
	assert.equal(view.heatmapGridNode.children.length, 90);
	assert.ok(view.heatmapCells.every((n) => n.className === 'ap-heat-cell ap-heat-void'));
	assert.ok(view.heatmapCells.every((n) => n.attrs.title === undefined));
	assert.equal(view.quotaSelect.children.length, 7);
	const css = view.heatmapStyle.textContent;
	for (const pattern of [ /repeat\(18, minmax\(0, 1fr\)\)/, /gap:3px; width:519px; max-width:100%/,
		/aspect-ratio:1; border-radius:20%/, /overflow-x:auto/,
		/\.ap-heat-wrap \{ flex:0 0 auto; max-width:100%; min-width:0/,
		/\.ap-traffic-live \{ flex:1 1 auto; min-width:0/,
		/gap:1.5em; align-items:flex-start; flex-wrap:nowrap/,
		/\.ap-heat-caption \{ display:flex; align-items:center; justify-content:space-between/,
		/@media \(max-width:719px\) \{ \.ap-traffic-columns \{ flex-direction:column; align-items:stretch \} /,
		/\.ap-heat-wrap, \.ap-traffic-live \{ flex-basis:auto; width:100%; max-width:100% \} /,
		/\.ap-heat-grid \{ width:100% \} \}/, /prefers-color-scheme: dark/ ])
		assert.match(css, pattern);
	for (const color of [ '#eef1f4', '#1c2228', '#dbe7f3', '#1f2a33', '#9ec9e8', '#2c4a63',
		'#74b3d8', '#4b8ab5', '#f2c14e', '#b08a2e', '#ef8c3c', '#c66a25', '#d9463f', '#d0453b' ])
		assert.ok(css.includes(color), color);
	assert.doesNotMatch(css, /legend|swatch|ap-rel-|box-shadow|::after|repeat\((15|30)/);
	assert.doesNotMatch(css, /max-width:400px|inline-size|379\.5px|35%|65%/);
	assert.doesNotMatch(css, /\.ap-traffic-columns \{[^}]*align-items:center/);
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
	t.mock.method(Date, 'now', () => new Date(2026, 10, 16, 12, 1).getTime());
	const mark = htmlWriteMark();
	await view.fetchRefresh();
	const after = [ view.heatmapContainer.children[0], view.quotaSelect, view.quotaInput, view.quotaControl,
		view.heatmapGridNode, view.heatmapCells[89], view.trafficTable, view.trafficValues.proxy.tx ];
	nodes.forEach((node, i) => assert.equal(after[i], node, 'strict node identity at index ' + i));
	assert.equal(view.quotaSelect.value, 'custom');
	assert.equal(view.quotaInput.value, '321', 'editing text is not overwritten');
	assert.equal(view.heatmapCells[89].className, 'ap-heat-cell ap-heat-l5');
	assert.notEqual(view.heatmapCells[89].attrs.title, oldTip);
	assert.equal(calls.filter((m) => m === 'stats_history').length, 2, 'TTL expiry reads fresh history');
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
	assert.equal(view.heatmapCells[89].className, 'ap-heat-cell ap-heat-l1');
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
	t.mock.method(Date, 'now', () => new Date(2026, 10, 1, 12, 1).getTime());
	await view.fetchRefresh();
	t.mock.method(Date, 'now', () => new Date(2026, 10, 1, 12, 2).getTime());
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
	h.view.heatmapReadAt = null; // Start a read after the cache has expired.
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
		await leaveQuota(view);
		assert.equal(requests.length, count, 'Escape and subsequently leaving the editor send no RPC');
		assert.equal(view.quotaSelect.value, bytes === 100e9 ? '100' : 'custom');
		assert.equal(view.quotaInput.value, String(bytes / 1e9));
		assert.equal(view.quotaErrorNode.textContent, tr('Saving quota failed (%s)', 'CANCELLED'));
		view.quotaSelect.value = 'custom';
		view.quotaSelect.attrs.change();
		view.quotaInput.value = '456';
		await leaveQuota(view, view.quotaInput.apClearAction);
		assert.equal(requests.length, count, 'focus onto the field action must not submit');
		await leaveQuota(view);
		await leaveQuota(view);
		assert.equal(requests.length, count + 1, 'leaving submits once, repeated focusout is a no-op');
		assert.deepEqual(requests.at(-1).params, { action: 'set', bytes: 456e9 });
		assert.equal(view.quotaControl, control);
	}
});

test('T16.7 model: relative levels stay in zero through four for every window population, never red', () => {
	const start = parse_local('2026-08-19');
	for (let n = 0; n <= 90; n++) {
		const days = Array.from({ length: 90 }, (_, i) => entry(
			new Date(start + i * 86400000).toISOString().slice(0, 10), i < n ? 2 ** (i % 40) : 0));
		const vm = dashboardModel().heatmap_view(history(days), '2026-11-16');
		assert.ok(vm.cells.every((c) => [ 0, 1, 2, 3, 4 ].includes(c.level)), 'n=' + n);
	}
});

test('T16.5 view: rejected quota RPC preserves input, colours and enabled controls', async () => {
	const { view } = await mounted({ stats_history: history([], 100e9),
		stats_quota: () => Promise.reject(new Error('offline')) });
	view.quotaSelect.value = 'custom';
	view.quotaSelect.attrs.change();
	view.quotaInput.value = '456';
	await leaveQuota(view);
	assert.equal(view.quotaInput.value, '456');
	assert.equal(view.heatmapGood.quota, 100e9);
	assert.equal(view.quotaInput.disabled, false);
	assert.equal(view.quotaErrorNode.textContent, tr('Saving quota failed (%s)', 'offline'));
});


test('T16.8 view: 60000ms TTL skips five-second polls and refreshes today colour and tooltip', async (t) => {
	let now = new Date(2026, 10, 16, 12).getTime();
	t.mock.method(Date, 'now', () => now);
	let total = 1e8;
	const { view, calls } = await mounted({
		stats_history: () => history([entry('2026-11-16', total)], 30e9)
	});
	const cell = view.heatmapCells[89], oldTip = cell.attrs.title;
	assert.equal(cell.className, 'ap-heat-cell ap-heat-l1');
	total = 2e9;
	for (let elapsed = 5000; elapsed < 60000; elapsed += 5000) {
		now += 5000;
		await view.fetchRefresh();
		assert.equal(calls.filter((m) => m === 'stats_history').length, 1);
	}
	now += 4999;
	await view.fetchRefresh();
	assert.equal(calls.filter((m) => m === 'stats_history').length, 1, '59999ms is cached');
	now += 1;
	await view.fetchRefresh();
	assert.equal(calls.filter((m) => m === 'stats_history').length, 2, '60000ms expires');
	assert.equal(view.heatmapCells[89], cell);
	assert.equal(cell.className, 'ap-heat-cell ap-heat-l5');
	assert.notEqual(cell.attrs.title, oldTip);
});

test('T16.8 view: local midnight bypasses TTL and only one history request stays in flight', async (t) => {
	let now = new Date(2026, 10, 16, 23, 59, 50).getTime();
	t.mock.method(Date, 'now', () => now);
	let resolve, pending = false;
	const { view, calls } = await mounted({ stats_history: () => pending
		? new Promise((done) => { resolve = done; }) : history() });
	now += 10000;
	pending = true;
	const reading = view.loadHeatmap();
	assert.equal(calls.filter((m) => m === 'stats_history').length, 2);
	assert.equal(view.loadHeatmap(), reading);
	now += 120000;
	assert.equal(view.loadHeatmap(), reading, 'even an expired cache cannot overlap a slow read');
	assert.equal(calls.filter((m) => m === 'stats_history').length, 2);
	resolve(history([entry('2026-11-17', 123)]));
	await reading;
	assert.equal(view.heatmapGood.cells[89].date, '2026-11-17');
	assert.equal(view.heatmapRequest, null);
});
