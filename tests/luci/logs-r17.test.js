'use strict';

/* T10.60, docs/10 r17: conditional precheck wording, historical nft names and
 * daemon failure steps. Use the real PO and shared models, leaving raw event
 * arguments immutable. The source gate catches newly introduced daemon steps.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
const ROOT = path.resolve(__dirname, '../..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const translate = text => po[text] ?? text;
globalThis._ = translate;
globalThis.E = element;
const baseclass = { extend: value => value };

function models() {
	const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'), { baseclass }, {});
	const logs = loadModule(path.join(RES, 'aether-proxy/model/logs.js'), {
		baseclass, 'aether-proxy.model.conflicts': conflicts
	}, {});
	const overview = loadModule(path.join(RES, 'aether-proxy/model/overview.js'), {
		baseclass, 'aether-proxy.model.conflicts': conflicts, 'aether-proxy.model.logs': logs
	}, {});
	return { conflicts, logs, overview };
}
const { conflicts, logs, overview } = models();
const event = (code, args) => ({ code, args, ts: 100, level: 'error' });

const PRECHECK_CASES = [
	['single conflict', ['conflict:ssr-plus'], '与 ShadowSocksR Plus+ 冲突'],
	['multiple conflicts', ['conflict:ssr-plus', 'conflict:passwall2'],
		'与 ShadowSocksR Plus+ 冲突、与 PassWall 2 冲突'],
	['mixed missing requirements', ['component:xray', 'conflict:ssr-plus', 'command:nft'],
		'与 ShadowSocksR Plus+ 冲突；缺少 component:xray、command:nft'],
	['no conflicts', ['component:xray', 'command:nft'], '缺少 component:xray、command:nft'],
	['only check diagnostic (review)', ['conflict-check:nft failed'], '无法检查其他代理插件（nft failed）'],
	['legacy check diagnostic', ['conflict-check:nft failed', 'component:xray'],
		'无法检查其他代理插件（nft failed）；缺少 component:xray'],
	['mixed check diagnostic', ['conflict:ssr-plus', 'conflict-check:nft failed', 'component:xray'],
		'与 ShadowSocksR Plus+ 冲突、无法检查其他代理插件（nft failed）；缺少 component:xray'],
	['empty list', [], '缺少 '],
	['scalar legacy missing', 'component:xray', '缺少 component:xray'],
	['absent missing', undefined, '缺少 ?'],
	['literal replacement characters', ['conflict:future$&', 'component:$&'],
		'与 future$& 冲突；缺少 component:$&']
];
for (const [name, missing, expected] of PRECHECK_CASES) {
	test('T10.60 scenario 1: PRECHECK_FAILED ' + name, () => {
		const args = Object.freeze({ missing: Array.isArray(missing) ? Object.freeze(missing) : missing });
		const failed = event('PRECHECK_FAILED', args);
		const before = JSON.stringify(args);
		assert.equal(logs.message(failed), '预检失败：' + expected);
		const row = logs.events({ ok: true, events: [failed] }).rows[0];
		assert.equal(row.text, '预检失败：' + expected);
		assert.equal(row.title, before);
		assert.equal(JSON.stringify(args), before);
		if (Array.isArray(missing) && missing.length && missing.every(s => s.startsWith('conflict:')))
			assert.doesNotMatch(row.text, /缺少/);
	});
}

for (const name of ['ss_spec', 'ss_spec_mangle']) {
	test('T10.60 scenario 2: historical ' + name + ' resolves in logs and overview startup reason', () => {
		const missing = ['conflict:' + name];
		assert.equal(conflicts.display_name(name), 'ShadowSocksR Plus+');
		assert.equal(logs.message(event('PRECHECK_FAILED', { missing })),
			'预检失败：与 ShadowSocksR Plus+ 冲突');
		const vm = overview.build({ state: 'error', last_error: 'START_FAILED' },
			{ ok: true }, {}, 100, true, null, null, { ok: true, events: [
				event('PRECHECK_FAILED', { missing }),
				event('START_FAILED', { step: 'precheck', detail: missing.join(',') })
			] });
		assert.equal(vm.error_text, '检测到 ShadowSocksR Plus+ 正在运行，请先在它的页面停用，再启动。');
	});
}

const STEPS = {
	lock: '获取锁', config: '读取配置', precheck: '预检', signal: '处理停止信号',
	wait_network: '等待网络', render: '生成配置', cleanup: '清理旧状态', publish: '发布配置',
	hash: '计算配置哈希', chinadns_start: '启动 chinadns-ng', dnsmasq_install: '安装 dnsmasq 片段',
	write_boot_list: '写入引导域名列表', xray_render: '生成 Xray 配置', xray_test: '校验 Xray 配置',
	xray_start: '启动 Xray', xray_listen: '等待 Xray 监听', sets_load: '读取已保存的动态集合',
	nft_render: '生成 nftables 规则', nft_load: '加载 nftables 规则', route_add: '添加策略路由',
	state: '写入服务状态', lock_release: '释放锁', uloop_init: '初始化事件循环',
	subscription_schedule: '调度订阅更新', sigusr2: '收到信号后重启 Xray',
	reload_stop: '为重载停止服务', stop: '停止服务'
};
for (const [step, expected] of Object.entries(STEPS)) {
	test('T10.60 scenario 3: START_FAILED translates ' + step + ' and reload/monitor prefixes with raw hover', () => {
		for (const [prefix, context] of [['', ''], ['reload:', '重载时'], ['monitor:', '监控时']]) {
			const args = Object.freeze({ step: prefix + step, detail: 'conflict:ss_spec' });
			const failed = event('START_FAILED', args);
			const text = '启动在 ' + context + expected + ' 失败：与 ShadowSocksR Plus+ 冲突';
			assert.equal(logs.message(failed), text);
			const row = logs.events({ ok: true, events: [failed] }).rows[0];
			assert.equal(row.text, text);
			assert.equal(row.title, JSON.stringify(args));
		}
	});
}

test('T10.60 scenario 3: unknown steps and ordinary detail remain byte-identical', () => {
	for (const step of ['future_step', 'reload:future_step', 'monitor:future_step', 'constructor', 'toString']) {
		for (const detail of ['command failed, exit 2', 'mentions conflict:ss_spec in prose', '', '$&', 'a\nb'])
			assert.equal(logs.message(event('START_FAILED', { step, detail })),
				'启动在 ' + step + ' 失败：' + detail);
	}
	assert.equal(logs.message(event('START_FAILED', {})), '启动在 ? 失败：?');
});

test('T10.60 scenario 3: detail formats conflict lists, missing entries, checks and unknown plugin names', () => {
	for (const [detail, expected] of [
		['conflict:ss_spec_mangle,conflict:passwall', '与 ShadowSocksR Plus+ 冲突、与 PassWall 冲突'],
		['component:xray,conflict:ss_spec', '与 ShadowSocksR Plus+ 冲突；缺少 component:xray'],
		['conflict:future$&', '与 future$& 冲突'],
		['conflict-check:nft $& failed', '无法检查其他代理插件（nft $& failed）']
	])
		assert.equal(logs.message(event('START_FAILED', { step: 'precheck', detail })),
			'启动在 预检 失败：' + expected);
});

function descendants(node) {
	return [node].concat((node.childNodes || []).flatMap(descendants));
}

test('T10.60 scenario 3: rendered conflict diagnostics are text nodes and hover retains original args', () => {
	const page = loadModule(path.join(RES, 'view/aether-proxy/logs.js'), {
		view: { extend: value => value }, uci: { sections: () => [] },
		'aether-proxy.model.logs': logs, 'aether-proxy.common': {},
		dom: { content: (node, children) => node.replaceChildren(...children) }
	}, { window: { setTimeout() {} }, document: {} });
	const root = page.render();
	const args = Object.freeze({ step: 'precheck', detail: 'conflict:<img src=x onerror=alert(1)>' });
	page.showEvents({ ok: true, events: [event('START_FAILED', args)] });
	const row = descendants(root).find(node => node.tag === 'tr' && node.attrs.title);
	assert.equal(row.children[3].textContent, '启动在 预检 失败：与 <img src=x onerror=alert(1)> 冲突');
	assert.equal(row.attrs.title, JSON.stringify(args));
	assert.ok(!descendants(root).some(node => node.tag === 'img'));
});

function daemonSteps(source) {
	// All literal failure sites: returned step fields, direct START_FAILED args
	// and event_failure(ctx, step, detail). Timing names in record_step are not failures.
	return new Set([
		...Array.from(source.matchAll(/\bstep\s*:\s*['"]([^'"]+)['"]/g), match => match[1]),
		...Array.from(source.matchAll(/\bevent_failure\(ctx,\s*['"]([^'"]+)['"]/g), match => match[1])
	]);
}

function checkStepTranslations(source) {
	const steps = daemonSteps(source);
	assert.ok(steps.size >= 27, 'the gate must detect returned and directly logged failure steps');
	for (const step of steps) {
		const text = logs.message(event('START_FAILED', { step, detail: 'test' }));
		assert.doesNotMatch(text, new RegExp('启动在 ' + step + ' 失败'), 'missing translation: ' + step);
		assert.ok(Object.prototype.hasOwnProperty.call(STEPS, step), 'missing expected Chinese step: ' + step);
		assert.equal(text, '启动在 ' + STEPS[step] + ' 失败：test', 'missing Chinese translation: ' + step);
	}
}

test('T10.60 scenario 4: every literal daemon failure step has a Chinese translation', () => {
	const source = fs.readFileSync(path.join(ROOT, 'aether-proxy/src/lib/daemon.uc'), 'utf8');
	checkStepTranslations(source);
	assert.deepEqual([...daemonSteps(source)].sort(), Object.keys(STEPS).sort());
	for (const added of ["return { step: 'new_step' };", "event_failure(ctx, 'new_step', 'test');"])
		assert.throws(() => checkStepTranslations(source + '\n' + added), /missing translation: new_step/);
});

test('T10.60 scenarios 1-3: English text and translated placeholder composition stay coherent', () => {
	globalThis._ = text => text;
	try {
		const english = models().logs;
		assert.equal(english.message(event('PRECHECK_FAILED', { missing: ['conflict:ss_spec'] })),
			'Precheck failed: Conflict with ShadowSocksR Plus+');
		assert.equal(english.message(event('PRECHECK_FAILED', { missing: ['component:xray', 'conflict:ss_spec'] })),
			'Precheck failed: Conflict with ShadowSocksR Plus+; Missing component:xray');
		assert.equal(english.message(event('PRECHECK_FAILED', { missing: ['component:xray'] })),
			'Precheck failed: Missing component:xray');
		assert.equal(english.message(event('START_FAILED', { step: 'reload:precheck', detail: 'conflict:ss_spec' })),
			'Start failed at During reload: Precheck: Conflict with ShadowSocksR Plus+');
	} finally {
		globalThis._ = translate;
	}
});
