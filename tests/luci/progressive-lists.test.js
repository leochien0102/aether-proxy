'use strict';

/* T10.16: exercise the real node/subscription grids with pending RPC replies.
 * Form and DOM doubles keep cell identity observable: a full redraw would lose
 * user input and an open modal even if the final text happened to be correct. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element, contentChildren, htmlWriteMark, htmlWritesSince } = require('./loader');
const { loadNodesPage } = require('./nodes-page');
const { actionRow, beforeTable, marginlessMessages, nowrapActions } = require('./button-layout');
const { selectWidget, selectType, textWidget } = require('./subscription-select');
const { renderFrame: sdkFlagFrame, checkboxWidget } = require('./flag-frame');
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
	return (predicate(root) ? [root] : []).concat((root.children ?? []).flatMap(n => find(n, predicate)));
}
const buttons = root => find(root, node => node.tag === 'button');
const flush = () => new Promise(resolve => setImmediate(resolve));
function deferred() {
	let resolve;
	const promise = new Promise(done => { resolve = done; });
	return { promise, resolve };
}
function optionDouble(uci, kind, field, title) {
	// LuCI methods live on the prototype: cloneOptions only copies own properties.
	class Option {
		constructor() {
			Object.assign(this, { kind, field, option: field, title });
			this.rmempty = true;
			if (kind === 'Flag')
				this.default = '0';
			this.widgets = new Map();
		}
		depends() {}
		cbid(id) { return `cbid.aetherproxy.${id}.${this.option}`; }
		value(key, label) {
			(this.keylist ??= []).push(String(key));
			(this.vallist ??= []).push(label);
		}
		formvalue(id) { return this.widgets.get(id)?.value; }
		getUIElement(id) { return this.widgets.get(id); }
		renderWidget(id, index, value) {
			const initial = value ?? this.default;
			let widget;
			if (kind === 'Flag') {
				// Render through the option hook, like LuCI, so flag wrappers are observable.
				widget = checkboxWidget(initial !== '0');
				widget.node = widget;
				widget.children[0].change = event => {
					const value = event.target.checked ? '1' : '0';
					this.setFormValue(id, value);
					this.onchange?.(event, id, value);
				};
				widget.value = initial ?? '';
			}
			else {
				widget = kind === 'ListValue'
					? selectWidget(initial, Object.fromEntries((this.keylist ?? []).map((key, i) =>
						[key, this.vallist[i]])), { sort: this.keylist, optional: this.optional,
						placeholder: this.placeholder })
					: field === 'user_agent' ? textWidget(E, initial, this.placeholder)
						: { value: initial ?? '', placeholder: this.placeholder,
							setPlaceholder(text) { this.placeholder = text; } };
			}
			this.widgets.set(id, widget);
			return widget;
		}
		renderFrame(id, in_table, index, widget) {
			const frame = sdkFlagFrame.call(this, id, in_table, index, widget);
			frame.field = this.field;
			return frame;
		}
		setFormValue(id, value) {
			if (!this.widgets.has(id))
				this.widgets.set(id, {});
			this.widgets.get(id).value = value;
		}
		cfgvalue(id) { return uci.get('aetherproxy', id, field); }
		isActive(id) { return this.widgets.has(id); }
		isValid() { return true; }
		write(id, value) { uci.set('aetherproxy', id, field, value); }
		remove(id) { uci.unset('aetherproxy', id, field); }
		parse(id) {
			const Type = kind === 'Flag' ? require('./form-sdk').Flag : require('./form-sdk').Value;
			return Type.prototype.parse.call(this, id);
		}
	}
	return new Option();
}
function formDouble(uci, maps, uciCalls, builtins, builtinKinds) {
	// Product composite widgets call the base Value renderer directly.
	function Value() {}
	Value.prototype.renderWidget = function(id, index, value) {
		const widget = textWidget(E, value ?? this.default, this.placeholder);
		this.widgets.set(id, widget);
		return widget;
	};
	async function renderSection(section) {
		if (section.kind === 'NamedSection') {
			const flags = [];
			for (const o of section.options) {
				const widget = o.renderWidget(section.type, 0, uci.get('aetherproxy', section.type, o.field));
				if (o.kind !== 'Flag')
					continue;
				// Like form.js, only a nonempty string title produces a label.
				const label = typeof o.title === 'string' && o.title
					? E('label', { class: 'cbi-value-title' }, [o.title]) : null;
				if (label)
					label.appendChild = child => { label.children.push(child); return child; };
				flags.push(E('div', { class: 'cbi-value', 'data-name': o.field },
					[label, E('div', { class: 'cbi-value-field' }, [widget, E('span', {}, o.description)])]));
			}
			const content = E('section', {}, flags);
			content.querySelector = selector => {
				assert.equal(selector, '[data-name="failover"] > .cbi-value-title');
				const row = find(content, node => node['data-name'] === 'failover')[0];
				return row?.children.find(node => node.class === 'cbi-value-title') ?? null;
			};
			return content;
		}
		return E('div', {}, [
			E('tr', { 'data-title': section.anonymous ? null : '名称' },
				section.options.filter(o => o.textvalue || o.editable).map(o => E('th', {}, o.title))),
			...uci.sections('aetherproxy', section.type).map(s => {
				const trEl = E('div', { sid: s['.name'] },
					section.options.filter(o => o.textvalue || o.editable).map(o => o.editable
						? o.renderFrame(s['.name'], true, 0, o.renderWidget(s['.name'], 0, s[o.field]))
						: section.renderTextValue(s['.name'], o)));
				trEl.getBoundingClientRect = () => ({ left: 30, top: 80 });
				trEl.children.push(section.renderRowActions(s['.name'], null, trEl));
				return trEl;
			})
		]);
	}
	return { NamedSection: 'NamedSection', GridSection: 'GridSection', Flag: 'Flag', DummyValue: 'DummyValue',
		ListValue: 'ListValue', Value, Map: class {
		constructor(config) { this.config = config; this.sections = []; maps.push(this); }
		section(kind, type, sectionType, title) {
			const section = {
				kind, type, sectionType, title, map: this, options: [], modal: { value: 'unsaved modal input' },
				renderTextValue(id, option) {
					const value = option.textvalue(id);
					value.contains = target => value === target || find(value, node => node === target).length > 0;
					return E('td', { field: option.field }, value);
				},
				render() { return renderSection(this); },
				handleModalCancel() {},
				option(kind, field, title) {
					const option = optionDouble(uci, kind === Value ? 'Value' : kind, field, title);
					option.map = this.map;
					option.section = this;
					this.options.push(option);
					return option;
				},
				renderMoreOptionsModal(id) {
					this.modal = { id, value: 'unsaved modal input' };
					if (this.addModalOptions)
						this.addModalOptions(this.modal, id);
					if (type === 'subscription') {
						this.modal.options = this.options.filter(o => o.modalonly !== false).map(source => {
							const clone = optionDouble(uci, source.kind, source.field, source.title);
							for (const key of Object.keys(source))
								if (key !== 'widgets')
									clone[key] = source[key];
							clone.map = this.modal;
							clone.widget = clone.renderWidget(id, 0, uci.get('aetherproxy', id, clone.field));
							return clone;
						});
						this.modal.save = async () => {
							for (const option of this.modal.options)
								await option.parse(id);
							await uci.save();
							await this.map.reset();
							await this.handleModalCancel(this.modal, null, true);
						};
						this.modal.cancel = () => this.handleModalCancel(this.modal, null, false);
					}
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
					// LuCI supplies the sort handle alongside Edit/Delete when sortable.
					if (section.sortable)
						kinds.unshift('drag');
					const original = kinds.map(kind => {
						const button = E('button', {
							'class': kind === 'drag' ? 'cbi-button drag-handle center'
								: 'btn cbi-button cbi-button-' + kind,
							'click': kind === 'drag' ? null : event => kind === 'remove'
								? section.handleRemove(args[0], event)
								: section.renderMoreOptionsModal(args[0])
						}, kind === 'drag' ? '☰' : kind === 'remove' ? '删除' : '编辑');
						if (kind === 'drag') {
							// Keep native listeners separate from addEventListener, as in the browser.
							button.dragstart = ev => uciCalls.push(['handleDragStart', ev, args[2]]);
							button.touchend = ev => uciCalls.push(['handleTouchEnd', ev]);
							button.listeners = {};
							button.addEventListener = (type, fn) => {
								(button.listeners[type] ??= []).push(fn);
							};
						}
						button.classList = { contains: name => button.class.split(/\s+/).includes(name) };
						button.style = { cssText: 'min-width:0;' };
						return button;
					});
					builtins.push({ id: args[0], buttons: original, trEl: args[2] });
					// LuCI puts its buttons inside the last child of the action td.
					return E('td', { class: 'td cbi-section-table-cell nowrap cbi-section-actions' },
						[E('div', {}, original)]);
				}
			};
			section.children = section.options;
			this.sections.push(section);
			return section;
		}
		async save(...args) {
			uciCalls.push(['map.save', ...args]);
			for (const section of this.sections) {
				const ids = section.kind === 'NamedSection' ? [section.type]
					: uci.sections('aetherproxy', section.type).map(s => s['.name']);
				for (const id of ids)
					for (const option of section.options)
						if (section.kind === 'NamedSection' || (option.editable && !option.modalonly))
							await option.parse(id);
			}
			await args[0]?.();
			return this.render();
		}
		render() { return this.renderContents(); }
		reset() { return this.renderContents(); }
		async renderContents() {
			this.node ??= E('form', { 'class': 'cbi-map', map: this });
			contentChildren(this.node, await Promise.all(this.sections.map(section =>
				section.render ? section.render() : renderSection(section))));
			return this.node;
		}
	} };
}
async function harness(name, builtinKinds = name === 'nodes' ? ['remove'] : ['edit', 'remove']) {
	const calls = [], reads = [], turns = [], allMaps = [], uciCalls = [], builtins = [];
	const otherReads = [], allCalls = [];
	const statusCalls = [], statusReads = [], timers = new Map(), notices = [];
	let now = 0, timerID = 0, current = 'n_a';
	const general = [], main = { '.name': 'main' }, versionRead = deferred(), versionCalls = [];
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
			const section = [main, ...nodes, ...subs, ...general].find(s => s['.name'] === id);
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
			const section = uci.get(config, id);
			if (section)
				section[option] = value;
		},
		save: async () => { uciCalls.push(['save']); }
	};
	const form = formDouble(uci, allMaps, uciCalls, builtins, builtinKinds);
	const ap = {
		call: (method, params) => {
			allCalls.push([method, params]);
			if ((name === 'nodes' && method === 'sub_status') ||
				(name === 'subscriptions' && method === 'probe_results')) {
				const read = deferred();
				otherReads.push(read);
				return read.promise;
			}
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
	const { view, subscriptions } = loadNodesPage({
		view: { extend: o => o }, form, uci,
		ui: {
			Select: selectType(E),
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
		dom: { content: (target, content) => contentChildren(target, content),
			findClassInstance: node => node },
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
	return { name, page: name === 'nodes' ? view : subscriptions, view, subscriptions,
		get maps() { return allMaps.filter(map => map.sections[0].type === (name === 'nodes' ? 'node' : 'sub')); },
		allMaps, otherReads, allCalls, calls, reads, turns, uciCalls, builtins, ap, model, nodes, subs, uci,
		general, main, versionRead, versionCalls,
		setChanges: fn => { changes = fn; },
		statusCalls, statusReads, timers, notices, tick, setCurrent: id => { current = id; } };
}
async function render(h) {
	await h.view.load();
	h.fullRoot = h.view.fullRoot = await h.view.render();
	h.root = h.page.root;
	assert.equal(h.maps.length, 1);
	assert.equal(h.allMaps.length, 2, 'the merged page renders both maps');
	assert.deepEqual(h.calls, [], 'the complete page returns before RPC starts');
	assert.equal(h.turns.length, 2);
	for (const turn of h.turns.splice(0))
		turn();
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
	const source = h.page.grid.options.find(o => o.field === field);
	return source.modalonly ? h.page.grid.modal.options?.find(o => o.field === field) ?? source : source;
}
function renderOption(o, id, value) {
	return o.renderWidget(id, 0, value);
}
const intervalLabels = ['不自动更新', '12 小时', '1 天', '3 天', '7 天'];

test('T16.124: UA mocks render both real controls and update dropdown labels on late version reads', async () => {
	const h = await harness('subscriptions');
	h.subs[0].user_agent = 'Legacy/1 (+spaces)';
	await render(h);
	const common = h.page.generalOptions.user_agent;
	const generalWidget = renderOption(common, 'sub', undefined);
	const labels = widget => find(widget, node => node.tag === 'option').map(text);
	assert.deepEqual(labels(generalWidget), ['应用默认（读取中…）', 'v2rayN', '自定义…']);
	assert.equal(find(generalWidget, node => node.tag === 'input')[0].value, '');
	h.page.grid.renderMoreOptionsModal('s_a');
	const single = subOption(h, 'user_agent');
	assert.equal(find(single.widget, node => node.tag === 'select')[0].value, '@custom');
	assert.equal(find(single.widget, node => node.tag === 'input')[0].value, 'Legacy/1 (+spaces)');
	assert.equal(single.formvalue('s_a'), 'Legacy/1 (+spaces)', 'formvalue is the UA, never the mode');
	h.versionRead.resolve({ ok: true, version: '0.2.0-r99' });
	await flush();
	assert.equal(labels(generalWidget)[0], '应用默认（aether-proxy/0.2.0-r99）');
	assert.equal(labels(single.widget)[0], '跟随通用设置（aether-proxy/0.2.0-r99）');
	assert.equal(single.formvalue('s_a'), 'Legacy/1 (+spaces)');
	assert.deepEqual(h.uciCalls.filter(call => ['set', 'unset', 'save'].includes(call[0])), []);
});

for (const interval of ['0', '12', '24', '72', '168', '6']) {
	for (const via of ['auto', 'direct', 'proxy']) {
		for (const action of ['save', 'cancel']) {
			test(`T10.40 scenario 1: ${interval}/${via} modal ${action} preserves explicit values without writes`,
			async () => {
				const h = await harness('subscriptions');
				Object.assign(h.subs[0], { interval_hours: interval, fetch_via: via });
				await render(h);
				h.page.grid.renderMoreOptionsModal('s_a');
				assert.equal(subOption(h, 'interval_hours').formvalue('s_a'), interval);
				assert.equal(subOption(h, 'fetch_via').formvalue('s_a'), via);
				await h.page.grid.modal[action]();
				assert.deepEqual(h.uciCalls.filter(call => ['set', 'unset'].includes(call[0])), []);
			});
		}
	}
}

for (const ua of [undefined, 'Custom/1']) {
	test(`T10.40 scenarios 1/2: inherited dropdowns and UA=${ua ?? 'inherit'} save without set or unset`, async () => {
		const h = await harness('subscriptions');
		if (ua != null)
			h.subs[0].user_agent = ua;
		await render(h);
		h.page.grid.renderMoreOptionsModal('s_a');
		assert.equal(subOption(h, 'interval_hours').formvalue('s_a'), '');
		assert.equal(subOption(h, 'fetch_via').formvalue('s_a'), '');
		assert.equal(subOption(h, 'user_agent').formvalue('s_a'), ua ?? '');
		await h.page.grid.modal.save();
		assert.deepEqual(h.uciCalls.filter(call => ['set', 'unset'].includes(call[0])), []);
	});
}

test('T10.34 scenario 1: existing general section displays its values without writes', async () => {
	const h = await harness('subscriptions');
	h.general.push({ '.name': 'sub', '.type': 'sub', interval_hours: '72',
		fetch_via: 'proxy', user_agent: 'Custom/1' });
	await render(h);
	const section = h.maps[0].sections[0];
	assert.equal(section.kind, 'NamedSection');
	assert.equal(section.type, 'sub');
	assert.equal(section.sectionType, 'sub');
	assert.equal(h.maps[0].node.children[0].firstChild.textContent, '通用设置');
	for (const field of ['interval_hours', 'fetch_via', 'user_agent'])
		assert.equal(h.page.generalOptions[field].getUIElement('sub').value, h.general[0][field]);
	assert.deepEqual(h.uciCalls, [['load', 'aetherproxy']]);
	assert.equal(h.allMaps.length, 2);
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
	/* textvalue returns a node: a string would be written as innerHTML (T9.42). */
	const intervalValue = subOption(h, '_interval').textvalue('s_a');
	assert.equal(typeof intervalValue, 'object', 'textvalue returns a node, not a string');
	assert.equal(intervalValue.tag, 'span');
	assert.equal(intervalValue.children[0].tag, '#text', 'the value is a text child, not markup');
	assert.equal(text(intervalValue), '1 天（通用）');
	assert.equal(text(subOption(h, '_via').textvalue('s_a')), '自动（先直连，失败经当前节点）（通用）');
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
	assert.equal(text(interval.textvalue('s_a')), '3 天（通用）');
	assert.equal(text(via.textvalue('s_a')), '经当前节点（通用）');
	assert.equal(text(interval.textvalue('s_b')), '12 小时');
	assert.equal(text(via.textvalue('s_b')), '直连');
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
	assert.equal(typeof interval.textvalue('s_a'), 'object', 'textvalue keeps returning a node');
	assert.equal(interval.textvalue('s_a').tag, 'span');
	assert.equal(text(interval.textvalue('s_a')), '不自动更新（通用）');
	assert.equal(text(via.textvalue('s_a')), '直连（通用）');
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
	assert.equal(h.page.rowWrappers.get('s_a').attrs.title, '请先保存并应用');
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
	assert.equal(h.page.rowButtons.get('s_a').disabled, false, 'redraw discards the unsaved widget difference');
	assert.equal(h.page.rowButtons.get('s_b').disabled, false);
});

