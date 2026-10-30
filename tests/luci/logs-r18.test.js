'use strict';

/* T10.64, docs/10 r18: START_FAILED wraps the translated step/context once.
 * Exercise both languages, the real view's raw hover and the overview consumer
 * so a shared template regression cannot hide behind model-to-model equality.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element, contentChildren } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
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
	return { logs, overview };
}

const CASES = [
	['precheck', '预检', 'Precheck'],
	['reload:render', '重载时生成配置', 'During reload: Generate configuration'],
	['monitor:render', '监控时生成配置', 'During monitoring: Generate configuration'],
	...['future_step', 'reload:future_step', 'monitor:future_step', 'constructor', 'toString']
		.map(step => [step, step, step])
];
const event = args => ({ code: 'START_FAILED', args, ts: 100, level: 'error' });

function descendants(node) {
	return [node].concat((node.childNodes || []).flatMap(descendants));
}

for (const language of ['Chinese', 'English']) {
	test(`T10.64 scenario 1: ${language} START_FAILED wraps known, prefixed and unknown steps with raw hover`, () => {
		globalThis._ = language === 'Chinese' ? translate : text => text;
		try {
			const { logs } = models();
			const page = loadModule(path.join(RES, 'view/aether-proxy/logs.js'), {
				view: { extend: value => value }, uci: { sections: () => [] },
				'aether-proxy.model.logs': logs, 'aether-proxy.common': {},
				dom: { content: (node, children) => contentChildren(node, children) }
			}, { window: { setTimeout() {} }, document: {} });
			const root = page.render();
			for (const [step, chinese, english] of CASES) {
				const args = Object.freeze({ step, detail: 'conflict:ssr-plus' });
				const original = JSON.stringify(args);
				const failed = event(args);
				const expected = language === 'Chinese'
					? `启动失败（${chinese}）：与 ShadowSocksR Plus+ 冲突`
					: `Start failed (${english}): Conflict with ShadowSocksR Plus+`;
				assert.equal(logs.message(failed), expected);
				const row = logs.events({ ok: true, events: [failed] }).rows[0];
				assert.equal(row.text, expected);
				assert.equal(row.title, original);
				page.showEvents({ ok: true, events: [failed] });
				const rendered = descendants(root).find(node => node.tag === 'tr' && node.attrs.title);
				assert.equal(rendered.children[3].textContent, expected);
				assert.equal(rendered.attrs.title, original);
				assert.equal(JSON.stringify(args), original);
			}
		} finally {
			globalThis._ = translate;
		}
	});
}

test('T10.64 scenario 1: overview reload failure inherits the revised shared log template', () => {
	const { overview } = models();
	const failed = event({ step: 'reload:render', detail: 'conflict:ss_spec' });
	const vm = overview.build({ ok: true, state: 'running', node_id: 'n_a' }, null,
		{ n_a: '甲', n_b: '乙' }, 130, true, 'n_b', null, { ok: true, events: [failed] });
	assert.equal(vm.switch_notice,
		'切换到「乙」未生效，服务仍在使用「甲」。原因：启动失败（重载时生成配置）：'
		+ '与 ShadowSocksR Plus+ 冲突（30 秒前）。可以点「重启」用配置的节点重新启动'
		+ '（会短暂中断代理），或到日志页查看详情。');
});
