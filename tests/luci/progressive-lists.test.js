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
function optionDouble(uci, kind, field, title) {
	const values = new Map(), widgets = new Map();
	return {
		kind, field, title, depends() {},
		value(key, label) {
			(this.keylist ??= []).push(key);
			(this.vallist ??= []).push(label);
		},
		formvalue: id => values.get(id),
		getUIElement: id => widgets.get(id),
		renderWidget(id, index, value) {
			const widget = {
				value: value ?? '', placeholder: this.placeholder,
				setPlaceholder(text) { this.placeholder = text; }
			};
			widgets.set(id, widget);
			return widget;
		},
		setFormValue: (id, value) => values.set(id, value),
		// LuCI AbstractValue.parse removes rmempty options rather than writing ''.
		async parse(id) {
			if (!values.has(id))
				return;
			const value = values.get(id);
			if (this.rmempty && value === '')
				uci.unset('aetherproxy', id, field);
			else
				uci.set('aetherproxy', id, field, value);
		}
	};
}
function formDouble(uci, maps, uciCalls, builtins, builtinKinds) {
	async function renderSection(section) {
		if (section.kind === 'NamedSection') {
			for (const o of section.options)
				o.renderWidget(section.type, 0, uci.get('aetherproxy', section.type, o.field) ?? o.default);
			return E('section', {}, section.title);
		}
		return E('div', {}, [
			E('tr', { 'data-title': section.anonymous ? null : '名称' },
				section.options.filter(o => o.textvalue || o.editable).map(o => E('th', {}, o.title))),
			...uci.sections('aetherproxy', section.type).map(s => E('div', { sid: s['.name'] }, [
				...section.options.filter(o => o.textvalue || o.editable).map(o =>
					E('td', { field: o.field }, o.editable ? E('input', {
						type: 'checkbox', checked: s[o.field] !== '0' || null,
						change: event => o.onchange(event, s['.name'], event.target.checked ? '1' : '0')
					}) : o.textvalue(s['.name']))),
				section.renderRowActions(s['.name'])
			]))
		]);
	}
	return { NamedSection: 'NamedSection', GridSection: 'GridSection', Flag: 'Flag',
		ListValue: 'ListValue', Value: 'Value', Map: class {
		constructor() { this.sections = []; maps.push(this); }
		section(kind, type, sectionType, title) {
			const section = {
				kind, type, sectionType, title, options: [], modal: { value: 'unsaved modal input' },
				option(kind, field, title) {
					const option = optionDouble(uci, kind, field, title);
					this.options.push(option);
					return option;
				},
				renderMoreOptionsModal(id) {
					this.modal = { id, value: 'unsaved modal input' };
					if (this.addModalOptions)
						this.addModalOptions(this.modal, id);
					for (const o of this.options.filter(o => o.modalonly && o.renderWidget))
						o.renderWidget(id, 0, uci.get('aetherproxy', id, o.field) ?? o.default);
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
					if (method === 'render')
						return renderSection(section);
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
			this.node = E('form', {}, await Promise.all(this.sections.map(section =>
				section.render ? section.render() : renderSection(section))));
			return this.node;
		}
	} };
}
async function harness(name, builtinKinds = name === 'nodes' ? ['remove'] : ['edit', 'remove']) {
	const calls = [], reads = [], turns = [], maps = [], uciCalls = [], builtins = [];
	const statusCalls = [], statusReads = [], timers = new Map(), notices = [];
	let now = 0, timerID = 0, current = 'n_a';
	const general = [], versionRead = deferred(), versionCalls = [];
	let changes = async () => ({});
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
		unload: config => { uciCalls.push(['unload', config]); },
		get: (config, id, option) => {
			if (id === 'main' && option === 'node')
				return current;
			const section = [...nodes, ...subs, ...general].find(s => s['.name'] === id);
			return option == null ? section ?? null : section?.[option];
		},
		changes: () => changes(),
		add: (config, type, id) => {
			uciCalls.push(['add', config, type, id]);
			(type === 'sub' ? general : subs).push({ '.name': id, '.type': type });
		},
		sections: (config, type) => type === 'node' ? nodes :
			type === 'subscription' ? subs : [...nodes, ...subs, ...general],
		unset: (config, id, option) => {
			uciCalls.push(['unset', config, id, option]);
			delete uci.get(config, id)[option];
		},
		remove: (config, id) => {
			uciCalls.push(['uci.remove', config, id]);
			for (const sections of [nodes, subs]) {
				const index = sections.findIndex(section => section['.name'] === id);
				if (index >= 0)
					sections.splice(index, 1);
			}
		},
		set: (config, id, option, value) => {
			uciCalls.push(['set', config, id, option, value]);
			const section = [...nodes, ...subs, ...general].find(s => s['.name'] === id);
			if (section)
				section[option] = value;
		},
		save: async () => { uciCalls.push(['save']); }
	};
	const form = formDouble(uci, maps, uciCalls, builtins, builtinKinds);
	const ap = {
		call: (method, params) => {
			if (method === 'version') {
				versionCalls.push(method);
				return versionRead.promise;
			}
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
			addNotification(...args) {
				uciCalls.push(['notify', ...args]);
				// luci-base returns the banner, including a separate Dismiss control.
				const dismiss = E('button', {}, '关闭');
				const banner = E('div', {}, [E('div', {}, args[1]), dismiss]);
				banner.remove = () => { banner.removed = true; };
				dismiss.click = () => banner.remove();
				notices.push(banner);
				return banner;
			}
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
		clearTimeout: id => timers.delete(id),
		crypto: { getRandomValues: bytes => bytes.fill(1) }
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
	return { name, page, maps, calls, reads, turns, uciCalls, builtins, ap, nodes, subs, uci,
		general, versionRead, versionCalls,
		setChanges: fn => { changes = fn; },
		statusCalls, statusReads, timers, notices, tick, setCurrent: id => { current = id; } };
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
// T10.34 uses the same asynchronous grid harness so inherited settings cannot
// regress first-paint behavior or erase an open modal when the version arrives.
function subOption(h, field) {
	return h.page.grid.options.find(o => o.field === field);
}
function renderOption(o, id, value) {
	return o.renderWidget(id, 0, value);
}
const intervalLabels = ['不自动更新', '12 小时', '1 天', '3 天', '7 天'];

test('T10.34 scenario 1: existing general section displays its values without writes', async () => {
	const h = await harness('subscriptions');
	h.general.push({ '.name': 'sub', '.type': 'sub', interval_hours: '72',
		fetch_via: 'proxy', user_agent: 'Custom/1' });
	await render(h);
	const section = h.maps[0].sections[0];
	assert.equal(section.kind, 'NamedSection');
	assert.equal(section.type, 'sub');
	assert.equal(section.sectionType, 'sub');
	assert.equal(section.title, '通用设置');
	for (const field of ['interval_hours', 'fetch_via', 'user_agent'])
		assert.equal(h.page.generalOptions[field].getUIElement('sub').value, h.general[0][field]);
	assert.deepEqual(h.uciCalls, [['load', 'aetherproxy']]);
});

test('T10.34 scenario 1: missing general section is added once empty and displays defaults', async () => {
	const h = await harness('subscriptions');
	await render(h);
	await h.page.load();
	assert.deepEqual(h.general, [{ '.name': 'sub', '.type': 'sub' }]);
	assert.equal(h.uciCalls.filter(call => call[0] === 'add').length, 1);
	assert.ok(!h.uciCalls.some(call => ['set', 'save'].includes(call[0])));
	assert.equal(h.page.generalOptions.interval_hours.getUIElement('sub').value, '24');
	assert.equal(h.page.generalOptions.fetch_via.getUIElement('sub').value, 'auto');
	assert.equal(h.page.generalOptions.user_agent.getUIElement('sub').value, '');
	assert.equal(subOption(h, '_interval').textvalue('s_a'), '1 天（通用）');
	assert.equal(subOption(h, '_via').textvalue('s_a'), '自动（先直连，失败经当前节点）（通用）');
});

test('T10.34 scenario 1: job reload recreates the empty common section for legacy configuration', async () => {
	const h = await harness('subscriptions');
	await render(h);
	h.uci.unload = config => {
		h.uciCalls.push(['unload', config]);
		// An empty, unsaved common section is not in the persisted legacy configuration.
		h.general.length = 0;
	};
	const pending = h.page.update(['s_a']);
	await flush();
	h.reads[1].resolve(success('subscriptions'));
	await pending;
	assert.deepEqual(h.general, [{ '.name': 'sub', '.type': 'sub' }]);
	assert.equal(h.uciCalls.filter(call => call[0] === 'add').length, 2);
	assert.ok(!h.uciCalls.some(call => ['set', 'save'].includes(call[0])));
	assert.equal(h.page.generalOptions.interval_hours.getUIElement('sub').value, '24');
});

test('T10.34 scenario 2: interval dropdown has five labels and retains a custom 6-hour value', async () => {
	const h = await harness('subscriptions');
	h.general.push({ '.name': 'sub', interval_hours: '6' });
	h.subs[0].interval_hours = '6';
	await render(h);
	const general = h.page.generalOptions.interval_hours;
	assert.equal(general.kind, 'ListValue');
	assert.deepEqual(general.keylist, ['0', '12', '24', '72', '168', '6']);
	assert.deepEqual(general.vallist, [...intervalLabels, '6 小时']);
	assert.equal(general.getUIElement('sub').value, '6');
	h.page.grid.renderMoreOptionsModal('s_a');
	const single = subOption(h, 'interval_hours');
	assert.equal(single.kind, 'ListValue');
	assert.deepEqual(single.keylist, ['', '0', '12', '24', '72', '168', '6']);
	assert.deepEqual(single.vallist, ['跟随通用设置（6 小时）', ...intervalLabels, '6 小时']);
	assert.equal(single.getUIElement('s_a').value, '6');
	// Reopening must not accumulate choices from another subscription.
	renderOption(single, 's_b', undefined);
	assert.deepEqual(single.keylist, ['', '0', '12', '24', '72', '168']);
});

test('T10.34 scenario 3: overrides follow live common values and empty Save removes all three options', async () => {
	const h = await harness('subscriptions');
	Object.assign(h.subs[0], { interval_hours: '24', fetch_via: 'auto', user_agent: 'Legacy/1' });
	await render(h);
	const common = h.page.generalOptions;
	common.interval_hours.setFormValue('sub', '72');
	common.fetch_via.setFormValue('sub', 'proxy');
	common.user_agent.setFormValue('sub', 'Common/2');
	h.page.grid.renderMoreOptionsModal('s_a');
	assert.equal(subOption(h, 'interval_hours').vallist[0], '跟随通用设置（3 天）');
	assert.equal(subOption(h, 'fetch_via').vallist[0], '跟随通用设置（经当前节点）');
	assert.equal(subOption(h, 'user_agent').placeholder, '跟随通用设置（Common/2）');
	for (const [field, legacy] of Object.entries({ interval_hours: '24', fetch_via: 'auto', user_agent: 'Legacy/1' })) {
		const option = subOption(h, field);
		assert.equal(option.default, undefined, 'no inherited field writes a default');
		assert.equal(option.getUIElement('s_a').value, legacy, 'explicit legacy values remain selected');
		assert.equal(option.rmempty, true);
		option.setFormValue('s_a', '');
		await option.parse('s_a');
		assert.equal(Object.hasOwn(h.subs[0], field), false, field + ' is removed, not saved as empty');
		assert.ok(h.uciCalls.some(call => call[0] === 'unset' && call[2] === 's_a' && call[3] === field));
	}
	await h.page.add();
	const added = h.subs.find(s => s['.name'] === 's_01010101');
	assert.deepEqual(added, { '.name': 's_01010101', '.type': 'subscription' });
	for (const field of ['interval_hours', 'fetch_via', 'user_agent'])
		assert.equal(subOption(h, field).getUIElement(added['.name']).value, '');
});

test('T10.34 scenario 3: late backend version fills UA placeholders without replacing an open modal', async () => {
	const h = await harness('subscriptions');
	await render(h);
	assert.deepEqual(h.versionCalls, ['version']);
	h.page.grid.renderMoreOptionsModal('s_a');
	const modal = h.page.grid.modal;
	const commonUA = h.page.generalOptions.user_agent;
	const singleUA = subOption(h, 'user_agent');
	assert.equal(commonUA.placeholder, '默认（读取中…）');
	h.versionRead.resolve({ ok: true, version: '0.2.0-r99' });
	await flush();
	assert.equal(commonUA.getUIElement('sub').placeholder, '默认（aether-proxy/0.2.0-r99）');
	assert.equal(singleUA.getUIElement('s_a').placeholder, '跟随通用设置（aether-proxy/0.2.0-r99）');
	assert.equal(h.page.grid.modal, modal);
	assert.equal(h.maps.length, 1);
	assert.ok(!h.uciCalls.some(call => call[0] === 'set'), 'UA placeholder never persists a version');
});

test('T10.34 scenario 3: unavailable backend version shows the UA shape, no error code, no write', async () => {
	const h = await harness('subscriptions');
	await render(h);
	h.versionRead.resolve({ ok: false, code: 'TIMEOUT' });
	await flush();
	assert.equal(h.page.generalOptions.user_agent.getUIElement('sub').placeholder, '默认（aether-proxy/…）');
	assert.ok(!h.uciCalls.some(call => call[0] === 'set'));
});

test('T10.34 scenario 4: effective table values mark inheritance and both dropdowns share fetch labels', async () => {
	const h = await harness('subscriptions');
	h.general.push({ '.name': 'sub', interval_hours: '72', fetch_via: 'proxy' });
	Object.assign(h.subs[1], { interval_hours: '12', fetch_via: 'direct' });
	await render(h);
	const interval = subOption(h, '_interval'), via = subOption(h, '_via');
	assert.equal(interval.textvalue('s_a'), '3 天（通用）');
	assert.equal(via.textvalue('s_a'), '经当前节点（通用）');
	assert.equal(interval.textvalue('s_b'), '12 小时');
	assert.equal(via.textvalue('s_b'), '直连');
	assert.equal(via.title, '获取方式');
	const labels = ['自动（先直连，失败经当前节点）', '直连', '经当前节点'];
	const common = h.page.generalOptions.fetch_via;
	assert.deepEqual(common.keylist, ['auto', 'direct', 'proxy']);
	assert.deepEqual(common.vallist, labels);
	const single = subOption(h, 'fetch_via');
	renderOption(single, 's_a', undefined);
	assert.deepEqual(single.keylist, ['', 'auto', 'direct', 'proxy']);
	assert.deepEqual(single.vallist, ['跟随通用设置（经当前节点）', ...labels]);
	// Table cells read saved session values rather than a captured initial row.
	h.uci.set('aetherproxy', 'sub', 'interval_hours', '0');
	h.uci.set('aetherproxy', 'sub', 'fetch_via', 'direct');
	assert.equal(interval.textvalue('s_a'), '不自动更新（通用）');
	assert.equal(via.textvalue('s_a'), '直连（通用）');
});

test('T10.34 scenario 5: first-column flag immediately locks only its row before any UCI save', async () => {
	const h = await harness('subscriptions');
	await render(h);
	const enabled = subOption(h, 'enabled');
	assert.equal(h.page.grid.options[0], enabled);
	assert.equal(enabled.kind, 'Flag');
	assert.equal(enabled.editable, true);
	assert.equal(enabled.modalonly, false);
	h.page.grid.renderMoreOptionsModal('s_a');
	assert.doesNotMatch(text(h.page.grid.modal.node), /启用/);
	const row = find(h.root, node => node.sid === 's_a')[0];
	const checkbox = find(row, node => node.tag === 'input')[0];
	assert.equal(checkbox.type, 'checkbox');
	checkbox.change({ target: { checked: false } });
	assert.equal(h.page.rowButtons.get('s_a').disabled, true);
	assert.equal(h.page.rowButtons.get('s_a').title, '请先保存并应用');
	assert.equal(h.page.rowButtons.get('s_b').disabled, false);
	assert.equal(h.page.updateAll.disabled, false);
	assert.equal(h.page.pendingHint.textContent, '未应用的订阅不会更新');
	assert.ok(!h.uciCalls.some(call => ['save', 'set'].includes(call[0])));
	await h.page.refresh_changes();
	assert.equal(h.page.rowButtons.get('s_a').disabled, true, 'empty session changes cannot undo local lock');
	const jobs = [];
	h.ap.run_job = async (...args) => { jobs.push(args); return { result: { subs: {} } }; };
	await h.page.update(['s_a']);
	assert.deepEqual(jobs, [], 'the update handler also guards the locally dirty row');
	await h.page.redraw();
	assert.equal(h.page.rowButtons.get('s_a').disabled, true, 'redraw preserves the local lock');
	assert.equal(h.page.rowButtons.get('s_b').disabled, false);
});

for (const name of ['nodes', 'subscriptions']) {
	test(`T10.16 ${name} scenario 1: load reads only UCI`, async () => {
		const h = await harness(name);
		await h.page.load();
		assert.deepEqual(h.uciCalls, name === 'nodes' ? [['load', 'aetherproxy']] :
			[['load', 'aetherproxy'], ['add', 'aetherproxy', 'sub', 'sub']]);
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
		assert.equal((h.page.grid ?? h.maps[0].sections[0]).options.filter(o => o.modalonly).length > 0, true);
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
		assert.equal((h.page.grid ?? h.maps[0].sections[0]).modal.value, 'unsaved modal input');
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
		const option = (h.page.grid ?? h.maps[0].sections[0]).options.find(o => o.field === field);
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

test('T10.29 scenarios 1/2/4: collapsed bulk import follows the table with its own summary and action row',
async () => {
	const h = await harness('nodes');
	await render(h);
	const details = find(h.root, node => node.tag === 'details');
	assert.equal(details.length, 1);
	const box = details[0];
	assert.equal(box.open, false, 'bulk import is initially collapsed');
	assert.equal(box.attrs.open, undefined, 'no open="false" HTML attribute');
	assert.equal(box.children[0].tag, 'summary');
	assert.equal(text(box.children[0]), '批量导入分享链接');
	assert.equal(box.children[1].tag, 'p');
	assert.equal(text(box.children[1]), '一次导入多行，每行一个链接，直接加入节点列表。');
	assert.equal(box.children[2], h.page.importText);
	assert.equal(h.page.importText.tag, 'textarea');
	assert.equal(h.page.importText.placeholder, '每行一个节点分享链接（URI）。');
	assert.equal(h.page.importText.value, '');
	const importRow = actionRow(box, ['导入'], [h.page.importResult]);
	assert.equal(box.children.at(-1), importRow);
	assert.equal(text(h.page.importResult), '');
	const toolbar = actionRow(h.root, ['检测全部', '删除所选', '添加节点'], [h.page.progressEl]);
	const content = find(h.root, node => node.children.includes(h.maps[0].node))[0];
	assert.deepEqual(content.children.slice(-3), [toolbar, h.maps[0].node, box],
		'toolbar immediately precedes the table, bulk import immediately follows it');
	assert.doesNotMatch(text(h.root), /导入 URI|Import URIs/);
});

test('T10.29 scenario 3: clicked sequential import redraws nodes, retaining open state, exact input and inline results',
async () => {
	const h = await harness('nodes');
	await render(h);
	h.reads[0].resolve(success('nodes'));
	await flush();
	const oldBox = h.page.importDetails;
	const oldInput = h.page.importText;
	const input = '\n  vless://new  \r\n\nvmess://duplicate\nbad://invalid\n';
	oldBox.open = true; // Native summary expansion changes the details.open property.
	oldInput.value = input;
	const importButton = buttons(oldBox).find(node => text(node) === '导入');
	importButton.click({ currentTarget: importButton });
	await flush();
	assert.equal(importButton.disabled, true);
	assert.deepEqual(h.calls.slice(1), [['node_import', { uri: 'vless://new' }]],
		'the next line waits for the previous reply');
	h.nodes.push({ '.name': 'n_new', label: 'Newly imported', source: 'manual' });
	h.reads[1].resolve({ ok: true, node: 'n_new', duplicate: false });
	await flush();
	assert.deepEqual(h.calls.slice(1), [
		['node_import', { uri: 'vless://new' }], ['node_import', { uri: 'vmess://duplicate' }]
	]);
	h.reads[2].resolve({ ok: true, node: 'n_b', duplicate: true });
	await flush();
	assert.deepEqual(h.calls[3], ['node_import', { uri: 'bad://invalid' }]);
	h.reads[3].resolve({ ok: false, code: 'CONFIG_INVALID', detail: '<invalid link>' });
	await flush();
	assert.deepEqual(h.calls[4], ['probe_results', undefined]);
	h.reads[4].resolve(success('nodes'));
	await flush();
	assert.equal(h.maps.length, 2, 'an added node triggers a full page rebuild');
	assert.notEqual(h.page.importDetails, oldBox);
	assert.notEqual(h.page.importText, oldInput);
	assert.equal(h.page.importDetails.open, true);
	assert.equal(h.page.importText.value, input, 'do not trim or clear the submitted textarea');
	assert.match(text(h.maps[1].node), /Newly imported/);
	assert.deepEqual(h.uciCalls.filter(call => ['unload', 'load'].includes(call[0])),
		[['load', 'aetherproxy'], ['unload', 'aetherproxy'], ['load', 'aetherproxy']]);
	assert.doesNotMatch(text(h.root), /操作失败/);
	assert.equal(text(h.page.importResult), '新增 1 个，已存在 1 个，失败 1 个#5 CONFIG_INVALID: <invalid link>');
	assert.equal(find(h.page.importDetails, node => node === h.page.importResult).length, 1);
	assert.equal(find(h.page.importResult, node => node.tag === 'li').length, 1);
	assert.equal(find(h.page.importResult, node => node.tag === 'invalid').length, 0);
	actionRow(h.page.importDetails, ['导入'], [h.page.importResult]);
	assert.equal(h.uciCalls.some(call => call[0] === 'notify'), false, 'results stay in the block, not a toast');
	assert.equal(buttons(h.page.importDetails)[0].disabled, false);

	// Further redraws preserve the user's choice to collapse, rather than always forcing open.
	h.page.importDetails.open = false;
	const pending = h.page.rebuild();
	await flush();
	h.reads[5].resolve(success('nodes'));
	await pending;
	assert.equal(h.page.importDetails.open, false);
	assert.equal(h.page.importText.value, input);
	assert.match(text(h.page.importResult), /^新增 1 个，已存在 1 个，失败 1 个/);
});

test('T10.29 scenario 3: duplicate-only and failed imports replace inline results without rebuilding', async () => {
	const h = await harness('nodes');
	await render(h);
	h.page.importDetails.open = true;
	h.page.importText.value = 'vless://duplicate';
	const box = h.page.importDetails;
	const pending = h.page.handleImport({});
	await flush();
	h.reads[1].resolve({ ok: true, node: 'n_b', duplicate: true });
	await pending;
	assert.equal(text(h.page.importResult), '新增 0 个，已存在 1 个，失败 0 个');
	h.page.importText.value = '\nbad://invalid';
	const failed = h.page.handleImport({});
	await flush();
	h.reads[2].resolve({ ok: false, code: 'CONFIG_INVALID', detail: 'malformed' });
	await failed;
	assert.equal(text(h.page.importResult), '新增 0 个，已存在 0 个，失败 1 个#2 CONFIG_INVALID: malformed');
	assert.equal(h.page.importDetails, box);
	assert.equal(box.open, true);
	assert.equal(h.page.importText.value, '\nbad://invalid');
	assert.equal(h.maps.length, 1);
	assert.equal(h.uciCalls.some(call => call[0] === 'notify'), false);
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

test('T10.28 scenario 1: subscription grid has one Name column and no section-name column', async () => {
	const h = await harness('subscriptions');
	await render(h);
	assert.equal(h.page.grid.anonymous, true);
	const header = find(h.root, node => node.tag === 'tr')[0];
	assert.equal(header.attrs['data-title'], null);
	assert.deepEqual(find(header, node => node.tag === 'th').map(text),
		['启用', '名称', '地址', '更新间隔', '获取方式', '最近一次结果']);
	assert.doesNotMatch(text(h.root), /s_a|s_b/);
});

test('T10.28 scenario 2: modal Save reads current UCI for every cell; removed sections show dashes', async () => {
	const h = await harness('subscriptions');
	await render(h);
	const before = h.maps.length;
	await h.page.add();
	const id = 's_01010101';
	assert.equal(h.page.grid.modal.id, id);
	assert.equal(h.page.map.addedSection, id, 'GridSection Cancel removes the new section');
	assert.equal(h.maps.length, before, 'the table is not redrawn before Save');
	assert.equal(find(h.root, node => node.sid === id).length, 0, 'no row until the modal is saved');
	for (const [option, value] of Object.entries({ name: 'New saved name',
		url: 'https://new.example/path?token=SECRET', enabled: '0', interval_hours: '0', fetch_via: 'proxy' }))
		h.uci.set('aetherproxy', id, option, value);
	await h.uci.save();
	h.page.status = { ok: true, subs: { [id]: { nodes: 13 } } };
	// A modal Save resets the parent map, reusing the existing option instances.
	await h.maps.at(-1).render();
	const options = h.page.grid.options.filter(o => o.textvalue);
	assert.deepEqual(options.slice(0, -1).map(o => o.textvalue(id)),
		['New saved name', 'https://new.example/…', '不自动更新', '经当前节点']);
	assert.match(text(options.at(-1).textvalue(id)), /成功，13 个节点/);
	h.uci.remove('aetherproxy', id);
	for (const option of options)
		assert.equal(option.textvalue(id), '–', option.field + ' tolerates a deleted section');
	await h.page.redraw();
	assert.equal(find(h.root, node => node.sid === id).length, 0);
});

for (const record of [['add', 's_a', 'subscription'], ['set', 's_a', 'name', 'Changed'], ['remove', 's_a']]) {
	test(`T10.28 scenario 3: ${record[0]} blocks only the affected row after a grid reset`, async () => {
		const h = await harness('subscriptions');
		let checks = 0;
		h.setChanges(async () => { checks++; return {}; });
		await render(h);
		assert.equal(checks, 1, 'check once after initial section rendering');
		h.setChanges(async () => { checks++; return { aetherproxy: [record] }; });
		await h.maps[0].render();
		await flush();
		assert.equal(checks, 2, 'modal parent reset must check the saved session again');
		const affected = h.page.rowButtons.get('s_a');
		assert.equal(affected.disabled, true);
		assert.equal(affected.title, '请先保存并应用');
		assert.equal(h.page.rowButtons.get('s_b').disabled, false);
		assert.equal(h.page.updateAll.disabled, false);
		assert.equal(text(h.page.pendingHint), '未应用的订阅不会更新');
		await h.page.update(['s_a']);
		assert.equal(h.reads.length, 1, 'direct invocation cannot bypass the pending guard');
		h.setChanges(async () => { throw new Error('uci changes failed'); });
		await h.page.redraw();
		await flush();
		assert.ok([...h.page.rowButtons.values()].every(button => !button.disabled));
		assert.equal(h.page.rowButtons.get('s_a').title, '');
		assert.equal(text(h.page.pendingHint), '');
	});
}

test('T10.28 scenario 3: saved deletion still warns; unrelated packages and nodes do not block', async () => {
	const h = await harness('subscriptions');
	h.setChanges(async () => ({ aetherproxy: [['remove', 's_deleted']] }));
	await render(h);
	assert.equal(text(h.page.pendingHint), '未应用的订阅不会更新');
	assert.ok([...h.page.rowButtons.values()].every(button => !button.disabled));
	assert.equal(h.page.updateAll.disabled, false);
	h.setChanges(async () => ({ dhcp: [['set', 's_a', 'name', 'Not ours']],
		aetherproxy: [['set', 'n_a', 'label', 'Node'], ['set', 'main', 'enabled', '1']] }));
	await h.page.redraw();
	await flush();
	assert.equal(text(h.page.pendingHint), '');
	assert.ok([...h.page.rowButtons.values()].every(button => !button.disabled));
});

test('T10.28 scenario 3: slow changes RPC does not delay rendering or overwrite a newer reply', async () => {
	const h = await harness('subscriptions');
	const old = deferred();
	h.setChanges(() => old.promise);
	await render(h);
	assert.equal(h.page.rowButtons.get('s_a').disabled, false);
	h.setChanges(async () => ({ aetherproxy: [['set', 's_a', 'name', 'Pending']] }));
	await h.page.redraw();
	await flush();
	old.resolve({});
	await flush();
	assert.equal(h.page.rowButtons.get('s_a').disabled, true);
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

/* T10.32: synchronous unload regressions and the returned LuCI banner lifecycle. */
test('T10.32 scenario 1: single subscription update reloads after synchronous unload and shows new results',
async () => {
	const h = await harness('subscriptions');
	await render(h);
	h.reads[0].resolve({ ok: true, subs: {} });
	await flush();
	assert.match(text(h.page.resultCells.s_a), /尚未更新/);
	h.ap.run_job = async (kind, ids) => {
		assert.equal(kind, 'sub_update');
		assert.deepEqual(ids, ['s_a']);
		return { state: 'ok', result: { subs: { s_a: { ok: true, added: 7 } } } };
	};
	const button = h.page.rowButtons.get('s_a');
	assert.equal(button.click({ currentTarget: button }), undefined, 'LuCI handlers return no value');
	await flush();
	assert.deepEqual(h.uciCalls.filter(call => ['unload', 'load'].includes(call[0])),
		[['load', 'aetherproxy'], ['unload', 'aetherproxy'], ['load', 'aetherproxy']]);
	assert.deepEqual(h.calls.at(-1), ['sub_status', undefined]);
	h.reads[1].resolve(success('subscriptions'));
	await flush();
	assert.match(text(h.page.resultCells.s_a), /成功，7 个节点/);
	assert.doesNotMatch(text(h.page.summary), /操作失败/);
	assert.match(text(h.page.summary), /Alpha: 新增 7/);
	assert.equal(h.page.busy, false);
	assert.ok(!h.page.rowButtons.get('s_a').disabled);
});

test('T10.32 scenario 3: subscription actions are Update, Edit, Delete and Edit opens that subscription', async () => {
	const h = await harness('subscriptions');
	await render(h);
	for (const id of ['s_a', 's_b']) {
		const rowButtons = buttons(actions(h, id));
		assert.deepEqual(rowButtons.map(text), ['立即更新', '编辑', '删除']);
		const edit = rowButtons[1];
		assert.ok(h.builtins.find(row => row.id === id).buttons.includes(edit));
		edit.click({ currentTarget: edit });
		assert.equal(h.page.grid.modal.id, id);
		assert.match(text(h.page.grid.modal.node), /名称订阅地址/);
	}
});

async function beginSwitch(h, id) {
	const previous = h.uci.get('aetherproxy', 'main', 'node');
	const button = buttons(actions(h, id)).find(node => text(node) === '设为当前');
	const pending = button.click({ currentTarget: button });
	assert.deepEqual(h.calls.at(-1), ['node_use', { id }]);
	h.setCurrent(id);
	h.reads.at(-1).resolve({ ok: true, reload: true });
	await flush();
	h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: previous });
	await pending;
	return h.notices.at(-1);
}
async function switchHarness() {
	const h = await harness('nodes');
	h.nodes.push({ '.name': 'n_c', label: 'Node C' });
	await render(h);
	h.reads[0].resolve(success('nodes'));
	h.statusReads[0].resolve({ ok: true, state: 'running', node_id: 'n_a' });
	await flush();
	return h;
}

test('T10.32 scenario 4: completed switch updates the same banner, keeps Dismiss and removes it after 5s', async () => {
	const h = await switchHarness();
	const banner = await beginSwitch(h, 'n_b');
	const content = h.page.switchNotice.content;
	const dismiss = banner.children[1];
	assert.equal(content.textContent, '正在切换到「Node B」…');
	assertSwitchLocked(h, true);
	await h.tick(3000);
	h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	assert.equal(h.page.switchNotice.element, banner, 'reuse addNotification return value');
	assert.equal(banner.children[0].children[0], content, 'update only our text node');
	assert.equal(content.textContent, '已切换到「Node B」');
	assert.equal(banner.children[1], dismiss, 'keep the SDK Dismiss control');
	assert.equal(h.notices.length, 1, 'do not stack a second banner');
	assertSwitchLocked(h, false);
	await h.tick(4999);
	assert.ok(!banner.removed);
	await h.tick(1);
	assert.equal(banner.removed, true);
	assert.equal(h.page.switchNotice, null);
	assert.equal(h.timers.size, 0);
});

test('T10.32 scenario 4: 60s timeout retains an unfinished banner, ignores late status and permits Dismiss',
async () => {
	const h = await switchHarness();
	const banner = await beginSwitch(h, 'n_b');
	await h.tick(59999);
	assert.equal(h.page.switchNotice.content.textContent, '正在切换到「Node B」…');
	assertSwitchLocked(h, true);
	await h.tick(1);
	assert.equal(h.page.switchNotice.element, banner);
	assert.equal(h.page.switchNotice.content.textContent,
		'切换到「Node B」还没有完成，可到概览页或日志页查看原因');
	assertSwitchLocked(h, false);
	assert.equal(h.timers.size, 0);
	h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: 'n_b' });
	await flush();
	await h.tick(60000);
	assert.ok(!banner.removed, 'unfinished notices do not auto-expire');
	assert.match(text(banner), /还没有完成/);
	banner.children[1].click();
	assert.equal(banner.removed, true, 'the original Dismiss control still works');
});

for (const outcome of ['complete', 'timeout']) {
	test(`T10.32 defensive: slow form rendering retains the ${outcome} watch outcome`, async () => {
		const h = await switchHarness();
		const gate = deferred();
		const buildPage = h.page.buildPage.bind(h.page);
		h.page.buildPage = async () => {
			const content = await buildPage();
			await gate.promise;
			return content;
		};
		const pending = beginSwitch(h, 'n_b');
		await flush();
		assert.equal(h.page.switchPending, true, 'watch starts before the form settles');
		if (outcome === 'complete') {
			await h.tick(3000);
			h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: 'n_b' });
			await flush();
		}
		else
			await h.tick(60000);
		assert.equal(h.page.switchPending, false);
		assert.equal(h.notices.length, 0, 'form has not returned yet');
		gate.resolve();
		const banner = await pending;
		assert.equal(h.page.switchNotice.content.textContent, outcome === 'complete'
			? '已切换到「Node B」' : '切换到「Node B」还没有完成，可到概览页或日志页查看原因');
		assertSwitchLocked(h, false);
		await h.tick(5000);
		assert.equal(!!banner.removed, outcome === 'complete');
	});
}

test('T10.32 defensive: failed form refresh retains the original bounded switch lock', async () => {
	const h = await switchHarness();
	h.page.buildPage = async () => { throw new Error('form unavailable'); };
	await beginSwitch(h, 'n_b');
	assertSwitchLocked(h, true);
	assert.match(text(h.notices.at(-1)), /已切换节点，但刷新页面数据失败/);
	await h.tick(60000);
	assertSwitchLocked(h, false);
	assert.equal(h.notices.length, 1, 'no extra switch banner after refresh failure');
});

for (const outcome of ['complete', 'timeout']) {
	test(`T10.32 scenario 4: switching again removes the ${outcome} banner before node_use returns`, async () => {
		const h = await switchHarness();
		const old = await beginSwitch(h, 'n_b');
		if (outcome === 'complete') {
			await h.tick(3000);
			h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: 'n_b' });
			await flush();
			await h.tick(2000);
		}
		else
			await h.tick(60000);
		const pending = beginSwitch(h, 'n_c');
		assert.equal(old.removed, true, 'remove before awaiting the next write');
		const next = await pending;
		assert.notEqual(next, old);
		assert.equal(h.notices.length, 2);
		await h.tick(3000);
		assert.ok(!next.removed, 'old success timer must not remove a new banner');
		assert.equal(h.page.switchNotice.content.textContent, '正在切换到「Node C」…');
	});
}
for (const completed of [false, true]) {
	test(`T10.32 scenario 4: page redraw removes the ${completed ? 'completed' : 'pending'} switch banner`,
	async () => {
		const h = await switchHarness();
		const banner = await beginSwitch(h, 'n_b');
		if (completed) {
			await h.tick(3000);
			h.statusReads.at(-1).resolve({ ok: true, state: 'running', node_id: 'n_b' });
			await flush();
		}
		await h.page.buildPage();
		assert.equal(banner.removed, true);
		assert.equal(h.page.switchNotice, null);
		assert.equal(h.page.switchNoticeTimer, null);
		await h.tick(60000);
		assert.equal(h.notices.length, 1, 'old watch must not recreate the notice');
	});
}

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
