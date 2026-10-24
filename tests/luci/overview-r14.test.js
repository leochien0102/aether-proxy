'use strict';

/* T10.48: exercise live UCI cache invalidation and deferred pre-start inventory
 * through the real overview view/model. UCI unload is synchronous like SDK
 * 24.10.8 uci.js; load caches values until explicitly unloaded. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
const RES = path.join(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(RES, '../../../po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = text => po[text] ?? text;
globalThis.E = element;

function all(node, tag) {
	if (!node || typeof node !== 'object')
		return [];
	return [...(node.tag === tag ? [node] : []), ...(node.children ?? []).flatMap(child => all(child, tag))];
}

function model() {
	const baseclass = { extend: value => value };
	const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'), { baseclass }, {});
	const logs = loadModule(path.join(RES, 'aether-proxy/model/logs.js'),
		{ baseclass, 'aether-proxy.model.conflicts': conflicts }, {});
	return loadModule(path.join(RES, 'aether-proxy/model/overview.js'), {
		baseclass, 'aether-proxy.model.logs': logs, 'aether-proxy.model.conflicts': conflicts
	}, {});
}

async function livePage(options = {}) {
	const disk = { enabled: '0', node: 'n_a', mode: 'bypass_cn', labels: { n_a: 'Alpha', n_b: 'Beta' } };
	const h = { disk, status: { state: 'stopped', since: 10 }, calls: [], order: [], polls: [], notes: [] };
	let cache;
	const uci = {
		load: async () => {
			h.order.push('load');
			if (h.failLoad)
				throw new Error('UCI unavailable');
			await h.beforeLoad?.();
			cache ??= structuredClone(disk);
		},
		unload: () => { h.order.push('unload'); cache = undefined; },
		get: (config, section, option) => cache?.[option],
		sections: (config, type, cb) => {
			for (const [id, label] of Object.entries(cache?.labels ?? {}))
				cb({ '.name': id, label });
		},
		set: (config, section, option, value) => { cache[option] = value; },
		save: async () => options.save?.(),
		changes: async () => ({})
	};
	const page = h.page = loadModule(path.join(RES, 'view/aether-proxy/overview.js'), {
		view: { extend: value => value }, uci,
		ui: {
			createHandlerFn: (ctx, fn) => (...args) => fn.apply(ctx, args),
			changes: { apply() {} },
			addNotification: (title, body, kind) => h.notes.push({ text: body.textContent, kind })
		},
		dom: { content: (node, value) => { node.children = Array.isArray(value) ? value : [value]; } },
		'aether-proxy.model.overview': model(),
		'aether-proxy.common': {
			confirm: async () => true,
			call: async (method, params) => {
				h.calls.push([method, params]);
				h.order.push(method);
				if (method === 'status')
					return { ...h.status };
				if (method === 'version' || method === 'components') {
					const generation = h.calls.filter(([name]) => name === method).length;
					if (options.inventory)
						return options.inventory(method, generation);
					return method === 'version' ? { ok: true, version: '0.2.0-r14' }
						: { ok: true, components: { xray: {
							found: true, version: '26.9.30', path: '/usr/bin/xray'
						} } };
				}
				return { ok: true, events: [] };
			},
			poll: (fn, ms) => {
				const poll = { fn, ms, stop() { this.stopped = true; } };
				h.polls.push(poll);
				return poll;
			}
		}
	}, { window: {
		localStorage: { getItem: () => options.interval ?? '5', setItem() {} },
		setTimeout() {}, clearTimeout() {}, addEventListener() {}, removeEventListener() {}
	}, document: { addEventListener() {}, removeEventListener() {} } });
	h.root = page.render(await page.load());
	await page.initialRequest;
	if (!options.inventory)
		await Promise.all([page.versionRequest, page.componentRequest]);
	h.controls = () => {
		const [node, mode] = all(page.nodeControl, 'select');
		return { node, mode, apply: all(page.nodeControl, 'button')[0], enable: all(page.enableControl, 'input')[0] };
	};
	return h;
}

for (const interval of ['5', '0']) {
	const name = interval === '0' ? 'manual' : 'automatic';
	test(`T10.48 scenario 1: ${name} refresh synchronizes external enable and disable`,
		async () => {
		const h = await livePage({ interval });
		assert.ok(h.page.vm.disabled_notice);
		assert.equal(h.controls().enable.checked, false);
		h.disk.enabled = '1';
		h.status = { state: 'running', since: 20, node_id: 'n_a', mode: 'bypass_cn' };
		h.order.length = 0;
		if (interval === '0')
			await all(h.root, 'button').find(button => button.textContent === '刷新').attrs.click();
		else
			await h.polls[0].fn();
		await Promise.all([h.page.versionRequest, h.page.componentRequest]);
		assert.equal(h.page.vm.disabled_notice, null);
		assert.equal(h.controls().enable.checked, true);
		assert.equal(h.page.vm.components[1].version, '26.9.30');
		assert.ok(h.order.indexOf('status') < h.order.indexOf('unload'));
		assert.ok(h.order.indexOf('unload') < h.order.indexOf('load'));
		h.disk.enabled = '0';
		h.status = { state: 'stopped', since: 30 };
		await h.page.fetchRefresh();
		assert.ok(h.page.vm.disabled_notice);
		assert.equal(h.controls().enable.checked, false);
	});
}

test('T10.48 scenario 1: same-second external enable replaces pending pre-start inventory', async () => {
	const stale = [];
	const h = await livePage({ inventory: (method, generation) => {
		if (generation === 1)
			return new Promise(resolve => stale.push(resolve));
		return method === 'version' ? { ok: true, version: 'new-app' }
			: { ok: true, components: { xray: { found: true, version: 'new-xray', path: '/usr/bin/xray' } } };
	} });
	assert.match(h.page.componentContent.textContent, /读取中…/);
	h.disk.enabled = '1';
	/* since is second-resolution, so an inactive-to-active edge need not change it. */
	h.status = { state: 'running', since: 10, node_id: 'n_a', mode: 'bypass_cn' };
	await h.page.fetchRefresh();
	assert.equal(h.calls.filter(([method]) => method === 'components').length, 2,
		'first activation must issue fresh inventory even when since is unchanged');
	await Promise.all([h.page.versionRequest, h.page.componentRequest]);
	assert.match(h.page.componentContent.textContent, /new-app.*new-xray/);
	for (const resolve of stale)
		resolve({ ok: false, code: 'TIMEOUT' });
	for (let i = 0; i < 12; i++)
		await Promise.resolve();
	assert.match(h.page.componentContent.textContent, /new-app.*new-xray/);
	assert.doesNotMatch(h.page.componentContent.textContent, /读取中…|读取失败/);
});

