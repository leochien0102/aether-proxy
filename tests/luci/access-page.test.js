'use strict';

/* T10.36 access-page contract tests (docs/10 访问控制页定案).
 * Form doubles follow the SDK's GridSection extension, modal option cloning,
 * optional-value remove path and synchronous UCI writes. Map redraws build
 * detached sections while formvalue() still reads the old Map root, then
 * replace the root contents (SDK Map.renderContents). No real RPC is used.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element: E } = require('./loader.js');

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
	const calls = { save: 0, reset: 0, apply: 0, hints: 0, notifications: [], writes: [] };
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
		unset: (config, sid, key) => { delete data.find((h) => h['.name'] == sid)[key]; },
		save: () => { calls.save++; return Promise.resolve(); }
	};
	class Option {
		constructor(section, option, title) {
			Object.assign(this, { section, map: section.map, option, title, choices: [], dependencies: [] });
		}
		value(key, label) { this.choices.push({ key, label }); }
		depends(value) { this.dependencies.push(value); }
		formvalue(sid) { return inputs[sid]?.[this.option]; }
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
		handleModalSave(modalMap) {
			/* SDK saves the child first, then reloads and resets its parent. */
			return modalMap.save().then(() => this.map.load()).then(() => this.map.reset());
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
					sid, style: {}, cell,
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
		ui: {
			createHandlerFn: (ctx, method) => (ev) => ctx[method](ev),
			changes: { apply: () => { calls.apply++; return Promise.resolve(); } },
			addNotification: (title, node, level) => calls.notifications.push({ node, level })
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
		modalSave(sid, values) {
			return page.hostSection.handleModalSave({ save: () => {
				for (const [key, value] of Object.entries(values))
					uci.set('aetherproxy', sid, key, value);
				return uci.save();
			} });
		}
	};
}

function host(id, policy, options = {}) {
	return { '.name': id, policy, ip: [ '192.168.1.10' ], ...options };
}

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
	assert.equal(f.option('ip').title, 'IP / 网段（可选）');
	assert.match(f.option('ip').description, /任一命中即生效/);
	assert.equal(mac.onchange, undefined, 'selecting a device cannot copy a DHCP IP');

	/* SDK cloneOptions copies custom handlers but replaces map/section. */
	const modalMac = Object.assign({}, mac, { formvalue: () => [ MAC.toUpperCase() ] });
	const modalName = Object.assign({}, f.option('name'), {
		map: { lookupOption: () => [ modalMac ] }
	});
	modalName.remove('a');
	assert.equal(f.data[1].name, 'laptop', 'empty optional name uses remove, not write');
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
	assert.equal(node.children[2].textContent, '', 'no stock button appears after the table');
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
		assert.equal(f.data[1].policy, unlisted, 'modal save stages the new policy');
		assert.equal(f.inputs.a.policy, unlisted, 'new parent widget reflects staged UCI');
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
