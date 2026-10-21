'use strict';

/* T8.10/T10.16 contracts: catalog templates, progressive loading, and the real
 * controller exercised with text-only DOM and request/poll/timer doubles.
 */
process.env.TZ = 'UTC';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
const ROOT = path.resolve(__dirname, '../..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const modelFile = path.join(RES, 'aether-proxy/model/logs.js');
const viewFile = path.join(RES, 'view/aether-proxy/logs.js');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = s => po[s] ?? s;
const model = loadModule(modelFile, { baseclass: { extend: o => o } }, { window: {}, document: {} });
const event = (code, level = 'notice', ts = 1760400000, args = {}) => ({ code, level, ts, args });
const payload = events => ({ ok: true, events, skipped: 0 });

test('T8.10 scenario 1: every catalog event has a template using only documented parameters', () => {
	globalThis._ = s => s;
	const english = loadModule(modelFile, { baseclass: { extend: o => o } }, { window: {}, document: {} });
	globalThis._ = s => po[s] ?? s;
	const doc = fs.readFileSync(path.join(ROOT, 'docs/09-logging.md'), 'utf8');
	const catalog = doc.split('## 事件码目录')[1].split('## logd 容量')[0];
	let count = 0;
	for (const line of catalog.split('\n')) {
		const cells = line.split('|');
		if (!cells[2] || !/notice|warn|error/.test(cells[2]))
			continue;
		const codes = Array.from(cells[1].matchAll(/`([A-Z0-9_]+)`/g), m => m[1]);
		const params = Array.from(cells[3].matchAll(/`(\w+)`/g), m => m[1]);
		for (const code of codes) {
			assert.ok(model.templates[code], code + ' template missing');
			for (const templates of [ model.templates, english.templates ])
				for (const match of templates[code].matchAll(/\{(\w+)\}/g))
					assert.ok(params.includes(match[1]), code + ' undocumented parameter ' + match[1]);
			count++;
		}
	}
	assert.ok(count >= 50, 'catalog parsing must not silently match nothing');
	assert.equal(model.templates.CHILD_STARTED, undefined);
	assert.equal(model.templates.CMD_RUN, undefined);
});

test('T9.8 scenario 7: RELOAD_APPLIED uses only docs/04 fields and shows Chinese nodes and duration', () => {
	globalThis._ = s => s;
	const english = loadModule(modelFile, { baseclass: { extend: o => o } }, { window: {}, document: {} });
	globalThis._ = s => po[s] ?? s;
	const doc = fs.readFileSync(path.join(ROOT, 'docs/04-lifecycle.md'), 'utf8');
	const contract = doc.split('**完成后记 `RELOAD_APPLIED`**')[1].split('原来重载成功')[0];
	const fields = Array.from(contract.matchAll(/`([a-z_]+)`/g), m => m[1]);
	assert.deepEqual(fields, [ 'from_node', 'to_node', 'actions', 'elapsed_ms', 'steps' ]);
	for (const templates of [ english.templates, model.templates ]) {
		assert.ok(templates.RELOAD_APPLIED);
		for (const match of templates.RELOAD_APPLIED.matchAll(/\{(\w+)\}/g))
			assert.ok(fields.includes(match[1]), 'undocumented field ' + match[1]);
	}
	assert.ok(po[english.templates.RELOAD_APPLIED], 'translation must exist');
	assert.equal(model.message(event('RELOAD_APPLIED', 'notice', 1, {
		from_node: 'n_old', to_node: 'n_new', elapsed_ms: 123,
		actions: [ 'restart_xray' ], steps: { validate: 50 }
	})), '已从节点 n_old 重载到 n_new，耗时 123 毫秒');
});

test('T8.10 scenario 2: parameter values, unknown codes and compact SERVICE_STARTED', () => {
	assert.equal(model.value_text(undefined), '?');
	assert.equal(model.value_text([ 'a', 'b' ]), 'a、b');
	assert.equal(model.value_text({ invalid: 2, unsupported: 3 }), 'invalid 2、unsupported 3');
	assert.equal(model.value_text(42), '42');
	assert.equal(model.value_text('proxy_unhealthy'), 'proxy_unhealthy');
	assert.equal(model.message(event('NEW_CODE', 'warn', 1, { x: '<script>' })), 'NEW_CODE {"x":"<script>"}');
	assert.equal(model.message(event('BUSY')), '操作被 ? 锁定');
	const started = event('SERVICE_STARTED', 'notice', 1, { elapsed_ms: 123, steps: { SECRET_STEP: 99 } });
	assert.equal(model.message(started), '服务已启动，耗时 123 毫秒');
	assert.match(model.events(payload([ started ])).rows[0].title, /SECRET_STEP/);
	assert.equal(model.message(event('DNS_TIER_CHANGED', 'warn', 1,
		{ from: 'T1', to: 'T2', reason: 'proxy_unhealthy' })),
		'DNS 已从 T1 切换到 T2（原因：proxy_unhealthy）');
});

test('T8.10 scenario 3: reverse chronological stable ties, cumulative levels and code intersection', () => {
	const data = payload([
		event('Z', 'error', 1), event('B', 'notice', 2), event('A', 'warn', 2), event('B', 'error', 3)
	]);
	const rows = (level, code) => model.events(data, null, level, code).rows.map(r => r.code);
	assert.deepEqual(rows(), [ 'B', 'A', 'B', 'Z' ]);
	assert.deepEqual(rows('error'), [ 'B', 'Z' ]);
	assert.deepEqual(rows('warn'), [ 'B', 'A', 'Z' ]);
	assert.deepEqual(rows('notice'), rows());
	assert.deepEqual(rows('', 'B'), [ 'B', 'B' ]);
	assert.deepEqual(rows('warn', 'B'), [ 'B' ]);
	assert.deepEqual(model.events(data, null, 'error', 'B').codes, [ 'A', 'B', 'Z' ]);
	assert.deepEqual(model.events(payload([])).codes, []);
});

test('T8.10 scenario 4: local timestamps, damaged-line hint and last successful list on failure', () => {
	const data = payload([ event('DNS_RECOVERED') ]);
	const first = model.events(data);
	assert.equal(first.rows[0].time, '2025-10-14 00:00:00');
	assert.equal(first.skipped, null);
	assert.equal(model.events({ ...data, skipped: 3 }).skipped, '有 3 行记录损坏，已跳过');
	const failed = model.events({ ok: false, code: 'RPC_FAILED', detail: 'network broken' }, first.data);
	assert.deepEqual(failed.rows, first.rows);
	assert.equal(failed.error, 'RPC_FAILED: network broken');
	assert.equal(model.events({ ok: false, code: 'TIMEOUT' }).rows.length, 0);
	assert.deepEqual(first.rows.map(r => r.class_name), [ 'label notice' ]);
	const colored = model.events(payload([ event('A', 'warn'), event('B', 'error') ])).rows;
	assert.deepEqual(colored.map(r => r.class_name), [ 'label danger', 'label warning' ]);
});

test('T8.10 scenario 5: raw source/line parameters, debug-only hint and error details', () => {
	assert.deepEqual(model.sources().map(s => s[0]), [ 'all', 'aether-proxy', 'xray', 'dns' ]);
	assert.deepEqual(model.line_counts(), [ 100, 200, 500, 1000, 2000 ]);
	for (const [ source ] of model.sources())
		for (const lines of model.line_counts())
			assert.deepEqual(model.log_params(source, String(lines)), { source, lines });
	const res = { ok: true, lines: [ { text: 'first <x>' }, { text: 'second' } ] };
	assert.equal(model.raw(res, 'debug').text, 'first <x>\nsecond');
	assert.equal(model.raw(res, 'debug').hint, '建议在 系统 → 日志 中调大缓冲区，排查完成后调回 notice');
	for (const level of [ 'info', 'notice', 'warn', 'error', undefined ])
		assert.equal(model.raw(res, level).hint, null);
	assert.equal(model.raw({ ok: false, code: 'CMD_FAILED', detail: 'logread failed' }).error,
		'CMD_FAILED: logread failed');
});

/* Strings become text nodes, never interpreted markup. The test traverses
 * rendered descendants rather than accepting the model's safe string alone.
 */
function setContent(node, children) {
	const flat = (Array.isArray(children) ? children : [ children ]).flat(Infinity);
	node.replaceChildren(...flat);
	if (node.tag == 'select')
		node.value = node.children[0]?.value ?? '';
}
function descendants(node) {
	return [ node ].concat((node.childNodes || []).flatMap(descendants));
}

test('T8.10 scenario 6: default events poll, tab/checkbox stop, raw refresh and text-node safety', async () => {
	const calls = [], polls = [], timers = [];
	const malicious = '<img src=x onerror=alert(1)>';
	const data = payload([ event('NEW', 'warn', 1, { text: malicious }) ]);
	const ap = {
		call: async (method, params) => {
			calls.push({ method, params });
			return method == 'events' ? data : { ok: true, lines: [ { text: malicious } ] };
		},
		poll: (fn, interval) => {
			const poll = { fn, interval, stopped: false, stop() { this.stopped = true; } };
			polls.push(poll);
			return poll;
		}
	};
	globalThis.E = element;
	const view = loadModule(viewFile, {
		view: { extend: o => o }, uci: { load: async () => {}, get: () => 'debug' },
		dom: { content: setContent }, 'aether-proxy.common': ap, 'aether-proxy.model.logs': model
	}, { window: { setTimeout: (fn, delay) => timers.push({ fn, delay }) }, document: {} });
	const root = view.render(await view.load());
	assert.deepEqual(calls, [], 'render returns before the initial events request');
	assert.equal(timers.length, 1);
	assert.equal(timers[0].delay, 0);
	timers[0].fn();
	await Promise.resolve();
	assert.equal(view.tab, 'events');
	assert.equal(view.eventPanel.hidden, false);
	assert.equal(view.rawPanel.hidden, true);
	assert.equal(view.auto.checked, true);
	assert.deepEqual(calls, [ { method: 'events', params: {} } ]);
	assert.equal(polls[0].interval, 5000);
	await polls[0].fn();
	assert.equal(calls[1].method, 'events');
	await view.switchTab('raw');
	assert.equal(polls[0].stopped, true);
	assert.equal(view.eventPanel.hidden, true);
	assert.deepEqual(calls[2], { method: 'log', params: { source: 'all', lines: 200 } });
	assert.equal(polls.length, 1, 'raw logs never poll');
	view.source.value = 'xray';
	view.lines.value = '1000';
	const refresh = view.rawPanel.children.find(c => c.tag == 'button');
	await refresh.attrs.click();
	assert.deepEqual(calls[3], { method: 'log', params: { source: 'xray', lines: 1000 } });
	await view.switchTab('events');
	assert.equal(polls.length, 2);
	view.auto.checked = false;
	view.auto.attrs.change();
	assert.equal(polls[1].stopped, true);
	assert.equal(view.poller, null);
	view.auto.checked = true;
	view.auto.attrs.change();
	assert.equal(polls.length, 3);
	const nodes = descendants(root);
	assert.ok(nodes.some(n => n.tag == '#text' && n.text.includes('NEW') && n.text.includes(malicious)));
	const pre = nodes.find(n => n.tag == 'pre');
	assert.equal(pre.childNodes[0].tag, '#text');
	assert.equal(pre.childNodes[0].text, malicious);
	assert.ok(!nodes.some(n => n.tag == 'img'));
	view.stopPolling();
});

function text(node) {
	return descendants(node).filter(n => n.tag == '#text').map(n => n.text).join('');
}
function load_view() {
	const calls = [], polls = [], timers = [], loads = [], writes = [];
	globalThis.E = element;
	const page = loadModule(viewFile, {
		view: { extend: o => o },
		uci: { load: name => { loads.push(name); return Promise.resolve('uci-loaded'); }, get: () => 'debug' },
		dom: { content: (node, children) => { writes.push(node); setContent(node, children); } },
		'aether-proxy.model.logs': model,
		'aether-proxy.common': {
			call: (method, params) => {
				let resolve;
				const promise = new Promise(done => { resolve = done; });
				calls.push({ method, params, resolve });
				return promise;
			},
			poll: (fn, interval) => {
				const poll = { fn, interval, stopped: false, stop() { this.stopped = true; } };
				polls.push(poll);
				return poll;
			}
		}
	}, { window: { setTimeout: (fn, delay) => timers.push({ fn, delay }) }, document: {} });
	return { page, calls, polls, timers, loads, writes,
		start: () => {
			assert.equal(timers.length, 1);
			assert.equal(timers[0].delay, 0);
			timers.shift().fn();
		}
	};
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('T10.16 logs scenario 1: load only loads UCI and never calls ap.call', async () => {
	const h = load_view();
	assert.equal(await h.page.load(), 'uci-loaded');
	assert.deepEqual(h.loads, [ 'aetherproxy' ]);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.timers, []);
	assert.deepEqual(h.polls, []);
});

test('T10.16 logs scenario 2: model owns pending text and enables filters after success or failure', () => {
	const pending = model.events();
	assert.equal(pending.loading, '读取中…');
	assert.equal(pending.filters_disabled, true);
	assert.equal(pending.error, null);
	assert.deepEqual(pending.rows, []);
	for (const reply of [ payload([]), { ok: false, code: 'TIMEOUT' } ]) {
		const vm = model.events(reply);
		assert.equal(vm.loading, null);
		assert.equal(vm.filters_disabled, false);
		assert.equal(vm.error, reply.ok ? null : 'TIMEOUT');
	}
});

test('T10.16 logs scenario 3: pending RPC leaves the complete page usable with only filters disabled', async () => {
	const h = load_view(), v = h.page;
	const root = v.render(await v.load());
	assert.equal(root.tag, 'div');
	assert.equal(root.attrs.class, 'cbi-map');
	assert.deepEqual(root.children.slice(0, 3).map(text), [ '日志', '事件', '原始日志' ]);
	assert.equal(root.children[3], v.eventPanel);
	assert.equal(root.children[4], v.rawPanel);
	assert.equal(v.eventPanel.hidden, false);
	assert.equal(v.rawPanel.hidden, true);
	assert.equal(text(v.eventContent), '读取中…');
	assert.equal(v.level.disabled, true);
	assert.equal(v.code.disabled, true);
	assert.deepEqual(v.level.children.map(n => n.value), [ '', 'error', 'warn', 'notice' ]);
	assert.equal(text(v.code), '全部');
	assert.equal(v.auto.checked, true);
	assert.equal(v.auto.disabled, false);
	assert.equal(v.source.disabled, false);
	assert.equal(v.lines.disabled, false);
	assert.deepEqual(v.source.children.map(n => n.value), model.sources().map(s => s[0]));
	assert.deepEqual(v.lines.children.map(n => Number(n.value)), model.line_counts());
	assert.equal(v.lines.value, '200');
	assert.equal(text(v.rawPanel.children[2]), '刷新');
	assert.ok(descendants(root).filter(n => n.tag == 'button').every(n => !n.disabled));
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.polls, []);
	h.start();
	await settle(); // The events promise intentionally never settles.
	assert.deepEqual(h.calls.map(c => [ c.method, c.params ]), [ [ 'events', {} ] ]);
	assert.equal(h.polls[0].interval, 5000);
	assert.equal(text(v.eventContent), '读取中…');
	assert.equal(v.level.disabled, true);
	assert.equal(v.code.disabled, true);
	v.stopPolling();
});

