'use strict';

/* T10.50: docs/10 "r14 修正：事件文字". Check conditional templates,
 * localized modes, and the real controller's unchanged raw-argument hover.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const modelFile = path.join(RES, 'aether-proxy/model/logs.js');
const conflictFile = path.join(RES, 'aether-proxy/model/conflicts.js');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = s => po[s] ?? s;
const conflicts = loadModule(conflictFile, { baseclass: { extend: o => o } }, {});
const model = loadModule(modelFile, {
	baseclass: { extend: o => o }, 'aether-proxy.model.conflicts': conflicts
}, {});
const names = {
	nodes: { n_a: '节点甲', n_b: '节点乙', n_alias: '节点甲', n_plain: 'n_plain' },
	subscriptions: { s_a: '订阅甲' }
};
const event = (code, args) => ({ code, args, ts: 100, level: 'notice' });
const updated = { sub: 's_a', added: 1, updated: 2, stale: 3, removed: 4 };
const noSkipped = '订阅 订阅甲：新增 1、更新 2、失效 3、移除 4';

for (const [description, extra] of [
	['empty object', { skipped: {} }],
	['missing', {}],
	['all zero counts', { skipped: { invalid: 0, unsupported: 0 } }],
	['null', { skipped: null }]
]) {
	test(`T10.50 scenario 1: SUB_UPDATED omits skipped for ${description}`, () => {
		const args = Object.freeze({ ...updated, ...extra });
		assert.equal(model.message(event('SUB_UPDATED', args), names), noSkipped);
		assert.equal(model.events({ ok: true, events: [event('SUB_UPDATED', args)] }, null, '', '', names)
			.rows[0].text, noSkipped);
		assert.equal(model.message(event('SUB_UPDATED', args)), noSkipped.replace('订阅甲', 's_a'));
	});
}

test('T10.50 scenario 1: nonzero skipped counts retain the original reasons, zeros and ordering', () => {
	for (const skipped of [{ invalid: 5 }, { unsupported: 0, invalid: 2, duplicate: 3 }]) {
		const args = { ...updated, skipped: Object.freeze(skipped) };
		const expected = noSkipped + '、跳过 ' + Object.entries(skipped).map(([k, v]) => k + ' ' + v).join('、');
		assert.equal(model.message(event('SUB_UPDATED', Object.freeze(args)), names), expected);
	}
	// SUB_NO_VALID_NODES is not a successful update and retains its existing template.
	assert.equal(model.message(event('SUB_NO_VALID_NODES', { sub: 's_a', skipped: {} }), names),
		'订阅 订阅甲 无有效节点，跳过 ');
});

test('T10.50 scenario 2: same-node reload resolves names, section fallback, deleted nodes and legacy IDs', () => {
	for (const [id, maps, name] of [
		['n_a', names, '节点甲'],
		['n_plain', names, 'n_plain'],
		['n_deleted', names, '已删除的节点'],
		['n_a', undefined, 'n_a']
	]) {
		const args = Object.freeze({
			from_node: id, to_node: id, label: 'not an endpoint label', elapsed_ms: 123,
			actions: ['restart_xray'], steps: { validate: 12 }
		});
		assert.equal(model.message(event('RELOAD_APPLIED', args), maps),
			'已重载配置（节点未变：' + name + '），用时 123 毫秒');
	}
});

test('T10.50 scenario 2: different IDs keep the original reload text even when names match', () => {
	for (const [to, name] of [['n_b', '节点乙'], ['n_alias', '节点甲']]) {
		const args = { from_node: 'n_a', to_node: to, elapsed_ms: 42 };
		assert.equal(model.message(event('RELOAD_APPLIED', args), names),
			'已从节点 节点甲 重载到 ' + name + '，耗时 42 毫秒');
	}
	for (const missing of [undefined, null, '']) {
		assert.equal(model.message(event('RELOAD_APPLIED', {
			from_node: missing, to_node: missing, elapsed_ms: 42
		}), names), '已从节点 ? 重载到 ?，耗时 42 毫秒');
	}
});

const MODES = [
	['gfw', '仅代理被墙网站（GFW）'],
	['bypass_cn', '绕过大陆'],
	['global', '全局（所有流量走代理）'],
	['direct', '直连'],
	['proxy', '全局（所有流量走代理）']
];
for (const [mode, label] of MODES) {
	test(`T10.50 scenario 3: mode ${mode} uses its shared Chinese name and preserves raw args`, () => {
		const args = Object.freeze({ mode, node: 'n_a' });
		const original = JSON.stringify(args);
		const data = { ok: true, events: [event('SERVICE_STOPPED', args)] };
		assert.equal(model.message(data.events[0], names), '服务已停止（模式 ' + label + '，节点 节点甲）');
		assert.equal(model.message(data.events[0]), '服务已停止（模式 ' + label + '，节点 n_a）');
		const row = model.events(data, null, '', '', names).rows[0];
		assert.equal(row.text, model.message(data.events[0], names));
		assert.equal(row.title, original);
		assert.equal(JSON.stringify(args), original);
	});
}

test('T10.50 scenario 3: unknown and missing modes retain literal and question-mark fallbacks', () => {
	for (const mode of ['future_mode', '__proto__', 'constructor', 'toString']) {
		assert.equal(model.message(event('SERVICE_STOPPED', { mode, node: 'n_a' }), names),
			'服务已停止（模式 ' + mode + '，节点 节点甲）');
	}
	for (const mode of [undefined, null])
		assert.equal(model.message(event('SERVICE_STOPPED', { mode, node: 'n_a' }), names),
			'服务已停止（模式 ?，节点 节点甲）');
	const unknown = event('FUTURE', { mode: 'gfw', node: 'n_a' });
	assert.equal(model.message(unknown, names), 'FUTURE ' + JSON.stringify(unknown.args));
	// Starting stays compact even though its catalog parameters also include mode.
	assert.equal(model.message(event('SERVICE_STARTED', { mode: 'gfw', elapsed_ms: 12 }), names),
		'服务已启动，耗时 12 毫秒');
});

test('T10.50 scenarios 1-3: alternate templates and modes also render in English', () => {
	globalThis._ = s => s;
	try {
		const englishConflicts = loadModule(conflictFile, { baseclass: { extend: o => o } }, {});
		const english = loadModule(modelFile, {
			baseclass: { extend: o => o }, 'aether-proxy.model.conflicts': englishConflicts
		}, {});
		assert.equal(english.message(event('SUB_UPDATED', updated), names),
			'Subscription 订阅甲: added 1, updated 2, stale 3, removed 4');
		assert.equal(english.message(event('RELOAD_APPLIED', {
			from_node: 'n_a', to_node: 'n_a', elapsed_ms: 12
		}), names), 'Configuration reloaded (node unchanged: 节点甲) in 12 ms');
		assert.equal(english.message(event('SERVICE_STOPPED', { mode: 'bypass_cn', node: 'n_a' }), names),
			'Service stopped (mode Bypass China, node 节点甲)');
	} finally {
		globalThis._ = s => po[s] ?? s;
	}
});

function descendants(node) {
	return [node].concat((node.childNodes || []).flatMap(descendants));
}

test('T10.50 scenarios 1-3: real log view renders revised text safely and keeps byte-identical raw hover', () => {
	globalThis.E = element;
	const unsafe = '<img src=x onerror=alert(1)>';
	const page = loadModule(path.join(RES, 'view/aether-proxy/logs.js'), {
		view: { extend: o => o }, 'aether-proxy.model.logs': model, 'aether-proxy.common': {},
		uci: {
			sections: (config, type, cb) => (type === 'node'
				? [{ '.name': 'n_a', label: unsafe }] : [{ '.name': 's_a', name: '订阅甲' }]).forEach(cb)
		},
		dom: { content: (node, children) => node.replaceChildren(...(Array.isArray(children) ? children : [children])) }
	}, { window: { setTimeout() {} }, document: {} });
	const root = page.render();
	const events = [
		event('SUB_UPDATED', { ...updated, skipped: {} }),
		event('RELOAD_APPLIED', { from_node: 'n_a', to_node: 'n_a', elapsed_ms: 12 }),
		...MODES.map(([mode]) => event('SERVICE_STOPPED', { mode, node: 'n_a' }))
	];
	const originals = events.map(e => JSON.stringify(e.args));
	page.showEvents({ ok: true, events });
	const rows = descendants(root).filter(n => n.tag === 'tr' && n.attrs.title);
	assert.equal(rows.length, events.length);
	for (const [index, row] of rows.entries()) {
		const original = events[events.length - 1 - index];
		assert.equal(row.attrs.title, JSON.stringify(original.args));
		assert.equal(row.children[3].textContent, model.message(original, page.names));
	}
	assert.ok(rows.some(row => row.children[3].textContent === noSkipped));
	assert.ok(rows.some(row => row.children[3].textContent ===
		'已重载配置（节点未变：' + unsafe + '），用时 12 毫秒'));
	assert.ok(!descendants(root).some(n => n.tag === 'img'));
	assert.deepEqual(events.map(e => JSON.stringify(e.args)), originals);
});
