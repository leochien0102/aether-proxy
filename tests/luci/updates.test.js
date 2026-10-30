'use strict';

/* T8.9b update-page contracts and T10.16 progressive status loading.
 * T10.46 replaces grouped rollback with Xray-only rollback and manual install guidance.
 * T10.67 adds grouped forward-update results using the real backend wire shape.
 * Cover pure decisions, CLI URL parity and actual view rendering/clicks.
 * Translations are loaded so assertions cover the text actually shown to users.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadModule, parsePo, element } = require('./loader');
const { actionRow, descendants, marginlessMessages } = require('./button-layout');
const { renderList, parseList } = require('./dynamic-list');
const ROOT = path.resolve(__dirname, '../..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = s => po[s] ?? s;
// LuCI supplies String.format in the browser; only %s is used by this model.
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
const model = loadModule(path.join(RES, 'aether-proxy/model/updates.js'),
	{ baseclass: { extend: o => o } }, { window: {}, document: {} });
const names = [ 'xray-core', 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn' ];
const entry = { installed: '2', available: '3', previous: '1', asset: 'x.ipk', newer: true };
function status(p = entry) {
	return { updates_available: { arch: 'test_arch', checked: 100, url: 'https://channel/',
		packages: { 'xray-core': p } } };
}
function row(s, busy = false) {
	return model.table(s, busy, 160).rows[0];
}
test('T8.9b scenario 2: package state precedence and every action', () => {
	const cases = [
		[ { updates_available: null }, '未检查', false, false, false ],
		[ status(undefined), '有更新', false, true, true ],
		[ status({ ...entry, asset: null }), '本机不可用 (test_arch)', false, false, true ],
		[ status({ ...entry, installed: null, newer: false }), '未安装', true, false, false ],
		[ status(), '有更新', false, true, true ],
		[ status({ ...entry, newer: false }), '最新', false, false, true ]
	];
	const absent = status();
	delete absent.updates_available.packages['xray-core'];
	cases.push([ absent, '通道中没有', false, false, false ]);
	for (const [s, text, install, update, rollback] of cases) {
		const r = row(s);
		assert.equal(r.status, text);
		assert.deepEqual([ r.install, r.update, r.rollback ], [ install, update, rollback ]);
	}
	for (const previous of [ null, '2' ])
		assert.equal(row(status({ ...entry, previous })).rollback, false);
	const unchecked = row({ updates_available: null });
	assert.deepEqual([ unchecked.installed, unchecked.available, unchecked.previous ], [ '–', '–', '–' ]);
	assert.deepEqual(model.table(status(), false, 160).rows.map(r => r.name), names);
	assert.equal(model.table(status(), true, 160).can_check, false);
	assert.ok(model.table(status(), true, 160).rows.every(r => r.disabled));
	assert.equal(model.table(status(), false, 160).url, 'https://channel/');
	assert.match(model.table(status(), false, 160).checked, /1/);
});
test('T8.9b scenario 3 / T10.46: Xray rollback confirmation includes both versions without restart warning', () => {
	assert.equal(model.confirmation('xray-core', 'CURRENT', 'PREVIOUS'),
		'将安装 PREVIOUS，替换当前的 CURRENT？');
});
test('T8.9b scenario 4: check and install result messages cover success, rollback and failures', () => {
	assert.equal(model.job_result('update_check', null, { state: 'ok', result: {
		packages: { a: { newer: true }, b: { newer: false }, c: { newer: true } }
	} }), '检查完成，2 个包有更新');
	const errors = {
		UPDATE_FETCH_FAILED: '连不上发布通道', MANIFEST_BAD_SIGNATURE: '签名校验失败',
		CONFIG_INVALID: '没有可用的通道地址', BUSY: '另一个更新作业正在运行',
		JOB_LOST: '作业进程意外退出', FUTURE: 'FUTURE'
	};
	for (const [code, text] of Object.entries(errors)) {
		assert.equal(model.job_result('update_check', null, { ok: false, code, detail: 'WHY' }), text + '：WHY');
		assert.equal(model.job_result('update_package', 'xray-core',
			{ state: 'failed', result: { ok: false, code } }), text);
	}
	assert.equal(model.job_result('update_check', null, { state: 'failed', error: 'JOB_LOST' }),
		'作业进程意外退出');
	for (const name of names) {
		for (const from of [ null, 'OLD' ]) {
			const text = model.job_result('update_package', name,
				{ result: { ok: true, from, to: 'NEW' } });
			assert.ok(text.includes(name));
			assert.ok(text.includes('NEW'));
			assert.equal(text.includes('OLD'), from != null);
			assert.equal(text.includes('请刷新浏览器'), name != 'xray-core');
		}
	}
	assert.equal(model.job_result('update_package', 'xray-core',
		{ result: { ok: false, rolled_back: true, from: 'OLD' } }), '安装后检查失败，已回滚到 OLD');
	for (const [code, expected] of [ [ 'UPDATE_VERIFY_FAILED', '校验失败' ],
		[ 'NO_SPACE', '空间不足' ], [ 'ARCH_UNSUPPORTED', '本机不可用' ], [ 'NEW_CODE', 'NEW_CODE' ] ]) {
		for (const detail of [ undefined, 'WHY' ])
			assert.equal(model.job_result('update_package', 'xray-core', { result: { ok: false, code, detail } }),
				expected + (detail ? '：WHY' : ''));
	}
});
test('T8.9b scenario 5: running versions, paths and optional architecture note', () => {
	const s = { ...status(), components: { xray: { version: null, path: '/xray' },
		'chinadns-ng': { version: 'DNSVER', path: '/dns' } } };
	const rows = model.components(s);
	assert.equal(rows[0].version, '未知');
	assert.equal(rows[0].path, '/xray');
	assert.equal(rows[1].version, 'DNSVER');
	assert.equal(rows[1].path, '/dns');
	assert.match(rows[1].note, /软件包页面.*test_arch/);
	s.updates_available = null;
	// Without a check there is no arch at all, not an empty or undefined one.
	assert.doesNotMatch(model.components(s)[1].note, /test_arch|本机架构/);
	assert.equal(model.components({})[1].version, '未知');
});
test('T8.9b scenario 6: every channel URL fixture agrees with real CLI validation', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ap-updates-'));
	try {
		for (const name of [ 'conf', 'data', 'base', 'custom', 'run' ])
			fs.mkdirSync(path.join(dir, name));
		for (const name of [ 'gfwlist', 'chnlist', 'apple', 'chnroute4', 'gfw_static4' ])
			fs.writeFileSync(path.join(dir, 'base', name + '.txt'), '');
		for (const url of [ 'http://host', 'https://host', 'https://host:8443/path?q=x',
			'ftp://host', 'http://', 'https:///path', 'http://a b', '' ]) {
			fs.writeFileSync(path.join(dir, 'conf/aetherproxy'),
				"config global 'main'\n option enabled '0'\nconfig update 'update'\n" +
				` list channel_urls '${url}'\n`);
			const args = [ '-S', path.join(ROOT, 'aether-proxy/src/aether-proxy'), '--',
				'check', '--json', '--no-precheck' ];
			for (const [opt, name] of [ [ 'confdir', 'conf' ], [ 'data-dir', 'data' ],
				[ 'baseline-dir', 'base' ], [ 'custom-dir', 'custom' ], [ 'run-dir', 'run' ] ])
				args.push('--' + opt, path.join(dir, name));
			const r = spawnSync(path.join(ROOT, 'tests/host/ucode'), args, { encoding: 'utf8' });
			assert.equal(r.stderr, '');
			assert.ok([ 0, 2 ].includes(r.status));
			const errors = JSON.parse(r.stdout).errors ?? [];
			const invalid = errors.some(e => e.field.startsWith('update.channel_urls'));
			// A stored empty item is invalid; an unused add box is tested through the view below.
			assert.equal(!invalid, model.validate_url(url) === true, JSON.stringify(url));
			assert.equal(model.validate_url(url) === true, url.startsWith('http') &&
				[ 'http://host', 'https://host', 'https://host:8443/path?q=x' ].includes(url));
		}
	}
	finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});
test('T8.9b job lifecycle: disable all actions, refresh status once, and confirm rollback before dispatch',
async () => {
	const calls = [];
	let finish;
	let confirmed = false;
	const ap = {
		confirm: async () => confirmed,
		job_progress: () => ({ stop() {} }),
		run_job: (kind, args) => {
			calls.push([ kind, args ]);
			return new Promise(resolve => { finish = resolve; });
		},
		call: async method => {
			calls.push([ method ]);
			return status({ ...entry, installed: '3', newer: false });
		}
	};
	globalThis.E = element;
	const page = loadModule(path.join(RES, 'view/aether-proxy/updates.js'), {
		view: { extend: o => o }, form: {}, uci: {},
		ui: { createHandlerFn: (self, fn) => fn.bind(self) },
		'aether-proxy.common': ap, 'aether-proxy.model.updates': model
	}, { window: {}, document: {} });
	page.status = status();
	page.inventory = E('div');
	page.summary = E('p');
	page.progress = E('p');
	const button = page.package_button(row(status()), 'rollback', true);
	await button.attrs.click();
	assert.deepEqual(calls, []);
	confirmed = true;
	const pending = button.attrs.click();
	await Promise.resolve();
	assert.equal(page.busy, true);
	assert.deepEqual(calls, [ [ 'update_package', [ 'xray-core', '--previous' ] ] ]);
	const buttons = node => {
		if (!node || typeof node != 'object')
			return [];
		return (node.tag == 'button' ? [ node ] : []).concat(
			(Array.isArray(node.children) ? node.children : []).flatMap(buttons));
	};
	assert.ok(buttons(page.inventory).length >= 3);
	assert.ok(buttons(page.inventory).every(b => b.disabled));
	finish({ result: { ok: true, from: '2', to: '1' } });
	await pending;
	assert.equal(page.busy, false);
	assert.deepEqual(calls[1], [ 'status' ]);
	assert.equal(calls.length, 2);
	assert.ok(buttons(page.inventory).every(b => !b.disabled));
});
/* Deferred RPC and zero-delay timer doubles let the page render while status
 * never settles. Shared elements expose identity and unsaved form values. */
