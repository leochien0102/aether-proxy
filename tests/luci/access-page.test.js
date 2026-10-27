'use strict';

/* Access-page contract tests (docs/10 访问控制页定案 and r16 modal validation).
 * Form doubles follow the SDK's GridSection extension, modal option cloning,
 * optional-value remove path and synchronous UCI writes. Map redraws build
 * detached sections while formvalue() still reads the old Map root, then
 * replace the root contents (SDK Map.renderContents). T10.66 validation doubles
 * use validation.js attributes and bubbling events; tooltip show/hide follows
 * ui.js focus/mouseover handling. No real RPC is used.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element: E, htmlWriteMark, htmlWritesSince } = require('./loader.js');
const { nowrapActions } = require('./button-layout');
const { parseList } = require('./dynamic-list');
const { textInput, renderAccessList } = require('./access-input');

const APP = path.join(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = (s) => po[s] ?? s;
globalThis.E = E;
const env = { window: {}, document: {}, L: { resolveDefault: (p, fallback) => p.catch(() => fallback) } };
const model = loadModule(path.join(RES, 'aether-proxy/model/access.js'), {
	baseclass: { extend: (o) => o }
}, env);
const MAC = 'aa:bb:cc:dd:ee:01';
const HINTS = { hosts: {
	[MAC]: { name: 'laptop', ipaddrs: [ '192.168.1.10' ] },
	'aa:bb:cc:dd:ee:02': { ipaddrs: [ '192.168.1.11' ] },
	'aa:bb:cc:dd:ee:03': { name: 'phone' }
} };

function fixture(hosts = [], main = {}) {
	const data = [ { '.name': 'main', mode: 'bypass_cn', unlisted_policy: 'follow', ...main }, ...hosts ];
	const calls = { save: 0, reset: 0, apply: 0, hints: 0, closed: 0, notifications: [], writes: [],
		tooltip: { opacity: 0, hides: [] } };
	const inputs = {};
	const uci = {
		load: () => Promise.resolve(),
		sections: () => data.slice(1),
		get: (config, sid, key) => key == null ? data.find((h) => h['.name'] == sid)
			: data.find((h) => h['.name'] == sid)?.[key],
		set: (config, sid, key, value) => {
			calls.writes.push({ sid, key, value });
			data.find((h) => h['.name'] == sid)[key] = value;
		},
		unset: (config, sid, key) => {
			calls.writes.push({ sid, key, remove: true });
			delete data.find((h) => h['.name'] == sid)[key];
		},
		save: () => {
			calls.save++;
			return calls.saveError ? Promise.reject(calls.saveError) : Promise.resolve();
		}
	};
	class Option {
		constructor(section, option, title) {
			Object.assign(this, { section, map: section.map, option, title, choices: [], dependencies: [] });
		}
		value(key, label) { this.choices.push({ key, label }); }
		depends(value) { this.dependencies.push(value); }
		formvalue(sid) { return inputs[sid]?.[this.option]; }
		cfgvalue(sid) { return uci.get('aetherproxy', sid, this.option); }
		write(sid, value) { return uci.set('aetherproxy', sid, this.option, value); }
		remove(sid) { return uci.unset('aetherproxy', sid, this.option); }
		renderWidget(sid, index, value) {
			if ([ 'ip', 'mac' ].includes(this.option)) return renderAccessList(this, sid, value);
			const input = textInput(value ?? '');
			return { input, querySelector: () => input };
		}
		getUIElement() { return { node: this.widget }; }
	}
	class Section {
		constructor(map, type) { Object.assign(this, { map, type, children: [] }); }
		option(Type, key, title) {
			const option = new Type(this, key, title);
			this.children.push(option);
			return option;
		}
	}
	class GridSection extends Section {
		static extend(methods) {
			class Extended extends this {}
			Object.assign(Extended.prototype, methods);
			return Extended;
		}
		handleAdd() {
			/* SDK handleAdd adds an unnamed section then opens its modal. */
			data.push({ '.name': 'cfgnew', '.anonymous': this.anonymous });
			return Promise.resolve({ modal: 'cfgnew' });
		}
		handleModalCancel() { calls.closed++; return Promise.resolve(); }
		handleModalSave(modalMap, ev) {
			/* SDK TableSection saves the active child silently, resets parents,
			   then closes only on success. Its catch deliberately resolves. */
			return modalMap.save(null, true).then(() => this.map.load()).then(() => this.map.reset())
				.then(() => this.handleModalCancel(modalMap, ev, true)).catch(() => {});
		}
		renderRowActions(sid) {
			// SDK GridSection keeps TableSection's action cell and its Edit/Delete handlers.
			const buttons = ['编辑', '删除'].map(label => {
				const button = E('button', { click: () => ({ sid, label }) }, label);
				button.style = { cssText: 'min-width:0;' };
				return button;
			});
			calls.actions ??= [];
			calls.actions.push({ sid, buttons });
			return E('td', { class: 'td cbi-section-table-cell nowrap cbi-section-actions' },
				E('div', {}, buttons));
		}
		renderSectionAdd() {
			return E('div', {}, E('button', { class: 'cbi-button cbi-button-add' }, 'Add'));
		}
		renderContents(ids) {
			const rows = ids.map((sid) => {
				const cell = E('td');
				cell.querySelector = () => cell.children[0];
				cell.appendChild = (node) => cell.children.push(node);
				return {
					sid, style: {}, cell, actions: this.renderRowActions(sid),
					getAttribute: () => sid,
					querySelector: () => cell
				};
			});
			const parent = {
				appendChild(row) {
					rows.splice(rows.indexOf(row), 1);
					rows.push(row);
				}
			};
			rows.forEach((row) => { row.parentNode = parent; });
			const table = E('table');
			const node = E('div', {}, [ table, this.renderSectionAdd() ]);
			node.rows = rows;
			node.querySelectorAll = () => rows.slice();
			node.querySelector = (selector) => selector == 'table' ? table : null;
			node.insertBefore = (child, before) => node.children.splice(node.children.indexOf(before), 0, child);
			return node;
		}
	}
	class Map {
		constructor() { this.children = []; }
		section(Type, type) {
			const section = new Type(this, type);
			this.children.push(section);
			return section;
		}
		lookupOption(key) {
			return this.children.flatMap((s) => s.children).filter((o) => o.option == key);
		}
		parse() { return Promise.resolve(); }
		load() { return Promise.resolve(); }
		reset() { calls.reset++; return this.renderContents(); }
		render() { return this.load().then(() => this.renderContents()); }
		renderContents() {
			/* New widgets use loaded UCI; old widgets remain searchable until
			   section rendering finishes and Map installs its new contents. */
			const next = Object.fromEntries(data.map((h) => [ h['.name'], { ...h } ]));
			const section = this.children[1];
			section.renderContents(section.cfgsections(), []);
			for (const sid of Object.keys(inputs))
				delete inputs[sid];
			Object.assign(inputs, next);
			return Promise.resolve(this);
		}
	}
	const form = { Map, NamedSection: Section, GridSection, Flag: Option, Value: Option,
		DummyValue: Option, DynamicList: Option, ListValue: Option };
	let hintReply = HINTS;
	const page = loadModule(path.join(RES, 'view/aether-proxy/access.js'), {
		view: { extend: (o) => o }, form, uci,
		dom: { findClassInstance: node => node },
		ui: {
			hideTooltip: ev => {
				// ui.js accepts an event-like object; input is outside tooltipDiv.
				assert.ok(ev.target);
				calls.tooltip.hides.push(ev.target);
				calls.tooltip.opacity = 0;
			},
			createHandlerFn: (ctx, method) => (ev) => ctx[method](ev),
			changes: { apply: () => { calls.apply++; return Promise.resolve(); } },
			addNotification: (title, node, level) => calls.notifications.push({
				node, level, savedAt: calls.save, closedAt: calls.closed
			})
		},
		network: { getHostHints: () => { calls.hints++; return Promise.resolve().then(() => {
			if (hintReply instanceof Error) throw hintReply;
			return hintReply;
		}); } },
		'aether-proxy.model.access': model
	}, env);
	return {
		page, calls, data, inputs,
		option: (key) => page.map.lookupOption(key)[0],
		hints: (value) => { hintReply = value; },
		async start() { await page.render(await page.load()); },
		table() { return page.tableNode; },
		openModal(sid, values = {}, addIP = '') {
			/* SDK renderMoreOptionsModal creates a child Map + NamedSection;
			   cloneOptions keeps custom handlers but replaces map and section.
			   Child inputs must never read the parent's old inline widgets. */
			const modalMap = { section: sid, parent: page.map };
			/* Map.render() sets root to the editor's own form (SDK); errors shown
			   while the modal is open must land here, not behind the overlay. */
			const root = E('div');
			root.insertBefore = (child, before) => {
				const i = before == null ? -1 : root.children.indexOf(before);
				root.children.splice(i < 0 ? 0 : i, 0, child);
				child.parentNode = root;
			};
			root.removeChild = child => {
				root.children = root.children.filter(c => c !== child);
				child.parentNode = null;
			};
			Object.defineProperty(root, 'firstChild', { get() { return root.children[0]; } });
			modalMap.root = root;
			const current = { ...data.find(h => h['.name'] == sid), ...values };
			const section = { map: modalMap, children: [] };
			modalMap.children = [ section ];
			modalMap.lookupOption = key => section.children.filter(o => o.option == key);
			modalMap.checkDepends = () => {
				for (const option of section.children)
					option.widget?.triggerValidation?.();
			};
			for (const source of page.hostSection.children.filter(o => o.modalonly !== false)) {
				const o = Object.assign(Object.create(Object.getPrototypeOf(source)), source,
					{ map: modalMap, section });
				const value = current[o.option] ?? o.default;
				if ([ 'ip', 'mac' ].includes(o.option)) {
					o.widget = o.renderWidget(sid, 0, value);
					if (o.option == 'ip') o.widget.input.edit(addIP);
					o.formvalue = () => o.widget.getValue();
				}
				else if (o.option == 'name') {
					o.widget = o.renderWidget(sid, 0, value);
					o.formvalue = () => o.widget.input.value;
				}
				else {
					o.formvalue = () => value ?? '';
				}
				o.isActive = () => o.option != 'udp' || current.policy != 'direct';
				o.isValid = () => !o.widget?.triggerValidation || o.widget.triggerValidation();
				o.getValidationError = () => o.widget?.getValidationError() ?? '';
				section.children.push(o);
			}
			modalMap.save = (cb, silent) => {
				calls.modalSaveArgs = { cb, silent };
				return Promise.resolve().then(() => {
					for (const o of section.children) {
						if (o.isActive() && !o.isValid())
							throw new TypeError(o.getValidationError());
						if (!o.isActive()) continue;
						const write = value => o.write ? o.write(sid, value)
							: uci.set('aetherproxy', sid, o.option, value);
						const remove = () => o.remove ? o.remove(sid) : uci.unset('aetherproxy', sid, o.option);
						if (o.widget?.getValue)
							parseList(o, sid, o.widget, uci.get('aetherproxy', sid, o.option), write, remove);
						else if (o.formvalue() === '')
							remove();
						else if (o.formvalue() !== uci.get('aetherproxy', sid, o.option))
							write(o.formvalue());
					}
				}).then(cb).then(() => uci.save());
			};
			const alerts = () => root.children.filter(c => /alert-message error/.test(c.attrs?.class ?? ''));
			return { map: modalMap, alerts, option: key => modalMap.lookupOption(key)[0],
				save: () => page.hostSection.handleModalSave(modalMap, {}) };
		},
		async modalSave(sid, values) {
			const modal = this.openModal(sid, values);
			await modal.save();
			this.lastModal = modal;
			return modal;
		}
	};
}

