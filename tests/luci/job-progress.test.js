'use strict';

/* T10.15: real common.js timers and real page/model code, with deferred jobs
 * and a mutable DOM. The handler double deliberately does NOT restore buttons:
 * recovery must come from the page's finally, not from the LuCI wrapper. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, createRpc, element } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = (text, context) => {
	assert.equal(context, 'aether-proxy');
	assert.ok(po[text], 'translation exists: ' + text);
	return po[text];
};
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
globalThis.E = element;
function text(node) {
	return node == null ? '' : typeof node === 'object' ? node.textContent : String(node);
}
function find(node, predicate) {
	if (node == null || typeof node !== 'object')
		return [];
	return (predicate(node) ? [node] : []).concat(node.children.flatMap(n => find(n, predicate)));
}
const buttons = root => find(root, node => node.tag === 'button');
const button = (root, label) => {
	const found = buttons(root).find(node => text(node) === label);
	assert.ok(found, 'button exists: ' + label);
	return found;
};
function click(node) {
	return node.click({ currentTarget: node });
}
function deferred() {
	let resolve, reject;
	const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
	return { promise, resolve, reject };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
function model(name) {
	const modules = { baseclass: { extend: props => props } };
	if (name === 'overview')
		modules['aether-proxy.model.logs'] = model('logs');
	return loadModule(path.join(RES, 'aether-proxy/model', name + '.js'), modules, {});
}
function common(t) {
	t.mock.timers.enable({ apis: ['Date', 'setInterval'] });
	return loadModule(path.join(RES, 'aether-proxy/common.js'), {
		rpc: createRpc(), baseclass: { extend: props => props }, ui: {}
	}, {});
}
const status = () => ({ ok: true, updates_available: {
	arch: 'test_arch', checked: 100, packages: {
		'xray-core': { installed: null, available: '3', previous: null, asset: 'x.ipk', newer: true },
		'aether-proxy': { installed: '2', available: '3', previous: '1', asset: 'a.ipk', newer: true }
	}
} });

/* Render real GridSection action hooks, not just the top-level toolbar. */
function formDouble(uci) {
	async function renderSection(name, section) {
		return E('div', {}, section.renderRowActions ? uci.sections('aetherproxy', name).map(s =>
			E('div', {}, [
				...section.options.filter(o => o.textvalue).map(o => o.textvalue(s['.name'])),
				section.renderRowActions(s['.name'])
			])) : []);
	}
	return { Map: class {
		constructor() { this.sections = []; }
		section(kind, name) {
			const options = [];
			const section = {
				options,
				option: () => {
					const option = { value() {}, depends() {} };
					options.push(option);
					return option;
				},
				super: method => method === 'render' ? renderSection(name, section) :
					E('td', {}, [E('div', {}, [E('button', {}, 'edit'), E('button', {}, 'delete')])])
			};
			this.sections.push({ name, section });
			return section;
		}
		async render() {
			return E('form', {}, await Promise.all(this.sections.map(({ name, section }) =>
				section.render ? section.render() : renderSection(name, section))));
		}
	} };
}
async function harness(t, name) {
	const jobs = [], calls = [], notifications = [], uciCalls = [], initialReads = [];
	const ap = common(t), vm = model(name);
	const uci = {
		sections: (config, type) => type === 'subscription' ? [{ '.name': 's_a', name: 'Alpha' }] :
			type === 'node' ? [{ '.name': 'n_a', label: 'Node' }] : [],
		get: (config, id) => id === 's_a' ? { '.name': 's_a', name: 'Alpha' } : undefined,
		changes: async () => ({}),
		unload: config => { uciCalls.push(['unload', config]); },
		load: async config => { uciCalls.push(['load', config]); }
	};
	ap.confirm = async () => true;
	ap.run_job = (kind, args, on_update) => {
		const d = deferred();
		jobs.push({ kind, args, on_update, ...d });
		return d.promise;
	};
	ap.call = async method => {
		calls.push(method);
		if (method === 'status')
			return status();
		if (method === 'sub_status')
			return { ok: true, subs: { s_a: { nodes: 4 } } };
		if (method === 'probe_results')
			return { ok: true, done: 1, total: 1, finished: true, nodes: {} };
		return { ok: true, items: { gfwlist: { version: 'new-hash' } } };
	};
	const page = loadModule(path.join(RES, 'view/aether-proxy', name + '.js'), {
		view: { extend: props => props }, form: formDouble(uci), uci,
		ui: {
			createHandlerFn: (self, fn, ...bound) => (...rest) =>
				(typeof fn === 'string' ? self[fn] : fn).apply(self, [...bound, ...rest]),
			addNotification: (target, node) => notifications.push(text(node))
		},
		dom: { content: (target, content) => {
			target.replaceChildren(...(Array.isArray(content) ? content : [content]));
		} },
		'aether-proxy.common': ap, ['aether-proxy.model.' + name]: vm
	}, { window: { setTimeout: fn => initialReads.push(fn) } });
	const root = await page.render();
	// These lifecycle scenarios start after the deferred initial read; their
	// call assertions still count only job-driven refreshes, as before T10.16.
	if (name !== 'rules') {
		initialReads.forEach(fn => fn());
		await flush();
		calls.length = 0;
	}
	return { page, root, ap, vm, uci, jobs, calls, uciCalls, notifications };
}
function activeButtons(h, name) {
	if (name === 'nodes')
		return h.page.probeButtons;
	const labels = name === 'rules' ? ['立即更新'] : name === 'subscriptions' ? ['立即更新', '全部更新'] :
		['安装', '立即更新', '回滚到 1', '检查更新'];
	return buttons(h.root).filter(node => labels.includes(text(node)));
}
// T10.27 groups result/progress before the update button in the final action row.
function progress(h, name) {
	return name === 'rules' ? h.root.children.at(-1).children[1] : h.page.progress;
}
function summary(h, name) {
	return name === 'rules' ? h.root.children.at(-1).children[0] : h.page.summary;
}