for (const edited of [false, true]) {
	const outcome = edited ? 'preserving edits' : 'updating current selections';
	test(`T10.48 scenario 2: external node, mode and labels refresh ${outcome}`,
		async () => {
		const h = await livePage();
		h.disk.enabled = '1';
		h.status = { state: 'running', since: 20, node_id: 'n_a', mode: 'bypass_cn' };
		await h.page.fetchRefresh();
		if (edited) {
			h.controls().node.value = 'n_b';
			h.controls().mode.value = 'global';
			h.controls().mode.attrs.change();
		}
		h.disk.node = 'n_c';
		h.disk.labels = { ...h.disk.labels, n_b: 'Beta renamed', n_c: 'Gamma' };
		h.disk.mode = 'gfw';
		h.status = { state: 'running', since: 20, node_id: 'n_c', mode: 'gfw' };
		await h.page.fetchRefresh();
		assert.equal(h.page.currentNode, 'n_c');
		assert.equal(h.page.currentMode, 'gfw');
		assert.equal(h.page.vm.switch_notice, null, 'external changes are not mistaken for a stuck local switch');
		assert.equal(h.controls().node.value, edited ? 'n_b' : 'n_c');
		assert.equal(h.controls().mode.value, edited ? 'global' : 'gfw');
		assert.equal(h.controls().apply.disabled, !edited);
		assert.equal(h.controls().node.title, edited ? 'Beta renamed' : 'Gamma');
		assert.ok(h.controls().node.children.some(option => option.textContent === 'Gamma（当前）'));
	});
}

