'use strict';

/* T10.39 (docs/10 name-aware events): exercise every affected template, the
 * real log controller, and the overview's shared failure-reason presentation.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element, contentChildren } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = s => po[s] ?? s;
globalThis.E = element;
const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'),
	{ baseclass: { extend: o => o } }, {});
const model = loadModule(path.join(RES, 'aether-proxy/model/logs.js'), {
	baseclass: { extend: o => o }, 'aether-proxy.model.conflicts': conflicts
}, {});
const names = Object.freeze({
	nodes: Object.freeze({ n_a: '节点甲', n_b: '节点乙' }),
	subscriptions: Object.freeze({ s_a: '订阅甲' })
});
const IDS = { node: 'n_a', from_node: 'n_a', to_node: 'n_b', sub: 's_a' };
const LABELS = { node: '节点甲', from_node: '节点甲', to_node: '节点乙', sub: '订阅甲' };
const CASES = [
	['RELOAD_APPLIED', { from_node: 'n_a', to_node: 'n_b', elapsed_ms: 123 },
		'已从节点 $from_node 重载到 $to_node，耗时 123 毫秒'],
	['SERVICE_STOPPED', { mode: 'gfw', node: 'n_a' }, '服务已停止（模式 仅代理被墙网站（GFW），节点 $node）'],
	['NODE_RESOLVE_FALLBACK', { node: 'n_a', domain: 'node.example', lkg_ip: '203.0.113.1' },
		'节点 $node：为 node.example 使用最近可用地址 203.0.113.1'],
	['NODE_RESOLVE_FAILED', { node: 'n_a', domain: 'node.example' }, '节点 $node：无法解析 node.example'],
	['NODE_IP_CHANGED', { node: 'n_a', old: '203.0.113.1', new: '203.0.113.2' },
		'节点 $node 的 IP 已从 203.0.113.1 变为 203.0.113.2'],
	['NODE_STALE', { node: 'n_a' }, '节点 $node 已失效'],
	['NODE_STALE_IN_USE', { node: 'n_a' }, '当前节点 $node 已失效'],
	['NODE_INSECURE_IGNORED', { node: 'n_a' }, '已忽略节点 $node 的不安全设置'],
	['SUB_UPDATED', { sub: 's_a', added: 1, updated: 2, stale: 3, removed: 4, skipped: { invalid: 5 } },
		'订阅 $sub：新增 1、更新 2、失效 3、移除 4、跳过 invalid 5'],
	['SUB_FETCH_FAILED', { sub: 's_a', detail: 'offline' }, '订阅 $sub 获取失败：offline'],
	['SUB_DECODE_FAILED', { sub: 's_a', detail: 'invalid' }, '订阅 $sub 解码失败：invalid'],
	['SUB_FORMAT_UNSUPPORTED', { sub: 's_a', detail: 'yaml' }, '订阅 $sub 格式不支持：yaml'],
	['SUB_APPLY_INVALID', { sub: 's_a', detail: 'bad' }, '订阅 $sub 应用无效：bad'],
	['SUB_PROXY_UNAVAILABLE', { sub: 's_a', detail: 'stopped' }, '订阅 $sub 代理不可用：stopped'],
	['SUB_SHRANK', { sub: 's_a', old: 10, new: 2 }, '订阅 $sub 从 10 个节点缩减至 2 个'],
	['SUB_NO_VALID_NODES', { sub: 's_a', skipped: { invalid: 5 } }, '订阅 $sub 无有效节点，跳过 invalid 5']
];
const fill = (text, value) => text.replace(/\$(\w+)/g, (_, key) => value(key));
const event = (code, args) => ({ code, args, ts: 100, level: 'warn' });

for (const [code, args, expected] of CASES) {
	test(`T10.39 scenario 1: ${code} resolves names, event label, deleted references and missing parameters`, () => {
		const original = event(code, Object.freeze({ ...args }));
		assert.equal(model.message(original, names), fill(expected, key => LABELS[key]));
		// label names the event's node only (docs/09); subscriptions and reload endpoints ignore it.
		const deleted = key => key === 'sub' ? '已删除的订阅' : '已删除的节点';
		assert.equal(model.message(event(code, { ...args, label: '发生时的名称' }), names),
			fill(expected, key => key === 'node' ? '发生时的名称' : LABELS[key]));
		// Even deleted references retain a name captured in the event itself.
		assert.equal(model.message(event(code, { ...args, label: '旧名称' }), {}),
			fill(expected, key => key === 'node' ? '旧名称' : deleted(key)));
		for (const label of [undefined, null, '']) {
			assert.equal(model.message(event(code, { ...args, label }), names), fill(expected, key => LABELS[key]));
			assert.equal(model.message(event(code, { ...args, label }), {}),
				fill(expected, key => key === 'sub' ? '已删除的订阅' : '已删除的节点'));
		}
		const keys = Object.keys(args).filter(key => Object.hasOwn(IDS, key));
		for (const key of keys) {
			for (const missing of [undefined, null, '']) {
				const changed = { ...args, [key]: missing, label: '不能掩盖缺参' };
				if (missing === undefined)
					delete changed[key];
				assert.equal(model.message(event(code, changed), names),
					fill(expected, field => field === key ? '?' : field === 'node' ? '不能掩盖缺参' : LABELS[field]));
			}
		}
		assert.deepEqual(original.args, args, 'resolving names never rewrites stored args');
	});
}

test('T10.39 scenario 1: affected catalog coverage and own-property lookup', () => {
	const affected = Object.entries(model.templates).filter(([, template]) =>
		/\{(node|from_node|to_node|sub)\}/.test(template)).map(([code]) => code).sort();
	assert.deepEqual(CASES.map(([code]) => code).sort(), affected);
	for (const id of ['toString', '__proto__', 'constructor']) {
		assert.equal(model.message(event('NODE_STALE', { node: id }), { nodes: {} }), '节点 已删除的节点 已失效');
		assert.equal(model.message(event('SUB_FETCH_FAILED', { sub: id, detail: 'bad' }),
			{ subscriptions: {} }), '订阅 已删除的订阅 获取失败：bad');
	}
});

test('T10.39 scenario 2: stale and insecure templates show exactly one name', () => {
	for (const code of ['NODE_STALE', 'NODE_STALE_IN_USE', 'NODE_INSECURE_IGNORED']) {
		const description = model.message(event(code, { node: 'n_a', label: '发生时的名称' }), names);
		assert.equal(description.split('发生时的名称').length - 1, 1);
		assert.doesNotMatch(description, /n_a|节点甲|（|\(/);
	}
});

test('T10.39 scenario 3: name-aware rows retain byte-identical original args JSON, including IDs', () => {
	for (const [code, args] of CASES) {
		const original = event(code, Object.freeze({ ...args, label: '当时的名称', extra: { secret: 'debug' } }));
		const json = JSON.stringify(original.args);
		const reply = { ok: true, events: [original] };
		const vm = model.events(reply, null, '', '', names);
		assert.equal(vm.rows[0].title, json);
		assert.ok(Object.values(IDS).some(id => json.includes(id)));
		assert.equal(vm.rows[0].text, fill(CASES.find(([item]) => item === code)[2],
			key => key === 'node' ? '当时的名称' : LABELS[key]));
		const failed = model.events({ ok: false, code: 'TIMEOUT' }, vm.data, 'warn', code, names);
		assert.deepEqual(failed.rows, vm.rows, 'failed refresh and filters retain name-aware rows');
		assert.equal(JSON.stringify(original.args), json);
	}
});

const LEGACY = {
	NODE_STALE: '节点 n_a（历史名称）已失效',
	NODE_STALE_IN_USE: '当前节点 n_a（历史名称）已失效',
	NODE_INSECURE_IGNORED: '已忽略节点 n_a（历史名称）的不安全设置'
};
test('T10.39 scenario 4: omitted names preserve every affected legacy message byte for byte', () => {
	for (const [code, args, expected] of CASES) {
		const original = event(code, { ...args, label: '历史名称' });
		const text = LEGACY[code] ?? fill(expected, key => IDS[key]);
		assert.equal(model.message(original), text);
		assert.equal(model.events({ ok: true, events: [original] }).rows[0].text, text);
		for (const key of Object.keys(args).filter(key => Object.hasOwn(IDS, key))) {
			const missing = { ...args, label: '历史名称' };
			delete missing[key];
			assert.equal(model.message(event(code, missing)), text.replaceAll(IDS[key], '?'));
		}
	}
	assert.equal(model.message(event('NODE_STALE', { node: 'n_a' })), '节点 n_a（?）已失效');
	assert.equal(model.message(event('BUSY', {}), names), '操作被 ? 锁定');
	const unknown = event('FUTURE', { node: 'n_a', sub: 's_a', label: '旧名称' });
	assert.equal(model.message(unknown, names), 'FUTURE ' + JSON.stringify(unknown.args));
	assert.equal(model.message(unknown), model.message(unknown, names));
});

function descendants(node) {
	return [node].concat((node.childNodes || []).flatMap(descendants));
}
function content(node, children) {
	contentChildren(node, children);
	if (node.tag === 'select')
		node.value = node.childNodes[0]?.value ?? '';
}

test('T10.39 scenarios 1/3: log view builds UCI maps with section fallbacks and renders safe names plus raw titles',
async () => {
	const calls = [], sections = [], timers = [];
	const unsafe = '<img src=x onerror=alert(1)>';
	const nodes = [{ '.name': 'n_a', label: unsafe }, { '.name': 'n_b', label: '' }];
	const subs = [{ '.name': 's_a', name: '订阅名称' }, { '.name': 's_b' }];
	const events = [
		event('NODE_RESOLVE_FAILED', { node: 'n_a', domain: 'node.example' }),
		event('RELOAD_APPLIED', { from_node: 'n_a', to_node: 'n_b', elapsed_ms: 5 }),
		event('SUB_FETCH_FAILED', { sub: 's_a', detail: 'offline' }),
		event('SUB_FETCH_FAILED', { sub: 's_b', detail: 'offline' })
	];
	const page = loadModule(path.join(RES, 'view/aether-proxy/logs.js'), {
		view: { extend: o => o }, dom: { content }, 'aether-proxy.model.logs': model,
		uci: {
			load: async name => { calls.push(['load', name]); },
			get: () => 'notice',
			sections: (config, type, cb) => {
				sections.push([config, type]);
				(type === 'node' ? nodes : subs).forEach(cb);
			}
		},
		'aether-proxy.common': {
			call: async (method, params) => {
				calls.push([method, params]);
				return method === 'events' ? { ok: true, events } : { ok: true, lines: [{ text: 'raw n_a s_a' }] };
			},
			poll: () => ({ stop() {} })
		}
	}, { window: { setTimeout: fn => timers.push(fn) }, document: {} });
	const root = page.render(await page.load());
	assert.deepEqual(calls, [['load', 'aetherproxy']], 'name lookup adds no RPC and keeps deferred first paint');
	assert.deepEqual(sections, [['aetherproxy', 'node'], ['aetherproxy', 'subscription']]);
	assert.deepEqual({ ...page.names.nodes }, { n_a: unsafe, n_b: 'n_b' });
	assert.deepEqual({ ...page.names.subscriptions }, { s_a: '订阅名称', s_b: 's_b' });
	timers[0]();
	await new Promise(resolve => setImmediate(resolve));
	const rows = descendants(root).filter(node => node.tag === 'tr' && node.attrs.title);
	assert.equal(rows.length, events.length);
	for (const row of rows) {
		const original = events.find(item => JSON.stringify(item.args) === row.attrs.title);
		assert.ok(original, 'title must contain original args, not resolved names');
		assert.equal(row.children[3].textContent, model.message(original, page.names));
	}
	assert.ok(descendants(root).some(node => node.tag === '#text' && node.text.includes(unsafe)));
	assert.ok(!descendants(root).some(node => node.tag === 'img'));
	page.code.value = 'NODE_RESOLVE_FAILED';
	page.code.attrs.change();
	assert.ok(page.eventContent.textContent.includes(unsafe), 'refilter keeps name maps');
	await page.switchTab('raw');
	assert.equal(page.rawContent.textContent, 'raw n_a s_a', 'raw syslog is never name-resolved');
	page.stopPolling();
});

test('T10.39 scenario 5: overview failure reason resolves node names and shares event-label and deletion fallbacks',
() => {
	const overview = loadModule(path.join(RES, 'aether-proxy/model/overview.js'), {
		baseclass: { extend: o => o }, 'aether-proxy.model.logs': model,
		'aether-proxy.model.conflicts': conflicts
	}, {});
	for (const [args, reason] of [
		[{ node: 'n_b', domain: 'node.example' }, '节点 节点乙：无法解析 node.example'],
		[{ node: 'n_b', label: '事件旧名', domain: 'node.example' }, '节点 事件旧名：无法解析 node.example'],
		[{ node: 'n_deleted', domain: 'node.example' }, '节点 已删除的节点：无法解析 node.example']
	]) {
		const vm = overview.build({ ok: true, state: 'running', node_id: 'n_a' }, null,
			names.nodes, 130, true, 'n_b', null,
			{ ok: true, events: [event('NODE_RESOLVE_FAILED', args)] });
		assert.equal(vm.switch_notice,
			'切换到「节点乙」未生效，服务仍在使用「节点甲」。原因：' + reason + '（30 秒前）。'
			+ '可以点「重启」用配置的节点重新启动（会短暂中断代理），或到日志页查看详情。');
	}
});
