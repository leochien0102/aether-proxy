'use strict';

/* B25 usage heatmap tests (docs/tasks/m12.md T12.6/T12.7, docs/b25-heatmap.md §7,
 * docs/10 「B25：概览页使用热力图」).
 *
 * The model scenarios exercise aether-proxy/model/overview.js: the switch
 * interpretation, the stats_history reply mapping, the continuous 13×7 date
 * grid (91 row-major cells = one leading blank plus the last 90 days ending
 * today, blank gaps, no future dates), the log1p colour levels, the health
 * tiers and the text-only tooltip. The view scenarios load
 * view/aether-proxy/overview.js with the shared doubles: the switch off never
 * calls stats_history and renders nothing, the switch on fetches through
 * fetchRefresh only (TTL-gated), the bare grid (no section box, no title, no
 * weekday header) sits between the notices and the runtime status region,
 * centered and capped, a failed read keeps the last successful grid and never
 * spams the console, and every cell is a text node.
 */

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
	const ap = {
		confirm: async () => true,
		call: (method, params) => {
			calls.push(method);
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
			addNotification: () => {}
		},
		dom: { content: (el, node) => contentChildren(el, node) },
		'aether-proxy.common': ap,
		'aether-proxy.model.overview': dashboardModel()
	}, { window: {
		setTimeout: () => 0, clearTimeout: () => {},
		localStorage: { getItem: () => null, setItem: () => {} },
		addEventListener() {}, removeEventListener() {}
	}, document: { addEventListener() {}, removeEventListener() {} } });
	return { view, calls, state };
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

test('heatmap: the grid is 13×7 = 91 cells — one leading blank plus 90 days ending today', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		...weekReply().days,
		{ date: '2026-11-01', tx: 100, rx: 0, observed: 60, healthy: 60 }
	] }, '2026-11-01');

	assert.equal(vm.state, 'ok');
	assert.equal(vm.cells.length, 91, '13 columns × 7 rows of cells');
	assert.equal(vm.cells[0], null, 'the single leading blank opens the grid');
	assert.equal(vm.cells[1], null, '2026-08-04 has no entry in this sample and stays blank');
	/* Row-major layout: index 90 is row 6 (floor(90/13)), column 12 (90%13) —
	   the bottom-right corner holds today. */
	assert.equal(Math.floor(90 / 13), 6);
	assert.equal(90 % 13, 12);
	assert.equal(vm.cells[90].date, '2026-11-01', 'today is the bottom-right cell');
	assert.equal(vm.cells[89], null, '2026-10-31 has no entry and stays blank');
});

test('heatmap: no history still yields the full grid of blank cells', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [] }, '2026-11-01');

	assert.equal(vm.state, 'ok');
	assert.equal(vm.cells.length, 91);
	assert.ok(vm.cells.every((cell) => cell === null), 'every cell is blank');
});

test('heatmap: days without entries stay blank, wherever they fall in the grid', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view(weekReply(), '2026-11-01');

	/* Data spans 2026-10-26..10-29, i.e. cell indices 84..87 of the 90-day
	   window that starts on 2026-08-04. */
	assert.equal(vm.cells[84].date, '2026-10-26');
	assert.equal(vm.cells[85], null, '2026-10-27 has no entry and stays blank');
	assert.equal(vm.cells[86].date, '2026-10-28');
	assert.equal(vm.cells[87].date, '2026-10-29');
	assert.equal(vm.cells[88], null);
	assert.equal(vm.cells[89], null, 'past days without data are blank, not zero-filled');
	assert.equal(vm.cells[90], null, '2026-11-01 itself has no entry and stays blank');
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
		assert.equal(vm.cells.length, 91);
	}
	const full = model.heatmap_view({ ok: true, enabled: true, days: entries(90) }, '2026-11-01');
	assert.equal(full.cells[0], null, 'only the leading blank is empty');
	assert.equal(full.cells[1].date, '2026-08-04');
	assert.equal(full.cells[90].date, '2026-11-01');
	assert.ok(full.cells.slice(1).every(Boolean), 'a full 90-day history fills every day cell');

	/* The day cells are consecutive calendar days ending today — the grid is
	   continuous dates, not aligned to weeks (2026-08-04 is a Tuesday). */
	for (let i = 2; i < full.cells.length; i++)
		assert.equal((parse_local(full.cells[i].date) - parse_local(full.cells[i - 1].date)) / 86400000, 1,
			`${full.cells[i - 1].date} -> ${full.cells[i].date} is consecutive`);

	/* Entries older than the fixed window drop off. */
	const sparse = [ day(0), day(1), ...Array.from({ length: 20 }, (_, i) => day(160 + i)) ];
	const capped = model.heatmap_view({ ok: true, enabled: true,
		days: sparse.map((date) => ({ date, tx: 1, rx: 0, observed: 60, healthy: 60 })) }, day(179));
	assert.equal(capped.cells.length, 91);
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