test('T10.48 scenario 2: saving Enable and pending setting switches do not reload UCI', async () => {
	let finishSave;
	const h = await livePage({ save: () => new Promise(resolve => { finishSave = resolve; }) });
	const pending = h.page.handleEnable(true);
	h.order.length = 0;
	await h.page.fetchRefresh();
	assert.ok(!h.order.includes('unload'));
	assert.ok(!h.order.includes('load'));
	assert.equal(h.page.enabled, true, 'remote disabled config cannot overwrite the staged Enable');
	finishSave();
	await pending;
	assert.equal(h.page.enabling, false);
	for (const phase of ['writing', 'reloading']) {
		h.page.switching = phase === 'writing';
		if (phase === 'reloading') {
			h.status = { state: 'running', node_id: 'n_b', mode: 'bypass_cn' };
			h.page.refresh(h.status);
			assert.equal(h.page.vm.switch_busy, true);
		}
		h.order.length = 0;
		await h.page.fetchRefresh();
		assert.ok(!h.order.includes('unload'), phase);
		assert.ok(!h.order.includes('load'), phase);
	}
});

test('T10.48 conservative: failed UCI refresh keeps the last complete snapshot and the next refresh retries',
	async t => {
	const warnings = [];
	t.mock.method(console, 'warn', (...args) => warnings.push(args));
	const h = await livePage();
	h.failLoad = true;
	h.disk.enabled = '1';
	h.disk.node = 'n_b';
	await h.page.fetchRefresh();
	assert.equal(h.page.enabled, false);
	assert.equal(h.page.currentNode, 'n_a');
	assert.equal(h.controls().enable.checked, false);
	assert.equal(h.page.configRequest, null);
	assert.equal(h.page.refreshing, null);
	assert.equal(warnings.length, 1);
	assert.match(String(warnings[0][1]), /UCI unavailable/);
	h.failLoad = false;
	await h.page.fetchRefresh();
	assert.equal(h.page.enabled, true);
	assert.equal(h.page.currentNode, 'n_b');
});

test('T10.48 scenario 2: an in-flight UCI read settles before Enable stages a local change', async () => {
	const h = await livePage();
	let finishRead;
	h.beforeLoad = () => new Promise(resolve => { finishRead = resolve; });
	const refreshing = h.page.fetchRefresh();
	for (let i = 0; i < 12; i++)
		await Promise.resolve();
	assert.equal(typeof finishRead, 'function');
	const enabling = h.page.handleEnable(true);
	assert.equal(h.page.enabling, true);
	assert.equal(h.page.enabled, false, 'no stage until the cache read settles');
	finishRead();
	await Promise.all([refreshing, enabling]);
	assert.equal(h.page.enabled, true);
	assert.equal(h.page.enabling, false);
});

test('T10.48 scenario 5: mode label, dropdown and Apply form one nowrap group; node title follows selection',
	async () => {
	const h = await livePage();
	const { node, mode, apply } = h.controls();
	const [nodeGroup, modeGroup] = h.page.nodeControl.children;
	assert.equal(nodeGroup.children[0], node);
	assert.match(node.attrs.style, /max-width:\s*24em/);
	assert.match(node.attrs.style, /min-width:\s*min\(16em,\s*100%\)/);
	assert.match(nodeGroup.attrs.style, /max-width:\s*100%/);
	assert.match(h.page.nodeControl.attrs.style, /flex-wrap:\s*wrap/);
	assert.match(modeGroup.attrs.style, /flex-wrap:\s*nowrap/);
	assert.match(modeGroup.attrs.style, /white-space:\s*nowrap/);
	assert.match(modeGroup.attrs.style, /max-width:\s*100%/);
	assert.match(mode.attrs.style, /min-width:\s*0/);
	assert.equal(modeGroup.children[0].children[0], '默认模式');
	assert.equal(modeGroup.children[0].children[1], mode);
	assert.equal(modeGroup.children[1], apply);
	node.value = 'n_b';
	node.attrs.change();
	assert.equal(node.title, 'Beta');
});