function text(node) {
	if (node == null)
		return '';
	if (typeof node != 'object')
		return String(node);
	if (node.tag === '#text')
		return node.text;
	if (typeof node.textContent == 'string' && node.tag != null)
		return node.textContent;
	return (node.children ?? []).map(text).join('');
}
function buttons(node) {
	if (!node || typeof node != 'object')
		return [];
	return (node.tag == 'button' ? [ node ] : []).concat(node.children.flatMap(buttons));
}
function load_view(config = {}) {
	globalThis.E = element;
	const calls = [], loads = [], timers = [], maps = [], jobs = [], confirmations = [], writes = [];
	const ap = {
		call: method => {
			let resolve;
			const promise = new Promise(done => { resolve = done; });
			calls.push({ method, resolve });
			return promise;
		},
		confirm: async options => { confirmations.push(options); return false; },
		run_job: async (kind, args) => {
			jobs.push({ kind, args });
			return { state: 'ok', result: { ok: true, packages: {} } };
		},
		job_progress: () => ({ stop() {} })
	};
	const form = { NamedSection: 'named', ListValue: 'select', Flag: 'checkbox',
		Value: 'input', DynamicList: 'list' };
	form.Map = class {
		constructor(config, title) {
			this.config = config;
			this.title = title;
			this.options = [];
			maps.push(this);
		}
		section(type, name, section_type, title) {
			this.section_info = { type, name, section_type, title };
			return { children: this.options, option: (kind, key, label) => {
				const option = { kind, key, option: key, label, values: [], value(k, v) { this.values.push([ k, v ]); } };
				this.options.push(option);
				return option;
			} };
		}
		render() {
			this.node = E('form', {}, this.options.map(o => {
				o.input = o.kind == form.DynamicList ? renderList(o, 'update', config[o.key] ?? o.default) :
					E(o.kind, { name: o.key }, o.label);
				return o.input;
			}));
			return Promise.resolve(this.node);
		}
		parse() {
			for (const option of this.options.filter(o => o.kind == form.DynamicList))
				parseList(option, 'update', option.input, config[option.key],
					value => writes.push(['set', option.key, value]),
					() => { if (config[option.key]?.length) writes.push(['unset', option.key]); });
			return Promise.resolve();
		}
	};
	const page = loadModule(path.join(RES, 'view/aether-proxy/updates.js'), {
		view: { extend: o => o }, form,
		uci: { load: name => { loads.push(name); return Promise.resolve('uci-loaded'); } },
		ui: { createHandlerFn: (self, fn) => fn.bind(self) },
		'aether-proxy.model.updates': model,
		'aether-proxy.common': ap
	}, { window: { setTimeout: (fn, delay) => { timers.push({ fn, delay }); } }, document: {} });
	return { page, calls, loads, timers, maps, jobs, ap, confirmations, writes,
		start: () => {
			assert.equal(timers.length, 1);
			assert.equal(timers[0].delay, 0);
			timers.shift().fn();
		}
	};
}
const settle = () => new Promise(resolve => setImmediate(resolve));