test('T10.16 logs scenario 4: success replaces only event data and preserves controls and edits', async () => {
	const h = load_view(), v = h.page;
	const root = v.render(await v.load());
	const nodes = descendants(root).filter(n => n.tag != '#text' && n.tag != 'option');
	h.start();
	v.auto.checked = false;
	v.auto.attrs.change();
	v.source.value = 'dns';
	v.lines.value = '1000';
	h.writes.length = 0;
	const data = { ...payload([ event('DNS_RECOVERED'), event('XRAY_DOWN', 'error') ]), skipped: 2 };
	h.calls[0].resolve(data);
	await settle();
	assert.deepEqual(h.writes, [ v.code, v.eventContent ]);
	assert.ok(nodes.every(n => descendants(root).includes(n)), 'existing panels and controls must stay mounted');
	assert.equal(v.level.disabled, false);
	assert.equal(v.code.disabled, false);
	assert.equal(v.auto.checked, false);
	assert.equal(v.poller, null);
	assert.equal(v.source.value, 'dns');
	assert.equal(v.lines.value, '1000');
	assert.equal(text(v.rawContent), '');
	assert.equal(text(v.eventContent).includes('读取中…'), false);
	assert.ok(text(v.eventContent).includes('有 2 行记录损坏，已跳过'));
	assert.deepEqual(v.code.children.map(n => n.value), [ '', 'DNS_RECOVERED', 'XRAY_DOWN' ]);
	assert.deepEqual(descendants(v.eventContent).filter(n => n.tag == 'tr').slice(1)
		.map(row => text(row.children[2])), [ 'XRAY_DOWN', 'DNS_RECOVERED' ]);
	v.level.value = 'error';
	v.code.value = 'XRAY_DOWN';
	v.code.attrs.change();
	assert.equal(h.calls.length, 1, 'filter changes must not fetch again');
	assert.equal(v.level.value, 'error');
	assert.equal(v.code.value, 'XRAY_DOWN');
	assert.equal(text(v.eventContent).includes('DNS_RECOVERED'), false);
});

