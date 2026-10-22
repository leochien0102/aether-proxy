'use strict';

/* T10.16: exercise the real node/subscription grids with pending RPC replies.
 * Form and DOM doubles keep cell identity observable: a full redraw would lose
 * user input and an open modal even if the final text happened to be correct. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
const { actionRow, beforeTable } = require('./button-layout');
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
				renderMoreOptionsModal(id) {
					this.modal = { id, value: 'unsaved modal input' };
					this.addModalOptions(this.modal, id);
					this.modal.node = E('div', {}, [
						E('p', {}, this.modal.description ?? ''),
						...this.options.filter(o => o.modalonly).map(o => E('label', {}, o.title))
					]);
				},
				super(method, args) {
					if (method === 'handleRemove') {
						uciCalls.push(['remove', ...args]);
						return;
					}
					assert.equal(method, 'renderRowActions');
					// TableSection only generates Edit when more_label is supplied.
					const kinds = builtinKinds.filter(kind => kind !== 'edit' || args[1]);
					if (args[1] && !kinds.includes('edit'))
						kinds.unshift('edit');
					const original = kinds.map(kind => {
						const button = E('button', {
							'class': 'btn cbi-button cbi-button-' + kind,
							'click': event => kind === 'remove'
								? section.handleRemove(args[0], event)
								: section.renderMoreOptionsModal(args[0])
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
		async save(...args) {
			uciCalls.push(['map.save', ...args]);
			return this.render();
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
	const statusCalls = [], statusReads = [], timers = new Map();
	let now = 0, timerID = 0, current = 'n_a';
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
		get: () => current,
		sections: (config, type) => type === 'node' ? nodes : type === 'subscription' ? subs : [...nodes, ...subs],
		remove: (config, id) => {
			uciCalls.push(['uci.remove', config, id]);
			const index = nodes.findIndex(node => node['.name'] === id);
			if (index >= 0)
				nodes.splice(index, 1);
		},
		set: (...args) => uciCalls.push(['set', ...args]),
		save: async () => { uciCalls.push(['save']); }
	};
	const form = formDouble(uci, maps, uciCalls, builtins, builtinKinds);
	const ap = {
		call: (method, params) => {
			const read = deferred();
			if (method === 'status') {
				statusCalls.push([method, params]);
				statusReads.push(read);
			}
			else {
				calls.push([method, params]);
				reads.push(read);
			}
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
			/* Same contract as luci-base ui.js: bound arguments first, the event
			   last; the button is disabled until fn settles and nothing is returned. */
			createHandlerFn: (self, fn, ...args) => (...rest) => {
				const target = [...args, ...rest][args.length]?.currentTarget;
				if (target)
					target.disabled = true;
				Promise.resolve((typeof fn === 'string' ? self[fn] : fn).apply(self, [...args, ...rest]))
					.finally(() => { if (target) target.disabled = false; });
			},
			changes: { apply: () => assert.fail('must not apply staged UCI changes') },
			addNotification(...args) { uciCalls.push(['notify', ...args]); }
		},
		dom: { content: (target, content) => {
			target.replaceChildren(...(Array.isArray(content) ? content : [content]));
		} },
		'aether-proxy.common': ap, ['aether-proxy.model.' + name]: model
	}, { window: {
		setTimeout: (fn, delay) => {
			if (delay === 0) {
				turns.push(fn);
				return;
			}
			const id = ++timerID;
			timers.set(id, { fn, at: now + delay });
			return id;
		},
		clearTimeout: id => timers.delete(id)
	} });
	async function tick(ms) {
		const end = now + ms;
		while (true) {
			const next = [...timers].filter(([, timer]) => timer.at <= end)
				.sort((a, b) => a[1].at - b[1].at)[0];
			if (!next)
				break;
			now = next[1].at;
			timers.delete(next[0]);
			next[1].fn();
			await flush();
		}
		now = end;
	}
	return { name, page, maps, calls, reads, turns, uciCalls, builtins, ap, nodes,
		statusCalls, statusReads, timers, tick, setCurrent: id => { current = id; } };
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
		assert.ok(buttons(h.root).filter(node => text(node) !== '删除所选').every(node => !node.disabled));
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
			assert.ok(controls.filter(node => text(node) !== '删除所选').every(node => !node.disabled));
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
	assert.ok(buttons(h.root).filter(node => text(node) !== '删除所选').every(node => !node.disabled));
});

