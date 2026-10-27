'use strict';

/* T10.68 / docs/10 B19: mode degradation events describe a runtime override,
 * not a default-mode change. Raw event arguments must survive presentation. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element, contentChildren } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = text => po[text] ?? text;
globalThis.E = element;

function loadLogs() {
	const baseclass = { extend: value => value };
	const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'), { baseclass }, {});
	return loadModule(path.join(RES, 'aether-proxy/model/logs.js'), {
		baseclass, 'aether-proxy.model.conflicts': conflicts
	}, {});
}

function descendants(node) {
	return [node].concat((node.childNodes ?? []).flatMap(descendants));
}

const MODES = [
	['bypass_cn', '绕过大陆'],
	['gfw', '仅代理被墙网站（GFW）'],
	['global', '全局（所有流量走代理）']
];

test('T10.68 scenario 4: degradation and restoration use Chinese mode names and preserve raw hover', () => {
	const logs = loadLogs();
	const page = loadModule(path.join(RES, 'view/aether-proxy/logs.js'), {
		view: { extend: value => value }, uci: { sections: () => [] },
		'aether-proxy.model.logs': logs, 'aether-proxy.common': {},
		dom: { content: (node, children) => contentChildren(node, children) }
	}, { window: { setTimeout() {} }, document: {} });
	const root = page.render();
	for (const [mode, label] of MODES) {
		const cases = [
			['MODE_DEGRADED', { from: mode, to: 'gfw' }, 'warn',
				`节点不可用，绕过大陆临时按「仅代理被墙网站（GFW）」分流（默认模式：${label}）`],
			['MODE_RESTORED', { mode }, 'notice', `节点已恢复，分流已还原（默认模式：${label}）`]
		];
		for (const [code, args, level, expected] of cases) {
			Object.freeze(args);
			const raw = JSON.stringify(args);
			const event = { code, args, level, ts: 100 };
			assert.equal(logs.message(event), expected);
			const row = logs.events({ ok: true, events: [event] }).rows[0];
			assert.equal(row.text, expected);
			assert.equal(row.title, raw);
			page.showEvents({ ok: true, events: [event] });
			const rendered = descendants(root).find(node => node.tag === 'tr' && node.attrs.title);
			assert.equal(rendered.children[3].textContent, expected);
			assert.equal(rendered.attrs.title, raw);
			assert.equal(JSON.stringify(args), raw);
		}
	}
	// The to endpoint is mapped too, not just a literal replacement for gfw.
	assert.equal(logs.message({ code: 'MODE_DEGRADED', args: { from: 'global', to: 'bypass_cn' } }),
		'节点不可用，绕过大陆临时按「绕过大陆」分流（默认模式：全局（所有流量走代理））');
});

test('T10.68 scenario 4: DNS endpoints remain tiers and unknown mode arguments stay diagnostic', () => {
	const logs = loadLogs();
	assert.equal(logs.message({ code: 'DNS_TIER_CHANGED', args: {
		from: 'T1', to: 'T2', reason: 'proxy_unhealthy'
	} }), 'DNS 已从 T1 切换到 T2（原因：proxy_unhealthy）');
	// A generic from/to mapping would pass the tier example accidentally.
	assert.equal(logs.message({ code: 'DNS_TIER_CHANGED', args: {
		from: 'gfw', to: 'global', reason: 'future_reason'
	} }), 'DNS 已从 gfw 切换到 global（原因：future_reason）');
	assert.equal(logs.message({ code: 'MODE_DEGRADED', args: { from: 'future', to: 'future' } }),
		'节点不可用，绕过大陆临时按「future」分流（默认模式：future）');
	assert.equal(logs.message({ code: 'MODE_RESTORED', args: {} }),
		'节点已恢复，分流已还原（默认模式：?）');
});

test('T10.68 review: docs/09 catalog lists both mode events with their parameters', () => {
	const doc = fs.readFileSync(path.resolve(__dirname, '../../docs/09-logging.md'), 'utf8');
	const catalog = doc.split('## 事件码目录')[1].split('## logd 容量')[0];
	const row = catalog.split('\n').find(line => line.includes('`MODE_DEGRADED`'));
	assert.ok(row, 'MODE_DEGRADED catalog row');
	for (const part of ['`MODE_RESTORED`', 'warn / notice', '`from`', '`to`', '`mode`'])
		assert.ok(row.includes(part), part);
});