test('T10.47 scenario 2: empty channel URLs save unchanged without errors or writes', async () => {
	for (const config of [{}, { channel_urls: [] }]) {
		const h = load_view(config);
		await h.page.render();
		const option = h.maps[0].options.find(o => o.key == 'channel_urls');
		await h.maps[0].parse();
		assert.deepEqual(option.input.validationCalls, ['']);
		assert.equal(option.input.isValid(), true, 'optional empty add box has no validation error');
		assert.deepEqual(option.input.value, [], 'placeholder is not a persisted channel');
		assert.deepEqual(h.writes, [], 'removing an absent/zero-item UCI option is a no-op');
		assert.deepEqual(h.jobs, []);
	}
});

test('T10.47 scenarios 3/4: channel items and empty add box validate; illegal URLs still block Save', async () => {
	const h = load_view({ channel_urls: ['https://channel.example/path', 'http://backup.example/'] });
	await h.page.render();
	const option = h.maps[0].options.find(o => o.key == 'channel_urls');
	assert.deepEqual(option.input.validationCalls, ['https://channel.example/path', 'http://backup.example/', '']);
	assert.equal(option.input.isValid(), true);
	await h.maps[0].parse();
	assert.deepEqual(h.writes, []);
	option.input.value = ['ftp://invalid.example'];
	assert.equal(option.input.triggerValidation(), false);
	assert.throws(() => h.maps[0].parse(), /HTTP.*HTTPS/);
	assert.deepEqual(h.writes, []);
});

