'use strict';

/* T8.10 contracts: catalog-driven templates, pure presentation, and real view
 * controller exercised with text-only DOM and request/poll doubles.
 */
process.env.TZ = 'UTC';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo } = require('./loader');
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
function element(tag, attrs = {}, children = []) {
	const node = { tag, attrs, value: '', checked: !!attrs.checked, children: [], hidden: !!attrs.hidden };
	if ('value' in attrs)
		node.value = attrs.value;
	setContent(node, children);
	return node;
}
function setContent(node, children) {
	const flat = (Array.isArray(children) ? children : [ children ]).flat(Infinity);
	node.children = flat.map(c => typeof c == 'string' ? { tag: '#text', text: c } : c);
	if (node.tag == 'select')
		node.value = node.children[0]?.value ?? '';
}
function descendants(node) {
	return [ node ].concat((node.children || []).flatMap(descendants));
}

test('T8.10 scenario 6: default events poll, tab/checkbox stop, raw refresh and text-node safety', async () => {
	const calls = [], polls = [];
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
	}, { window: {}, document: {} });
	const root = view.render(await view.load());
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
	assert.equal(pre.children[0].tag, '#text');
	assert.equal(pre.children[0].text, malicious);
	assert.ok(!nodes.some(n => n.tag == 'img'));
	view.stopPolling();
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