function host(id, policy, options = {}) {
	return { '.name': id, policy, ip: [ '192.168.1.10' ], ...options };
}

function assertModalError(f, modal, pattern) {
	/* Review fix: the open editor shows the error; nothing goes behind the overlay. */
	assert.deepEqual(f.calls.notifications, [], 'no page notification while the editor is open');
	const alerts = modal.alerts();
	assert.equal(alerts.length, 1, 'exactly one error box at the top of the editor');
	assert.equal(modal.map.root.children[0], alerts[0]);
	if (pattern)
		assert.match(alerts[0].textContent, pattern);
}

test('T10.53 scenario 1: reversed range is invalid in the add box and modal Save leaves all UCI untouched',
async () => {
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const before = JSON.stringify(f.data);
	const modal = f.openModal('a', { name: 'changed' }, '192.168.8.200-192.168.8.100');
	await modal.save();
	assert.equal(f.calls.closed, 0);
	assert.equal(modal.option('ip').isValid('a'), false, 'SDK invalid class/error state on the add box');
	assert.match(modal.option('ip').getValidationError('a'), /不是合法的 IPv4 地址、范围或 CIDR/);
	assertModalError(f, modal, /不是合法的 IPv4 地址、范围或 CIDR/);
	await modal.save();
	assert.equal(modal.alerts().length, 1, 'a second attempt replaces, not stacks, the error box');
	assert.equal(f.calls.save, 0);
	assert.deepEqual(f.calls.writes, []);
	assert.equal(JSON.stringify(f.data), before);
});

test('T10.53 scenario 2: duplicate IP or normalized MAC blocks modal Save before any write', async () => {
	for (const values of [ { ip: [ '192.168.1.10/32' ] }, { mac: [ 'AA-BB-CC-DD-EE-01' ] } ]) {
		const f = fixture([ host('a', 'follow', { mac: [ MAC ], enabled: '0' }),
			host('b', 'proxy', { ip: [ '192.168.8.1' ] }) ]);
		await f.start();
		const before = JSON.stringify(f.data);
		const modal = await f.modalSave('b', { ...values, name: 'changed' });
		assert.equal(f.calls.save, 0);
		assert.equal(f.calls.closed, 0);
		assert.deepEqual(f.calls.writes, []);
		assert.equal(JSON.stringify(f.data), before);
		assertModalError(f, modal, /已被主机.*使用/);
	}
});