test('heatmap: colour levels follow log1p(tx+rx) over the shown days', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-10-26', tx: 0, rx: 0, observed: 60, healthy: 60 },
		{ date: '2026-10-27', tx: 500, rx: 0, observed: 60, healthy: 60 },
		{ date: '2026-10-28', tx: 999999, rx: 0, observed: 60, healthy: 60 }
	] }, '2026-11-01');

	/* The shown entries sit at cell indices 84..86 (2026-10-26..10-28). */
	assert.deepEqual(vm.cells.slice(84, 87).map((cell) => cell.level), [ 0, 2, 4 ],
		'0 traffic is level 0, log1p(500)/log1p(999999)≈0.45 is level 2, the max is level 4');

	/* A single day with traffic is the maximum: level 4. */
	const one = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-10-26', tx: 42, rx: 0, observed: 60, healthy: 60 }
	] }, '2026-11-01');
	assert.equal(one.cells[84].level, 4);

	/* All-zero traffic keeps every cell on the lightest level. */
	const zero = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-10-26', tx: 0, rx: 0, observed: 60, healthy: 60 },
		{ date: '2026-10-27', tx: 0, rx: 0, observed: 60, healthy: 60 }
	] }, '2026-11-01');
	assert.deepEqual(zero.cells.filter(Boolean).map((cell) => cell.level), [ 0, 0 ]);
});

test('heatmap: health tiers — ok, warn, bad and the neutral not-observed day', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-10-26', tx: 0, rx: 0, observed: 86400, healthy: 86400 },
		{ date: '2026-10-27', tx: 0, rx: 0, observed: 86400, healthy: 86300 },
		{ date: '2026-10-28', tx: 0, rx: 0, observed: 86400, healthy: 0 },
		{ date: '2026-10-29', tx: 0, rx: 0, observed: 0, healthy: 0 }
	] }, '2026-11-01');

	assert.deepEqual(vm.cells.slice(84, 88).map((cell) => cell.health),
		[ 'ok', 'warn', 'bad', 'none' ]);
});

test('heatmap: tooltip lines are date, traffic with an automatic unit, share and duration', () => {
	const model = dashboardModel();
	const vm = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-10-26', tx: 1048576, rx: 0, observed: 3600, healthy: 3528 },
		{ date: '2026-10-27', tx: 512, rx: 0, observed: 0, healthy: 0 },
		{ date: '2026-10-28', tx: 0, rx: 0, observed: 90000, healthy: 90000 }
	] }, '2026-11-01');

	const [ rich, unobserved, long ] = vm.cells.slice(84, 87);
	assert.equal(rich.tip, [ '2026-10-26', tr('Proxy traffic %s', '1.0 MB'),
		tr('Healthy share %s', '98%'), tr('Observed %s', tr('%s hours', 1)) ].join('\n'));
	assert.equal(unobserved.tip, [ '2026-10-27', tr('Proxy traffic %s', '512 B'),
		tr('Healthy share %s', '–'), tr('Observed %s', tr('%s seconds', 0)) ].join('\n'),
		'an unobserved day shows a neutral share, never a percentage');
	assert.equal(long.tip, [ '2026-10-28', tr('Proxy traffic %s', '0 B'),
		tr('Healthy share %s', '100%'), tr('Observed %s', tr('%s days', 1)) ].join('\n'));

	/* A corrupt entry with healthy above observed cannot claim more than 100%. */
	const clamped = model.heatmap_view({ ok: true, enabled: true, days: [
		{ date: '2026-10-26', tx: 0, rx: 0, observed: 100, healthy: 500 }
	] }, '2026-11-01');
	assert.ok(clamped.cells[84].tip.includes(tr('Healthy share %s', '100%')));
});

