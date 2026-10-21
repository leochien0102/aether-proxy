'use strict';

/* T8.9b update-page contracts: pure model, CLI URL parity and view wiring.
 * Translations are loaded so assertions cover the text actually shown to users.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadModule, parsePo } = require('./loader');
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
test('T8.9b scenario 3: rollback confirmation includes both versions and correct restart warning', () => {
	for (const name of names) {
		const text = model.confirmation(name, 'CURRENT', 'PREVIOUS');
		assert.match(text, /CURRENT/);
		assert.match(text, /PREVIOUS/);
		assert.equal(text.includes('服务会重启'), name != 'xray-core');
	}
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
		assert.equal(model.job_result('update_check', null, { ok: false, code, detail: 'WHY' }), text + ': WHY');
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
				expected + (detail ? ': WHY' : ''));
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
			assert.equal(!invalid, model.validate_url(url) === true, JSON.stringify(url));
			assert.equal(model.validate_url(url) === true, url.startsWith('http') &&
				[ 'http://host', 'https://host', 'https://host:8443/path?q=x' ].includes(url));
		}
	}
	finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});
test('T8.9b job lifecycle: disable all actions, refresh status once, and confirm rollback before dispatch', async () => {
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
	globalThis.E = (tag, attrs, children) => ({ tag, attrs, children,
		replaceChildren(...nodes) { this.children = nodes; } });
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
	assert.ok(buttons(page.inventory).every(b => b.attrs.disabled));
	finish({ result: { ok: true, from: '2', to: '1' } });
	await pending;
	assert.equal(page.busy, false);
	assert.deepEqual(calls[1], [ 'status' ]);
	assert.equal(calls.length, 2);
	assert.ok(buttons(page.inventory).every(b => !b.attrs.disabled));
});
test('T8.9b scenario 7: view job wiring, rollback confirmation, validation and translations', () => {
	const source = fs.readFileSync(path.join(RES, 'view/aether-proxy/updates.js'), 'utf8');
	assert.match(source, /new form.Map\('aetherproxy'/);
	assert.match(source, /ap.run_job\('update_check', \[\]/);
	assert.match(source, /ap.run_job\('update_package', previous \? \[ name, '--previous' \]/);
	assert.match(source, /cbi-button-remove/);
	assert.match(source, /previous && !await ap\.confirm\(/);
	assert.match(source, /text: row.confirmation/);
	assert.match(source, /validate.*function[^\n]*model.validate_url/);
	assert.doesNotMatch(source, /rpc.declare|cbi-button-reset|upload|\.depends\s*=/i);
	assert.doesNotMatch(source, /ap.poll/);
	assert.match(source, /disabled: row.disabled/);
	assert.match(source, /disabled: !vm.can_check/);
	for (const file of [ 'view/aether-proxy/updates.js', 'aether-proxy/model/updates.js' ]) {
		const text = fs.readFileSync(path.join(RES, file), 'utf8');
		for (const match of text.matchAll(/_\('([^']+)', 'aether-proxy'\)/g))
			assert.ok(po[match[1]], 'missing translation: ' + match[1]);
	}
});