for (const stored of [undefined, '1', '0']) {
	for (const staged of [false, true]) {
		test(`T10.40 scenarios 3/4: enabled=${stored ?? 'default'} staged=${staged} round trip uses actual differences`,
		async () => {
			const h = await harness('subscriptions');
			if (stored != null)
				h.subs[0].enabled = stored;
			if (staged)
				h.setChanges(async () => ({ aetherproxy: [['set', 's_a', 'name', 'Staged name']] }));
			await render(h);
			const button = h.page.rowButtons.get('s_a');
			const wrapper = h.page.rowWrappers.get('s_a');
			assert.equal(wrapper.tag, 'span');
			assert.equal(wrapper.children[0], button);
			const checkbox = find(gridRow(h, 's_a'), node => node.tag === 'input')[0];
			const original = stored !== '0';
			const toggle = checked => checkbox.change({ target: { checked } });
			assert.equal(button.disabled, staged || !original);
			assert.equal(wrapper.attrs.title, staged ? '请先保存并应用' : original ? undefined : '订阅已停用');
			toggle(!original);
			assert.equal(button.disabled, true);
			assert.equal(wrapper.attrs.title, '请先保存并应用');
			await h.page.refresh_changes();
			assert.equal(button.disabled, true, 'a changes reply must preserve the live difference');
			toggle(original);
			assert.equal(button.disabled, staged || !original);
			assert.equal(wrapper.attrs.title, staged ? '请先保存并应用' : original ? undefined : '订阅已停用');
			assert.equal(h.page.pendingHint.textContent, staged ? '未应用的订阅不会更新' : '');
			assert.equal(h.page.rowButtons.get('s_b').disabled, false);
			assert.equal(h.page.updateAll.disabled, false);
			assert.deepEqual(h.uciCalls.filter(call => ['set', 'unset', 'save'].includes(call[0])), []);
			let jobs = 0;
			h.ap.run_job = async () => { jobs++; return { result: { subs: {} } }; };
			const pending = h.page.update(['s_a']);
			await flush();
			if (!staged && original)
				h.reads[1].resolve(success('subscriptions'));
			await pending;
			assert.equal(jobs, staged || !original ? 0 : 1, 'pending or saved-disabled subscriptions cannot update');
		});
	}
}