test('heatmap view: switch off — no region content, no stats_history, other cards still render', async () => {
	const { view, calls } = loadView();
	const root = view.render(await view.load());
	await view.initialRequest;
	await tick();

	assert.equal(calls.filter((method) => method == 'stats_history').length, 0,
		'the disabled switch never calls the history API');
	assert.deepEqual(view.heatmapContainer.children, [], 'the region is completely absent');
	assert.equal(view.content.children[1], view.heatmapContainer,
		'the empty region keeps its place between the notices and the runtime status');
	assert.ok(findAll(root, 'h3').some((h) => h.textContent == tr('Runtime status')),
		'the other overview cards are untouched');
	assert.ok(findAll(root, 'h3').some((h) => h.textContent == tr('Traffic and connections')));
});

test('heatmap view: switch on — placeholder first, then one stats_history per refresh window', async () => {
	const { view, calls } = loadView({
		replies: { stats_history: weekReply() },
		state: { heatmap: '1' }
	});
	const root = view.render(await view.load());

	assert.equal(findAll(view.heatmapContainer, 'p')[0].textContent, tr('Reading…'),
		'the region shows the shared reading placeholder before the first reply');
	assert.equal(calls.filter((method) => method == 'stats_history').length, 0,
		'load() itself does not call the history API');

	await view.initialRequest;
	await tick();
	assert.equal(calls.filter((method) => method == 'stats_history').length, 1,
		'fetchRefresh issues the history call when the switch is on');
	assert.equal(findAll(view.heatmapContainer, 'div')
		.find((d) => d.attrs.class == 'ap-heat-grid').children.length, 91,
		'the first reply renders the full 91-cell grid');

	/* A second refresh inside the TTL window does not re-read the history. */
	calls.length = 0;
	await view.fetchRefresh();
	await tick();
	assert.equal(calls.filter((method) => method == 'stats_history').length, 0);

	/* After the TTL expires the next refresh reads it again. */
	view.heatmapAt = Date.now() - 601000;
	await view.fetchRefresh();
	await tick();
	assert.equal(calls.filter((method) => method == 'stats_history').length, 1);

	/* A new local date forces a read even inside the TTL window. */
	view.heatmapAt = Date.now();
	view.heatmapDay = '2000-01-01';
	await view.fetchRefresh();
	await tick();
	assert.equal(calls.filter((method) => method == 'stats_history').length, 2);
});

