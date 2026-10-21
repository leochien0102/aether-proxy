'use strict';

/* T10.16: exercise the real node/subscription grids with pending RPC replies.
 * Form and DOM doubles keep cell identity observable: a full redraw would lose
 * user input and an open modal even if the final text happened to be correct. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = (text, context) => {
	assert.equal(context, 'aether-proxy');
	assert.ok(po[text], 'translation exists: ' + text);
	return po[text];
};
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
function text(node) {
	return node == null ? '' : typeof node === 'object' ? node.textContent : String(node);
}
function element(tag, attrs = {}, children = []) {
	if (Array.isArray(tag)) {
		children = tag;
		tag = 'fragment';
	}
	return {
		tag, ...attrs, children: Array.isArray(children) ? children : [children],
		get childNodes() { return this.children; },
		get lastChild() { return this.children.at(-1); },
		get textContent() { return this.children.map(text).join(''); },
		set textContent(value) { this.children = [String(value)]; },
		replaceChildren(...nodes) { this.children = nodes; }
	};
}
globalThis.E = element;
function find(root, predicate) {
	if (!root || typeof root !== 'object')
		return [];
	return (predicate(root) ? [root] : []).concat(root.children.flatMap(n => find(n, predicate)));
}
const buttons = root => find(root, node => node.tag === 'button');
const flush = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
	let resolve;
	const promise = new Promise(done => { resolve = done; });
	return { promise, resolve };
}
async function harness(name) {
	const calls = [], reads = [], turns = [], maps = [], uciCalls = [];
	const nodes = [
		{ '.name': 'n_a', label: 'Node A', address: '203.0.113.1', port: '443' },
		{ '.name': 'n_b', label: 'Node B', source: 's_a' }
	];
	const subs = [
		{ '.name': 's_a', name: 'Alpha', url: 'https://example.com/sub?token=SECRET' },
		{ '.name': 's_b', name: 'Beta', url: 'https://example.org/sub?token=SECRET' }
	];
	const uci = {
		load: async config => { uciCalls.push(['load', config]); },
		unload: async config => { uciCalls.push(['unload', config]); },
		get: () => 'n_a',
		sections: (config, type) => type === 'node' ? nodes : type === 'subscription' ? subs : [...nodes, ...subs]
	};
	const form = { Map: class {
		constructor() { this.sections = []; maps.push(this); }
		section(kind, type) {
			const section = {
				type, options: [], modal: { value: 'unsaved modal input' },
				option(kind, field) {
					const option = { field, value() {}, depends() {} };
					this.options.push(option);
					return option;
				},
				super: () => E('td', {}, [E('div', {}, [E('button', {}, 'edit'), E('button', {}, 'delete')])])
			};
			this.sections.push(section);
			return section;
		}
		async render() {
			this.node = E('form', {}, this.sections.flatMap(section =>
				uci.sections('aetherproxy', section.type).map(s => E('div', {}, [
					...section.options.filter(o => o.textvalue).map(o =>
						E('td', { field: o.field }, o.textvalue(s['.name']))),
					section.renderRowActions(s['.name'])
				]))));
			return this.node;
		}
	} };
	const ap = {
		call: (method, params) => {
			calls.push([method, params]);
			const read = deferred();
			reads.push(read);
			return read.promise;
		},
		job_progress: () => ({ stop() {} }),
		run_job: async () => ({ result: { subs: {} } })
	};
	const model = loadModule(path.join(RES, 'aether-proxy/model', name + '.js'),
		{ baseclass: { extend: o => o } }, {});
	const page = loadModule(path.join(RES, 'view/aether-proxy', name + '.js'), {
		view: { extend: o => o }, form, uci,
		ui: {
			createHandlerFn: (self, fn, ...args) => (...rest) =>
				(typeof fn === 'string' ? self[fn] : fn).apply(self, [...args, ...rest]),
			addNotification() {}
		},
		dom: { content: (target, content) => {
			target.replaceChildren(...(Array.isArray(content) ? content : [content]));
		} },
		'aether-proxy.common': ap, ['aether-proxy.model.' + name]: model
	}, { window: { setTimeout: (fn, delay) => { assert.equal(delay, 0); turns.push(fn); } } });
	return { name, page, maps, calls, reads, turns, uciCalls };
}
async function render(h) {
	await h.page.load();
	h.root = await h.page.render();
	assert.equal(h.maps.length, 1);
	assert.deepEqual(h.calls, [], 'the complete page returns before RPC starts');
	assert.equal(h.turns.length, 1);
	h.turns.shift()();
	await flush();
}
function resultCells(h) {
	return Object.values(h.name === 'nodes' ? h.page.probeCells : h.page.resultCells);
}
function success(name) {
	return name === 'nodes' ? { ok: true, finished: true, nodes: {
		n_a: { ok: 3, median_ms: 42 }, n_b: { ok: 0, error: 'refused' }
	} } : { ok: true, subs: {
		s_a: { nodes: 7, last_attempt: Date.now() / 1000, skipped: { malformed: 2 } },
		s_b: { error: 'SUB_FETCH_FAILED' }
	} };
}
for (const name of ['nodes', 'subscriptions']) {
	test(`T10.16 ${name} scenario 1: load reads only UCI`, async () => {
		const h = await harness(name);
		await h.page.load();
		assert.deepEqual(h.uciCalls, [['load', 'aetherproxy']]);
		assert.deepEqual(h.calls, []);
		assert.deepEqual(h.turns, []);
	});
	test(`T10.16 ${name} scenario 2: pending RPC leaves a complete usable grid with reading cells`, async () => {
		const h = await harness(name);
		await render(h);
		assert.deepEqual(h.calls, [[name === 'nodes' ? 'probe_results' : 'sub_status', undefined]]);
		assert.equal(resultCells(h).length, 2);
		assert.ok(resultCells(h).every(cell => text(cell) === '读取中…'));
		assert.match(text(h.root), name === 'nodes' ? /Node A.*Node B/ : /Alpha.*Beta/);
		assert.doesNotMatch(text(h.root), /SECRET/);
		const labels = name === 'nodes' ? ['检测全部', '检测', '导入', '设为当前'] : ['全部更新', '立即更新', '添加'];
		for (const label of labels) {
			const matches = buttons(h.root).filter(node => text(node) === label);
			assert.ok(matches.length > 0, label + ' exists');
			assert.ok(matches.every(node => !node.disabled), label + ' usable without prior results');
		}
		assert.equal(h.maps[0].sections[0].options.filter(o => o.modalonly).length > 0, true);
		if (name === 'nodes') {
			assert.ok(h.page.importText);
			assert.equal(text(h.page.progressEl), '', 'reading is not a running probe');
		}
	});
	test(`T10.16 ${name} scenario 3: success fills only result cells without replacing user controls`, async () => {
		const h = await harness(name);
		await render(h);
		const cells = resultCells(h), form = h.maps[0].node;
		const stable = find(form, node => node.tag === 'td' && !['_result', '_probe'].includes(node.field));
		const controls = buttons(h.root);
		if (name === 'nodes')
			h.page.importText.value = 'vless://unsaved';
		h.reads[0].resolve(success(name));
		await flush();
		assert.deepEqual(resultCells(h), cells);
		assert.equal(h.maps.length, 1, 'initial reply must not redraw the form');
		assert.equal(h.maps[0].node, form);
		assert.deepEqual(buttons(h.root), controls);
		assert.ok(stable.every(node => find(h.root, n => n === node).length === 1));
		assert.equal(h.maps[0].sections[0].modal.value, 'unsaved modal input');
		assert.doesNotMatch(text(h.root), /读取中…/);
		const expected = name === 'nodes' ? /42 ms（3\/3）/ : /成功，7 个节点.*跳过 2 个：格式错误 2/;
		assert.match(text(cells[0]), expected);
		assert.equal(text(cells[1]).includes(name === 'nodes' ? '拒绝连接' : '下载失败'), true);
		assert.ok(buttons(h.root).every(node => !node.disabled));
		if (name === 'nodes')
			assert.equal(h.page.importText.value, 'vless://unsaved');
	});
	test(`T10.16 ${name}: later GridSection render uses settled results, not captured placeholders`, async () => {
		const h = await harness(name);
		await render(h);
		h.reads[0].resolve(success(name));
		await flush();
		const field = name === 'nodes' ? '_probe' : '_result';
		const option = h.maps[0].sections[0].options.find(o => o.field === field);
		const cell = option.textvalue(name === 'nodes' ? 'n_a' : 's_a');
		assert.match(text(cell), name === 'nodes' ? /42 ms/ : /成功，7 个节点/);
		assert.doesNotMatch(text(cell), /读取中…/);
		assert.equal(resultCells(h)[0], cell, 'future replies must target the new cell');
		if (name === 'nodes') {
			const pending = h.page.refreshResults();
			h.reads[1].resolve({ ok: true, finished: true, nodes: { n_a: { ok: 3, median_ms: 84 } } });
			await pending;
			assert.match(text(cell), /84 ms/);
		}
		else {
			h.page.status = { ok: true, subs: { s_a: { nodes: 9 } } };
			h.page.show_results();
			assert.match(text(cell), /成功，9 个节点/);
		}
	});
	for (const reply of [{ ok: false, code: 'TIMEOUT', detail: 'read failed' }, null]) {
		const state = reply ? 'failed' : 'null';
		test(`T10.16 ${name} scenario 3: ${state} reply clears reading and shows RPC error`, async () => {
			const h = await harness(name);
			await render(h);
			const cells = resultCells(h), controls = buttons(h.root);
			h.reads[0].resolve(reply);
			await flush();
			assert.equal(h.maps.length, 1);
			assert.deepEqual(resultCells(h), cells);
			assert.deepEqual(buttons(h.root), controls);
			assert.doesNotMatch(text(h.root), /读取中…/);
			assert.match(text(h.root), reply ? /TIMEOUT: read failed/ : /RPC_FAILED/);
			assert.ok(controls.every(node => !node.disabled));
			if (name === 'nodes')
				assert.equal(text(h.page.progressEl), '');
		});
	}
}
for (const kind of ['refreshResults', 'rebuild']) {
	test(`T10.16 nodes: late initial reply cannot overwrite newer ${kind} results`, async () => {
		const h = await harness('nodes');
		await render(h);
		const pending = h.page[kind]();
		await flush();
		h.reads[1].resolve(success('nodes'));
		await pending;
		h.reads[0].resolve({ ok: true, finished: false, nodes: {}, done: 0, total: 2 });
		await flush();
		assert.match(text(resultCells(h)[0]), /42 ms/);
		assert.equal(text(h.page.progressEl), '');
	});
}
test('T10.16 nodes: failed import rebuild settles pending cells and discards the older initial reply', async () => {
	const h = await harness('nodes');
	await render(h);
	const pending = h.page.rebuild();
	await flush();
	h.reads[1].resolve({ ok: false, code: 'TIMEOUT', detail: 'rebuild failed' });
	await pending;
	assert.doesNotMatch(text(h.root), /读取中…/);
	assert.match(text(resultCells(h)[0]), /TIMEOUT: rebuild failed/);
	h.reads[0].resolve(success('nodes'));
	await flush();
	assert.match(text(resultCells(h)[0]), /TIMEOUT: rebuild failed/);
	assert.equal(text(h.page.progressEl), '');
});
test('T10.16 nodes: failed later refresh preserves successful results', async () => {
	const h = await harness('nodes');
	await render(h);
	h.reads[0].resolve(success('nodes'));
	await flush();
	const pending = h.page.refreshResults();
	h.reads[1].resolve({ ok: false, code: 'TIMEOUT' });
	await pending;
	assert.match(text(resultCells(h)[0]), /42 ms/);
	assert.equal(text(h.page.progressEl), '');
});
test('T10.16 subscriptions: late initial status cannot overwrite a completed update', async () => {
	const h = await harness('subscriptions');
	await render(h);
	const pending = h.page.update([]);
	await flush();
	assert.equal(h.reads.length, 2);
	h.reads[1].resolve(success('subscriptions'));
	await pending;
	h.reads[0].resolve({ ok: true, subs: {} });
	await flush();
	assert.match(text(resultCells(h)[0]), /成功，7 个节点/);
	assert.equal(h.page.busy, false);
	assert.ok(buttons(h.root).every(node => !node.disabled));
});