for (const stored of [undefined, '1', '0']) {
	for (const staged of [false, true]) {
		test(`T10.49 scenarios 1/2: enabled=${stored ?? 'default'} staged=${staged} controls button and wrapper hint`,
		async () => {
			const h = await harness('subscriptions');
			if (stored != null)
				h.subs[0].enabled = stored;
			if (staged)
				h.setChanges(async () => ({ aetherproxy: [['set', 's_a', 'name', 'Staged']] }));
			await render(h);
			for (let pass = 0; pass < 2; pass++) {
				const button = h.page.rowButtons.get('s_a');
				const wrapper = h.page.rowWrappers.get('s_a');
				assert.equal(button.disabled, staged || stored === '0');
				assert.equal(wrapper.children[0], button);
				assert.equal(wrapper.attrs.title, staged ? '请先保存并应用'
					: stored === '0' ? '订阅已停用' : undefined);
				assert.equal(Object.hasOwn(button.attrs, 'title'), false, 'hint belongs to the wrapper');
				await h.page.redraw();
				await flush();
			}
			if (stored === '0') {
				let jobs = 0;
				h.ap.run_job = async () => {
					jobs++;
					throw new Error('unexpected single-subscription job');
				};
				await h.page.update(['s_a']);
				assert.equal(jobs, 0, 'saved-disabled rows cannot start a job through direct invocation');
				const checkbox = find(gridRow(h, 's_a'), node => node.tag === 'input')[0];
				checkbox.change({ target: { checked: true } });
				await h.page.refresh_changes();
				assert.equal(h.page.rowButtons.get('s_a').disabled, true);
				assert.equal(h.page.rowWrappers.get('s_a').attrs.title, '请先保存并应用');
				assert.equal(h.subs[0].enabled, '0', 'turning on the widget does not save the subscription');
				await h.page.update(['s_a']);
				assert.equal(jobs, 0, 'an unsaved toggle cannot bypass the job guard');
			}
		});
	}
}

test('T10.49 scenario 3: Update all still runs with saved-disabled and pending subscriptions', async () => {
	const h = await harness('subscriptions');
	h.subs[0].enabled = '0';
	h.setChanges(async () => ({ aetherproxy: [['set', 's_b', 'name', 'Staged']] }));
	await render(h);
	const jobs = [];
	h.ap.run_job = async (...args) => {
		jobs.push(args);
		return { result: { subs: {} } };
	};
	assert.equal(h.page.updateAll.disabled, false);
	assert.ok([...h.page.rowButtons.values()].every(button => button.disabled));
	const pending = h.page.update([]);
	assert.equal(h.page.updateAll.disabled, true, 'only busy state disables Update all');
	await flush();
	assert.deepEqual(jobs, [['sub_update', []]], 'the backend still receives an unfiltered all-subscriptions job');
	h.reads[1].resolve(success('subscriptions'));
	await pending;
	assert.equal(h.page.updateAll.disabled, false);
	assert.equal(h.page.rowButtons.get('s_a').disabled, true);
	assert.equal(h.page.rowWrappers.get('s_a').attrs.title, '订阅已停用');
	assert.equal(h.page.rowButtons.get('s_b').disabled, true);
	assert.equal(h.page.rowWrappers.get('s_b').attrs.title, '请先保存并应用');
});

test('T10.49 scenario 4: card flag and multiline results keep inline value-column layout after refresh/reset',
async () => {
	const h = await harness('subscriptions');
	await render(h);
	const check = () => {
		const row = gridRow(h, 's_a');
		const cell = find(row, node => node.field === 'enabled')[0];
		const field = cell.querySelector('[data-field]');
		assert.equal(field.tag, 'div', 'exercise the SDK outer field that a widget-only wrapper missed');
		assert.equal(field.style.display, 'inline');
		const checkbox = cell.querySelector('.cbi-checkbox');
		assert.equal(checkbox.tag, 'div');
		assert.deepEqual(checkbox.style, { display: 'inline-flex', alignItems: 'center' });
		assert.equal(find(checkbox, node => node.tag === 'input').length, 1, 'keep the native flag widget');
		const result = h.page.resultCells.s_a;
		assert.equal(result.tag, 'span');
		assert.equal(result.style, 'display:inline-block; vertical-align:top');
		assert.ok(result.children.every(node => node.tag === 'br' || node.tag === 'span'),
			'all result lines share the value wrapper');
		return result;
	};
	const result = check();
	h.reads[0].resolve(success('subscriptions'));
	await flush();
	assert.equal(check(), result, 'late status fills the existing styled wrapper');
	assert.match(text(result), /成功，7 个节点/);
	assert.match(text(result), /秒前/);
	assert.match(text(result), /跳过 2/);
	assert.equal(find(result, node => node.tag === 'br').length, 2, 'recorded results retain their three lines');
	await h.maps[0].render();
	await flush();
	check();
	await h.page.redraw();
	await flush();
	check();
});

for (const name of ['nodes', 'subscriptions']) {
	test(`T10.16 ${name} scenario 1: load reads only UCI`, async () => {
		const h = await harness(name);
		await h.view.load();
		assert.deepEqual(h.uciCalls,
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
		const labels = name === 'nodes' ? ['检测全部', '检测', '导入'] : ['全部更新', '立即更新', '添加'];
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
	assert.equal(details.length, 1, 'only bulk import is inside the node region');
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
	const actions = actionRow(h.root, ['检测全部', '删除所选', '添加节点'], [h.page.progressEl]);
	const toolbar = find(h.root, node => node.children?.includes(actions))[0];
	const content = find(h.root, node => (node.children ?? []).includes(h.maps[0].node))[0];
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
	assert.equal(h.maps.length, 2, 'an added node rebuilds the node region');
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
	const toolbar = find(h.root, node => node.class === 'aether-section-toolbar')[0];
	assert.ok(toolbar.children.includes(row));
	const parent = find(h.root, node => node.children?.includes(toolbar))[0];
	assert.equal(parent.children[parent.children.indexOf(toolbar) + 1], h.maps[0].node,
		'no import block separates the table toolbar from its table');
	const importRow = actionRow(h.root, ['导入']);
	const importBox = find(h.root, node => (node.children ?? []).includes(h.page.importText))[0];
	assert.equal(importBox.children.at(-1), importRow);
	assert.equal(importBox.children.at(-2), h.page.importText);
});

test('T16.23: subscription Update all and Add share a row before the table after redraw',
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
		const block = h.maps.at(-1).node.children[1];
		assert.equal(block.children[1].children[1], row, 'actions share the description line');
		assert.equal(block.children[2], h.page.details, 'only the table is collapsible');
	}
});