test('T10.15 scenario 1: progress starts at zero, reaches three seconds, stop clears and never updates again', t => {
	const ap = common(t), target = E('span', {}, 'old result');
	const handle = ap.job_progress(target, '测试');
	assert.equal(text(target), '测试（已用 0 秒）');
	t.mock.timers.tick(3000);
	assert.equal(text(target), '测试（已用 3 秒）');
	handle.stop();
	assert.equal(text(target), '');
	t.mock.timers.tick(10000);
	assert.equal(text(target), '');
	// A stale queued callback must not overwrite a later result after stop.
	target.textContent = 'done';
	t.mock.timers.tick(3000);
	assert.equal(text(target), 'done');
});
test('T10.15 scenario 1: elapsed time uses the clock when timer ticks are delayed', t => {
	const ap = common(t), target = E('span');
	const handle = ap.job_progress(target, '测试');
	t.mock.timers.setTime(Date.now() + 9000);
	t.mock.timers.tick(1000);
	assert.equal(text(target), '测试（已用 10 秒）');
	handle.stop();
});

const scenarios = [
	{ name: 'rules', label: '立即更新', kind: 'update_data', args: [], prompt: '正在更新规则数据…',
		job: { state: 'ok', result: { updated: ['gfwlist'], unchanged: ['apple'], failed: {} } },
		result: '已更新：被墙域名', calls: ['data_status'] },
	{ name: 'updates', label: '检查更新', kind: 'update_check', args: [], prompt: '正在检查更新…',
		job: { state: 'ok', result: { packages: { a: { newer: true } } } },
		result: '检查完成，1 个包有更新', calls: ['status'] },
	{ name: 'updates', label: '安装', kind: 'update_package', args: ['xray-core'], prompt: '正在安装 xray-core…',
		job: { result: { ok: true, from: null, to: '3' } }, result: 'xray-core 已安装 3', calls: ['status'] },
	{ name: 'updates', label: '立即更新', kind: 'update_package', args: ['aether-proxy'],
		prompt: '正在安装 aether-proxy…', job: { result: { ok: true, from: '2', to: '3' } },
		result: 'aether-proxy 已从 2 更新到 3 页面文件可能已变化，请刷新浏览器。', calls: ['status'] },
	{ name: 'updates', label: '回滚到 1', kind: 'update_package', args: ['aether-proxy', '--previous'],
		prompt: '正在回滚 aether-proxy…', job: { result: { ok: true, package: 'aether-proxy', from: '2', to: '1',
			companions: { 'luci-app-aether-proxy': 'rolled_back', 'luci-i18n-aether-proxy-zh-cn': 'skipped' } } },
		result: 'aether-proxy：已回滚到 1luci-app-aether-proxy: 已回滚luci-i18n-aether-proxy-zh-cn: 已跳过',
		calls: ['status'] },
	{ name: 'subscriptions', label: '立即更新', kind: 'sub_update', args: ['s_a'], prompt: '正在更新订阅…',
		job: { result: { subs: { s_a: { ok: true, added: 1, updated: 2, stale: 3, revived: 4, removed: 5 } } } },
		result: 'Alpha: 新增 1 / 更新 2 / 失效 3 / 恢复 4 / 移除 5', calls: ['sub_status'] },
	{ name: 'subscriptions', label: '全部更新', kind: 'sub_update', args: [], prompt: '正在更新订阅…',
		job: { result: { subs: { s_a: { ok: true, added: 1 } } } },
		result: 'Alpha: 新增 1 / 更新 0 / 失效 0 / 恢复 0 / 移除 0', calls: ['sub_status'] }
];
for (const s of scenarios) {
	test(`T10.15 scenario 2: ${s.name} ${s.label} times, disables, stops, renders results and refreshes`, async t => {
		const h = await harness(t, s.name);
		const pending = click(button(h.root, s.label));
		await flush();
		assert.equal(h.jobs.length, 1);
		assert.equal(h.jobs[0].kind, s.kind);
		assert.deepEqual(h.jobs[0].args, s.args);
		assert.equal(text(progress(h, s.name)), s.prompt + '（已用 0 秒）');
		assert.ok(activeButtons(h, s.name).length > 0);
		assert.ok(activeButtons(h, s.name).every(b => b.disabled));
		t.mock.timers.tick(3000);
		assert.equal(text(progress(h, s.name)), s.prompt + '（已用 3 秒）');
		h.jobs[0].resolve(s.job);
		await pending;
		assert.equal(text(progress(h, s.name)), '');
		assert.ok(text(summary(h, s.name)).includes(s.result), text(summary(h, s.name)));
		assert.ok(activeButtons(h, s.name).every(b => !b.disabled));
		assert.equal(h.page.busy ?? false, false);
		assert.deepEqual(h.calls, s.calls);
		if (s.name === 'subscriptions') {
			assert.doesNotMatch(text(summary(h, s.name)), /操作失败/);
			assert.deepEqual(h.uciCalls, [['unload', 'aetherproxy'], ['load', 'aetherproxy']]);
			assert.match(text(h.root), /成功，4 个节点/);
			assert.deepEqual(h.notifications, [s.result]);
		}
		if (s.name === 'rules')
			assert.match(text(h.root.children.at(-2)), /new-hash/);
		t.mock.timers.tick(10000);
		assert.equal(text(progress(h, s.name)), '');
		assert.ok(text(summary(h, s.name)).includes(s.result));
	});
}