test('T10.16 updates model: pending placeholders disable actions and settled failures clear them', () => {
	const vm = model.table(undefined, false, 160);
	assert.equal(vm.error, null);
	assert.equal(vm.checked, '读取中…');
	assert.equal(vm.can_check, false);
	assert.deepEqual(vm.rows.map(r => r.name), names);
	for (const r of vm.rows) {
		assert.deepEqual([ r.installed, r.available, r.previous, r.status ], Array(4).fill('读取中…'));
		assert.deepEqual([ r.install, r.update, r.rollback ], [ false, false, false ]);
		assert.equal(r.disabled, true);
	}
	for (const r of model.components(undefined)) {
		assert.equal(r.version, '读取中…');
		assert.equal(r.path, '读取中…');
		assert.equal(r.note, '');
	}
	for (const code of [ 'TIMEOUT', 'RPC_FAILED', 'UPDATE_FETCH_FAILED' ]) {
		const result = { ok: false, code, detail: 'offline' };
		const failed = model.table(result, false, 160);
		assert.equal(failed.error, (code == 'UPDATE_FETCH_FAILED' ? '连不上发布通道' : code) + '：offline');
		assert.equal(failed.can_check, true);
		assert.equal(model.table(result, true, 160).can_check, false);
		assert.doesNotMatch(JSON.stringify([ failed, model.components(result) ]), /读取中…/);
	}
});
test('T10.16 updates scenario 1: load only calls uci.load without RPC or timers', async () => {
	const h = load_view();
	assert.equal(await h.page.load(), 'uci-loaded');
	assert.deepEqual(h.loads, [ 'aetherproxy' ]);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.timers, []);
});
test('T10.16 updates scenario 2: complete form and disabled inventory render before pending status', async () => {
	const h = load_view();
	const root = await h.page.render();
	assert.deepEqual(h.calls, [], 'RPC must wait until render resolves');
	assert.equal(root.children.length, 2);
	assert.equal(root.children[0], h.maps[0].node);
	assert.equal(root.children[1], h.page.inventory);
	assert.ok(descendants(h.page.inventory).includes(h.page.summary), 'summary now belongs to the action row');
	const map = h.maps[0];
	assert.equal(map.config, 'aetherproxy');
	assert.equal(map.section_info.name, 'update');
	assert.deepEqual(map.options.map(o => o.key),
		[ 'xray_auto', 'data_auto', 'data_hour', 'data_minute', 'channel_urls' ]);
	assert.ok(map.node.children.every(o => !o.disabled));
	assert.deepEqual(map.options[0].values.map(v => v[0]), [ 'off', 'notify', 'auto' ]);
	assert.equal(map.options[3].placeholder, '30');
	assert.equal(map.options[4].validate('update', 'https://channel/'), true);
	assert.equal(map.options[4].validate('update', 'bad url'), model.validate_url('bad url'));
	const table = h.page.inventory.children.find(n => n.tag == 'table');
	assert.equal(table.children.length, 5);
	for (const row of table.children.slice(1))
		assert.deepEqual(row.children.slice(1, 5).map(text), Array(4).fill('读取中…'));
	for (const name of [ 'xray', 'chinadns-ng' ])
		assert.ok(h.page.inventory.children.some(n => text(n) == name + ': 读取中… — 读取中… '));
	assert.equal(buttons(h.page.inventory).length, 1, 'no package actions before status');
	assert.equal(text(buttons(h.page.inventory)[0]), '检查更新');
	assert.equal(buttons(h.page.inventory)[0].disabled, true);
	const original = text(root);
	h.start();
	await settle(); // No RPC promise is resolved.
	assert.deepEqual(h.calls.map(c => c.method), [ 'status' ]);
	assert.equal(text(root), original);
	assert.equal(buttons(h.page.inventory)[0].disabled, true);
});
test('T10.16 updates scenario 3: status fills only inventory and preserves unsaved policy controls', async () => {
	const h = load_view();
	const root = await h.page.render();
	const nodes = [ ...root.children ];
	const inputs = [ ...nodes[0].children ];
	inputs[0].value = 'off';
	inputs[4].value = 'https://unsaved/';
	h.start();
	const reply = { ok: true, ...status(), components: {
		xray: { version: 'XRAY', path: '/running/xray' },
		'chinadns-ng': { version: 'DNS', path: '/running/dns' }
	} };
	h.calls[0].resolve(reply);
	await settle();
	const table = h.page.inventory.children.find(n => n.tag == 'table');
	const vm = model.table(reply, false, Date.now() / 1000);
	assert.deepEqual(table.children.slice(1).map(r => r.children.slice(0, 5).map(text)),
		vm.rows.map(r => [ r.name, r.installed, r.available, r.previous, r.status ]));
	for (const row of model.components(reply))
		assert.ok(h.page.inventory.children.some(n => text(n) ==
			row.name + ': ' + row.version + ' — ' + row.path + ' ' + row.note));
	assert.doesNotMatch(text(root), /读取中…/);
	assert.deepEqual(buttons(h.page.inventory).map(text), [ '立即更新', '回滚到 1', '检查更新' ]);
	assert.ok(buttons(h.page.inventory).every(b => !b.disabled));
	for (const [i, node] of nodes.entries())
		assert.equal(root.children[i], node, 'only inventory contents may be replaced');
	for (const [i, input] of inputs.entries())
		assert.equal(nodes[0].children[i], input, 'form controls retain identity');
	assert.equal(inputs[0].value, 'off');
	assert.equal(inputs[4].value, 'https://unsaved/');
	assert.equal(h.maps.length, 1);
	assert.equal(h.calls.length, 1);
	assert.deepEqual(h.timers, []);
});
test('T10.16 updates scenario 3: failed status clears placeholders and Check can start a recovery job', async () => {
	for (const code of [ 'TIMEOUT', 'RPC_FAILED' ]) {
		const h = load_view();
		const root = await h.page.render();
		const form = root.children[0];
		form.children[4].value = 'https://unsaved/';
		h.start();
		h.calls[0].resolve({ ok: false, code, detail: 'offline' });
		await settle();
		assert.equal(text(h.page.inventory.children[0]), code + '：offline');
		assert.doesNotMatch(text(root), /读取中…/);
		const actions = buttons(h.page.inventory);
		assert.equal(actions.length, 1);
		assert.equal(actions[0].disabled, false);
		const running = actions[0].click();
		assert.equal(h.page.busy, true);
		assert.ok(buttons(h.page.inventory).every(b => b.disabled));
		await settle();
		assert.deepEqual(h.jobs, [ { kind: 'update_check', args: [] } ]);
		assert.deepEqual(h.calls.map(c => c.method), [ 'status', 'status' ]);
		h.calls[1].resolve({ ok: true, ...status() });
		await running;
		assert.equal(h.page.busy, false);
		assert.ok(buttons(h.page.inventory).every(b => !b.disabled));
		assert.equal(root.children[0], form);
		assert.equal(form.children[4].value, 'https://unsaved/');
	}
});
test('T10.18 scenario 2: settled update actions are enabled only while idle under the shared E', async () => {
	const h = load_view();
	await h.page.render();
	h.start();
	h.calls[0].resolve({ ok: true, ...status() });
	await settle();
	assert.deepEqual(buttons(h.page.inventory).map(text), [ '立即更新', '回滚到 1', '检查更新' ]);
	assert.ok(buttons(h.page.inventory).every(button => button.disabled === false));
	for (const busy of [ true, false ]) {
		h.page.busy = busy;
		h.page.show_inventory();
		assert.ok(buttons(h.page.inventory).every(button => button.disabled === busy));
	}
	// The install-only state must share the same enabled/disabled rule.
	h.page.status = { ok: true, ...status({ ...entry, installed: null, previous: null }) };
	h.page.show_inventory();
	assert.deepEqual(buttons(h.page.inventory).map(text), [ '安装', '检查更新' ]);
	assert.ok(buttons(h.page.inventory).every(button => button.disabled === false));
	h.page.busy = true;
	h.page.show_inventory();
	assert.ok(buttons(h.page.inventory).every(button => button.disabled === true));
});

