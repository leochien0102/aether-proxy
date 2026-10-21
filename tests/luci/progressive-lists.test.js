'use strict';

/* T10.16: exercise the real node/subscription grids with pending RPC replies.
 * Form and DOM doubles keep cell identity observable: a full redraw would lose
 * user input and an open modal even if the final text happened to be correct. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
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
function formDouble(uci, maps, uciCalls, builtins, builtinKinds) {
	return { Map: class {
		constructor() { this.sections = []; maps.push(this); }
		section(kind, type) {
			const section = {
				type, options: [], modal: { value: 'unsaved modal input' },
				option(kind, field, title) {
					const option = { field, title, value() {}, depends() {} };
					this.options.push(option);
					return option;
				},
				super(method, args) {
					if (method === 'handleRemove') {
						uciCalls.push(['remove', ...args]);
						return;
					}
					assert.equal(method, 'renderRowActions');
					const original = builtinKinds.map(kind => {
						const button = E('button', {
							'class': 'btn cbi-button cbi-button-' + kind,
							'click': event => kind === 'remove'
								? section.handleRemove(args[0], event)
								: section.addModalOptions(section.modal, args[0])
						}, kind === 'remove' ? '删除' : '编辑');
						button.classList = { contains: name => button.class.split(/\s+/).includes(name) };
						button.style = { cssText: 'min-width:0;' };
						return button;
					});
					builtins.push({ id: args[0], buttons: original });
					// LuCI puts its buttons inside the last child of the action td.
					return E('td', {}, [E('div', {}, original)]);
				}
			};
			this.sections.push(section);
			return section;
		}
		async render() {
			this.node = E('form', {}, this.sections.flatMap(section => [
				// LuCI's named header exposes the section ID via data-title/CSS.
				E('tr', { 'data-title': section.anonymous ? null : '名称' },
					section.options.filter(o => o.textvalue).map(o => E('th', {}, o.title))),
				...uci.sections('aetherproxy', section.type).map(s => E('div', { sid: s['.name'] }, [
					...section.options.filter(o => o.textvalue).map(o =>
						E('td', { field: o.field }, o.textvalue(s['.name']))),
					section.renderRowActions(s['.name'])
				]))
			]));
			return this.node;
		}
	} };
}
async function harness(name, builtinKinds = name === 'nodes' ? ['remove'] : ['edit', 'remove']) {
	const calls = [], reads = [], turns = [], maps = [], uciCalls = [], builtins = [];
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
		sections: (config, type) => type === 'node' ? nodes : type === 'subscription' ? subs : [...nodes, ...subs],
		set: (...args) => uciCalls.push(['set', ...args]),
		save: async () => { uciCalls.push(['save']); }
	};
	const form = formDouble(uci, maps, uciCalls, builtins, builtinKinds);
	const ap = {
		call: (method, params) => {
			calls.push([method, params]);
			const read = deferred();
			reads.push(read);
			return read.promise;
		},
		job_progress: () => ({ stop() {} }),
		run_job: async () => ({ result: { subs: {} } }),
		confirm: async () => true
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
	return { name, page, maps, calls, reads, turns, uciCalls, builtins, ap, nodes };
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
			/* nodes: each cell says 读取失败, the reason appears once in the progress line */
			if (name === 'nodes') {
				assert.ok(cells.every(cell => /读取失败/.test(text(cell))));
				assert.match(text(h.page.progressEl), reply ? /^读取检测结果失败：TIMEOUT: read failed$/ : /^读取检测结果失败：RPC_FAILED$/);
				assert.ok(cells.every(cell => !/TIMEOUT|RPC_FAILED/.test(text(cell))));
			}
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
	assert.match(text(resultCells(h)[0]), /读取失败/);
	assert.match(text(h.page.progressEl), /^读取检测结果失败：TIMEOUT: rebuild failed$/);
	h.reads[0].resolve(success('nodes'));
	await flush();
	/* the older initial reply is still discarded */
	assert.match(text(resultCells(h)[0]), /读取失败/);
	assert.match(text(h.page.progressEl), /^读取检测结果失败：TIMEOUT: rebuild failed$/);
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