for (const name of ['rules', 'updates', 'subscriptions', 'nodes']) {
	for (const stage of ['reject', 'sync throw', 'result', 'refresh']) {
		test(`T10.15 scenario 3: ${name} ${stage} shows error and restores state for retry`, async t => {
			const h = await harness(t, name);
			const label = name === 'updates' ? '检查更新' : name === 'subscriptions' ? '全部更新' :
				name === 'nodes' ? '检测全部' : '立即更新';
			const error = new Error('<boom>');
			let restore = () => {};
			if (stage === 'sync throw') {
				const run = h.ap.run_job;
				h.ap.run_job = () => { throw error; };
				restore = () => { h.ap.run_job = run; };
			}
			if (stage === 'result') {
				const key = name === 'nodes' ? 'job_failure_text' : 'job_result';
				const result = h.vm[key];
				h.vm[key] = () => { throw error; };
				restore = () => { h.vm[key] = result; };
			}
			if (stage === 'refresh') {
				const call = h.ap.call;
				h.ap.call = async () => { throw error; };
				restore = () => { h.ap.call = call; };
			}
			const pending = click(button(h.root, label));
			await flush();
			if (stage !== 'sync throw') {
				assert.ok(activeButtons(h, name).every(b => b.disabled));
				if (stage === 'reject')
					h.jobs[0].reject(error);
				else
					h.jobs[0].resolve({ state: 'ok', result: { ok: true, subs: {} } });
			}
			await pending;
			const result = name === 'nodes' ? h.notifications.at(-1) : text(summary(h, name));
			assert.equal(result, '操作失败：<boom>');
			assert.equal(h.page.busy ?? false, false);
			assert.equal(h.page.probing ?? false, false);
			assert.ok(activeButtons(h, name).every(b => !b.disabled));
			if (name !== 'nodes') {
				t.mock.timers.tick(10000);
				assert.equal(text(progress(h, name)), '');
				assert.equal(text(summary(h, name)), '操作失败：<boom>');
			}
			restore();
			const before = h.jobs.length;
			const retry = click(button(h.root, label));
			await flush();
			assert.equal(h.jobs.length, before + 1, 'retry dispatches a fresh job');
			h.jobs.at(-1).resolve({ state: 'ok', result: { ok: true, subs: {} } });
			await retry;
			assert.ok(activeButtons(h, name).every(b => !b.disabled));
		});
	}
}
for (const label of ['检测', '检测全部']) {
	test(`T10.15 scenario 3: nodes ${label} preserves native progress and restores both probe buttons`, async t => {
		const h = await harness(t, 'nodes');
		const pending = click(button(h.root, label));
		await flush();
		assert.equal(h.jobs[0].kind, 'probe_nodes');
		assert.deepEqual(h.jobs[0].args, label === '检测' ? ['n_a'] : []);
		assert.ok(h.page.probeButtons.every(b => b.disabled));
		h.ap.call = async method => {
			h.calls.push(method);
			return { ok: true, nodes: {}, done: 1, total: 2, finished: false };
		};
		h.jobs[0].on_update();
		await flush();
		assert.equal(text(h.page.progressEl), '检测中 1/2');
		h.jobs[0].resolve({ state: 'ok' });
		await pending;
		assert.deepEqual(h.calls, ['probe_results', 'probe_results']);
		assert.equal(h.page.probing, false);
		assert.ok(h.page.probeButtons.every(b => !b.disabled));
	});
}
test('T10.15 scenario 3: a rejected on_update refresh is reported without an unhandled rejection', async t => {
	const h = await harness(t, 'nodes');
	const pending = click(button(h.root, '检测全部'));
	h.ap.call = async () => { throw new Error('callback refresh'); };
	h.jobs[0].on_update();
	await flush();
	h.jobs[0].resolve({ state: 'ok' });
	await pending;
	assert.deepEqual(h.notifications, ['操作失败：callback refresh']);
	assert.equal(h.page.probing, false);
	assert.ok(h.page.probeButtons.every(b => !b.disabled));
});