test('T10.27 scenarios 1/2: node actions share progress before the table; Import has its own bottom row', async () => {
	const h = await harness('nodes');
	await render(h);
	const row = actionRow(h.root, ['检测全部', '删除所选', '添加节点'], [h.page.progressEl]);
	beforeTable(h.root, row, h.maps[0].node);
	const parent = find(h.root, node => node.children.includes(row))[0];
	assert.equal(parent.children[parent.children.indexOf(row) + 1], h.maps[0].node,
		'no import block separates the table toolbar from its table');
	const importRow = actionRow(h.root, ['导入']);
	const importBox = find(h.root, node => node.children.includes(h.page.importText))[0];
	assert.equal(importBox.children.at(-1), importRow);
	assert.equal(importBox.children.at(-2), h.page.importText);
});

test('T10.27 scenarios 1/2: subscription Update all and Add share text-first row above the table after redraw',
async () => {
	const h = await harness('subscriptions');
	await render(h);
	for (const busy of [false, true, false]) {
		h.page.busy = busy;
		await h.page.redraw();
		h.page.summary.textContent = 'update result';
		h.page.progress.textContent = 'elapsed';
		const row = actionRow(h.root, ['全部更新', '添加'],
			[h.page.statusError, h.page.progress, h.page.summary]);
		beforeTable(h.root, row, h.maps.at(-1).node);
		assert.deepEqual(h.root.children, [row, h.maps.at(-1).node]);
	}
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
			const expected = id === 'n_a' ? ['检测', '编辑'] : ['设为当前', '检测', '编辑', '删除'];
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
		button.click({ currentTarget: button });
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
		await flush();
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

/* T10.25: real view/grid tests with independent status RPCs and virtual time. */
test('T10.25 scenario 1: idle progress is hidden and empty; running progress shows done/total', async () => {
	const h = await harness('nodes');
	await render(h);
	assert.equal(h.page.progressEl.hidden, true);
	assert.deepEqual(h.page.progressEl.children, [], 'never pass null as a DOM child');
	assert.doesNotMatch(text(h.root), /null/);
	h.reads[0].resolve({ ok: true, finished: false, done: 1, total: 2, nodes: {} });
	await flush();
	assert.equal(h.page.progressEl.hidden, false);
	assert.equal(text(h.page.progressEl), '检测中 1/2');
	const pending = h.page.refreshResults();
	h.reads[1].resolve(success('nodes'));
	await pending;
	assert.equal(h.page.progressEl.hidden, true);
	assert.deepEqual(h.page.progressEl.children, []);
});

test('T10.25 scenarios 2/3: no address column; Edit opens the correct modal with subscription hint first', async () => {
	const h = await harness('nodes');
	await render(h);
	const section = h.maps[0].sections[0];
	const headers = find(h.root, node => node.tag === 'th').map(text);
	assert.deepEqual(headers, ['', '名称', '协议', '传输 / 安全层', '来源', '选用', 'TCP 可达／延迟']);
	assert.ok(!section.options.some(option => option.field === '_address'));
	for (const id of ['n_a', 'n_b']) {
		const edit = buttons(actions(h, id)).find(node => text(node) === '编辑');
		assert.ok(edit, 'Edit must be generated even when the parent initially only supplied Remove');
		await edit.click({ currentTarget: edit });
		assert.equal(section.modal.id, id);
		const modal = section.modal.node;
		assert.equal(text(modal.children[0]), id === 'n_a' ? ''
			: '此节点来自订阅，下次更新订阅时修改会被覆盖');
		for (const field of ['address', 'port'])
			assert.ok(section.options.some(option => option.field === field && option.modalonly));
		assert.match(text(modal), /地址端口/);
	}
	await buttons(actions(h, 'n_a')).find(node => text(node) === '编辑').click({});
	assert.equal(text(section.modal.node.children[0]), '', 'manual modal must not inherit the previous hint');
});

test('T10.25 scenario 4: only current row has a titled green check; stale name is faded', async () => {
	const h = await harness('nodes');
	h.nodes[1].stale = '1';
	await render(h);
	const cell = (id, field) => find(gridRow(h, id), node => node.field === field)[0];
	const mark = cell('n_a', '_current');
	assert.equal(text(mark), '✔');
	assert.equal(mark.children[0].title, '当前节点');
	assert.equal(mark.children[0].style, 'color:var(--success-color-high, #2f855a)');
	assert.equal(text(cell('n_b', '_current')), '');
	assert.equal(text(cell('n_b', '_label')), 'Node B（已失效）');
	assert.equal(cell('n_b', '_label').children[0].style, 'opacity:0.6');
	assert.equal(cell('n_a', '_label').children[0].style, null);
});

function selectAll(h) {
	h.page.selectAll.checked = true;
	h.page.selectAll.change({ currentTarget: h.page.selectAll });
}
for (const confirmed of [false, true]) {
	const outcome = confirmed ? 'confirm stages both removals without apply' : 'cancel removes nothing';
	test(`T10.25 scenario 5: select two then ${outcome}`, async () => {
		const h = await harness('nodes');
		h.nodes.push({ '.name': 'n_c', label: 'Node C', source: 'manual' });
		await render(h);
		assert.equal(h.page.deleteSelected.disabled, true);
		assert.equal(h.page.selectionBoxes.n_a.disabled, true);
		assert.equal(h.page.selectionBoxes.n_a.title, '当前节点不能删除。');
		const header = find(h.root, node => node.tag === 'th')[0];
		assert.equal(header.children[0], h.page.selectAll, 'select all is the first table column');
		assert.equal(gridRow(h, 'n_a').children[0].field, '_select');
		selectAll(h);
		assert.deepEqual([...h.page.selectedNodes], ['n_b', 'n_c']);
		assert.equal(h.page.selectionBoxes.n_a.checked, false);
		assert.equal(h.page.selectionBoxes.n_b.checked, true);
		assert.equal(h.page.selectionBoxes.n_c.checked, true);
		assert.equal(h.page.deleteSelected.disabled, false);
		let confirmations = 0;
		h.ap.confirm = async options => {
			confirmations++;
			assert.deepEqual(options, {
				title: '删除节点', text: '确定删除选中的 2 个节点？删除后需要「保存并应用」才生效。',
				ok: '删除', destructive: true
			});
			return confirmed;
		};
		await h.page.deleteSelected.click({ currentTarget: h.page.deleteSelected });
		assert.equal(confirmations, 1);
		assert.deepEqual(h.uciCalls.filter(call => call[0] === 'uci.remove'), confirmed
			? [['uci.remove', 'aetherproxy', 'n_b'], ['uci.remove', 'aetherproxy', 'n_c']] : []);
		assert.deepEqual(h.uciCalls.filter(call => call[0] === 'map.save'), confirmed
			? [['map.save', null, true]] : []);
		assert.equal(h.page.deleteSelected.disabled, confirmed);
		assert.equal(h.page.deleting, false);
		assert.ok(!h.uciCalls.some(call => ['set', 'save'].includes(call[0])), 'no unrelated session writes');
	});
}

test('T10.25 scenario 5: row toggles update select-all; confirmation protects a newly current node', async () => {
	const h = await harness('nodes');
	h.nodes.push({ '.name': 'n_c', label: 'Node C' });
	await render(h);
	const box = h.page.selectionBoxes.n_b;
	box.checked = true;
	box.change({ currentTarget: box });
	assert.equal(h.page.deleteSelected.disabled, false);
	assert.equal(h.page.selectAll.checked, false);
	assert.equal(h.page.selectAll.indeterminate, true);
	box.checked = false;
	box.change({ currentTarget: box });
	assert.equal(h.page.deleteSelected.disabled, true);
	assert.equal(h.page.selectAll.indeterminate, false);
	selectAll(h);
	h.ap.confirm = async () => { h.setCurrent('n_b'); return true; };
	await h.page.handleDeleteSelected();
	assert.deepEqual(h.uciCalls.filter(call => call[0] === 'uci.remove'), [['uci.remove', 'aetherproxy', 'n_c']]);
	assert.equal(h.page.selectionBoxes.n_b.disabled, true);
});

test('T10.25 scenario 5: confirmed single-row deletion clears its selection and disables bulk delete', async () => {
	const h = await harness('nodes');
	await render(h);
	selectAll(h);
	assert.equal(h.page.deleteSelected.disabled, false);
	const remove = buttons(actions(h, 'n_b')).find(node => text(node) === '删除');
	await remove.click({ currentTarget: remove });
	assert.equal(h.page.selectedNodes.size, 0);
	assert.equal(h.page.deleteSelected.disabled, true);
	assert.equal(h.page.selectAll.checked, false);
	assert.deepEqual(h.uciCalls.find(call => call[0] === 'remove').slice(0, 2), ['remove', 'n_b']);
});

test('T10.25 defensive: bulk save failure reports error and always clears busy state', async () => {
	const h = await harness('nodes');
	await render(h);
	selectAll(h);
	h.page.nodeMap.save = async () => { throw new Error('save failed'); };
	await h.page.handleDeleteSelected();
	assert.equal(h.page.deleting, false);
	assert.equal(h.page.deleteSelected.disabled, true);
	assert.match(text(h.uciCalls.at(-1)[2]), /操作失败：save failed/);
});

function switchButtons(h) {
	return buttons(h.root).filter(node => text(node) === '设为当前');
}
function assertSwitchLocked(h, locked) {
	assert.ok(switchButtons(h).length > 0);
	assert.ok(switchButtons(h).every(button => button.disabled === locked));
	if (locked)
		assert.ok(switchButtons(h).every(button => button.title === '正在切换节点，请稍候'));
}

test('T10.25 scenario 6: mismatch locks all switch actions, polls at 3s and unlocks on agreement', async () => {
	const h = await harness('nodes');
	h.nodes.push({ '.name': 'n_c', label: 'Node C' });
	await render(h);
	assert.deepEqual(h.statusCalls, [['status', undefined]]);
	h.statusReads[0].resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	assertSwitchLocked(h, true);
	assert.ok(h.page.probeButtons.every(button => !button.disabled));
	await h.tick(2999);
	assert.equal(h.statusCalls.length, 1);
	await h.tick(1);
	assert.equal(h.statusCalls.length, 2);
	h.statusReads[1].resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	assertSwitchLocked(h, true);
	await h.tick(3000);
	assert.equal(h.statusCalls.length, 3);
	h.statusReads[2].resolve({ ok: true, state: 'running', node_id: 'n_a' });
	await flush();
	assertSwitchLocked(h, false);
	assert.equal(h.timers.size, 0);
	await h.tick(60000);
	assert.equal(h.statusCalls.length, 3);
});

test('T10.25 scenario 6: 60s deadline unlocks even with RPC in flight and ignores its late reply', async () => {
	const h = await harness('nodes');
	await render(h);
	h.statusReads[0].resolve({ ok: true, state: 'degraded', node_id: 'n_b' });
	await flush();
	await h.tick(59999);
	assertSwitchLocked(h, true);
	assert.equal(h.statusCalls.length, 2, 'a pending poll must not overlap another status request');
	await h.tick(1);
	assertSwitchLocked(h, false);
	assert.equal(h.timers.size, 0);
	h.statusReads[1].resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	assertSwitchLocked(h, false);
	assert.equal(h.timers.size, 0, 'late mismatch cannot restart a timed-out watch');
});

test('T10.25 scenario 6: node_use success locks rebuilt actions and invalidates initial status', async () => {
	const h = await harness('nodes');
	h.nodes.push({ '.name': 'n_c', label: 'Node C' });
	await render(h);
	const button = switchButtons(h)[0];
	const pending = button.click({ currentTarget: button });
	assert.deepEqual(h.calls[1], ['node_use', { id: 'n_b' }]);
	assert.ok(switchButtons(h).every(button => button.disabled), 'all switch buttons lock during node_use');
	h.setCurrent('n_b');
	h.reads[1].resolve({ ok: true, reload: true });
	await flush();
	h.statusReads[1].resolve({ ok: true, state: 'running', node_id: 'n_a' });
	await pending;
	assert.equal(h.maps.length, 2);
	assertSwitchLocked(h, true);
	h.statusReads[0].resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	assertSwitchLocked(h, true);
	const before = h.calls.length;
	await h.page.handleSetCurrent('n_c', { currentTarget: {} });
	assert.equal(h.calls.length, before, 'directly invoking a locked action must not write');
	await h.tick(3000);
	h.statusReads[2].resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	assertSwitchLocked(h, false);
});

test('T10.25 defensive: failed status retains an existing lock only to its deadline, silently', async () => {
	const h = await harness('nodes');
	await render(h);
	h.statusReads[0].resolve({ ok: true, state: 'failsafe', node_id: 'n_b' });
	await flush();
	await h.tick(3000);
	h.statusReads[1].resolve({ ok: false, code: 'TIMEOUT' });
	await flush();
	assertSwitchLocked(h, true);
	assert.ok(!h.uciCalls.some(call => call[0] === 'notify'), 'a failed poll does not notify');
	await h.tick(57000);
	assertSwitchLocked(h, false);
});

test('T10.25 scenario 6: repeated mismatches never extend the original 60s deadline', async () => {
	const h = await harness('nodes');
	await render(h);
	h.statusReads[0].resolve({ ok: true, state: 'starting', node_id: 'n_b' });
	await flush();
	for (let second = 3; second < 60; second += 3) {
		await h.tick(3000);
		h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: 'n_b' });
		await flush();
		assertSwitchLocked(h, true);
	}
	assert.equal(h.statusCalls.length, 20);
	await h.tick(3000);
	assertSwitchLocked(h, false);
	assert.equal(h.timers.size, 0);
});

test('T10.25 scenario 6: matching, stopped and unread status do not start a switch watch', async () => {
	for (const status of [
		{ ok: true, state: 'running', node_id: 'n_a' },
		{ ok: true, state: 'stopped', node_id: 'n_b' },
		{ ok: true, state: 'error', node_id: 'n_b' },
		{ ok: false, code: 'RPC_FAILED' }, null
	]) {
		const h = await harness('nodes');
		await render(h);
		h.statusReads[0].resolve(status);
		await flush();
		assertSwitchLocked(h, false);
		assert.equal(h.timers.size, 0);
	}
});