test('T10.16 logs scenario 5: failures clear placeholders, restore filters and allow poll recovery', async () => {
	for (const code of [ 'TIMEOUT', 'RPC_FAILED' ]) {
		const h = load_view(), v = h.page;
		const root = v.render(await v.load());
		h.start();
		h.calls[0].resolve({ ok: false, code, detail: 'offline' });
		await settle();
		assert.ok(text(v.eventContent).includes(code + ': offline'));
		assert.equal(text(root).includes('读取中…'), false);
		assert.equal(v.level.disabled, false);
		assert.equal(v.code.disabled, false);
		assert.equal(h.polls[0].stopped, false);
		const refresh = h.polls[0].fn();
		h.calls[1].resolve(payload([ event('DNS_RECOVERED') ]));
		await refresh;
		assert.ok(text(v.eventContent).includes('DNS_RECOVERED'));
		assert.equal(text(v.eventContent).includes('offline'), false);
		v.code.value = 'DNS_RECOVERED';
		const failed_refresh = h.polls[0].fn();
		h.calls[2].resolve({ ok: false, code, detail: 'again' });
		await failed_refresh;
		assert.ok(text(v.eventContent).includes(code + ': again'));
		assert.ok(text(v.eventContent).includes('DNS_RECOVERED'), 'failed refresh keeps the last successful list');
		assert.equal(v.code.value, 'DNS_RECOVERED');
		assert.equal(v.level.disabled, false);
		assert.equal(v.code.disabled, false);
		v.stopPolling();
	}
});