test('T10.53 scenario 3: new overlapping bypass-China host stages, refreshes, closes and then warns', async () => {
	const f = fixture([ host('a', 'gfw', { ip: [ '192.168.8.250-192.168.8.254' ] }) ]);
	await f.start();
	await f.page.hostSection.handleAdd();
	await f.modalSave('cfgnew', { ip: [ '192.168.8.252' ], policy: 'bypass_cn' });
	assert.equal(f.data[2].ip[0], '192.168.8.252');
	assert.equal(f.data[2].policy, 'bypass_cn');
	assert.equal(f.calls.save, 1);
	assert.equal(f.calls.reset, 1);
	assert.equal(f.calls.closed, 1);
	assert.equal(f.calls.apply, 0);
	assert.equal(f.calls.notifications.length, 1);
	assert.equal(f.calls.notifications[0].level, 'warning');
	assert.equal(f.calls.notifications[0].savedAt, 1);
	assert.equal(f.calls.notifications[0].closedAt, 1, 'warning follows successful stock modal lifecycle');
	assert.match(f.calls.notifications[0].node.textContent, /直连 → 全局 → 绕过大陆 → 仅被墙 → 跟随/);
});

test('T10.53 scenario 4: modal uses cloned current values, not stale parent widgets or its own old IP', async () => {
	const f = fixture([ host('a', 'proxy', { ip: [ '192.168.8.1' ] }) ]);
	await f.start();
	f.inputs.a.policy = 'direct';
	await f.modalSave('a', { ip: [ '192.168.8.2' ], policy: 'follow', udp: '0' });
	assert.equal(f.calls.save, 1);
	assert.equal(f.calls.closed, 1);
	assert.equal(f.data[1].policy, undefined, 'T10.54: changing to the default removes the override');
	assert.deepEqual(f.data[1].ip, [ '192.168.8.2' ]);
	assert.equal(f.calls.notifications.length, 0, 'replacing the edited section cannot conflict with itself');
	assert.equal(f.table().rows[0].style.opacity, '0.6');
	assert.match(f.table().rows[0].cell.textContent, /不起作用/);
});

test('T10.53 modal precheck: invalid existing list item and missing match never write earlier fields', async () => {
	for (const ip of [ [ '192.168.8.200-192.168.8.100' ], [] ]) {
		const f = fixture([ host('a', 'proxy') ]);
		await f.start();
		const before = JSON.stringify(f.data);
		const modal = await f.modalSave('a', { name: 'changed', ip, mac: [] });
		assert.equal(f.calls.save, 0);
		assert.equal(f.calls.closed, 0);
		assert.deepEqual(f.calls.writes, []);
		assert.equal(JSON.stringify(f.data), before);
		assertModalError(f, modal);
	}
});

test('T10.53 modal precheck: other hosts use current session values rather than old table inputs', async () => {
	const f = fixture([ host('a', 'follow'), host('b', 'proxy', { ip: [ '192.168.8.1' ] }) ]);
	await f.start();
	f.data[1].ip = [ '192.168.8.2' ];
	const modal = await f.modalSave('b', { ip: [ '192.168.8.2' ] });
	assert.equal(f.calls.save, 0);
	assert.equal(f.calls.closed, 0);
	assert.deepEqual(f.calls.writes, []);
	assertModalError(f, modal, /已被主机.*使用/);
});

test('T10.53 modal save failure: keep editor open, report failure, never emit a success overlap warning', async () => {
	const f = fixture([ host('a', 'gfw', { ip: [ '192.168.8.250-192.168.8.254' ] }),
		host('b', 'bypass_cn', { ip: [ '192.168.8.1' ] }) ]);
	await f.start();
	f.calls.saveError = new Error('session save failed');
	const modal = await f.modalSave('b', { ip: [ '192.168.8.252' ] });
	assert.equal(f.calls.save, 1, 'precheck succeeds and actually attempts the session save');
	assert.equal(f.calls.closed, 0);
	assert.equal(f.calls.reset, 0);
	assertModalError(f, modal, /session save failed/);
});

test('T10.53 scenario 5: empty add box is valid and Chinese IP sentences have no intervening space', async () => {
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const modal = f.openModal('a');
	assert.equal(f.option('ip').validate('a', ''), true);
	assert.equal(modal.option('ip').isValid('a'), true);
	assert.match(f.option('ip').description, /设备。单个/);
	await modal.save();
	assert.equal(f.calls.save, 1);
	assert.equal(f.calls.closed, 1);
});

test('T10.51 scenario 3: IP label and all three examples are translated; summaries retain range spelling', async () => {
	const range = '192.168.8.250-192.168.8.254';
	const singleRange = '192.168.8.7-192.168.8.7';
	const f = fixture([ host('a', 'proxy', { ip: [ range ] }),
		host('b', 'follow', { mac: [ MAC ], ip: [ range, singleRange ] }) ]);
	await f.start();
	assert.equal(f.option('ip').title, 'IP / 范围 / 网段（可选）');
	assert.equal(f.option('ip').description, [
		'按 MAC 或 IP 匹配，任一命中即生效；同一设备一般只选设备。IP 用于固定地址、整个网段或经过另一台路由器的设备。',
		'单个 192.168.8.250、范围 192.168.8.250-192.168.8.254、网段 192.168.8.0/24。'
	].join(''));
	const summary = f.option('_devices').textvalue('a');
	assert.equal(summary.textContent, range);
	assert.equal(summary.title, range);
	const truncated = f.option('_devices').textvalue('b');
	assert.equal(truncated.textContent, 'laptop、' + range + ' 等 3 项');
	assert.equal(truncated.title, 'laptop、' + range + '、' + singleRange);
});

test('T10.51 scenario 4: unlisted notice keeps only first sentence and top instructions stay unchanged', async () => {
	const f = fixture();
	await f.start();
	assert.equal(f.option('_notice').renderWidget().textContent, '所有未列出的设备（包括物联网设备）都会走代理。');
	assert.equal(f.page.map.children[0].description, [
		'想让所有设备走代理：未列出的设备选『跟随默认模式』，个别不需要代理的设备在下面设为『直连』。',
		'只想让部分设备走代理：未列出的设备选『直连』，再在下面列出要走代理的设备。'
	].join(' '));
	f.inputs.main.unlisted_policy = 'direct';
	f.option('unlisted_policy').onchange();
	assert.equal(f.page.notice.textContent, '');
	f.inputs.main.unlisted_policy = 'follow';
	f.option('unlisted_policy').onchange();
	assert.equal(f.page.notice.textContent, '所有未列出的设备（包括物联网设备）都会走代理。');
});

test('T10.51 save paths: overlapping ranges warn and save; duplicate and invalid ranges block both buttons',
async () => {
	const range = '192.168.8.250-192.168.8.254';
	const cases = [
		{ ip: '192.168.8.252', level: 'warning', saved: 1 },
		{ ip: range, level: 'error', saved: 0 },
		{ ip: '192.168.8.254-192.168.8.250', level: 'error', saved: 0 }
	];
	for (const apply of [ false, true ]) {
		for (const c of cases) {
			const f = fixture([ host('a', 'direct', { ip: [ range ] }),
				host('b', 'proxy', { ip: [ c.ip ] }) ]);
			await f.start();
			if (apply) await f.page.handleSaveApply();
			else await f.page.handleSave();
			assert.equal(f.calls.save, c.saved);
			assert.equal(f.calls.apply, apply ? c.saved : 0);
			assert.equal(f.calls.notifications.length, 1);
			assert.equal(f.calls.notifications[0].level, c.level);
		}
	}
});