test('T10.15 scenario 3: probe refreshes serialize and settle before buttons are restored', async t => {
	const h = await harness(t, 'nodes'), reads = [];
	h.ap.call = method => {
		assert.equal(method, 'probe_results');
		const read = deferred();
		reads.push(read);
		return read.promise;
	};
	const pending = click(button(h.root, '检测全部'));
	h.jobs[0].on_update();
	h.jobs[0].on_update();
	await flush();
	assert.equal(reads.length, 1, 'a slow reply must not overlap the next refresh');
	h.jobs[0].resolve({ state: 'ok' });
	await flush();
	assert.equal(h.page.probing, true);
	reads[0].resolve({ ok: true, finished: false, nodes: {} });
	await flush();
	assert.equal(reads.length, 2);
	assert.ok(h.page.probeButtons.every(b => b.disabled));
	reads[1].resolve({ ok: true, finished: true, nodes: {} });
	await flush();
	assert.equal(reads.length, 3, 'final results are fetched after the on_update reads');
	assert.equal(h.page.probing, true);
	reads[2].resolve({ ok: true, finished: true, nodes: {} });
	await pending;
	assert.equal(h.page.probing, false);
	assert.ok(h.page.probeButtons.every(b => !b.disabled));
});

for (const name of ['updates', 'subscriptions', 'nodes']) {
	for (const stage of ['initial rendering', 'final rendering']) {
		test(`T10.15 scenario 3: ${name} ${stage} failure cannot strand existing buttons`, async t => {
			const h = await harness(t, name);
			const label = name === 'updates' ? '检查更新' : name === 'subscriptions' ? '全部更新' : '检测全部';
			// Fail the underlying renderer, including the final cleanup redraw itself.
			const key = name === 'updates' ? 'table' : 'build';
			const render = h.vm[key];
			const fail = () => { throw new Error('render failed'); };
			if (stage === 'initial rendering')
				h.vm[key] = fail;
			const pending = click(button(h.root, label));
			await flush();
			if (stage === 'final rendering') {
				assert.ok(activeButtons(h, name).every(b => b.disabled));
				h.vm[key] = fail;
				h.jobs[0].resolve({ state: 'ok', result: { ok: true, subs: {} } });
			}
			await pending;
			assert.equal(h.page.busy ?? false, false);
			assert.equal(h.page.probing ?? false, false);
			assert.ok(activeButtons(h, name).every(b => !b.disabled));
			const message = name === 'nodes' ? h.notifications.at(-1) : text(h.page.summary);
			assert.equal(message, '操作失败：render failed');
			h.vm[key] = render;
			const before = h.jobs.length;
			const retry = click(button(h.root, label));
			await flush();
			assert.equal(h.jobs.length, before + 1);
			h.jobs.at(-1).resolve({ state: 'ok', result: { ok: true, subs: {} } });
			await retry;
		});
	}
}
for (const name of ['rules', 'updates', 'subscriptions', 'nodes']) {
	test(`T10.15 scenario 3: ${name} resolved job failure retains original result and refresh rules`, async t => {
		const h = await harness(t, name);
		const label = name === 'updates' ? '检查更新' : name === 'subscriptions' ? '全部更新' :
			name === 'nodes' ? '检测全部' : '立即更新';
		const pending = click(button(h.root, label));
		await flush();
		h.jobs[0].resolve({ ok: false, code: 'JOB_LOST', detail: 'lost' });
		await pending;
		const message = name === 'nodes' ? h.notifications.at(-1) : text(summary(h, name));
		assert.match(message, /JOB_LOST|作业进程意外退出/);
		assert.doesNotMatch(message, /操作失败/);
		assert.ok(activeButtons(h, name).every(b => !b.disabled));
		assert.deepEqual(h.calls, [name === 'updates' ? 'status' : name === 'subscriptions' ? 'sub_status' :
			name === 'nodes' ? 'probe_results' : 'data_status']);
	});
}