test('T10.44 scenario 1: subscription errors, progress and multiline results stay marginless beside actions',
async () => {
	const h = await harness('subscriptions');
	await render(h);
	h.reads[0].resolve({ ok: false, code: 'TIMEOUT', detail: 'offline' });
	await flush();
	assert.match(text(h.page.statusError), /TIMEOUT: offline/);
	const feedback = () => [h.page.statusError, h.page.progress, h.page.summary, h.page.pendingHint];
	const check = () => {
		actionRow(h.root, ['全部更新', '添加'], feedback());
		marginlessMessages(feedback());
	};
	check();
	const job = deferred();
	h.ap.job_progress = target => {
		target.textContent = '正在更新订阅…（已用 0 秒）';
		return { stop() { target.textContent = ''; } };
	};
	h.ap.run_job = () => job.promise;
	const pending = h.page.update([]);
	assert.match(text(h.page.progress), /已用 0 秒/);
	check();
	job.resolve({ state: 'ok', result: { subs: {
		s_a: { ok: true, added: 1 }, s_b: { ok: true, added: 2 }
	} } });
	await flush();
	h.reads[1].resolve(success('subscriptions'));
	await pending;
	assert.equal(h.page.summary.children.length, 2, 'both subscription results are rendered');
	assert.match(text(h.page.summary), /Alpha: 新增 1.*Beta: 新增 2/);
	assert.equal(text(h.page.progress), '');
	check();
	await h.page.redraw();
	check();
});

test('T10.44 scenario 2: subscription action buttons stay nowrap without a fixed column width after redraw',
async () => {
	const h = await harness('subscriptions');
	await render(h);
	for (const redraw of [false, true]) {
		if (redraw)
			await h.page.redraw();
		for (const id of ['s_a', 's_b']) {
			const cell = gridRow(h, id).lastChild;
			nowrapActions(cell, ['立即更新', '编辑', '删除']);
			const originals = h.builtins.filter(row => row.id === id).at(-1).buttons;
			for (const button of originals) {
				assert.ok(buttons(cell).includes(button), 'keep built-in button identity and handlers');
				assert.match(button.style, /min-width:0;/, 'keep existing inline button styles');
			}
			const wrapper = h.page.rowWrappers.get(id);
			assert.equal(wrapper.children[0], h.page.rowButtons.get(id), 'keep the disabled-button tooltip wrapper');
		}
	}
});

test('T10.28 scenario 1: subscription grid has one Name column and no section-name column', async () => {
	const h = await harness('subscriptions');
	await render(h);
	assert.equal(h.page.grid.anonymous, true);
	const header = find(h.root, node => node.tag === 'tr')[0];
	assert.equal(header.attrs['data-title'], null);
	assert.deepEqual(find(header, node => node.tag === 'th').map(text),
		['启用', '名称', '地址', '更新间隔', '获取方式', '自动切换', '最近一次结果']);
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
	assert.deepEqual(options.slice(0, -1).map(o => text(o.textvalue(id))),
		['New saved name', 'https://new.example/…', '不自动更新', '经当前节点', '']);
	assert.match(text(options.at(-1).textvalue(id)), /成功，13 个节点/);
	h.uci.remove('aetherproxy', id);
	for (const option of options)
		assert.equal(text(option.textvalue(id)), '–', option.field + ' tolerates a deleted section');
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
		assert.equal(h.page.rowWrappers.get('s_a').attrs.title, '请先保存并应用');
		assert.equal(h.page.rowButtons.get('s_b').disabled, false);
		assert.equal(h.page.updateAll.disabled, false);
		assert.equal(text(h.page.pendingHint), '未应用的订阅不会更新');
		await h.page.update(['s_a']);
		assert.equal(h.reads.length, 1, 'direct invocation cannot bypass the pending guard');
		h.setChanges(async () => { throw new Error('uci changes failed'); });
		await h.page.redraw();
		await flush();
		assert.ok([...h.page.rowButtons.values()].every(button => !button.disabled));
		assert.equal(Object.hasOwn(h.page.rowWrappers.get('s_a').attrs, 'title'), false);
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
			assert.equal(h.page.nodeGrid.sortable, true, 'use LuCI built-in sorting');
			const expected = id === 'n_a' ? ['☰', '检测', '编辑'] : ['☰', '检测', '编辑', '删除'];
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
test('T10.76: desktop drag image uses the whole row and preserves native drag/touch handlers', async () => {
	const h = await harness('nodes');
	await render(h);
	for (const id of ['n_a', 'n_b']) {
		const trEl = gridRow(h, id);
		const builtin = h.builtins.find(row => row.id === id);
		assert.equal(builtin.trEl, trEl, 'forward the row to the parent renderer');
		const handle = builtin.buttons.find(button => button.classList.contains('drag-handle'));
		const images = [];
		const ev = { clientX: 245, clientY: 96, dataTransfer: {
			setDragImage: (...args) => images.push(args)
		} };
		handle.dragstart(ev);
		assert.deepEqual(h.uciCalls.at(-1), ['handleDragStart', ev, trEl]);
		assert.equal(handle.listeners.dragstart?.length, 1, 'add a listener, do not replace native dragstart');
		for (const listener of handle.listeners.dragstart)
			listener(ev);
		assert.deepEqual(images, [[trEl, 215, 16]], 'pointer offset is relative to row left/top');
		handle.touchend(ev);
		assert.deepEqual(h.uciCalls.at(-1), ['handleTouchEnd', ev]);
		assert.equal(handle.listeners.touchend, undefined, 'no custom touch drag image');
		assert.equal(images.length, 1);
	}
});

test('T10.76: older SDK callers without trEl resolve the attached row at dragstart', async () => {
	const h = await harness('nodes');
	await render(h);
	const trEl = gridRow(h, 'n_b');
	const tdEl = h.page.nodeGrid.renderRowActions('n_b', null);
	tdEl.closest = selector => {
		assert.equal(selector, '.tr');
		return trEl;
	};
	const handle = buttons(tdEl).find(button => button.classList.contains('drag-handle'));
	const images = [];
	for (const listener of handle.listeners.dragstart)
		listener({ clientX: 270, clientY: 105, dataTransfer: {
			setDragImage: (...args) => images.push(args)
		} });
	assert.deepEqual(images, [[trEl, 240, 25]]);
});

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
		po['This node comes from a subscription; edits will be overwritten at the next subscription update.']
			+ '<br>' + po['Fields marked with * are required.']);
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
	const placeholder = h.page.resultCells.s_a;
	assert.equal(text(placeholder), '尚未更新');
	assert.equal(placeholder.children.length, 1, 'no line break or missing-timestamp dash');
	assert.equal(placeholder.firstChild.style, 'white-space:nowrap');
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

// T10.71: node-page switch/watch tests removed; Overview owns this interaction.

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
	assert.deepEqual(headers, ['', '名称', '协议', '传输 / 安全层', '来源', '自动切换', 'TCP 可达／延迟']);
	assert.ok(!section.options.some(option => option.field === '_address'));
	for (const id of ['n_a', 'n_b']) {
		const edit = buttons(actions(h, id)).find(node => text(node) === '编辑');
		assert.ok(edit, 'Edit must be generated even when the parent initially only supplied Remove');
		await edit.click({ currentTarget: edit });
		assert.equal(section.modal.id, id);
		const modal = section.modal.node;
		/* The section description is page-authored markup: luci-base renders it
		 * through innerHTML, so a text-only comparison cannot see the <br>. */
		assert.equal(modal.children[0].innerHTML, id === 'n_a' ? '带 * 的为必填项。'
			: '此节点来自订阅，下次更新订阅时修改会被覆盖<br>带 * 的为必填项。');
		for (const field of ['address', 'port'])
			assert.ok(section.options.some(option => option.field === field && option.modalonly));
		assert.match(text(modal), /地址端口/);
	}
	await buttons(actions(h, 'n_a')).find(node => text(node) === '编辑').click({});
	assert.equal(section.modal.node.children[0].innerHTML, '带 * 的为必填项。',
		'manual modal must not inherit the previous subscription hint');
});