test('T10.16 logs scenario 6: tab switches during the initial read preserve raw data and polling', async () => {
	const h = load_view(), v = h.page;
	v.render(await v.load());
	h.start();
	const raw = v.switchTab('raw');
	assert.equal(h.polls[0].stopped, true);
	h.calls[1].resolve({ ok: true, lines: [ { text: 'raw content' } ] });
	await raw;
	const raw_nodes = [ ...v.rawContent.children ];
	h.calls[0].resolve(payload([ event('DNS_RECOVERED') ]));
	await settle();
	assert.equal(v.tab, 'raw');
	assert.equal(v.eventPanel.hidden, true);
	assert.equal(v.rawPanel.hidden, false);
	assert.deepEqual(v.rawContent.children, raw_nodes);
	assert.ok(text(v.rawContent).includes('raw content'));
	assert.equal(h.polls.length, 1, 'an events reply must not restart polling on the raw tab');
	const back = v.switchTab('events');
	assert.equal(h.polls.length, 2);
	assert.equal(h.polls[1].interval, 5000);
	h.calls[2].resolve(payload([]));
	await back;
	assert.equal(v.eventPanel.hidden, false);
	assert.equal(v.rawPanel.hidden, true);
	assert.equal(text(v.eventContent).includes('读取中…'), false);
	v.stopPolling();
});