test('T10.27 scenario 1: Check for updates shares a spaced right-aligned row with result and progress after redraw',
async () => {
	const h = load_view();
	await h.page.render();
	for (const busy of [false, true, false]) {
		h.page.status = { ok: true, ...status() };
		h.page.busy = busy;
		h.page.show_inventory();
		h.page.summary.textContent = 'check result';
		h.page.progress.textContent = 'elapsed';
		const row = actionRow(h.page.inventory, ['检查更新'], [h.page.summary, h.page.progress]);
		const index = h.page.inventory.children.indexOf(row);
		assert.equal(text(h.page.inventory.children[index - 1]), model.manual_install_note(),
			'manual installation guidance precedes actions');
		assert.equal(h.page.inventory.children[index + 1].tag, 'h3', 'next block follows the action row');
	}
});

test('T10.44 scenario 1: Last checked, live progress and completed check share the centered button row', async () => {
	const h = load_view();
	await h.page.render();
	function checkRow() {
		const row = actionRow(h.page.inventory, ['检查更新'], [h.page.summary, h.page.progress]);
		const checked = descendants(h.page.inventory).filter(node =>
			['span', 'p'].includes(node.tag) && text(node).startsWith('上次检查: '));
		assert.equal(checked.length, 1, 'Last checked is mounted exactly once');
		assert.ok(row.children.includes(checked[0]), 'Last checked shares the button row');
		assert.ok(row.children.indexOf(checked[0]) < row.children.indexOf(buttons(row)[0]),
			'Last checked precedes the button');
		marginlessMessages([checked[0], h.page.summary, h.page.progress]);
		return checked[0];
	}
	assert.match(text(checkRow()), /读取中…/);
	h.page.status = status();
	h.page.show_inventory();
	assert.doesNotMatch(text(checkRow()), /读取中…/);
	let finishJob;
	h.ap.run_job = () => new Promise(resolve => { finishJob = resolve; });
	h.ap.job_progress = target => {
		target.textContent = '正在检查更新…（已用 0 秒）';
		return { stop() { target.textContent = ''; } };
	};
	const pending = h.page.run('update_check');
	assert.match(text(h.page.progress), /已用 0 秒/);
	checkRow();
	finishJob({ state: 'ok', result: { ok: true, packages: {} } });
	await settle();
	assert.equal(text(h.page.summary), '检查完成，0 个包有更新');
	checkRow();
	h.calls[0].resolve(status());
	await pending;
	assert.equal(text(h.page.progress), '');
	assert.equal(text(h.page.summary), '检查完成，0 个包有更新');
	checkRow();
});

