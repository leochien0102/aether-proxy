'use strict';

/* T10.71: regressions use the shipped view/model, not a second state machine. */
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadModule, element, contentChildren } = require('./loader');
const RES = path.join(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
globalThis._ = text => text;
globalThis.E = element;
const baseclass = { extend: value => value };
const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'), { baseclass }, {});
const logs = loadModule(path.join(RES, 'aether-proxy/model/logs.js'),
	{ baseclass, 'aether-proxy.model.conflicts': conflicts }, {});
const model = loadModule(path.join(RES, 'aether-proxy/model/overview.js'),
	{ baseclass, 'aether-proxy.model.logs': logs, 'aether-proxy.model.conflicts': conflicts }, {});
function all(node, tag) {
	return !node || typeof node !== 'object' ? []
		: [...(node.tag === tag ? [node] : []), ...(node.children ?? []).flatMap(n => all(n, tag))];
}
async function harness(node = 'n_a') {
	const h = { disk: { node, mode: 'bypass_cn', enabled: '0' }, calls: [], timers: [], polls: [], saves: 0 };
	h.status = { state: 'running', node_id: node, mode: 'bypass_cn' };
	const page = h.page = loadModule(path.join(RES, 'view/aether-proxy/overview.js'), {
		view: baseclass,
		uci: { load: async () => {}, unload() {}, get: (c, s, k) => h.disk[k],
			sections: (c, t, fn) => ['n_a', 'n_b'].forEach(id => fn({ '.name': id, label: id })),
			set: (c, s, k, v) => { h.disk[k] = v; }, save: async () => { h.saves++; } },
		ui: { createHandlerFn: (ctx, fn) => (...args) => fn.apply(ctx, args), changes: { apply() {} },
			addNotification() {} }, dom: { content: contentChildren },
		'aether-proxy.model.overview': model,
		'aether-proxy.common': { confirm: async () => true,
			poll: (fn, ms) => { const p = { fn, ms, stop() { this.stopped = true; } }; h.polls.push(p); return p; },
			call: async (method, params) => {
				h.calls.push([method, params]);
				if (method === 'status') return h.readStatus ? h.readStatus() : structuredClone(h.status);
				if (method.endsWith('_use')) {
					if (h.use) return h.use(method, params);
					const previous = h.disk.node, previous_mode = h.disk.mode;
					h.disk.node = params.id ?? h.disk.node;
					h.disk.mode = params.mode ?? h.disk.mode;
					return { ok: true, committed: true, previous, previous_mode, reload: true };
				}
				return { ok: true, events: [], sites: [] };
			} }
	}, { window: { localStorage: { getItem: () => '0' },
		setTimeout: (fn, ms) => { const t = { fn, ms }; h.timers.push(t); return t; },
		clearTimeout: t => { if (t) t.cleared = true; }, addEventListener() {}, removeEventListener() {} },
		document: { addEventListener() {}, removeEventListener() {} } });
	h.root = page.render(await page.load());
	await page.initialRequest;
	return h;
}

test('T10.71 first reproduce: no current node has an explicit empty placeholder and disabled Apply', async () => {
	const h = await harness(null);
	const first = all(h.page.nodeControl, 'option')[0];
	assert.equal(first.value, '');
	assert.equal(first.textContent, 'Not selected');
	assert.equal(all(h.page.nodeControl, 'button')[0].disabled, true);
});
test('T10.71 first reproduce: enabling without an applied node cannot write enabled', async () => {
	const h = await harness(null);
	assert.equal(h.page.enableInput.disabled, true);
	await h.page.handleEnable(true);
	await h.page.saveEnable(true);
	assert.equal(h.saves, 0);
});
test('T10.71 first reproduce: node page has no set-current handler', () => {
	const fs = require('node:fs');
	const source = fs.readFileSync(path.join(RES, 'view/aether-proxy/nodes.js'), 'utf8');
	assert.doesNotMatch(source, /handleSetCurrent|switchButtons|Set as current/);
});
test('T10.71 first reproduce: Apply opens an unclosable switching overlay', async () => {
	const h = await harness();
	let resolve;
	h.use = () => new Promise(r => { resolve = r; });
	const pending = h.page.handleNode('n_b', 'bypass_cn');
	assert.equal(h.page.switchSession?.phase, 'switching');
	assert.equal(all(h.page.switchOverlay, 'button').length, 0);
	resolve({ ok: false, committed: false, code: 'CONFIG_INVALID' });
	await pending;
});

function completion(h, ok, node = 'n_b', mode = 'bypass_cn') {
	h.status.last_reload = { at: Math.floor(Date.now() / 1000) + 1,
		target_node: node, target_mode: mode, ok, error: ok ? null : 'reload broken' };
	if (ok) {
		h.status.node_id = node;
		h.status.mode = mode;
	}
}
async function closeAfterTwoSeconds(h) {
	const timer = h.timers.find(t => t.ms === 2000 && !t.cleared);
	assert.ok(timer, 'success has a two-second close timer');
	assert.equal(h.page.switching, true, 'actions stay blocked during the success message');
	await timer.fn();
	assert.equal(h.page.switchSession, null);
	assert.equal(h.page.actionFields.disabled, false);
}

test('T10.71 scenario 1: matching completion succeeds, refreshes UCI/status and closes after two seconds', async () => {
	const h = await harness();
	await h.page.handleNode('n_b', 'bypass_cn');
	assert.equal(h.page.switchSession.phase, 'switching');
	completion(h, true);
	await h.page.pollSwitch(h.page.switchSession);
	assert.equal(h.page.switchSession.phase, 'success');
	assert.equal(h.page.currentNode, 'n_b');
	assert.equal(h.page.nodeSelect.value, 'n_b');
	await closeAfterTwoSeconds(h);
	assert.equal(h.calls.filter(([name]) => name === 'node_use').length, 1);
});

test('T10.71 result matching rejects old, baseline, wrong target, failed reads and non-boolean ok', () => {
	const session = { started: 100, node: 'n_b', mode: 'gfw' };
	const valid = { at: 101, target_node: 'n_b', target_mode: 'gfw', ok: true, error: null };
	for (const changes of [{ at: 99 }, { at: 100 }, { at: NaN }, { target_node: 'n_a' },
		{ target_mode: 'global' }, { ok: 'true' }])
		assert.equal(model.reload_result({ last_reload: { ...valid, ...changes } }, session), null);
	assert.equal(model.reload_result({ ok: false, last_reload: valid }, session), null);
	assert.equal(model.reload_result({ last_reload: valid }, { ...session, baseline: JSON.stringify(valid) }), null);
	assert.deepEqual(model.reload_result({ last_reload: valid }, session), valid);
});

for (const code of ['CONFIG_INVALID', 'FS_FAILED']) {
	test(`T10.71 scenario 2: ${code} preflight failure is closable and never rolls back`, async () => {
		const h = await harness();
		h.use = async () => ({ ok: false, committed: false, code, detail: '<bad config>' });
		await h.page.handleNode('n_b', 'bypass_cn');
		assert.equal(h.page.switchSession.phase, 'preflight-failed');
		assert.ok(h.page.switchOverlay.textContent.includes('<bad config>'));
		assert.equal(all(h.page.switchOverlay, 'button').length, 1);
		h.page.closeSwitch();
		assert.equal(h.page.switching, false);
		assert.equal(h.disk.node, 'n_a');
		assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
	});
}

for (const kind of ['node', 'mode', 'both']) {
	test(`T10.71 scenario 3: ${kind} committed reload failure restores only returned previous values`, async () => {
		const h = await harness();
		const target = kind === 'mode' ? 'n_a' : 'n_b';
		const mode = kind === 'node' ? 'bypass_cn' : 'gfw';
		await h.page.handleNode(target, mode);
		completion(h, false, target, mode);
		await h.page.pollSwitch(h.page.switchSession);
		assert.equal(h.page.switchSession.phase, 'rolling-back');
		const rollback = h.calls.filter(([name]) => name.endsWith('_use'))[1];
		assert.deepEqual(rollback, kind === 'mode' ? ['mode_use', { mode: 'bypass_cn' }]
			: ['node_use', { id: 'n_a', mode: 'bypass_cn' }]);
		assert.equal(h.disk.node, 'n_a');
		assert.equal(h.disk.mode, 'bypass_cn');
		completion(h, true, 'n_a');
		await h.page.pollSwitch(h.page.switchSession);
		assert.equal(h.page.switchSession.phase, 'rolled-back');
		assert.equal(h.page.status.node_id, 'n_a');
		await closeAfterTwoSeconds(h);
	});
}

test('T10.71 scenario 4: changed UCI is not overwritten and failure banner survives Close', async () => {
	const h = await harness();
	await h.page.handleNode('n_b', 'bypass_cn');
	h.disk.mode = 'global';
	completion(h, false);
	await h.page.pollSwitch(h.page.switchSession);
	assert.equal(h.page.switchSession.phase, 'rollback-failed');
	assert.equal(h.disk.mode, 'global');
	assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
	h.page.closeSwitch();
	assert.ok(h.page.switchBanner);
	assert.ok(h.page.noticeContent.textContent.includes('not overwritten'));
	assert.equal(h.page.nodeSelect.disabled, false, 'closing a local failure releases the old pending guard');
	assert.equal(h.page.modeSelect.disabled, false);
});

for (const failure of ['rpc', 'reload', 'timeout']) {
	test(`T10.71 scenario 4: rollback ${failure} leaves a closable persistent banner`, async () => {
		const h = await harness();
		await h.page.handleNode('n_b', 'bypass_cn');
		if (failure === 'rpc')
			h.use = async () => ({ ok: false, committed: false, code: 'BUSY' });
		completion(h, false);
		await h.page.pollSwitch(h.page.switchSession);
		if (failure === 'reload') {
			completion(h, false, 'n_a');
			await h.page.pollSwitch(h.page.switchSession);
		}
		if (failure === 'timeout')
			h.timers.find(t => t.ms === 60000).fn();
		assert.equal(h.page.switchSession.phase, failure === 'timeout' ? 'timeout' : 'rollback-failed');
		h.page.closeSwitch();
		assert.ok(h.page.switchBanner);
	});
}

test('T10.71 scenario 4: sixty-second timeout fences late completion and never blindly rolls back', async () => {
	const h = await harness();
	let release;
	h.use = () => new Promise(resolve => { release = resolve; });
	const pending = h.page.handleNode('n_b', 'bypass_cn');
	h.timers.find(t => t.ms === 60000).fn();
	assert.equal(h.page.switchSession.phase, 'timeout');
	h.page.closeSwitch();
	release({ ok: false, committed: true, previous: 'n_a', previous_mode: 'bypass_cn' });
	await pending;
	assert.ok(h.page.switchBanner);
	assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
	assert.equal(h.page.nodeSelect.disabled, false, 'timeout does not permanently lock the dropdown');
});

for (const committed of [null, undefined]) {
	test(`T10.71 scenario 4: committed ${committed} is uncertain, not preflight failure`, async () => {
		const h = await harness();
		h.use = async () => ({ ok: false, committed, code: 'FS_FAILED' });
		await h.page.handleNode('n_b', 'bypass_cn');
		assert.equal(h.page.switchSession.phase, 'timeout');
		assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
		assert.ok(h.page.switchBanner);
	});
}

test('T10.71 scenario 5: selecting and applying a node while stopped makes Enable usable', async () => {
	const h = await harness(null);
	h.status = { state: 'stopped' };
	h.page.refresh(h.status);
	h.use = async (method, params) => {
		h.disk.node = params.id;
		return { ok: true, committed: true, previous: null, previous_mode: 'bypass_cn', reload: false };
	};
	await h.page.handleNode('n_b', 'bypass_cn');
	assert.equal(h.page.switchSession.phase, 'success');
	await closeAfterTwoSeconds(h);
	assert.equal(h.page.enableInput.disabled, false);
	await h.page.handleEnable(true);
	assert.equal(h.saves, 1);
});

test('T10.71 scenario 7: external changes show only the old banner; overlay disables all actions', async () => {
	const h = await harness();
	h.disk.node = 'n_b';
	await h.page.fetchRefresh();
	assert.ok(h.page.vm.switch_notice);
	assert.equal(h.page.switchSession, undefined);
	h.disk.node = 'n_a';
	await h.page.readSwitchConfig();
	h.page.refresh(h.status);
	await h.page.handleNode('n_b', 'bypass_cn');
	assert.equal(h.page.actionFields.disabled, true);
	assert.equal(h.page.nodeSelect.disabled, true);
	assert.equal(h.page.modeSelect.disabled, true);
	assert.equal(h.page.enableInput.disabled, true);
	const count = h.calls.length;
	await h.page.handleService('stop');
	await h.page.handleEnable(true);
	await h.page.handleNode('n_a', 'global');
	await h.page.handleProbe();
	await all(h.root, 'button').find(button => button.textContent === 'Refresh').attrs.click();
	h.page.setInterval('1');
	assert.equal(h.calls.length, count);
	h.page.closeSwitch();
	assert.equal(h.page.switching, true, 'switching cannot be closed');
});


test('T10.71 committed command failure enters rollback; restoring an unset previous value never guesses', async () => {
	const h = await harness();
	h.use = async () => {
		h.disk.node = 'n_b';
		return { ok: false, committed: true, previous: null, previous_mode: 'bypass_cn', code: 'CMD_FAILED' };
	};
	await h.page.handleNode('n_b', 'bypass_cn');
	assert.equal(h.page.switchSession.phase, 'rollback-failed');
	assert.ok(h.page.switchBanner.includes('cannot be restored'));
	assert.equal(h.disk.node, 'n_b');
	assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
});

test('T10.71 status matching does not accept old successful runtime or unrelated reloads', async () => {
	const h = await harness();
	await h.page.handleNode('n_b', 'bypass_cn');
	const session = h.page.switchSession;
	h.status.node_id = 'n_b';
	h.status.last_reload = { at: session.started - 1, target_node: 'n_b', target_mode: 'bypass_cn', ok: true };
	await h.page.pollSwitch(session);
	assert.equal(session.phase, 'switching');
	completion(h, true, 'n_a');
	await h.page.pollSwitch(session);
	assert.equal(session.phase, 'switching');
	completion(h, true, 'n_b', 'global');
	await h.page.pollSwitch(session);
	assert.equal(session.phase, 'switching');
	h.status = { ok: false, code: 'TIMEOUT' };
	await h.page.pollSwitch(session);
	assert.equal(session.phase, 'switching');
	h.timers.find(t => t.ms === 60000).fn();
	assert.equal(session.phase, 'timeout');
	assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
});

test('T10.71 late polling result after timeout and Close cannot start rollback', async () => {
	const h = await harness();
	await h.page.handleNode('n_b', 'bypass_cn');
	const session = h.page.switchSession;
	let release;
	h.readStatus = () => new Promise(resolve => { release = resolve; });
	const pending = h.page.pollSwitch(session);
	h.timers.find(t => t.ms === 60000).fn();
	h.page.closeSwitch();
	completion(h, false);
	release(structuredClone(h.status));
	await pending;
	assert.equal(h.page.switchSession, null);
	assert.equal(h.calls.filter(([name]) => name.endsWith('_use')).length, 1);
	assert.ok(h.page.switchBanner);
});

test('T10.71 success close refresh failure keeps a closable timeout banner', async () => {
	const h = await harness();
	await h.page.handleNode('n_b', 'bypass_cn');
	completion(h, true);
	await h.page.pollSwitch(h.page.switchSession);
	assert.equal(h.page.switchSession.phase, 'success');
	h.page.load = async () => { throw new Error('UCI offline'); };
	await h.timers.find(t => t.ms === 2000 && !t.cleared).fn();
	assert.equal(h.page.switchSession.phase, 'timeout');
	assert.ok(h.page.switchBanner.includes('UCI offline'));
	h.page.closeSwitch();
	assert.equal(h.page.actionFields.disabled, false);
});