test('T10.36 scenario 1: default-mode and five-policy wording reserve global for all traffic', async () => {
	const f = fixture();
	await f.start();
	assert.equal(typeof f.page.map.children[0].description, 'string', 'NamedSection only renders string descriptions');
	assert.doesNotMatch(f.page.map.children[0].description, /helloworld|unlisted_policy|policy=|host/);
	assert.equal(f.option('_mode').title, '默认模式');
	assert.equal(f.option('_mode').cfgvalue(), '绕过大陆');
	assert.equal(f.option('unlisted_policy').title, '未列出的设备');
	assert.deepEqual(f.option('unlisted_policy').choices.map((c) => c.label), [ '跟随默认模式', '直连' ]);
	assert.deepEqual(f.option('policy').choices, [
		{ key: 'follow', label: '跟随默认模式' },
		{ key: 'direct', label: '直连' },
		{ key: 'bypass_cn', label: '绕过大陆' },
		{ key: 'gfw', label: '仅代理被墙网站（GFW）' },
		{ key: 'proxy', label: '全局（所有流量走代理）' }
	]);
	assert.equal(model.mode_text('global'), '全局（所有流量走代理）');
	assert.equal(model.mode_text('gfw'), '仅代理被墙网站（GFW）');
	assert.match(f.option('policy').description, /DNS 按默认模式解析/);
});

test('T10.36 scenario 2: unlisted notice follows staged policy and UCI mode', async () => {
	for (const mode of [ 'bypass_cn', 'global', 'gfw' ]) {
		for (const policy of [ 'follow', 'direct' ]) {
			const f = fixture([], { mode, unlisted_policy: policy });
			await f.start();
			const notice = f.option('_notice').renderWidget();
			const expected = mode != 'gfw' && policy == 'follow';
			assert.equal(notice.textContent.includes('包括物联网设备'), expected);
			f.inputs.main = { unlisted_policy: policy == 'follow' ? 'direct' : 'follow' };
			f.option('unlisted_policy').onchange();
			assert.equal(notice.textContent.includes('包括物联网设备'), mode != 'gfw' && !expected);
			assert.equal(notice.attrs.class, undefined, 'ordinary description, not a warning alert');
		}
	}
});

test('T10.36 scenario 3: anonymous GridSection Add opens a modal without a section-name prompt', async () => {
	const f = fixture();
	await f.start();
	assert.equal(f.page.hostSection.anonymous, true);
	assert.equal(f.page.hostSection.addremove, true);
	assert.deepEqual(await f.page.hostSection.handleAdd(), { modal: 'cfgnew' });
	assert.equal(f.data.at(-1)['.anonymous'], true);
});

test('T10.36 scenario 4: all non-direct policies offer game mode; direct plus UDP still fails precheck', async () => {
	const f = fixture([ host('a', 'direct', { udp: '1' }) ]);
	await f.start();
	assert.deepEqual(f.option('udp').dependencies.map((d) => d.policy), [ 'follow', 'proxy', 'bypass_cn', 'gfw' ]);
	for (const policy of [ 'follow', 'proxy', 'bypass_cn', 'gfw' ])
		assert.equal(model.validate([ host('a', policy, { udp: '1' }) ]).errors.length, 0);
	await f.page.handleSaveApply();
	assert.equal(f.calls.save, 0);
	assert.equal(f.calls.apply, 0);
	assert.match(f.calls.notifications[0].node.textContent, /不能开启游戏模式/);
});

test('T10.36 scenario 5: only enabled no-effect rules are annotated and dimmed; inline edits refresh them',
async () => {
	for (const unlisted of [ 'follow', 'direct' ]) {
		for (const policy of [ 'follow', 'direct', 'proxy', 'bypass_cn', 'gfw' ]) {
			for (const enabled of [ '0', '1' ]) {
				for (const udp of [ '0', '1' ]) {
					const f = fixture([ host('a', policy, { enabled, udp }) ], { unlisted_policy: unlisted });
					await f.start();
					const row = f.table().rows[0];
					const ineffective = enabled == '1' && (unlisted == 'direct'
						? policy == 'direct' : policy == 'follow' && udp == '0');
					assert.equal(row.style.opacity, ineffective ? '0.6' : '');
					assert.equal(row.cell.textContent.includes('不起作用'), ineffective);
				}
			}
		}
	}
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const row = f.table().rows[0];
	f.inputs.a = { udp: '1' };
	f.option('udp').onchange();
	assert.equal(row.style.opacity, '');
	f.inputs.a = { policy: 'direct', udp: '0' };
	f.inputs.main = { unlisted_policy: 'direct' };
	f.option('unlisted_policy').onchange();
	assert.equal(row.style.opacity, '0.6');
	f.inputs.a.enabled = '0';
	f.option('enabled').onchange();
	assert.equal(row.style.opacity, '');
	assert.equal(row.cell.textContent, '');
	for (const policy of [ 'follow', 'direct' ]) {
		const same = fixture([ host('a', policy) ], { unlisted_policy: policy });
		await same.start();
		await same.page.handleSaveApply();
		assert.equal(same.calls.save, 1, 'ineffective rules do not block saving');
		assert.equal(same.calls.apply, 1);
	}
});

test('T10.36 scenario 6: stable five-policy grouping changes only display, including inline policy edits', async () => {
	const hosts = [ host('f1', 'follow'), host('g1', 'gfw'), host('p1', 'proxy'), host('d1', 'direct'),
		host('b1', 'bypass_cn'), host('d2', 'direct'), host('p2', 'proxy'), host('f2', 'follow') ];
	const f = fixture(hosts);
	await f.start();
	const before = JSON.stringify(f.data);
	const expected = [ 'd1', 'd2', 'p1', 'p2', 'b1', 'g1', 'f1', 'f2' ];
	assert.deepEqual(f.page.hostSection.cfgsections(), expected);
	const table = f.table();
	assert.deepEqual(table.rows.map((r) => r.sid), expected);
	f.inputs.f1 = { policy: 'direct' };
	f.option('policy').onchange();
	assert.deepEqual(table.rows.map((r) => r.sid), [ 'f1', 'd1', 'd2', 'p1', 'p2', 'b1', 'g1', 'f2' ]);
	assert.equal(JSON.stringify(f.data), before, 'UCI sections and .index/order untouched');
	assert.deepEqual(f.calls.writes, []);
});