test('T16.23: only the current name starts with a labelled green dot; stale names stay faded', async () => {
	const h = await harness('nodes');
	h.nodes[1].stale = '1';
	await render(h);
	const cell = (id, field) => find(gridRow(h, id), node => node.field === field)[0];
	const mark = cell('n_a', '_label').firstChild.firstChild;
	assert.equal(mark.class, 'aether-node-current');
	assert.equal(mark.title, '当前节点');
	assert.equal(mark.attrs['aria-label'], '当前节点');
	assert.deepEqual(find(h.root, node => node.class === 'aether-node-current'), [mark]);
	assert.equal(find(h.root, node => node.field === '_current').length, 0);
	assert.doesNotMatch(text(h.root), /选用/);
	const styles = () => find(h.fullRoot, node => node.id === 'aether-nodes-page-style');
	assert.equal(styles().length, 1);
	assert.match(text(styles()[0]), /@keyframes aether-node-pulse/);
	assert.match(text(styles()[0]), /@media \(prefers-reduced-motion: reduce\)[\s\S]*animation: none/);
	await h.view.redrawNodes();
	assert.equal(styles().length, 1);
	assert.equal(text(cell('n_b', '_label')), 'Node B（已失效）');
	assert.equal(cell('n_b', '_label').firstChild.class, 'aether-node-name');
	assert.equal(cell('n_b', '_label').firstChild.lastChild.style, 'opacity:0.6');
	assert.equal(cell('n_a', '_label').firstChild.lastChild.style, null);
	assert.ok(text(h.root).includes('切换节点请到概览页选择后点「应用」。'));
	assert.ok(!buttons(h.root).some(button => text(button) === '设为当前'));
	assert.equal(h.page.handleSetCurrent, undefined);
});