test('T10.16 logs: late initial replies cannot overwrite newer tab or poll results and filters', async () => {
	for (const trigger of ['tab', 'poll']) {
		for (const stale of [payload([event('DNS_RECOVERED')]), { ok: false, code: 'TIMEOUT' }]) {
			const h = load_view(), v = h.page;
			v.render(await v.load());
			h.start();
			const pending = trigger == 'tab' ? v.switchTab('events') : h.polls[0].fn();
			assert.equal(h.calls.length, 2);
			h.calls[1].resolve(payload([event('XRAY_DOWN', 'error')]));
			await pending;
			v.level.value = 'error';
			v.code.value = 'XRAY_DOWN';
			v.code.attrs.change();
			h.calls[0].resolve(stale);
			await settle();
			assert.ok(text(v.eventContent).includes('XRAY_DOWN'));
			assert.equal(text(v.eventContent).includes('DNS_RECOVERED'), false);
			assert.equal(text(v.eventContent).includes('TIMEOUT'), false);
			assert.equal(v.level.value, 'error');
			assert.equal(v.code.value, 'XRAY_DOWN');
			assert.equal(v.level.disabled, false);
			assert.equal(v.code.disabled, false);
			v.stopPolling();
		}
	}
});

test('T8.10 scenario 7: common RPC/poll wiring, no unsafe APIs, and complete translations', () => {
	const source = fs.readFileSync(viewFile, 'utf8');
	assert.match(source, /ap\.call\('events',/);
	assert.match(source, /ap\.call\('log',/);
	assert.match(source, /ap\.poll\(/);
	assert.doesNotMatch(source, /rpc\.declare|innerHTML|cbi-button-reset|setInterval/);
	for (const file of [ viewFile, modelFile ]) {
		const text = fs.readFileSync(file, 'utf8');
		for (const match of text.matchAll(/_\('([^']*)', 'aether-proxy'\)/g))
			assert.ok(po[match[1]], 'missing translation: ' + match[1]);
	}
});