test('T10.36 scenario 7: device hints, optional name autofill and MAC-only selection survive modal save', async () => {
	const f = fixture([ host('a', 'follow', { ip: [], mac: [ MAC ] }) ]);
	await f.start();
	assert.equal(f.calls.hints, 1);
	const mac = f.option('mac');
	assert.equal(f.page.hostSection.children[2], mac, 'device follows enabled and name in the modal');
	assert.equal(mac.modalonly, true);
	assert.deepEqual(mac.choices[0], { key: MAC, label: 'laptop（192.168.1.10，aa:bb:cc:dd:ee:01）' });
	assert.equal(mac.choices[1].label, '192.168.1.11，aa:bb:cc:dd:ee:02');
	assert.equal(f.option('ip').title, 'IP / 范围 / 网段（可选）');
	assert.match(f.option('ip').description, /任一命中即生效/);
	assert.equal(mac.onchange, undefined, 'selecting a device cannot copy a DHCP IP');

	/* SDK cloneOptions copies custom handlers but replaces map/section. */
	const modalMac = Object.assign(Object.create(Object.getPrototypeOf(mac)), mac,
		{ formvalue: () => [ MAC.toUpperCase() ] });
	const source = f.option('name');
	const modalName = Object.assign(Object.create(Object.getPrototypeOf(source)), source, {
		map: { lookupOption: () => [ modalMac ] }
	});
	modalName.write('a', '');
	assert.equal(f.data[1].name, 'laptop', 'a changed empty name still uses the custom device-name writer');
	assert.deepEqual(f.data[1].ip, [], 'no DHCP IP written');
	modalName.write('a', 'my label');
	assert.equal(f.data[1].name, 'my label');
	modalMac.formvalue = () => [ '00:11:22:33:44:55', MAC ];
	modalName.remove('a');
	assert.equal(f.data[1].name, undefined, 'only the first selected device supplies the name');
	assert.ok(f.calls.writes.every((w) => w.key == 'name'));

	const failed = fixture();
	failed.hints(new Error('lookup failed'));
	await failed.start();
	assert.deepEqual(failed.option('mac').choices, [], 'lookup failure retains manual input');
});

test('T10.36 scenario 8: table has only summaries; names replace known MACs and title retains every item', async () => {
	const f = fixture([ host('a', 'proxy', { mac: [ MAC, '00:11:22:33:44:55' ], ip: [ '10.0.0.0/8' ] }) ]);
	await f.start();
	const columns = f.page.hostSection.children.filter((o) => !o.modalonly);
	assert.deepEqual(columns.map((o) => o.option), [ 'enabled', 'name', '_devices', 'policy', 'udp' ]);
	assert.deepEqual(columns.filter((o) => o.editable).map((o) => o.option), [ 'enabled', 'policy', 'udp' ]);
	assert.equal(f.option('_devices').modalonly, false, 'summary excluded from modal cloning');
	const summary = f.option('_devices').textvalue('a');
	assert.equal(summary.textContent, 'laptop、00:11:22:33:44:55 等 3 项');
	assert.equal(summary.title, 'laptop、00:11:22:33:44:55、10.0.0.0/8');
	assert.equal(f.table().rows[0].style.whiteSpace, 'nowrap', 'whole table row stays one line');
	assert.match(summary.style, /white-space:nowrap/);
	assert.equal(model.device_summary({ ip: [ '10.0.0.0/8', '10.2.3.4' ] }, []).text, '10.0.0.0/8、10.2.3.4');
	assert.equal(model.device_summary({ mac: [ MAC ] }, f.page.candidates).text, 'laptop');
	assert.equal(model.device_summary({ mac: [ MAC ] }, []).text, MAC);
});

test('T10.36 scenario 9: overlaps use five-policy order, notify without blocking Save or Save and Apply', async () => {
	for (const apply of [ false, true ]) {
		const f = fixture([ host('a', 'bypass_cn', { ip: [ '10.0.0.0/8' ] }),
			host('b', 'gfw', { ip: [ '10.1.2.3' ] }) ]);
		await f.start();
		if (apply) await f.page.handleSaveApply();
		else await f.page.handleSave();
		assert.equal(f.calls.save, 1);
		assert.equal(f.calls.apply, apply ? 1 : 0);
		assert.equal(f.calls.reset, apply ? 0 : 1);
		assert.equal(f.calls.notifications[0].level, 'warning');
		assert.match(f.calls.notifications[0].node.textContent, /直连 → 全局 → 绕过大陆 → 仅被墙 → 跟随/);
	}
});


test('T10.44 scenario 2: access actions stay nowrap and content-sized with original handlers after reset', async () => {
	const f = fixture([host('a', 'proxy'), host('b', 'follow')]);
	await f.start();
	for (const reset of [false, true]) {
		if (reset)
			await f.page.map.reset();
		for (const row of f.table().rows) {
			nowrapActions(row.actions, ['编辑', '删除']);
			const originals = f.calls.actions.filter(action => action.sid === row.sid).at(-1).buttons;
			assert.deepEqual(row.actions.lastChild.children, originals, 'keep the built-in buttons');
			for (const button of originals) {
				assert.match(button.style, /min-width:0;/, 'keep existing inline button styles');
				assert.deepEqual(button.click(), { sid: row.sid, label: button.textContent });
			}
		}
	}
});

test('T10.42 scenario 1: modal fields are enabled, name, device, IP, policy and game mode', async () => {
	const f = fixture();
	await f.start();
	/* SDK cloneOptions excludes modalonly=false, preserving registration order. */
	const modalOptions = f.page.hostSection.children.filter((o) => o.modalonly !== false);
	assert.deepEqual(modalOptions.map((o) => o.option), [ 'enabled', 'name', 'mac', 'ip', 'policy', 'udp' ]);
});

test('T10.42 scenario 2: page descriptions use plain language without application or UCI names', async () => {
	const f = fixture();
	await f.start();
	assert.equal(f.page.map.children[0].description, [
		'想让所有设备走代理：未列出的设备选『跟随默认模式』，个别不需要代理的设备在下面设为『直连』。',
		'只想让部分设备走代理：未列出的设备选『直连』，再在下面列出要走代理的设备。'
	].join(' '));
	const visibleText = [ f.page.map.children[0].description,
		...f.page.map.children.flatMap((s) => s.children.map((o) => o.title || '')) ].join(' ');
	assert.doesNotMatch(visibleText, /helloworld|unlisted_policy|policy=|config host/);
});

test('T10.42 scenario 3: only one Add button is above the table in a right-aligned row and opens a modal',
async () => {
	const f = fixture();
	await f.start();
	const node = f.table();
	const toolbar = node.children[0];
	assert.equal(toolbar.tag, 'div');
	assert.equal(node.children[1].tag, 'table', 'toolbar immediately precedes the table');
	for (const rule of [ 'display:flex', 'justify-content:flex-end', 'align-items:center',
		'gap:0.5em', 'flex-wrap:wrap', 'margin:0.5em 0 1em' ])
		assert.ok(toolbar.style.includes(rule), rule);
	const button = toolbar.children[0];
	assert.match(button.class, /cbi-button-add/);
	assert.equal(button.textContent, '添加');
	assert.equal(button.disabled, false);
	assert.deepEqual(f.page.hostSection.renderSectionAdd().children, [], 'stock lower-left Add is empty');
	/* renderSectionAdd() returns an empty fragment: appending a fragment moves
	 * its (zero) children, so after the table there is no stock Add node. */
	assert.deepEqual(node.children.slice(2), [], 'no stock button appears after the table');
	assert.deepEqual(await button.click({}), { modal: 'cfgnew' });
	assert.equal(f.data.at(-1)['.anonymous'], true, 'anonymous Add opens the editor without a name prompt');
	f.page.map.readonly = true;
	await f.page.map.reset();
	assert.equal(f.table().children[0].children[0].disabled, true, 'read-only maps cannot add hosts');
});