test('T16.23: only disabled nodes cause a read-only Enabled column to render', async () => {
	const h = await harness('nodes');
	await render(h);
	const headers = () => find(h.root, node => node.tag === 'th').map(text);
	const cells = () => find(h.root, node => node.field === '_enabled');
	const option = () => h.view.nodeGrid.children.find(child => child.option === '_enabled');
	assert.ok(!headers().includes('启用'));
	assert.equal(cells().length, 0);
	assert.equal(option(), undefined);

	h.nodes[1].disabled = '1';
	await h.view.nodeMap.reset();
	assert.deepEqual(headers().slice(0, 3), ['', '启用', '名称']);
	assert.deepEqual(cells().map(text), ['启用', '已停用']);
	assert.equal(option().kind, 'DummyValue');
	assert.notEqual(option().editable, true);

	h.nodes.splice(1, 1);
	await h.view.nodeMap.reset();
	assert.ok(!headers().includes('启用'));
	assert.equal(cells().length, 0);
	assert.equal(option(), undefined);
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
		assert.equal(h.page.selectionBoxes.n_a.title, '当前节点不可删除，请先在概览页切换到其他节点。');
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

test('T16.23: three shared sections contain their own headings, descriptions, tools and bodies', async () => {
	const h = await harness('nodes');
	await render(h);
	const page = h.view;
	assert.equal(h.fullRoot.children[0].textContent, '节点与订阅');
	const { root, map: subMap, details } = h.subscriptions;
	assert.deepEqual(h.fullRoot.children.slice(2), [root, page.root]);
	assert.deepEqual(root.children, [subMap.node, h.subscriptions.failoverStyle]);
	assert.deepEqual(subMap.sections.map(section => section.type), ['sub', 'subscription']);
	const [general, subscriptionBlock] = subMap.node.children;
	assert.equal(general.tag, 'div');
	assert.equal(general.children[0].tag, 'h3');
	assert.equal(general.children[0].textContent, '通用设置');
	const [subscriptionHeading, subscriptionToolbar, list] = subscriptionBlock.children;
	assert.equal(subscriptionHeading.tag, 'h3');
	assert.equal(subscriptionHeading.textContent, '订阅');
	assert.equal(subscriptionToolbar.class, 'aether-section-toolbar');
	assert.equal(subscriptionToolbar.firstChild.class, 'cbi-map-descr');
	assert.equal(subscriptionToolbar.lastChild.class, 'aether-section-actions');
	assert.deepEqual(buttons(subscriptionToolbar.lastChild).map(text), ['全部更新', '添加']);
	assert.equal(list, details);
	assert.equal(details.tag, 'details');
	assert.equal(details.open, true);
	assert.equal(details.firstChild.tag, 'summary');
	assert.equal(details.firstChild.textContent, '订阅清单');
	assert.match(details.lastChild.textContent, /Alpha.*Beta/);
	assert.doesNotMatch(details.textContent, /全部更新|通用设置/, 'collapse excludes tools and general settings');
	const tools = actionRow(page.root, ['检测全部', '删除所选', '添加节点']);
	const region = find(page.root, node => (node.children ?? []).includes(page.nodeMap.node))[0];
	for (const block of [general, subscriptionBlock, region]) {
		assert.equal(block.class, 'cbi-section');
		assert.equal(block.style, general.style);
	}
	const nodeToolbar = region.children[1];
	assert.equal(nodeToolbar.class, 'aether-section-toolbar');
	assert.equal(nodeToolbar.firstChild.class, 'cbi-map-descr');
	assert.equal(nodeToolbar.lastChild, tools);
	assert.deepEqual(region.children.slice(2), [page.nodeMap.node, page.importDetails]);
	assert.equal(page.importDetails.open, false);
	assert.deepEqual(find(h.fullRoot, node => node.tag === 'h2').map(text), ['节点与订阅'],
		'one page heading; the node region uses a section heading');
	assert.deepEqual(find(page.root, node => node.tag === 'h3').map(text).slice(0, 1), ['节点']);
	assert.deepEqual(find(h.fullRoot, node => node.class === 'cbi-map').map(node => node.map),
		[subMap, page.nodeMap], 'no extra wrapper is mistaken for a form by the footer');
	assert.deepEqual(h.allCalls.map(call => call[0]), ['version', 'sub_status', 'probe_results'],
		'first-paint requests follow the displayed subscription-then-node order');
});

for (const ids of [['s_a'], []]) {
	test(`T10.37 scenario 4: ${ids.length ? 'single' : 'all'} subscription update shows new nodes without losing inputs`,
	async () => {
		const h = await harness('subscriptions');
		await render(h);
		const block = h.subscriptions, page = h.view;
		const common = block.generalOptions;
		common.interval_hours.setFormValue('sub', '72');
		common.fetch_via.setFormValue('sub', 'proxy');
		common.user_agent.setFormValue('sub', 'Unsaved/UA');
		const flag = find(gridRow(h, 's_b'), node => node.tag === 'input')[0];
		flag.checked = false;
		flag.change({ target: flag });
		block.grid.renderMoreOptionsModal('s_a');
		block.grid.modal.value = 'Unsaved modal text';
		const modal = block.grid.modal, form = block.map.node;
		block.details.open = false;
		page.importDetails.open = true;
		page.importText.value = '\n vless://unsaved-import \n';
		page.importResult.textContent = 'Previous import result';
		const job = deferred();
		h.ap.run_job = (kind, args) => {
			assert.equal(kind, 'sub_update');
			assert.deepEqual(args, ids);
			return job.promise;
		};
		const pending = block.update(ids);
		assert.equal(block.map.node, form, 'starting a job cannot replace live subscription widgets');
		assert.equal(block.generalOptions, common);
		h.nodes.push({ '.name': 'n_fresh', label: 'Fresh subscription node', source: 's_a' });
		job.resolve({ state: 'ok', result: { subs: { s_a: { ok: true, added: 1 } } } });
		await flush();
		h.reads[1].resolve(success('subscriptions'));
		await pending;
		assert.match(page.nodeMap.node.textContent, /Fresh subscription node/);
		assert.equal(block.map.node, form, 'finishing a job only fills result cells in the subscription form');
		assert.equal(block.generalOptions, common);
		assert.deepEqual(block.general_values(), {
			interval_hours: '72', fetch_via: 'proxy', user_agent: 'Unsaved/UA'
		});
		assert.equal(block.grid.modal, modal);
		assert.equal(modal.value, 'Unsaved modal text');
		assert.equal(flag.checked, false);
		assert.equal(subOption(h, 'enabled').formvalue('s_b'), '0');
		assert.equal(block.rowButtons.get('s_b').disabled, true, 'local pending flag survives refresh');
		assert.equal(block.details.open, false);
		assert.equal(page.importDetails.open, true);
		assert.equal(page.importText.value, '\n vless://unsaved-import \n');
		assert.equal(page.importResult.textContent, 'Previous import result');
		assert.match(block.resultCells.s_a.textContent, /成功，7 个节点/);
		assert.doesNotMatch(block.summary.textContent, /操作失败/);
		assert.equal(h.uciCalls.some(call => ['set', 'save', 'map.save'].includes(call[0])), false,
			'refresh never saves unrelated inputs to retain them');
	});
}

test('T10.37 scenarios 3/4: node reload keeps subscription widgets and recreates the legacy common section',
async () => {
	const h = await harness('nodes');
	await render(h);
	const block = h.subscriptions, common = block.generalOptions, form = block.map.node;
	common.user_agent.setFormValue('sub', 'Not saved yet');
	h.uci.unload = config => {
		h.uciCalls.push(['unload', config]);
		h.general.length = 0;
	};
	const pending = h.view.rebuild();
	await flush();
	h.reads[1].resolve(success('nodes'));
	await pending;
	assert.equal(block.map.node, form);
	assert.equal(block.generalOptions, common);
	assert.equal(common.user_agent.formvalue('sub'), 'Not saved yet');
	assert.deepEqual(h.general, [{ '.name': 'sub', '.type': 'sub' }]);
	assert.equal(h.uciCalls.filter(call => call[0] === 'add').length, 2,
		'node imports use the combined load path after unloading a legacy configuration');
	assert.ok(h.fullRoot.children.includes(block.root));
	assert.equal(h.uciCalls.some(call => call[0] === 'save'), false);
});

test('T10.37 scenario 3: subscription redraw leaves node form and bulk-import controls mounted', async () => {
	const h = await harness('nodes');
	await render(h);
	const page = h.view, nodeMap = page.nodeMap, form = nodeMap.node;
	const label = page.nodeGrid.options.find(option => option.field === 'label');
	label.setFormValue('n_b', 'Unfinished node edit');
	page.importText.value = 'vless://keep-this';
	page.importDetails.open = true;
	const input = page.importText;
	await h.subscriptions.redraw();
	assert.equal(page.nodeMap, nodeMap);
	assert.equal(page.nodeMap.node, form);
	assert.equal(label.formvalue('n_b'), 'Unfinished node edit');
	assert.equal(page.importText, input);
	assert.equal(input.value, 'vless://keep-this');
	assert.equal(page.importDetails.open, true);
	assert.equal(find(h.fullRoot, node => node === form).length, 1);
});

test('T10.37 defensive: node repaint failure preserves subscription input and restores update buttons', async () => {
	const h = await harness('subscriptions');
	await render(h);
	const block = h.subscriptions, form = block.map.node, common = block.generalOptions;
	common.user_agent.setFormValue('sub', 'Keep after failure');
	h.view.buildPage = async () => { throw new Error('node repaint failed'); };
	const pending = block.update([]);
	await flush();
	h.reads[1].resolve(success('subscriptions'));
	await pending;
	assert.equal(block.busy, false);
	assert.equal(block.updateAll.disabled, false);
	assert.ok([...block.rowButtons.values()].every(button => !button.disabled));
	assert.equal(block.summary.textContent, '操作失败：node repaint failed');
	assert.equal(block.map.node, form);
	assert.equal(common.user_agent.formvalue('sub'), 'Keep after failure');
});

test('T10.37 scenario 5: page Save saves both maps and their pending settings', async () => {
	const h = await harness('nodes');
	await render(h);
	const block = h.subscriptions;
	block.generalOptions.interval_hours.setFormValue('sub', '168');
	block.generalOptions.fetch_via.setFormValue('sub', 'direct');
	block.generalOptions.user_agent.setFormValue('sub', 'Save both/1');
	block.grid.options.find(option => option.field === 'enabled').setFormValue('s_b', '0');
	await h.view.handleSave();
	assert.equal(h.uciCalls.filter(call => call[0] === 'map.save').length, 2);
	assert.equal(h.uci.get('aetherproxy', 'sub', 'interval_hours'), '168');
	assert.equal(h.uci.get('aetherproxy', 'sub', 'fetch_via'), 'direct');
	assert.equal(h.uci.get('aetherproxy', 'sub', 'user_agent'), 'Save both/1');
	assert.equal(h.uci.get('aetherproxy', 's_b', 'enabled'), '0');
});

const failoverRisk = '频繁切换出口 IP 可能导致部分网站/应用触发风控，建议只在必要时开启。';

function toggleFailover(h, checked) {
	const checkbox = h.subscriptions.generalOptions.failover.getUIElement('sub').children[0];
	checkbox.checked = checked;
	checkbox.change({ target: checkbox });
}

test('T16.18: general Flag defaults off and does not write on unchanged Save', async () => {
	const h = await harness('nodes');
	await render(h);
	const flag = h.subscriptions.generalOptions.failover;
	const writes = () => h.uciCalls.filter(call => call[3] === 'failover');
	assert.equal(flag.kind, 'Flag');
	assert.equal(flag.formvalue('sub'), '0');
	assert.equal(flag.getUIElement('sub').children[0].checked, false);
	const general = h.subscriptions.map.node.children[0];
	const inline = find(general, node => node.class === 'aether-failover-setting')[0];
	assert.equal(inline.firstChild, flag.getUIElement('sub'));
	assert.equal(inline.lastChild.textContent, '当前节点不可达时自动切换。');
	assert.equal(flag.getUIElement('sub').title, inactiveFailover);
	await h.view.handleSave();
	assert.equal(h.uciCalls.some(call => call[3] === 'failover'), false);
	assert.equal(Object.hasOwn(h.general[0], 'failover'), false);
	toggleFailover(h, true);
	assert.equal(h.uci.get('aetherproxy', 'sub', 'failover'), undefined, 'preview does not stage a write');
	h.subscriptions.details.open = false;
	await h.subscriptions.map.reset();
	assert.equal(h.subscriptions.generalOptions.failover.formvalue('sub'), '0', 'Reset discards the unsaved Flag');
	assert.equal(h.subscriptions.details.open, false, 'map re-render preserves collapsed details');
	toggleFailover(h, true);
	await h.view.handleSave();
	assert.deepEqual(writes(), [['set', 'aetherproxy', 'sub', 'failover', '1']]);
	toggleFailover(h, false);
	await h.view.handleSave();
	assert.deepEqual(writes().at(-1), ['unset', 'aetherproxy', 'sub', 'failover']);
	assert.equal(Object.hasOwn(h.general[0], 'failover'), false);
});

const inactiveFailover = '总开关未开启，当前不生效';
const failoverCell = (h, id) => find(find(h.fullRoot, node => node.sid === id)[0],
	node => node.field === '_failover')[0];
const failoverBox = (h, id) => failoverCell(h, id).firstChild;
const failoverWrites = h => h.uciCalls.filter(call => call[3] === 'failover_nodes');

const failoverDescription = h => find(h.fullRoot, node => node.class === 'aether-failover-setting')[0].lastChild;
const failoverSwitchTitle = h => h.subscriptions.generalOptions.failover.getUIElement('sub').title;
const failoverEffective = '当前节点不可达时自动切换。';
const failoverUnlisted = '当前节点未加入名单，自动切换暂不生效。';
const currentNodeHint = '当前节点；未加入名单时不会触发自动切换。';

test('T16.27: failover risk warning shares the hint behavior without toggling the switch', async () => {
	for (const value of ['0', '1']) {
		const h = await harness('nodes');
		h.general.push({ '.name': 'sub', failover: value });
		await render(h);
		const general = h.subscriptions.map.node.firstChild;
		const row = find(general, node => node['data-name'] === 'failover')[0];
		const label = row.firstChild;
		assert.equal(label.tag, 'label');
		assert.equal(label.class, 'cbi-value-title');
		assert.equal(label.firstChild.textContent, '自动切换');
		const icon = label.lastChild;
		assert.equal(icon.tag, 'span');
		assert.equal(icon.class, 'aether-warning');
		const [glyph, bubble] = icon.children;
		assert.equal(glyph.textContent, '⚠');
		assert.equal(bubble.textContent, failoverRisk);
		assert.equal(icon.getAttribute('role'), 'button');
		assert.equal(icon.getAttribute('tabindex'), '0');
		assert.equal(icon.getAttribute('title'), failoverRisk);
		assert.equal(icon.getAttribute('aria-label'), '自动切换风险说明');
		const visible = expected => {
			assert.equal(icon.getAttribute('aria-expanded'), String(expected));
			assert.equal(bubble.hidden, !expected);
		};
		visible(false);
		const rules = h.subscriptions.failoverStyle.textContent.split('.aether-failover-title')[0];
		assert.match(rules, /var\(--warn-color-high, #e0a800\)/);
		assert.match(rules, /var\(--warn-color-high, #f0b429\)/);
		assert.doesNotMatch(rules, /--primary/);
		assert.deepEqual(find(general, node => node.class === 'aether-warning'), [icon]);
		assert.ok(!failoverSwitchTitle(h).includes(failoverRisk));
		icon.focus();
		visible(true);
		icon.blur();
		visible(false);
		const cancelled = [];
		const event = {
			stopPropagation: () => cancelled.push('propagation'),
			preventDefault: () => cancelled.push('default')
		};
		icon.pointerdown();
		icon.focus();
		icon.click(event);
		visible(true);
		icon.pointerdown();
		icon.click(event);
		visible(false);
		assert.deepEqual(cancelled, ['default', 'propagation', 'default', 'propagation']);
		for (const [key, open] of [['Enter', true], [' ', false], [' ', true], ['Escape', false]]) {
			icon.keydown({ ...event, key });
			visible(open);
		}
		assert.equal(h.subscriptions.failover_enabled(), value === '1');
	}
});

test('T16.25: switch and membership drafts update the description and only the unchecked current row in place', async () => {
	const h = await harness('nodes');
	await render(h);
	const description = failoverDescription(h);
	const current = failoverBox(h, 'n_a');
	const other = failoverBox(h, 'n_b');
	const subscription = failoverBox(h, 's_a');

	const assertOff = () => {
		assert.equal(description.textContent, failoverEffective);
		assert.equal(description.style, 'opacity:0.65');
		assert.equal(failoverSwitchTitle(h), inactiveFailover);
		assert.equal(current.title, '自动切换 — ' + inactiveFailover + ' — ' + currentNodeHint);
		assert.equal(other.title, '自动切换 — ' + inactiveFailover);
		assert.equal(subscription.title, '自动切换 — ' + inactiveFailover);
	};
	const assertUnlisted = () => {
		assert.equal(description.textContent, failoverUnlisted);
		assert.equal(description.style, '');
		assert.equal(failoverSwitchTitle(h),
			'当前节点「Node A」不在自动切换名单中。请将其加入名单，或关闭总开关。');
		assert.equal(current['aria-checked'], 'false');
		assert.equal(current.title, '自动切换 — ' + currentNodeHint);
		assert.equal(other.title, '自动切换');
		assert.equal(subscription.title, '自动切换');
	};

	assertOff();
	toggleFailover(h, true);
	assertUnlisted(); // Empty list.
	await other.click();
	assertUnlisted(); // List contains only another node.
	await current.click();
	assert.equal(description.textContent, failoverEffective);
	assert.equal(failoverSwitchTitle(h), '');
	assert.equal(current['aria-checked'], 'true');
	assert.equal(current.title, '自动切换');
	assert.equal(other.title, '自动切换');
	await current.click();
	assertUnlisted();
	toggleFailover(h, false);
	assertOff();
	assert.equal(failoverDescription(h), description, 'draft edits must not replace the description');
	assert.equal(failoverBox(h, 'n_a'), current, 'draft edits must not replace the control');
	assert.deepEqual(failoverWrites(h), []);
});

test('T16.25: a disabled current node takes precedence over missing membership while the switch is on', async () => {
	const h = await harness('nodes');
	h.general.push({ '.name': 'sub', failover: '1' });
	h.main.failover_nodes = ['n_a'];
	h.nodes[0].disabled = '1';
	await render(h);
	const disabled = '当前节点已停用，自动切换暂不生效。';
	assert.equal(failoverDescription(h).textContent, disabled);
	assert.equal(failoverSwitchTitle(h), disabled);
	await failoverBox(h, 'n_a').click();
	assert.equal(failoverDescription(h).textContent, disabled);
	assert.equal(failoverSwitchTitle(h), disabled);
	toggleFailover(h, false);
	assert.equal(failoverDescription(h).textContent, failoverEffective);
	assert.equal(failoverSwitchTitle(h), inactiveFailover);
});

function assertFailover(h, id, pressed, label, active = false) {
	const box = failoverBox(h, id);
	assert.equal(box.tag, 'span');
	assert.equal(box.role, 'checkbox');
	assert.equal(box.tabindex, '0');
	assert.equal(box['aria-label'], '自动切换');
	assert.equal(box['aria-checked'], pressed);
	const state = { 'true': 'on', 'false': 'off', mixed: 'mixed' }[pressed];
	assert.equal(box.class, `aether-tri aether-tri--${state}${active ? '' : ' aether-tri--inactive'}`);
	const mixed = pressed === 'mixed';
	assert.deepEqual(box.children.map(child => child.class),
		mixed ? ['aether-tri-box', 'aether-tri-check', 'aether-tri-count'] : ['aether-tri-box', 'aether-tri-check']);
	for (const child of box.children.slice(0, 2)) {
		assert.equal(child.tag, 'span');
		assert.equal(child['aria-hidden'], 'true');
	}
	assert.equal(box.title, (pressed === 'mixed' ? label : '自动切换') +
		(active ? '' : ' — ' + inactiveFailover));
	assert.equal(failoverCell(h, id).textContent, mixed ? label.split(' · ')[1] : '');
	assert.equal(box['aria-disabled'], null);
}

test('T16.22: subscription off, partial 8/10 and on; batches and confirmation are draft-only', async () => {
	const h = await harness('nodes');
	const ids = ['n_b', ...Array.from({ length: 9 }, (_, i) => 'n_extra_' + i)];
	h.nodes.push(...ids.slice(1).map(id => ({ '.name': id, source: 's_a' })));
	h.main.failover_nodes = ['n_a', ...ids.slice(0, 8)];
	await render(h);
	assertFailover(h, 's_a', 'mixed', '半选 · 8/10');
	assertFailover(h, 's_b', 'false', '关');
	assertFailover(h, ids.at(-1), 'false', '关');
	toggleFailover(h, true);
	assertFailover(h, 's_a', 'mixed', '半选 · 8/10', true);
	assertFailover(h, ids.at(-1), 'false', '关', true);
	let confirm = false;
	const confirmations = [];
	h.ap.confirm = async options => { confirmations.push(options); return confirm; };
	const button = failoverBox(h, 's_a');
	const ua = h.subscriptions.generalOptions.user_agent;
	ua.setFormValue('sub', 'Keep this draft');
	await button.click();
	assertFailover(h, 's_a', 'true', '开', true);
	assertFailover(h, ids.at(-1), 'true', '开', true);
	assert.equal(confirmations.length, 0, 'partial click adds all without confirmation');
	await button.click();
	assertFailover(h, 's_a', 'true', '开', true);
	assert.equal(confirmations[0].text, '从自动切换名单移除 10 个节点？');
	confirm = true;
	await button.click();
	assertFailover(h, 's_a', 'false', '关', true);
	assertFailover(h, ids[0], 'false', '关', true);
	assertFailover(h, 'n_a', 'true', '开', true);
	assert.equal(failoverBox(h, 's_a'), button, 'repaint in place');
	assert.equal(ua.formvalue('sub'), 'Keep this draft');
	assert.deepEqual(failoverWrites(h), []);
	await h.view.handleSave();
	assert.deepEqual(failoverWrites(h), [['set', 'aetherproxy', 'main', 'failover_nodes', ['n_a']]]);
	await failoverBox(h, 's_a').click();
	assertFailover(h, 's_a', 'true', '开', true);
	await h.view.handleSave();
	assert.deepEqual(h.main.failover_nodes, ['n_a', ...ids]);
});

test('T16.26: click, Space, Enter, and cell background use the same toggle once', async () => {
	const h = await harness('nodes');
	await render(h);
	const cell = failoverCell(h, 'n_b');
	const box = cell.firstChild;
	const toggles = [];
	h.subscriptions.toggle_failover = async (...args) => { toggles.push(args); };
	let prevented = 0;
	const press = (key, repeat = false) => box.keydown({ key, repeat, preventDefault: () => { prevented++; } });
	await box.click();
	await press(' ');
	await press('Enter');
	await cell.click({ target: cell });
	// Simulate a mark click followed by bubbling in the DOM double.
	await box.click({ target: box.firstChild });
	await cell.click({ target: box.firstChild });
	await press(' ', true);
	await press('Tab');
	assert.deepEqual(toggles, Array.from({ length: 5 }, () => ['node', 'n_b']));
	assert.equal(prevented, 3, 'suppress scrolling and repeat activation, but allow Tab');
});

test('T16.26: failover no longer uses native mixed-state styling or assignment', () => {
	const block = fs.readFileSync(path.join(RES, 'aether-proxy/subscriptions-block.js'), 'utf8');
	const view = fs.readFileSync(path.join(RES, 'view/aether-proxy/nodes.js'), 'utf8');
	assert.doesNotMatch(block, /\.indeterminate\s*=/);
	assert.doesNotMatch(view, /appearance\s*:\s*auto\s*!important|\[data-name="_failover"\]\s*>\s*input/);
});

test('T16.22: entire node cell toggles while grey; it repaints subscription and footer reset drops changes', async () => {
	const h = await harness('nodes');
	await render(h);
	const cell = failoverCell(h, 'n_b');
	await cell.click({ target: cell });
	assertFailover(h, 'n_b', 'true', '开');
	assertFailover(h, 's_a', 'true', '开');
	await h.view.handleReset();
	assertFailover(h, 'n_b', 'false', '关');
	assertFailover(h, 's_a', 'false', '关');
	assert.deepEqual(failoverWrites(h), []);
	await failoverCell(h, 'n_b').click({ target: failoverCell(h, 'n_b') });
	await h.view.handleSave();
	assert.deepEqual(h.main.failover_nodes, ['n_b']);
	await failoverBox(h, 'n_b').click();
	assertFailover(h, 's_a', 'false', '关');
	await h.view.handleSave();
	assert.deepEqual(failoverWrites(h), [
		['set', 'aetherproxy', 'main', 'failover_nodes', ['n_b']],
		['unset', 'aetherproxy', 'main', 'failover_nodes']
	]);
});

test('T16.22: binary subscription modal follows the column, stages only on successful modal Save', async () => {
	const h = await harness('nodes');
	h.nodes.push({ '.name': 'n_c', source: 's_a' });
	h.main.failover_nodes = 'n_b'; // UCI may return a scalar.
	await render(h);
	const open = () => {
		h.subscriptions.grid.renderMoreOptionsModal('s_a');
		const modal = h.subscriptions.grid.modal;
		const option = modal.options.find(o => o.field === '_failover_edit');
		const checkbox = option.getUIElement('s_a').firstChild;
		assert.equal(option.widget.title, inactiveFailover);
		assert.doesNotMatch(option.widget.textContent, new RegExp(inactiveFailover));
		return { modal, checkbox, set(checked) { checkbox.checked = checked; checkbox.change({ target: checkbox }); } };
	};
	assertFailover(h, 's_a', 'mixed', '半选 · 1/2');
	let edit = open();
	assert.equal(edit.checkbox.checked, false);
	await edit.modal.save();
	assertFailover(h, 's_a', 'mixed', '半选 · 1/2', false);
	edit = open();
	edit.set(true);
	await edit.modal.cancel();
	assertFailover(h, 's_a', 'mixed', '半选 · 1/2');
	edit = open();
	edit.set(true);
	const save = h.uci.save;
	h.uci.save = async () => { throw new Error('UCI save failed'); };
	await assert.rejects(edit.modal.save(), /UCI save failed/);
	assertFailover(h, 's_a', 'mixed', '半选 · 1/2');
	h.uci.save = save;
	await edit.modal.save();
	assertFailover(h, 's_a', 'true', '开');
	assertFailover(h, 'n_c', 'true', '开');
	assert.deepEqual(failoverWrites(h), [], 'modal UCI save did not flush the list');
	edit = open();
	assert.equal(edit.checkbox.checked, true, 'modal sees the same unapplied list');
	edit.set(false);
	await edit.modal.save();
	assertFailover(h, 's_a', 'false', '关');
	await h.view.handleSave();
	assert.equal(h.main.failover_nodes, undefined);
});

for (const active of [true, false]) {
	test(`T16.22: import reflects the backend list default (main switch ${active ? 'on' : 'off'})`, async () => {
		const h = await harness('nodes');
		h.general.push({ '.name': 'sub', failover: active ? '1' : '0' });
		await render(h);
		await failoverBox(h, 'n_b').click();
		h.view.importText.value = 'vless://new';
		const imported = h.view.handleImport({});
		await flush();
		assert.deepEqual(h.calls[1], ['node_import', { uri: 'vless://new' }]);
		// Mock the backend commit before import returns, not a frontend set call.
		h.nodes.push({ '.name': 'n_new', source: 'manual' });
		if (active)
			h.main.failover_nodes = ['n_new'];
		h.reads[1].resolve({ ok: true, duplicate: false, node: 'n_new' });
		await flush();
		h.reads[2].resolve(success('nodes'));
		await imported;
		assertFailover(h, 'n_new', String(active), active ? '开' : '关', active);
		assertFailover(h, 'n_b', 'true', '开', active);
		assert.deepEqual(failoverWrites(h), []);
		await h.view.handleSave();
		assert.deepEqual(h.main.failover_nodes, active ? ['n_new', 'n_b'] : ['n_b']);
	});
}

test('T16.22: exceeding the list cap does not silently make a partial selection', async () => {
	const h = await harness('nodes');
	h.main.failover_nodes = Array.from({ length: 64 }, (_, i) => 'n_old_' + i);
	await render(h);
	await failoverBox(h, 's_a').click();
	assertFailover(h, 's_a', 'false', '关');
	assert.match(h.notices[0].textContent, /名单最多包含 64 个节点/);
	await h.view.handleSave();
	assert.deepEqual(failoverWrites(h), []);
});

test('T16.18: docs/10 records block order, default and exit IP risk', () => {
	const docs = fs.readFileSync(path.resolve(APP, '../docs/10-cli-luci.md'), 'utf8');
	assert.match(docs, /\*\*通用设置\*\*[^\n]+\*\*订阅\*\*[^\n]+\*\*节点\*\*[^\n]+批量导入/);
	const section = docs.split('### 节点故障自动切换（T16.18）')[1]?.split('\n### ')[0] ?? '';
	assert.match(section, /`sub\.failover`[^\n]*默认关闭[^\n]*标签旁的 ⚠ 图标[^\n]*风控/);
});

test('T9.42: a hostile node name stays literal text on the nodes page', async () => {
	const unsafe = '<img src=x onerror=alert(1)>';
	const h = await harness('nodes');
	h.nodes[0].label = unsafe;
	h.subs[0].name = unsafe;
	const writeMark = htmlWriteMark();
	await render(h);
	const cell = (id, field) => find(gridRow(h, id), node => node.field === field)[0];
	assert.equal(text(cell('n_a', '_label')), unsafe, 'node name is a text node');
	assert.equal(text(cell('n_b', '_source')), unsafe, 'source column shows the subscription name as text');
	/* The DummyValue returns a node whose child is a text node, so luci-base's
	 * form.js renderTextValue (E('td', ..., value)) cannot see HTML. */
	assert.equal(cell('n_a', '_label').children[0].tag, 'span', 'textvalue returns an element');
	assert.equal(cell('n_a', '_label').firstChild.lastChild.firstChild.tag, '#text');
	assert.equal(find(h.root, node => node.tag === 'img').length, 0,
		'a hostile name never builds an element, including its onerror handler');
	assert.deepEqual(htmlWritesSince(writeMark).filter(text => text.includes(unsafe)), [],
		'the hostile name never takes the innerHTML path');
});

test('T16.19: subscription address reveals as text, toggles in place and masks again on redraw', async () => {
	const h = await harness('subscriptions');
	const url = 'https://user:password@host/sub?token=fake&x=<b>literal</b>';
	h.subs[0].url = url;
	const masked = h.model.mask(url);
	const writeMark = htmlWriteMark();
	await render(h);
	const addressCell = id => find(gridRow(h, id), node => node.field === '_address')[0];
	const cell = addressCell('s_a');
	const control = cell.firstChild;
	const other = addressCell('s_b');
	assert.equal(text(cell), masked);
	assert.equal(control.tag, 'a');
	assert.equal(control.getAttribute('role'), 'button');
	assert.equal(control.getAttribute('tabindex'), '0');
	assert.equal(control.getAttribute('title'), '点击显示完整地址');
	assert.equal(control.getAttribute('href'), null);

	let active;
	control.focus = () => { active = control; };
	const snapshot = [h.uciCalls.length, h.allCalls.length];
	control.click();
	cell.click({ target: control }); // Browser bubble must not toggle twice.
	assert.equal(text(cell), url);
	assert.equal(cell.firstChild, control);
	assert.equal(control.getAttribute('title'), '点击隐藏完整地址');
	assert.equal(control.firstChild.tag, '#text');
	assert.equal(active, control);
	assert.equal(text(other), h.model.mask(h.subs[1].url));
	control.click();
	assert.equal(text(cell), masked);
	assert.equal(control.getAttribute('title'), '点击显示完整地址');

	let prevented = 0;
	const press = (key, repeat = false) => control.keydown({ key, repeat, preventDefault: () => { prevented++; } });
	press('Tab');
	assert.equal(prevented, 0);
	assert.equal(text(cell), masked);
	press('Enter');
	assert.equal(text(cell), url);
	press('Enter', true);
	assert.equal(text(cell), url);
	press(' ');
	assert.equal(text(cell), masked);
	assert.equal(prevented, 3);
	assert.equal(active, control);
	cell.click({ target: cell });
	assert.equal(text(cell), url);
	assert.deepEqual([h.uciCalls.length, h.allCalls.length], snapshot, 'toggle never writes UCI or calls RPC');

	await h.page.redraw();
	assert.notEqual(addressCell('s_a').firstChild, control);
	assert.equal(text(addressCell('s_a')), masked);
	assert.equal(addressCell('s_a').firstChild.getAttribute('title'), '点击显示完整地址');
	assert.ok(!htmlWritesSince(writeMark).some(value => value.includes(url)), 'URL never takes the HTML path');
});

test('T9.42: a hostile subscription name stays literal text in the subscription grid', async () => {
	const unsafe = '<img src=x onerror=alert(1)>';
	const h = await harness('subscriptions');
	h.subs[0].name = unsafe;
	const writeMark = htmlWriteMark();
	await render(h);
	const cell = find(gridRow(h, 's_a'), node => node.field === '_name')[0];
	assert.equal(text(cell), unsafe, 'subscription name is a text node');
	assert.equal(cell.children[0].tag, 'span', 'textvalue returns an element, never a string');
	assert.equal(find(h.root, node => node.tag === 'img').length, 0, 'a hostile name never builds an element');
	assert.deepEqual(htmlWritesSince(writeMark).filter(text => text.includes(unsafe)), [],
		'the hostile name never takes the innerHTML path');
});