for (const [job, expected] of [
	[{ ok: false, code: 'USAGE', detail: 'unknown subscription' }, '订阅尚未应用，请先保存并应用'],
	[{ ok: false, code: 'BUSY', detail: 'locked' }, '更新失败：BUSY（locked）'],
	[{ ok: false, code: 'TIMEOUT' }, '更新失败：TIMEOUT'],
	[{ state: 'failed', result: { ok: false, code: 'FS_FAILED', detail: 'read failed' } },
		'更新失败：FS_FAILED（read failed）']
]) {
	test(`T10.28 scenario 4: subscription failure displays one nonempty line: ${expected}`, async t => {
		const h = await harness(t, 'subscriptions');
		const pending = click(button(h.root, '全部更新'));
		await flush();
		h.jobs[0].resolve(job);
		await pending;
		assert.equal(text(h.page.summary), expected);
		assert.equal(h.page.summary.children.length, 1);
		assert.deepEqual(h.notifications, [expected]);
		assert.ok(activeButtons(h, 'subscriptions').every(button => !button.disabled));
	});
}

test('T10.28 scenario 4: job rows use current UCI names, deleted IDs fall back, failures use event text', async t => {
	const h = await harness(t, 'subscriptions');
	const pending = click(button(h.root, '全部更新'));
	await flush();
	// Resolve names only after the job finishes, not from its pre-job row snapshot.
	const lookups = [];
	h.uci.get = (config, id) => {
		lookups.push(id);
		return id === 's_a' ? { '.name': id, name: 'Current name' } : null;
	};
	h.jobs[0].resolve({ result: { subs: {
		s_a: { ok: false, code: 'SUB_FETCH_FAILED' }, s_deleted: { ok: true, added: 2 }
	} } });
	await pending;
	assert.deepEqual(lookups.slice(0, 2), ['s_a', 's_deleted'], 'resolve only the result IDs before redraw');
	assert.deepEqual(h.page.summary.children.map(text), [
		'Current name: 下载失败', 's_deleted: 新增 2 / 更新 0 / 失效 0 / 恢复 0 / 移除 0'
	]);
});