test('T10.42 scenario 4: unsaved inline policy and game-mode changes immediately toggle no-effect marks', async () => {
	for (const unlisted of [ 'follow', 'direct' ]) {
		const f = fixture([ host('a', 'proxy', { udp: '0' }) ], { unlisted_policy: unlisted });
		await f.start();
		const before = JSON.stringify(f.data);
		const row = f.table().rows[0];
		f.inputs.a.policy = unlisted;
		f.option('policy').onchange();
		assert.equal(row.style.opacity, '0.6');
		assert.match(row.cell.textContent, /不起作用/);
		f.inputs.a.policy = 'proxy';
		f.option('policy').onchange();
		assert.equal(row.style.opacity, '');
		assert.equal(row.cell.textContent, '');
		assert.equal(JSON.stringify(f.data), before, 'inline editing has not written UCI');
		assert.equal(f.calls.save, 0);
		assert.equal(f.calls.apply, 0);
	}
	const f = fixture([ host('a', 'follow', { udp: '1' }) ]);
	await f.start();
	const row = f.table().rows[0];
	f.inputs.a.udp = '0';
	f.option('udp').onchange();
	assert.equal(row.style.opacity, '0.6');
	assert.match(row.cell.textContent, /不起作用/);
	f.inputs.a.udp = '1';
	f.option('udp').onchange();
	assert.equal(row.style.opacity, '');
	assert.equal(row.cell.textContent, '');
	assert.equal(f.data[1].udp, '1');
	assert.equal(f.calls.save, 0);
});

test('T10.42 scenario 4: modal saves recalculate no-effect marks from new widgets, not the old Map root', async () => {
	for (const unlisted of [ 'follow', 'direct' ]) {
		const f = fixture([ host('a', 'proxy', { udp: '0' }) ], { unlisted_policy: unlisted });
		await f.start();
		const oldRow = f.table().rows[0];
		assert.equal(oldRow.style.opacity, '');
		await f.modalSave('a', { policy: unlisted });
		const newRow = f.table().rows[0];
		assert.notEqual(newRow, oldRow, 'parent Map replaces the table');
		assert.equal(f.data[1].policy, unlisted == 'follow' ? undefined : unlisted,
			'T10.54: modal save removes the default override or stages the explicit policy');
		assert.equal(f.inputs.a.policy ?? 'follow', unlisted, 'new parent widget reflects staged UCI or its default');
		assert.equal(newRow.style.opacity, '0.6');
		assert.match(newRow.cell.textContent, /不起作用/);
		assert.equal(f.calls.apply, 0, 'no apply is needed to update the mark');
		await f.modalSave('a', { policy: 'proxy' });
		assert.equal(f.table().rows[0].style.opacity, '');
		assert.equal(f.table().rows[0].cell.textContent, '');
	}
	const f = fixture([ host('a', 'follow', { udp: '1' }) ]);
	await f.start();
	await f.modalSave('a', { udp: '0' });
	assert.equal(f.table().rows[0].style.opacity, '0.6');
	await f.modalSave('a', { udp: '1' });
	assert.equal(f.table().rows[0].style.opacity, '');
	assert.equal(f.table().rows[0].cell.textContent, '');
	assert.equal(f.calls.apply, 0);
});

function assertFeedback(input, pattern) {
	assert.equal(input.style.borderColor, 'var(--error-color-high, #c53030)');
	assert.match(input.accessFeedback.textContent, pattern);
	assert.equal(input.parentNode.children.at(-1), input.accessFeedback, 'reason below input and its add button');
	assert.equal(input.animations.at(-1).options.duration, 300);
	assert.equal(input.animations.at(-1).frames.length, 4);
}

test('T10.59 scenario 1: invalid IP and MAC plus/Enter shake, show red reason, reject and reset on input', async () => {
	for (const field of [ 'ip', 'mac' ]) {
		for (const action of [ 'plus', 'enter' ]) {
			const f = fixture([ host('a', 'follow') ]);
			f.hints({ hosts: {} });
			await f.start();
			const modal = f.openModal('a');
			const widget = modal.option(field).widget;
			const before = [...widget.value];
			widget.input.edit(field == 'ip' ? '192.168.8.200-192.168.8.100' : 'bad-mac');
			widget.attempt(action);
			assert.deepEqual(widget.value, before);
			assert.equal(widget.input.animations.length, 1);
			assertFeedback(widget.input, /不是合法的/);
			widget.input.edit(field == 'ip' ? '192.168.8.1' : MAC);
			assert.equal(widget.input.style.borderColor, 'original');
			assert.equal(widget.input.accessFeedback.textContent, '');
			widget.attempt(action);
			assert.equal(widget.input.value, '');
			assert.equal(widget.value.at(-1), field == 'ip' ? '192.168.8.1' : MAC);
		}
	}
});

test('T10.59 scenario 1: MAC dropdown Enter rejects invalid custom text before SDK creates it', async () => {
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const widget = f.openModal('a').option('mac').widget;
	widget.input.edit('bad-mac');
	widget.attempt('enter');
	assert.deepEqual(widget.value, []);
	assertFeedback(widget.input, /不是合法的 MAC/);
	widget.input.edit(MAC);
	widget.attempt('enter');
	assert.deepEqual(widget.value, [ MAC ]);
});

test('T10.59 scenario 3: modal duplicates point to the other host regardless of edited UCI position', async () => {
	for (const sid of [ 'a', 'b' ]) {
		for (const field of [ 'ip', 'mac' ]) {
			const f = fixture([ host('a', 'follow', { name: 'first', mac: [ MAC ] }),
				host('b', 'proxy', { name: 'second', ip: [ '192.168.8.1' ], mac: [ 'aa:bb:cc:dd:ee:02' ] }) ]);
			await f.start();
			const other = f.data.find(h => h['.name'] == (sid == 'a' ? 'b' : 'a'));
			const modal = await f.modalSave(sid, { [field]: other[field] });
			assertModalError(f, modal, new RegExp(other[field][0] + ' 已被主机 ' + other.name + ' 使用'));
			assert.doesNotMatch(modal.alerts()[0].textContent, /重复|主机 first：|主机 second：/);
			assert.equal(f.calls.save, 0);
			assert.deepEqual(f.calls.writes, []);
		}
	}
});

test('T10.59 scenario 4: pending valid/invalid plain/dropdown IP/MAC text blocks modal save without writes',
async () => {
	for (const field of [ 'ip', 'mac' ]) {
		for (const dropdown of [ false, true ]) {
			for (const valid of [ false, true ]) {
				const f = fixture([ host('a', 'follow') ]);
				f.hints({ hosts: {} });
				await f.start();
				if (dropdown) f.option(field).value('choice', 'choice');
				const modal = f.openModal('a', { name: 'must not write' });
				const widget = modal.option(field).widget;
				const text = valid ? (field == 'ip' ? '192.168.8.1' : MAC) : 'invalid';
				widget.input.edit(text);
				assert.equal(widget.getValue().includes(text), valid && !dropdown,
					'SDK saves valid pending plain text but drops dropdown text');
				await modal.save();
				assert.equal(f.calls.save, 0);
				assert.equal(f.calls.closed, 0);
				assert.deepEqual(f.calls.writes, []);
				const label = field == 'ip' ? 'IP / 范围 / 网段' : '设备';
				const expected = valid
					? '「' + label + '」里还有未添加的内容「' + text + '」：点「+」添加，或清空'
					: '「' + label + '」里的「' + text + '」不是合法的 '
						+ (field == 'ip' ? 'IPv4 地址、范围或 CIDR。' : 'MAC 地址。');
				assertModalError(f, modal);
				assert.ok(modal.alerts()[0].textContent.includes(expected));
				assert.doesNotMatch(modal.alerts()[0].textContent, /（可选）|「\s|\s」/);
				if (!valid)
					assert.doesNotMatch(modal.alerts()[0].textContent, /点「\+」添加/);
				assertFeedback(widget.input, /不是合法的|还有未添加的内容/);
				assert.equal(widget.input.accessFeedback.textContent, expected);
				widget.input.edit(' \t ');
				await modal.save();
				assert.equal(f.calls.save, 1, 'whitespace-only pending input does not block saving');
				assert.equal(f.calls.closed, 1);
			}
		}
	}
});