test('T8.9b scenario 7: view job wiring, rollback confirmation, validation and translations', () => {
	const source = fs.readFileSync(path.join(RES, 'view/aether-proxy/updates.js'), 'utf8');
	assert.match(source, /new form.Map\('aetherproxy'/);
	assert.match(source, /ap.run_job\('update_check', \[\]/);
	assert.match(source, /ap.run_job\('update_package', previous \? \[ name, '--previous' \]/);
	assert.match(source, /cbi-button-remove/);
	assert.match(source, /previous && !await ap\.confirm\(/);
	assert.match(source, /text: row.confirmation,/);
	assert.match(source, /validate.*function[^\n]*model.validate_url/);
	assert.doesNotMatch(source, /rpc.declare|cbi-button-reset|upload|\.depends\s*=/i);
	assert.doesNotMatch(source, /ap.poll/);
	assert.match(source, /disabled: row.disabled \|\| null/);
	assert.match(source, /disabled: !vm.can_check \|\| null/);
	for (const file of [ 'view/aether-proxy/updates.js', 'aether-proxy/model/updates.js' ]) {
		const text = fs.readFileSync(path.join(RES, file), 'utf8');
		for (const match of text.matchAll(/_\('([^']+)', 'aether-proxy'\)/g))
			assert.ok(po[match[1]], 'missing translation: ' + match[1]);
	}
});

function all_packages_status() {
	return { updates_available: { arch: 'test_arch', packages: Object.fromEntries(
		names.map((name, i) => [ name, { ...entry, installed: 'CURRENT-' + i, previous: 'OLD-' + i } ])) } };
}
async function ready_view(s = all_packages_status()) {
	const h = load_view();
	h.root = await h.page.render();
	h.page.status = s;
	h.page.show_inventory();
	h.ap.call = async () => s;
	return h;
}
function rollback_button(h, name) {
	const table = h.page.inventory.children.find(node => node.tag == 'table');
	const row = table.children.find(node => text(node.children[0]) == name);
	return buttons(row).find(node => text(node).startsWith('回滚到'));
}

test('T10.46 scenario 1: only Xray offers rollback even when all four previous versions are installable', async () => {
	const s = all_packages_status();
	const rows = model.table(s, false, 160).rows;
	assert.deepEqual(rows.map(r => r.rollback), [true, false, false, false]);
	assert.ok(rows.every(r => r.update));
	assert.ok(rows.slice(1).every(r => r.confirmation === ''));
	const h = await ready_view(s);
	for (const name of names)
		assert.equal(!!rollback_button(h, name), name == 'xray-core');
	assert.equal(buttons(h.page.inventory).filter(b => text(b).startsWith('回滚')).length, 1);
	assert.deepEqual(buttons(h.page.inventory).map(text),
		['立即更新', '回滚到 OLD-0', '立即更新', '立即更新', '立即更新', '检查更新']);
});
test('T10.46 scenario 1: Xray keeps single-package confirmation, cancellation, dispatch and result', async () => {
	const h = await ready_view();
	assert.equal(rollback_button(h, 'xray-core').attrs.class, 'cbi-button cbi-button-remove');
	await rollback_button(h, 'xray-core').click();
	assert.deepEqual(h.confirmations[0], {
		title: '回滚 xray-core', text: '将安装 OLD-0，替换当前的 CURRENT-0？',
		ok: '回滚', destructive: true
	});
	assert.deepEqual(h.jobs, []);
	assert.equal(h.page.busy, false);
	assert.equal(text(h.page.summary), '');
	assert.ok(buttons(h.page.inventory).every(b => !b.disabled));
	h.ap.confirm = async () => true;
	h.ap.run_job = async (kind, args) => {
		h.jobs.push({ kind, args });
		return { state: 'ok', result: { ok: true, from: 'CURRENT', to: 'OLD' } };
	};
	await rollback_button(h, 'xray-core').click();
	assert.deepEqual(h.jobs, [{ kind: 'update_package', args: ['xray-core', '--previous'] }]);
	assert.equal(text(h.page.summary), 'xray-core 已从 CURRENT 更新到 OLD');
	assert.ok(buttons(h.page.inventory).every(b => !b.disabled));
	assert.equal(h.root.children[0], h.maps[0].node, 'no rollback refresh banner before the form');
});
test('T10.46 scenario 2: model and view contain no grouped rollback or manual refresh UI', () => {
	for (const file of ['aether-proxy/model/updates.js', 'view/aether-proxy/updates.js']) {
		const source = fs.readFileSync(path.join(RES, file), 'utf8');
		// Forward-update companions are allowed by T10.67; grouped manual rollback is still forbidden.
		assert.doesNotMatch(source, /grouped_rollback|ROLLBACK_GROUP|rolls_back_together/);
		assert.doesNotMatch(source, /page_rolled_back|refreshWarning|show_refresh_warning|location.reload/);
		assert.doesNotMatch(source, /These three packages|Roll back Aether Proxy|Refresh page/);
	}
});
const manual_note = '如需安装其他版本：从发布页下载对应版本的三个包，在系统的『软件包』页面上传安装，' +
	'或用 opkg install。降级前注意：新版本的设置旧版本可能不认识，必要时先恢复默认配置。';
test('T10.46 scenario 3: translated manual install guidance sits immediately below the package table', async () => {
	assert.equal(model.manual_install_note(), manual_note);
	const h = load_view();
	await h.page.render();
	for (const s of [undefined, all_packages_status(), { ok: false, code: 'RPC_FAILED' }]) {
		h.page.status = s;
		h.page.show_inventory();
		const children = h.page.inventory.children;
		const index = children.findIndex(node => node.tag == 'table');
		assert.equal(children[index + 1].tag, 'p');
		assert.equal(text(children[index + 1]), manual_note);
	}
});
test('T10.46 scenario 4: automatic recovery text remains unchanged for Xray and backend installs', async () => {
	for (const name of ['xray-core', 'aether-proxy']) {
		const h = await ready_view();
		for (const rolled_back of [true, false]) {
			h.ap.run_job = async () => ({ state: 'failed', result: {
				ok: false, code: 'UPDATE_VERIFY_FAILED', detail: '<probe failed>', rolled_back, from: 'CURRENT'
			} });
			await h.page.run('update_package', name, false);
			assert.equal(text(h.page.summary), rolled_back ?
				'安装后检查失败，已回滚到 CURRENT' : '校验失败：<probe failed>');
			assert.equal(h.page.busy, false);
			assert.ok(buttons(h.page.inventory).every(b => !b.disabled));
			assert.doesNotMatch(text(h.root), /两个页面包没有改动|后端已回滚|页面已换成旧版本/);
		}
	}
});
test('T10.46 scenario 5: every package still installs and updates without previous or rollback confirmation', async () => {
	for (const installed of [null, 'CURRENT']) {
		const s = all_packages_status();
		for (const p of Object.values(s.updates_available.packages))
			p.installed = installed;
		const h = await ready_view(s);
		h.ap.run_job = async (kind, args) => {
			h.jobs.push({ kind, args });
			return { state: 'ok', result: { ok: true, from: installed, to: 'NEW' } };
		};
		for (const name of names) {
			const table = h.page.inventory.children.find(node => node.tag == 'table');
			const row = table.children.find(node => text(node.children[0]) == name);
			const button = buttons(row).find(b => text(b) == (installed ? '立即更新' : '安装'));
			assert.ok(button && !button.disabled);
			await button.click();
			assert.deepEqual(h.jobs.at(-1), { kind: 'update_package', args: [name] });
			const result = installed ? `${name} 已从 CURRENT 更新到 NEW` : `${name} 已安装 NEW`;
			assert.equal(text(h.page.summary), result +
				(name == 'xray-core' ? '' : ' 页面文件可能已变化，请刷新浏览器。'));
		}
		assert.deepEqual(h.confirmations, []);
	}
});
// update.uc update_together() emits a backend transaction plus string-valued companion
// statuses. Failed pages share the first failure's top-level code/detail, not per-page objects.
function group_result(app = 'installed', translation = 'installed', overrides = {}) {
	return { ok: true, package: 'aether-proxy', from: '0.3.0-r1', to: '0.3.1-r1',
		rolled_back: false, code: null, companions: {
			'luci-app-aether-proxy': app, 'luci-i18n-aether-proxy-zh-cn': translation
		}, ...overrides };
}
const refresh_page = '请刷新页面。';
const backend_updated = 'aether-proxy 已从 0.3.0-r1 更新到 0.3.1-r1';
async function display_group_result(result, expected) {
	// A click on the UI package still returns package=aether-proxy from the CLI.
	const h = await ready_view();
	h.ap.run_job = async (kind, args) => {
		assert.equal(kind, 'update_package');
		assert.deepEqual(args, ['luci-app-aether-proxy']);
		return { state: result.ok ? 'ok' : 'failed', result };
	};
	const table = h.page.inventory.children.find(node => node.tag == 'table');
	const row = table.children.find(node => text(node.children[0]) == 'luci-app-aether-proxy');
	await buttons(row).find(b => text(b) == '立即更新').click();
	assert.equal(text(h.page.summary), expected);
	assert.equal(h.page.busy, false);
	assert.ok(buttons(h.page.inventory).every(b => !b.disabled));
	return h;
}
test('T10.67 scenario 1: backend and both pages installed render one grouped result and refresh sentence', async () => {
	await display_group_result(group_result(), backend_updated + '；界面、翻译已同时更新。' + refresh_page);
});
test('T10.67 scenario 2: unchanged backend never claims an update while installed pages request refresh', async () => {
	const h = await display_group_result(group_result('installed', 'installed', { to: '0.3.0-r1' }),
		'界面、翻译已更新。' + refresh_page);
	assert.doesNotMatch(text(h.page.summary), /aether-proxy|已从/);
	await display_group_result(group_result('skipped', 'installed', { to: '0.3.0-r1' }),
		'翻译已更新。' + refresh_page);
});
test('T10.67 scenario 3: skipped pages leave only the backend update and never request refresh', async () => {
	await display_group_result(group_result('skipped', 'skipped'), backend_updated + '。');
});
test('T10.67 scenario 4: one or two page failures retain backend success and only the first cause', async () => {
	for (const [app, translation, suffix, refresh] of [
		['failed', 'skipped', '界面更新失败：校验失败：<bad hash>', false],
		['skipped', 'failed', '翻译更新失败：校验失败：<bad hash>', false],
		['failed', 'failed', '界面更新失败：校验失败：<bad hash>；翻译更新失败', false],
		['failed', 'installed', '翻译已同时更新；界面更新失败：校验失败：<bad hash>', true],
		['installed', 'failed', '界面已同时更新；翻译更新失败：校验失败：<bad hash>', true]
	]) {
		await display_group_result(group_result(app, translation, {
			ok: false, code: 'UPDATE_VERIFY_FAILED', detail: '<bad hash>'
		}), backend_updated + '；' + suffix + '。' + (refresh ? refresh_page : ''));
	}
	await display_group_result(group_result('installed', 'failed', {
		ok: false, to: '0.3.0-r1', code: 'UPDATE_VERIFY_FAILED'
	}), '界面已更新；翻译更新失败：校验失败。' + refresh_page);
	await display_group_result(group_result('failed', 'failed', {
		ok: false, to: '0.3.0-r1', code: 'CMD_FAILED', detail: 'opkg exited 1',
		// Object order is not the backend's installation order.
		companions: { 'luci-i18n-aether-proxy-zh-cn': 'failed', 'luci-app-aether-proxy': 'failed' }
	}), '界面更新失败：CMD_FAILED：opkg exited 1；翻译更新失败。');
});
test('T10.67 scenario 5: all skipped, automatic rollback and primary failures preserve truthful results', async () => {
	await display_group_result(group_result('skipped', 'skipped', { to: '0.3.0-r1' }), '已是最新。');
	await display_group_result(group_result('skipped', 'skipped', {
		ok: false, rolled_back: true, code: 'UPDATE_VERIFY_FAILED'
	}), '安装后检查失败，已回滚到 0.3.0-r1');
	for (const code of ['UPDATE_FETCH_FAILED', 'ARCH_UNSUPPORTED', 'UPDATE_VERIFY_FAILED']) {
		const result = group_result('skipped', 'skipped', { ok: false, code, detail: 'WHY' });
		const expected = model.job_result('update_package', 'aether-proxy', {
			state: 'failed', result: { ok: false, code, detail: 'WHY' }
		});
		await display_group_result(result, expected);
	}
});
test('T10.67 scenario 6: ungrouped Xray and translation updates keep their exact previous messages', () => {
	for (const [name, expected] of [
		['xray-core', 'xray-core 已从 OLD 更新到 NEW'],
		['luci-i18n-aether-proxy-zh-cn',
			'luci-i18n-aether-proxy-zh-cn 已从 OLD 更新到 NEW 页面文件可能已变化，请刷新浏览器。']
	]) {
		assert.equal(model.job_result('update_package', name, {
			state: 'ok', result: { ok: true, package: name, from: 'OLD', to: 'NEW', rolled_back: false, code: null }
		}), expected);
	}
});
test('T10.67 scenario 7: clicked package progress warns only when the backend row is newer', async () => {
	for (const newer of [true, false]) {
		for (const name of names) {
			const s = all_packages_status();
			s.updates_available.packages['aether-proxy'].newer = newer;
			const h = await ready_view(s);
			let finish;
			h.ap.run_job = () => new Promise(resolve => { finish = resolve; });
			const progress = [];
			h.ap.job_progress = (target, prompt) => {
				progress.push(prompt);
				target.textContent = prompt;
				return { stop() { target.textContent = ''; } };
			};
			// Exercise the real package-button handler even when the backend itself has no update.
			const row = model.table(s, false, 160).rows.find(r => r.name == name);
			const pending = h.page.package_button(row, 'install', false).click();
			const grouped = name == 'aether-proxy' || name == 'luci-app-aether-proxy';
			assert.deepEqual(progress, [grouped ? '正在更新 aether-proxy 及其界面…' +
				(newer ? '服务会短暂中断。' : '') : '正在安装 ' + name + '…']);
			assert.ok(buttons(h.page.inventory).every(b => b.disabled));
			finish({ state: 'ok', result: { ok: true, package: name, from: 'OLD', to: 'NEW' } });
			await pending;
			assert.equal(text(h.page.progress), '');
			assert.equal(h.page.busy, false);
		}
	}
	assert.equal(model.job_progress('update_check'), '正在检查更新…');
	assert.equal(model.job_progress('update_package', 'xray-core', true), '正在回滚 xray-core…');
});
test('T10.67 scenario 8: failure code/detail and grouped punctuation use translated format strings', () => {
	assert.equal(model.job_result('update_check', null, { ok: false, code: 'BUSY', detail: 'locked' }),
		'另一个更新作业正在运行：locked');
	assert.equal(model.job_result('update_package', 'xray-core', {
		result: { ok: false, code: 'FUTURE', detail: '<detail>' }
	}), 'FUTURE：<detail>');
	// English must retain ASCII separators and spaces between complete sentences.
	const translate = globalThis._;
	try {
		globalThis._ = s => s;
		assert.equal(model.job_result('update_package', 'luci-app-aether-proxy', { result: group_result() }),
			'aether-proxy updated from 0.3.0-r1 to 0.3.1-r1; Interface, Translation updated together. ' +
			'Please refresh the page.');
		assert.equal(model.job_result('update_check', null, { ok: false, code: 'BUSY', detail: 'locked' }),
			'Another update job is running: locked');
	}
	finally {
		globalThis._ = translate;
	}
});

test('T10.46 scenario 5: pre-install and transport failures retain causes without grouped rollback claims', () => {
	for (const code of ['UPDATE_FETCH_FAILED', 'MANIFEST_BAD_SIGNATURE', 'BUSY', 'JOB_LOST', 'RPC_FAILED']) {
		for (const name of names) {
			const r = { ok: false, code, detail: 'WHY' };
			const result = model.job_result('update_package', name, { state: 'failed', result: r });
			assert.equal(result, model.job_result('update_package', name, r));
			assert.ok(result.endsWith('：WHY'));
			assert.doesNotMatch(result, /两个页面包没有改动|后端已回滚|已回滚到/);
		}
	}
});