test('heatmap view: renders the bare 13×7 grid — no title, no weekday header, no section box', async () => {
	const mark = htmlWriteMark();
	const { view } = loadView({
		replies: { stats_history: weekReply() },
		state: { heatmap: '1' }
	});
	view.render(await view.load());
	await view.initialRequest;
	await tick();

	const grid = findAll(view.heatmapContainer, 'div').find((d) => d.attrs.class == 'ap-heat-grid');
	assert.ok(grid, 'the region contains the heat grid');
	assert.equal(grid.children.length, 91, 'one leading blank + 90 day cells, no weekday header');
	assert.ok(findAll(view.heatmapContainer, 'h3').length === 0, 'no 「使用热力图」 title');
	assert.ok(view.heatmapContainer.children.every((node) => !String(node.attrs?.class ?? '').includes('cbi-section')),
		'no section box wraps the grid');

	/* The grid opens with the leading blank and ends with today's cell
	   (bottom-right); the data sits at cell indices 84..87. */
	assert.equal(grid.children[0].attrs.class, 'ap-heat-cell ap-heat-blank');
	assert.equal(grid.children[0].attrs.title, undefined, 'the leading blank carries no tooltip');
	assert.equal(grid.children[90].attrs.class, 'ap-heat-cell ap-heat-blank');
	assert.equal(grid.children[90].attrs.title, undefined, '2026-11-01 has no entry and stays blank');
	const [ mon, tue, wed, thu ] = grid.children.slice(84, 88);
	assert.equal(mon.attrs.class, 'ap-heat-cell ap-heat-l4 ap-heat-ok');
	assert.equal(mon.attrs.title, [ '2026-10-26', tr('Proxy traffic %s', '976.6 KB'),
		tr('Healthy share %s', '100%'), tr('Observed %s', tr('%s days', 1)) ].join('\n'));
	assert.equal(tue.attrs.class, 'ap-heat-cell ap-heat-blank');
	assert.equal(tue.attrs.title, undefined, 'blank cells carry no tooltip');
	assert.equal(wed.attrs.class, 'ap-heat-cell ap-heat-l2 ap-heat-bad');
	assert.equal(thu.attrs.class, 'ap-heat-cell ap-heat-l0 ap-heat-none');

	/* Cell data reaches the DOM only through text nodes and attributes: no
	   innerHTML write anywhere may carry a date, a byte amount or a tooltip
	   (static labels take the scalar path, like every other section title). */
	const writes = htmlWritesSince(mark);
	assert.ok(writes.length > 0, 'the scan covers the whole rendering');
	for (const needle of [ '2026-10-26', '2026-10-28', '2026-10-29', '976.6', '500', '100%' ])
		assert.ok(writes.every((write) => !write.includes(needle)),
			`no HTML write carries "${needle}"`);

	/* The styles ship with the view: every cell is a rounded square, the grid
	   keeps 13 equal columns between 2.0em and 2.4em (about 480–540px wide),
	   the region is centered and capped, and the wrapper scrolls horizontally
	   on narrow screens instead of squeezing the cells. */
	const style = findAll(view.heatmapStyle, '#text').map((node) => node.text).join('');
	assert.match(style, /aspect-ratio:\s*1/);
	assert.match(style, /border-radius:\s*20%/);
	assert.match(style, /repeat\(13,\s*minmax\(2\.0em,\s*2\.4em\)\)/);
	assert.match(style, /\.ap-heat-wrap \{ max-width: 540px; margin-inline: auto \}/);
	assert.match(style, /overflow-x:\s*auto/);
	assert.ok(!style.includes('ap-heat-head'), 'the weekday header styles are gone');
	assert.ok(!/repeat\(7,/.test(style), 'no seven-column rule remains');
});

test('heatmap view: the region sits between the notices and the runtime status card, centered and capped', async () => {
	const { view } = loadView({
		replies: { stats_history: weekReply() },
		state: { heatmap: '1' }
	});
	view.render(await view.load());
	await view.initialRequest;
	await tick();

	assert.deepEqual(view.content.children,
		[ view.noticeContent, view.heatmapContainer, view.runtimeContent,
			view.trafficContainer, view.componentSection ],
		'T12.7 content order: notices, heatmap, runtime status, traffic, components');
	assert.deepEqual(findAll(view.content, 'h3').map((h) => h.textContent),
		[ tr('Runtime status'), tr('Traffic and connections'), tr('Component versions') ],
		'the heatmap adds no heading of its own');

	/* The region itself is the centered width cap (a bare wrap, not a card);
	   the other cards keep their section boxes. */
	assert.equal(view.heatmapContainer.attrs.class, 'ap-heat-wrap');
	assert.equal(view.runtimeContent.children[0].attrs.class, 'cbi-section');
	assert.equal(view.trafficContainer.children[0].attrs.class, 'cbi-section');
	assert.equal(view.componentSection.attrs.class, 'cbi-section');
});

test('heatmap view: a failed history read shows a short error and keeps the last grid', async () => {
	let fail = false;
	const { view, calls } = loadView({
		replies: { stats_history: () => fail ? { ok: false, code: 'TIMEOUT' } : weekReply() },
		state: { heatmap: '1' }
	});
	const warns = [];
	const original = console.warn;
	console.warn = (...args) => warns.push(args.join(' '));
	try {
		view.render(await view.load());
		await view.initialRequest;
		await tick();
		assert.equal(findAll(view.heatmapContainer, 'div')
			.some((d) => d.attrs.class == 'ap-heat-grid'), true, 'the first read renders the grid');

		/* The next read fails: the grid stays, a short error joins it, and the
		   other cards are untouched. */
		fail = true;
		view.heatmapAt = Date.now() - 601000;
		await view.fetchRefresh();
		await tick();
		assert.equal(findAll(view.heatmapContainer, 'div')
			.some((d) => d.attrs.class == 'ap-heat-grid'), true, 'the last successful grid is kept');
		assert.ok(findAll(view.heatmapContainer, 'p')
			.some((p) => p.textContent == tr('Reading the usage history failed (%s)', 'TIMEOUT')));
		assert.equal(warns.length, 1, 'the console is warned once, not per failure');

		/* A second failure keeps the grid and stays quiet. */
		view.heatmapAt = Date.now() - 601000;
		await view.fetchRefresh();
		await tick();
		assert.equal(warns.length, 1);
		assert.equal(calls.filter((method) => method == 'stats_history').length, 3);

		/* A first-ever failure (nothing to keep) shows only the error text. */
		const fresh = loadView({
			replies: { stats_history: { ok: false, code: 'RPC_FAILED' } },
			state: { heatmap: '1' }
		});
		console.warn = (...args) => warns.push(args.join(' '));
		fresh.view.render(await fresh.view.load());
		await fresh.view.initialRequest;
		await tick();
		assert.deepEqual(fresh.view.heatmapContainer.children.length, 1);
		assert.ok(findAll(fresh.view.heatmapContainer, 'p')
			.some((p) => p.textContent == tr('Reading the usage history failed (%s)', 'RPC_FAILED')));
		assert.equal(findAll(fresh.view.heatmapContainer, 'div')
			.some((d) => d.attrs.class == 'ap-heat-grid'), false);
	}
	finally {
		console.warn = original;
	}
});

test('heatmap view: an enabled:false reply follows the applied configuration and hides the region', async () => {
	const { view } = loadView({
		replies: { stats_history: { ok: true, enabled: false, days: [] } },
		state: { heatmap: '1' }
	});
	view.render(await view.load());
	await view.initialRequest;
	await tick();

	assert.deepEqual(view.heatmapContainer.children, [], 'the backend switch wins over the page copy');
});

test('heatmap view: an empty history renders the full neutral grid, not a notice', async () => {
	const { view } = loadView({
		replies: { stats_history: { ok: true, enabled: true, days: [] } },
		state: { heatmap: '1' }
	});
	view.render(await view.load());
	await view.initialRequest;
	await tick();

	const grid = findAll(view.heatmapContainer, 'div').find((d) => d.attrs.class == 'ap-heat-grid');
	assert.ok(grid, 'the region shows the 13×7 grid even without any data');
	assert.equal(grid.children.length, 91, 'one leading blank + 90 day cells');
	assert.ok(grid.children.every((cell) => cell.attrs.class == 'ap-heat-cell ap-heat-blank'),
		'every cell is the neutral blank colour');
	assert.ok(grid.children.every((cell) => cell.attrs.title === undefined), 'blank cells carry no tooltip');
	assert.deepEqual(findAll(view.heatmapContainer, 'p'), [], 'no no-data notice replaces the grid');
});

test('heatmap view: flipping the switch re-evaluates the region without reloading the page', async () => {
	const { view, calls, state } = loadView({
		replies: { stats_history: weekReply() },
		state: { heatmap: '0' }
	});
	view.render(await view.load());
	await view.initialRequest;
	await tick();
	assert.deepEqual(view.heatmapContainer.children, []);

	/* Turned on (saved and applied on the advanced page): the next refresh
	   picks the new UCI value up and reads the history. */
	state.heatmap = '1';
	calls.length = 0;
	await view.fetchRefresh();
	await tick();
	assert.equal(calls.filter((method) => method == 'stats_history').length, 1);
	assert.equal(findAll(view.heatmapContainer, 'div')
		.find((d) => d.attrs.class == 'ap-heat-grid').children.length, 91);

	/* Turned off again: the region disappears and the calls stop. */
	state.heatmap = '0';
	calls.length = 0;
	await view.fetchRefresh();
	await tick();
	assert.equal(calls.filter((method) => method == 'stats_history').length, 0);
	assert.deepEqual(view.heatmapContainer.children, []);
});