test('T10.59 scenario 5: trimmed duplicate name blocks and feeds back; correction and unnamed rules save', async () => {
	for (const names of [ [ 'same', 'same' ], [ ' same ', 'same ' ] ]) {
		const f = fixture([ host('a', 'follow', { name: names[0] }),
			host('b', 'proxy', { ip: [ '192.168.8.1' ] }) ]);
		await f.start();
		const modal = f.openModal('b', { name: names[1] });
		await modal.save();
		assert.equal(f.calls.save, 0);
		assert.equal(f.calls.closed, 0);
		assert.deepEqual(f.calls.writes, []);
		assertModalError(f, modal, /名称「same」已被另一条规则使用/);
		const input = modal.option('name').widget.input;
		assertFeedback(input, /名称「same」/);
		input.edit('different');
		assert.equal(input.style.borderColor, 'original');
		await modal.save();
		assert.equal(f.calls.save, 1);
		assert.equal(f.data[2].name, 'different');
	}
	const f = fixture([ host('a', 'follow'), host('b', 'proxy', { ip: [ '192.168.8.1' ] }) ]);
	await f.start();
	await f.modalSave('b', { name: '   ' });
	assert.equal(f.calls.save, 1, 'two unnamed rules do not collide');
});

test('T10.63 scenarios 1-2: pending reversed IP range and invalid dropdown MAC show exact short-field errors',
async () => {
	for (const [field, text, reason] of [
		[ 'ip', '192.168.8.200-192.168.8.100', 'IPv4 地址、范围或 CIDR。' ],
		[ 'mac', 'zz:zz', 'MAC 地址。' ]
	]) {
		const f = fixture([ host('a', 'follow') ]);
		await f.start();
		const before = JSON.stringify(f.data);
		const modal = f.openModal('a', { name: 'must not write' });
		const option = modal.option(field);
		option.widget.input.edit(text);
		await modal.save();
		const label = field == 'ip' ? 'IP / 范围 / 网段' : '设备';
		const expected = '「' + label + '」里的「' + text + '」不是合法的 ' + reason;
		assertModalError(f, modal);
		assert.ok(modal.alerts()[0].textContent.includes(expected));
		assert.equal(modal.alerts()[0].children[0].children[1].children.length, 1,
			'the pending error is not repeated as an unlabelled widget error');
		assert.doesNotMatch(modal.alerts()[0].textContent, /点「\+」添加|（可选）/);
		assert.equal(option.widget.input.accessFeedback.textContent, expected);
		assertFeedback(option.widget.input, /不是合法的/);
		assert.equal(f.option('ip').title, 'IP / 范围 / 网段（可选）');
		assert.equal(f.option('mac').title, '设备');
		assert.equal(f.calls.save, 0);
		assert.equal(f.calls.closed, 0);
		assert.deepEqual(f.calls.writes, []);
		assert.equal(JSON.stringify(f.data), before);
	}
});

test('T10.63 scenario 3: device custom item stays DOM-last before/after creation; only its open list is flex-first',
async () => {
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const modal = f.openModal('a');
	const widget = modal.option('mac').widget;
	const { list, customItem, dropdown } = widget;
	const original = [...list.children];
	assert.equal(list.children.at(-1), customItem);
	assert.equal(customItem.style.order, '-1');
	assert.equal(list.style.display, '', 'closed layout belongs to the theme');
	for (const creation of [ false, true ]) {
		dropdown.openDropdown();
		assert.deepEqual(list.style, { display: 'flex', flexDirection: 'column', alignItems: 'stretch' });
		assert.deepEqual(widget.previewStyle, { display: '', flexDirection: '', alignItems: '' });
		widget.finishOpen();
		assert.equal(widget.scrollTop, 0, 'SDK scroll calculation keeps the selected placeholder at the top');
		const visual = [...list.children].sort((a, b) => Number(a.style?.order ?? 0)
			- Number(b.style?.order ?? 0));
		assert.deepEqual(visual.slice(0, 2), [ widget.placeholder, customItem ]);
		if (creation) {
			widget.input.edit('11:22:33:44:55:66');
			widget.attempt('enter');
			assert.equal(list.children.at(-2).attrs['data-value'], '11:22:33:44:55:66');
			assert.equal(widget.value.at(-1), '11:22:33:44:55:66');
			assert.deepEqual(list.children.slice(0, -2), original.slice(0, -1));
		}
		assert.equal(list.children.at(-1), customItem);
		assert.equal(customItem.style.order, '-1');
		dropdown.closeDropdown();
		assert.deepEqual(list.style, { display: '', flexDirection: '', alignItems: '' });
	}
	// The IP field and an otherwise identical list not decorated by the page stay untouched.
	assert.equal(modal.option('ip').widget.list, undefined);
	const other = renderAccessList({ choices: f.option('mac').choices, validate: () => true }, 'x', []);
	other.dropdown.openDropdown();
	assert.deepEqual(other.list.style, { display: '', flexDirection: '', alignItems: '' });
	assert.equal(other.customItem.style.order, undefined);
	const manual = fixture([ host('a', 'follow') ]);
	manual.hints({ hosts: {} });
	await manual.start();
	assert.equal(manual.openModal('a').option('mac').widget.list, undefined, 'plain manual fallback still renders');
});

test('T10.66 scenarios 1-2: placeholder/custom input keep DOM positions, visual order and SDK scroll after creation',
async () => {
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const modal = f.openModal('a');
	const widget = modal.option('mac').widget;
	const { list, placeholder, customItem, dropdown } = widget;
	const original = [...list.children];
	assert.equal(placeholder.attrs['data-value'], undefined, 'SDK-generated placeholder has only [placeholder]');
	for (const create of [ false, true ]) {
		if (create) {
			widget.input.edit('11:22:33:44:55:66');
			widget.attempt('enter');
			assert.equal(list.children.at(-2).attrs['data-value'], '11:22:33:44:55:66');
			assert.deepEqual(list.children.slice(0, -2), original.slice(0, -1));
		}
		assert.equal(list.children[0], placeholder);
		assert.equal(list.children.at(-1), customItem);
		assert.equal(placeholder.style.order, '-2');
		assert.equal(customItem.style.order, '-1');
		dropdown.openDropdown();
		widget.finishOpen();
		assert.equal(placeholder.offsetTop, 0);
		assert.equal(customItem.offsetTop, placeholder.offsetHeight);
		assert.equal(list.scrollTop, 0, 'calculated from selected offsetTop - offsetHeight, not hard-coded');
		dropdown.closeDropdown();
	}
	assert.equal(modal.option('ip').widget.list, undefined, 'plain IP add box is not decorated');
	// Some choice providers supply the empty-value item instead of SDK's placeholder.
	const explicit = renderAccessList({ choices: f.option('mac').choices, validate: () => true }, 'x', []);
	delete explicit.placeholder.attrs.placeholder;
	explicit.placeholder.attrs['data-value'] = '';
	const option = { renderWidget: () => explicit };
	f.page.deviceInputFirst(option);
	option.renderWidget();
	assert.equal(explicit.placeholder.style.order, '-2');
});