test('T10.28 scenario 4: an empty subscription result never emits an empty notification', async t => {
	const h = await harness(t, 'subscriptions');
	const pending = click(button(h.root, '全部更新'));
	await flush();
	h.jobs[0].resolve({ state: 'ok', result: { subs: {} } });
	await pending;
	assert.deepEqual(h.page.summary.children, []);
	assert.deepEqual(h.notifications, []);
});

test('T10.28 scenario 3: Update all stays usable with pending rows; finally preserves their lock', async t => {
	const h = await harness(t, 'subscriptions');
	h.uci.changes = async () => ({ aetherproxy: [['set', 's_a', 'name', 'Pending']] });
	await h.page.refresh_changes();
	assert.equal(button(h.root, '立即更新').disabled, true);
	assert.equal(button(h.root, '全部更新').disabled, false);
	const pending = click(button(h.root, '全部更新'));
	await flush();
	assert.equal(h.jobs.length, 1);
	assert.deepEqual(h.jobs[0].args, []);
	h.jobs[0].resolve({ result: { subs: { s_a: { ok: true } } } });
	await pending;
	assert.equal(h.page.busy, false);
	assert.equal(button(h.root, '立即更新').disabled, true);
	assert.equal(button(h.root, '立即更新').title, '请先保存并应用');
	assert.equal(button(h.root, '全部更新').disabled, false);
});

test('T10.31 scenario 4: a rollback warning survives a rejected status refresh and later retry', async t => {
	const h = await harness(t, 'updates');
	const pending = click(button(h.root, '回滚到 1'));
	await flush();
	assert.equal(text(h.page.progress), '正在回滚 aether-proxy…（已用 0 秒）');
	assert.ok(activeButtons(h, 'updates').every(button => button.disabled));
	h.ap.call = async () => { throw new Error('status unavailable'); };
	h.jobs[0].resolve({ result: { ok: true, package: 'aether-proxy', to: '1', companions: {
		'luci-app-aether-proxy': 'rolled_back', 'luci-i18n-aether-proxy-zh-cn': 'rolled_back'
	} } });
	await pending;
	assert.equal(text(h.page.summary), '操作失败：status unavailable');
	assert.equal(text(h.page.progress), '');
	assert.match(text(h.root.children[0]), /页面已换成旧版本，请刷新页面/);
	assert.ok(activeButtons(h, 'updates').every(button => !button.disabled));
	assert.equal(h.page.busy, false);
	t.mock.timers.tick(10000);
	assert.equal(text(h.page.progress), '');
	h.ap.call = async () => status();
	const retry = click(button(h.root, '检查更新'));
	await flush();
	h.jobs[1].resolve({ result: { ok: true, packages: {} } });
	await retry;
	assert.match(text(h.root.children[0]), /页面已换成旧版本，请刷新页面/);
	assert.equal(h.page.busy, false);
});

test('T10.15 scenario 4: chinadns-ng instructions embed optional arch; xray missing notice is unchanged', () => {
	const updates = model('updates');
	assert.equal(updates.components(status())[1].note,
		'不经发布通道自动更新：请在软件包页面从软件源安装或更新，或从发布页下载 chinadns-ng 包（本机架构 test_arch）手工安装。');
	assert.equal(updates.components({ updates_available: null })[1].note,
		'不经发布通道自动更新：请在软件包页面从软件源安装或更新，或从发布页下载 chinadns-ng 包手工安装。');
	const overview = model('overview');
	const vm = overview.build({ ok: true, notices: [
		{ code: 'COMPONENT_MISSING', args: { component: 'chinadns-ng' } },
		{ code: 'COMPONENT_MISSING', args: { component: 'xray' } }
	] });
	assert.equal(vm.notices[0],
		'缺少组件 chinadns-ng，请先安装再启动服务。 或从发布页下载 chinadns-ng 包手工安装。');
	assert.equal(vm.notices[1], '缺少组件 xray，请先安装再启动服务。');
});
