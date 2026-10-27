'use strict';

/* T10.56: docs/10 "r16 修正：日志页筛选行与事件文字". Exercise the
 * rendered filter hierarchy and conditional messages with real PO translations;
 * keep raw hover arguments and untrusted diagnostics byte-identical.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element, contentChildren } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const translate = s => po[s] ?? s;
globalThis._ = translate;
globalThis.E = element;

function loadModel() {
	const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'),
		{ baseclass: { extend: o => o } }, {});
	return loadModule(path.join(RES, 'aether-proxy/model/logs.js'), {
		baseclass: { extend: o => o }, 'aether-proxy.model.conflicts': conflicts
	}, {});
}
const model = loadModel();
const names = { nodes: { n_a: '节点甲', n_b: '节点乙' } };
const event = (code, args) => ({ code, args, ts: 100, level: 'notice' });

function loadPage() {
	return loadModule(path.join(RES, 'view/aether-proxy/logs.js'), {
		view: { extend: o => o }, 'aether-proxy.model.logs': model, 'aether-proxy.common': {},
		uci: { sections: () => [] },
		dom: { content: (node, children) => contentChildren(node, children) }
	}, { window: { setTimeout() {} }, document: {} });
}

function descendants(node) {
	return [node].concat((node.childNodes || []).flatMap(descendants));
}

function style(node) {
	return Object.fromEntries((node.attrs.style || '').split(';').filter(rule => rule.trim()).map(rule =>
		rule.split(':').map(part => part.trim())));
}

test('T10.56 scenario 1: labeled filters share a spaced wrapping left group; auto refresh is separate on the right',
() => {
	const page = loadPage();
	page.render();
	const [row, content] = page.eventPanel.children;
	assert.equal(content, page.eventContent, 'the filter row stays above event content');
	assert.equal(style(row).display, 'flex');
	assert.equal(style(row)['justify-content'], 'space-between');
	assert.equal(style(row)['flex-wrap'], 'wrap');
	assert.equal(style(row).gap, '1em');
	const [left, auto] = row.children;
	assert.equal(row.children.length, 2, 'only the filter group and refresh control share the outer row');
	assert.equal(left.tag, 'div');
	assert.equal(style(left).display, 'flex');
	assert.equal(style(left).gap, '1em');
	assert.equal(style(left)['flex-wrap'], 'wrap');
	assert.equal(style(left)['max-width'], '100%');
	assert.equal(left.children.length, 2);
	for (const [index, label, select] of [[0, '等级', page.level], [1, '事件码', page.code]]) {
		const group = left.children[index];
		assert.equal(group.tag, 'label');
		assert.equal(group.children.length, 2);
		assert.equal(group.children[0].textContent, label);
		assert.equal(group.children[1], select, 'the label contains its own dropdown');
		assert.equal(style(group).display, 'flex');
		assert.equal(style(group).gap, '0.5em');
		assert.equal(style(group)['flex-wrap'], 'wrap');
		assert.equal(style(group)['max-width'], '100%');
		assert.equal(style(select).width, 'auto', 'override theme width:100% inside a flex row');
		assert.equal(style(select)['max-width'], '100%', 'long event codes cannot exceed the narrow row');
	}
	assert.equal(auto.tag, 'label');
	assert.equal(auto.children.length, 2);
	assert.equal(auto.children[0].textContent, '自动刷新');
	assert.equal(style(auto.children[0])['white-space'], 'nowrap');
	assert.equal(auto.children[1], page.auto);
	assert.equal(style(auto).display, 'flex');
	assert.equal(style(auto).gap, '0.5em');
	assert.equal(page.auto.checked, true);
});

test('T10.56 scenario 1 / X7: filter styles are layout-only and every flex container aligns its controls', () => {
	const page = loadPage();
	page.render();
	const allowed = new Set(['display', 'align-items', 'justify-content', 'gap', 'flex-wrap',
		'margin', 'white-space', 'width', 'max-width']);
	const nodes = descendants(page.eventPanel.children[0]).filter(node => node.tag !== '#text');
	for (const node of nodes) {
		assert.equal(node.attrs.class, undefined, 'the filter row introduces no custom theme classes');
		const rules = style(node);
		for (const key of Object.keys(rules))
			assert.ok(allowed.has(key), 'layout-only property: ' + key);
		if (rules.display === 'flex')
			assert.equal(rules['align-items'], 'center', 'avoid stretching controls to the row height');
		assert.doesNotMatch(node.attrs.style || '', /#[0-9a-f]+|\b\d+px\b/i);
	}
});

test('T10.56 scenario 2: same-node reload says 耗时 and other elapsed_ms messages stay unchanged', () => {
	for (const elapsed_ms of [0, 123]) {
		const args = { from_node: 'n_a', to_node: 'n_a', elapsed_ms };
		const data = { ok: true, events: [event('RELOAD_APPLIED', args)] };
		assert.equal(model.message(data.events[0], names),
			'已重载配置（节点未变：节点甲），耗时 ' + elapsed_ms + ' 毫秒');
		assert.equal(model.events(data, null, '', '', names).rows[0].title, JSON.stringify(args));
		assert.equal(model.message(event('RELOAD_APPLIED', { ...args, to_node: 'n_b' }), names),
			'已从节点 节点甲 重载到 节点乙，耗时 ' + elapsed_ms + ' 毫秒');
		assert.equal(model.message(event('SERVICE_STARTED', { elapsed_ms }), names),
			'服务已启动，耗时 ' + elapsed_ms + ' 毫秒');
	}
});

for (const [description, extra] of [['empty', { stderr: '' }], ['missing', {}], ['null', { stderr: null }]]) {
	test(`T10.56 scenario 3: CMD_FAILED ${description} stderr has no trailing colon`, () => {
		const args = Object.freeze({ cmd: 'nft', rc: 2, ...extra });
		const failed = event('CMD_FAILED', args);
		for (const maps of [undefined, names])
			assert.equal(model.message(failed, maps), '命令 nft 退出码 2');
		const row = model.events({ ok: true, events: [failed] }).rows[0];
		assert.equal(row.text, '命令 nft 退出码 2');
		assert.equal(row.title, JSON.stringify(args));
	});
}

test('T10.56 scenario 3: nonempty stderr keeps its colon, exact content, safe text nodes and original hover', () => {
	const page = loadPage();
	const root = page.render();
	const diagnostics = ['permission denied', 'line one\nline two', ' ', '<img src=x onerror=alert(1)>'];
	const events = diagnostics.map(stderr => event('CMD_FAILED', Object.freeze({ cmd: 'nft', rc: 2, stderr })));
	page.showEvents({ ok: true, events });
	const rows = descendants(root).filter(node => node.tag === 'tr' && node.attrs.title);
	assert.equal(rows.length, events.length);
	for (const [index, row] of rows.entries()) {
		const original = events[events.length - 1 - index];
		assert.equal(model.message(original), '命令 nft 退出码 2：' + original.args.stderr);
		assert.equal(row.children[3].textContent, '命令 nft 退出码 2：' + original.args.stderr);
		assert.equal(row.attrs.title, JSON.stringify(original.args));
	}
	assert.ok(!descendants(root).some(node => node.tag === 'img'));
});

test('T10.56 scenarios 2-3: English reload is unchanged and command suffix follows stderr presence', () => {
	globalThis._ = s => s;
	try {
		const english = loadModel();
		assert.equal(english.message(event('RELOAD_APPLIED', {
			from_node: 'n_a', to_node: 'n_a', elapsed_ms: 12
		}), names), 'Configuration reloaded (node unchanged: 节点甲) in 12 ms');
		for (const extra of [{}, { stderr: '' }, { stderr: null }])
			assert.equal(english.message(event('CMD_FAILED', { cmd: 'nft', rc: 2, ...extra })),
				'Command nft exited with 2');
		assert.equal(english.message(event('CMD_FAILED', { cmd: 'nft', rc: 2, stderr: 'permission denied' })),
			'Command nft exited with 2: permission denied');
	} finally {
		globalThis._ = translate;
	}
});