function gridRow(h, id) {
	return find(h.root, node => node.sid === id)[0];
}
function actions(h, id) {
	return gridRow(h, id).lastChild.lastChild;
}
for (const kinds of [['remove'], ['edit', 'remove'], ['remove', 'edit']]) {
	test(`T10.19 scenarios 1/2/5: ${kinds.join('+')} actions keep built-ins except current deletion`, async () => {
		const h = await harness('nodes', kinds);
		await render(h);
		for (const id of ['n_a', 'n_b']) {
			const container = actions(h, id);
			const expected = id === 'n_a' ? ['检测'] : ['设为当前', '检测'];
			expected.push(...kinds.filter(kind => id !== 'n_a' || kind !== 'remove')
				.map(kind => kind === 'remove' ? '删除' : '编辑'));
			assert.deepEqual(buttons(container).map(text), expected);
			assert.equal(container.childNodes.length, expected.length);
			assert.ok(container.childNodes.every(node => node && node.tag === 'button'),
				'no undefined or empty text nodes in actions');
			const original = h.builtins.find(row => row.id === id).buttons;
			for (const button of original) {
				const removed = id === 'n_a' && button.classList.contains('cbi-button-remove');
				assert.equal(container.children.includes(button), !removed, 'preserve original button identity');
				if (!removed)
					assert.ok(button.style.includes('min-width:0;'), 'preserve built-in inline styles');
			}
			for (const button of buttons(container))
				assert.ok(button.style.includes('white-space:nowrap'), 'button text stays on one line');
			for (const style of ['display:flex', 'flex-wrap:nowrap', 'gap:0.25em', 'align-items:center'])
				assert.ok(container.style.includes(style), style);
		}
	});
}
for (const all of [false, true]) {
	test(`T10.19 scenario 3: ${all ? 'all' : 'one'} probe shows pending before any job reply`, async () => {
		const h = await harness('nodes');
		await render(h);
		h.reads[0].resolve(success('nodes'));
		await flush();
		const job = deferred();
		let update;
		h.ap.run_job = (kind, ids, onUpdate) => {
			assert.equal(kind, 'probe_nodes');
			assert.deepEqual(ids, all ? [] : ['n_b']);
			update = onUpdate;
			return job.promise;
		};
		const cells = resultCells(h);
		const before = cells.map(text);
		const button = all ? buttons(h.root).find(node => text(node) === '检测全部')
			: buttons(actions(h, 'n_b')).find(node => text(node) === '检测');
		const pending = button.click({ currentTarget: button });
		assert.equal(h.reads.length, 1, 'no result poll needed for immediate feedback');
		assert.equal(text(cells[1]), '检测中…');
		assert.equal(text(cells[0]), all ? '检测中…' : before[0], 'unselected row stays unchanged');
		assert.ok(h.page.probeButtons.every(node => node.disabled));
		const option = h.maps[0].sections[0].options.find(o => o.field === '_probe');
		const rerendered = option.textvalue('n_b');
		assert.equal(text(rerendered), '检测中…', 'modal rerender keeps local pending feedback');
		update();
		await flush();
		h.reads[1].resolve({ ok: true, finished: false, nodes: {}, pending: ['n_b'], done: 0, total: 1 });
		await flush();
		assert.equal(text(rerendered), '检测中…', 'backend pending takes over');
		assert.equal(text(h.page.probeCells.n_a), '未检测', 'backend clears local-only pending IDs');
		job.resolve({ state: 'ok' });
		await flush();
		h.reads[2].resolve(success('nodes'));
		await pending;
		assert.equal(text(rerendered), '拒绝连接');
		assert.equal(text(h.page.probeCells.n_a), '42 ms（3/3）');
		assert.ok(h.page.probeButtons.every(node => !node.disabled));
		assert.equal(h.page.probing, false);
	});
}
test('T10.19 scenario 3: late initial read cannot erase immediate probe feedback', async () => {
	const h = await harness('nodes');
	await render(h);
	const job = deferred();
	h.ap.run_job = () => job.promise;
	const pending = h.page.handleProbeOne('n_b', {});
	assert.equal(text(h.page.probeCells.n_a), '读取中…');
	assert.equal(text(h.page.probeCells.n_b), '检测中…');
	h.reads[0].resolve(success('nodes'));
	await flush();
	assert.equal(text(h.page.probeCells.n_b), '检测中…');
	job.resolve({ state: 'ok' });
	await flush();
	h.reads[1].resolve(success('nodes'));
	await pending;
	assert.equal(text(h.page.probeCells.n_b), '拒绝连接');
});
test('T10.19 scenario 3: rejected job clears local pending and restores buttons', async () => {
	const h = await harness('nodes');
	await render(h);
	h.reads[0].resolve(success('nodes'));
	await flush();
	h.ap.run_job = () => Promise.reject(new Error('job failed'));
	await h.page.handleProbeOne('n_b', {});
	assert.equal(text(h.page.probeCells.n_b), '拒绝连接');
	assert.equal(h.page.probing, false);
	assert.ok(h.page.probeButtons.every(node => !node.disabled));
});
test('T10.19 scenario 4: anonymous grid hides section names without changing edit, delete or import IDs', async () => {
	const h = await harness('nodes', ['edit', 'remove']);
	await render(h);
	const section = h.maps[0].sections[0];
	assert.equal(section.anonymous, true);
	const header = find(h.root, node => node.tag === 'tr')[0];
	assert.equal(header.attrs['data-title'], null);
	assert.equal(find(header, node => node.tag === 'th' && text(node) === '名称').length, 1);
	assert.doesNotMatch(text(h.root), /n_a|n_b/);
	assert.equal(find(section.renderSectionAdd(), node => node.tag === 'button').length, 0);
	const edit = buttons(actions(h, 'n_b')).find(node => text(node) === '编辑');
	edit.click();
	assert.equal(section.modal.description,
		po['This node comes from a subscription; edits will be overwritten at the next subscription update.']);
	assert.ok(section.options.some(option => option.field === 'label' && option.modalonly));
	let confirmations = 0;
	h.ap.confirm = async () => { confirmations++; return false; };
	const remove = buttons(actions(h, 'n_b')).find(node => text(node) === '删除');
	await remove.click({});
	assert.equal(h.uciCalls.some(call => call[0] === 'remove'), false);
	h.ap.confirm = async () => { confirmations++; return true; };
	const event = {};
	await remove.click(event);
	assert.deepEqual(h.uciCalls.find(call => call[0] === 'remove'), ['remove', 'n_b', event]);
	await section.handleRemove('n_a', event);
	assert.equal(confirmations, 2, 'current node blocked even if removal handler is invoked directly');
	assert.equal(h.uciCalls.filter(call => call[0] === 'remove').length, 1);
	h.page.importText.value = 'vless://new\n\nvless://duplicate';
	const importing = h.page.handleImport({});
	await flush();
	assert.deepEqual(h.calls[1], ['node_import', { uri: 'vless://new' }]);
	h.reads[1].resolve({ ok: true, node: 'n_new', duplicate: false });
	await flush();
	assert.deepEqual(h.calls[2], ['node_import', { uri: 'vless://duplicate' }]);
	h.reads[2].resolve({ ok: true, node: 'n_b', duplicate: true });
	await flush();
	assert.deepEqual(h.uciCalls.slice(-2), [['unload', 'aetherproxy'], ['load', 'aetherproxy']]);
	assert.equal(h.calls[3][0], 'probe_results');
	h.reads[3].resolve(success('nodes'));
	await importing;
	assert.equal(h.maps[1].sections[0].anonymous, true);
	assert.equal(text(h.page.probeCells.n_b), '拒绝连接');
});