function showInputTooltip(calls, input, type) {
	assert.ok([ 'focus', 'mouseover' ].includes(type));
	// ui.js showTooltip returns without changing opacity when no ancestor has data-tooltip.
	if (Object.hasOwn(input.attrs, 'data-tooltip'))
		calls.tooltip.opacity = 1;
}

function assertNoTooltip(input) {
	assert.equal(Object.hasOwn(input.attrs, 'data-tooltip'), false);
	assert.equal(Object.hasOwn(input.attrs, 'data-tooltip-style'), false);
}

test('T10.66 scenario 3: IP and plain/dropdown MAC validation uses inline reasons without shake and clears on success',
async () => {
	for (const field of [ 'ip', 'mac' ]) {
		for (const hints of [ HINTS, { hosts: {} } ]) {
			const f = fixture([ host('a', 'follow') ]);
			f.hints(hints);
			await f.start();
			const option = f.openModal('a').option(field);
			const input = option.widget.input;
			input.edit(field == 'ip' ? '192.168.8.200-192.168.8.100' : 'zz:zz');
			const reason = option.validate('a', input.value);
			// A previously open tooltip must also be hidden on failure.
			f.calls.tooltip.opacity = 1;
			for (const event of [ 'keyup', 'blur' ]) {
				input.dispatchEvent({ type: event });
				assert.equal(option.widget.valid, false);
				assertNoTooltip(input);
				assert.equal(input.accessFeedback.textContent, reason);
				assert.equal(input.style.borderColor, 'var(--error-color-high, #c53030)');
				assert.equal(input.animations.length, 0, 'typing and blur never shake');
				assert.equal(f.calls.tooltip.hides.at(-1), input);
				assert.equal(f.calls.tooltip.opacity, 0);
				for (const type of [ 'focus', 'mouseover' ]) {
					showInputTooltip(f.calls, input, type);
					assert.equal(f.calls.tooltip.opacity, 0);
				}
			}
			// Use keyup without input to prove validation-success, not the edit reset, clears feedback.
			input.value = field == 'ip' ? '192.168.8.1' : MAC;
			input.dispatchEvent({ type: 'keyup' });
			assert.equal(option.widget.valid, true);
			assert.equal(input.accessFeedback.textContent, '');
			assert.equal(input.style.borderColor, 'original');
			assert.equal(input.animations.length, 0);
			assertNoTooltip(input);
		}
	}
});

test('T10.66 scenario 4: rejected plus/Enter and blocked Save still shake with red text but never show tooltips',
async () => {
	for (const field of [ 'ip', 'mac' ]) {
		for (const action of [ 'plus', 'enter', 'save' ]) {
			const f = fixture([ host('a', 'follow') ]);
			if (action == 'plus') f.hints({ hosts: {} });
			await f.start();
			const modal = f.openModal('a', { name: 'must not write' });
			const widget = modal.option(field).widget;
			widget.input.edit('invalid');
			f.calls.tooltip.opacity = 1;
			if (action == 'save') await modal.save();
			else widget.attempt(action);
			assertFeedback(widget.input, /不是合法的/);
			assert.equal(widget.input.animations.length, 1);
			assertNoTooltip(widget.input);
			assert.equal(f.calls.tooltip.opacity, 0);
			for (const type of [ 'focus', 'mouseover' ]) {
				showInputTooltip(f.calls, widget.input, type);
				assert.equal(f.calls.tooltip.opacity, 0);
			}
			assert.equal(f.calls.save, 0);
			assert.equal(f.calls.closed, 0);
			assert.deepEqual(f.calls.writes, []);
			assert.deepEqual(widget.value, field == 'ip' ? [ '192.168.1.10' ] : []);
			if (action == 'save') assertModalError(f, modal, /不是合法的/);
		}
	}
});

test('T10.66 scenario 5: other modal fields, stored items and undecorated page inputs retain SDK tooltips',
async () => {
	const f = fixture([ host('a', 'follow') ]);
	await f.start();
	const modal = f.openModal('a');
	const name = modal.option('name').widget.input;
	const other = renderAccessList({ choices: [], validate: () => 'other page error' }, 'x', []);
	const stored = textInput('stored');
	stored.eventParent = modal.option('ip').widget;
	for (const input of [ name, other.input, stored ]) {
		const hides = f.calls.tooltip.hides.length;
		input.validationResult('SDK reason');
		assert.equal(input.attrs['data-tooltip'], 'SDK reason');
		assert.equal(input.attrs['data-tooltip-style'], 'error');
		assert.equal(input.accessFeedback, undefined);
		assert.equal(f.calls.tooltip.hides.length, hides, 'unrelated validation must not hide its tooltip');
		for (const type of [ 'focus', 'mouseover' ]) {
			f.calls.tooltip.opacity = 0;
			showInputTooltip(f.calls, input, type);
			assert.equal(f.calls.tooltip.opacity, 1);
		}
	}
});

test('T10.59 scenario 5: footer Save and Save and Apply accept pre-existing duplicate names', async () => {
	for (const apply of [ false, true ]) {
		const f = fixture([ host('a', 'follow', { name: 'same' }),
			host('b', 'proxy', { name: 'same', ip: [ '192.168.8.1' ] }) ]);
		await f.start();
		await f.page.saveChecked(apply);
		assert.equal(f.calls.save, 1);
		assert.equal(f.calls.apply, Number(apply));
		assert.deepEqual(f.calls.notifications, []);
	}
});

/* T9.42: a host name comes from the DHCP hints or the user's input, and the
 * device summary also folds in entered IP/MAC text. It must reach the table as
 * text nodes: luci-base writes a single string child through innerHTML. */
function renderTree(node) {
	return [ node ].concat((node?.childNodes ?? []).flatMap(renderTree));
}

test('T9.42: a hostile DHCP host name stays literal text in the device summary', async () => {
	const unsafe = '<img src=x onerror=alert(1)>';
	const f = fixture([ host('a', 'proxy', { mac: [ MAC ], ip: [ '10.0.0.0/8' ] }) ]);
	f.hints({ hosts: { [MAC]: { name: unsafe } } });
	const writeMark = htmlWriteMark();
	await f.start();
	const summary = f.option('_devices').textvalue('a');
	assert.equal(summary.textContent, unsafe + '、10.0.0.0/8');
	assert.equal(summary.title, unsafe + '、10.0.0.0/8');
	assert.equal(summary.tag, 'span', 'textvalue returns an element, never a string');
	assert.equal(renderTree(summary).filter((node) => node.tag === 'img').length, 0,
		'a hostile name never builds an element');
	assert.ok(renderTree(summary).some((node) => node.tag === '#text' && node.text.includes(unsafe)),
		'the name is present as a text node');
	/* The render tree has no HTML sink at all: every child is a node. */
	assert.deepEqual(htmlWritesSince(writeMark).filter(text => text.includes(unsafe)), [],
		'the hostile name never takes the innerHTML path');
});
