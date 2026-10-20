'use strict';

/* Overview model/view tests (docs/tasks/m8.md T8.4, T8.11a, T8.12c; m10.md T10.3–T10.6, T10.9).
 *
 * 7-8 exercise the pure model module (aether-proxy/model/overview.js) through
 * the LuCI loader with a baseclass double; _() resolves from the real po file
 * so the assertions check the documented Chinese wording end to end. 9 holds
 * the static source checks on the view: no rpc.declare, no business fields of
 * the rpc results, stop button negative+confirmed, no cbi-button-reset.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { loadModule, parsePo } = require('./loader.js');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs', 'luci-static', 'resources');
const MODEL = path.join(RES, 'aether-proxy', 'model', 'overview.js');
const VIEW = path.join(RES, 'view', 'aether-proxy', 'overview.js');
const PO = path.join(APP, 'po', 'zh_Hans', 'aether-proxy.po');

const po = parsePo(fs.readFileSync(PO, 'utf8'));

/* The model goes through the browser-global _(); resolve it from the real po
   so the tests also fail when a translation goes missing. */
globalThis._ = (s) => po[s] ?? s;

const NOW = 1760400000;

/* Lightweight E() double for the view tests (docs/tasks/m8.md T8.11a): stores
   tag/attrs/children so a test can walk the returned tree. */
globalThis.E = (tag, attrs, children) => {
	const el = {
		tag, attrs: attrs || {}, children: children ?? [],
		addEventListener(event, fn) { this.attrs[event] = fn; }
	};
	if (tag === 'select') {
		const options = children ?? [];
		el.value = (options.find((o) => o.attrs.selected) ?? options[0])?.attrs.value ?? '';
	}
	return el;
};

function findTag(node, tag) {
	if (!node || typeof node != 'object')
		return null;

	if (node.tag == tag)
		return node;

	for (const child of node.children ?? []) {
		const found = findTag(child, tag);

		if (found)
			return found;
	}

	return null;
}

function build(status, version, labels, now, enabled, configuredNode, components) {
	const model = loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });

	return model.build(status, version ?? { ok: true, version: '0.1.0-r2' }, labels ?? {}, now ?? NOW,
		enabled, configuredNode, components);
}

/* Load view/aether-proxy/overview.js with doubles for the modules it requires,
   the way T8.9b loads the updates view for its job-flow test. Each test sees
   the recorded rpc calls and the order of uci/ui operations. */
function loadView(overrides = {}) {
	const rpcCalls = overrides.rpcCalls ?? [];
	const ap = overrides.ap ?? {
		call: (method) => {
			rpcCalls.push(method);

			return Promise.resolve(method == 'version'
				? { ok: true, version: '0.1.0-r2' }
				: { ok: true, state: 'running' });
		},
		poll: () => ({ stop() {} })
	};
	const uciDouble = Object.assign({
		load: () => Promise.resolve(),
		sections: () => {},
		get: () => undefined,
		set: () => {},
		save: () => Promise.resolve()
	}, overrides.uci ?? {});
	const uiDouble = Object.assign({
		// Same contract as LuCI's ui.createHandlerFn(ctx, fn, ...args): a missing fn yields null.
		createHandlerFn: (ctx, fn, ...args) => {
			if (typeof fn == 'string')
				fn = ctx[fn];
			return typeof fn == 'function' ? (...rest) => fn.call(ctx, ...args, ...rest) : null;
		},
		changes: { apply: () => {} },
		addNotification: () => {}
	}, overrides.ui ?? {});
	const modelMod = loadModule(MODEL, { baseclass: { extend: (o) => o } },
		{ window: {}, document: { addEventListener() {}, removeEventListener() {} } });

	return loadModule(VIEW, {
		view: { extend: (o) => o },
		uci: uciDouble,
		ui: uiDouble,
		/* dom.content replaces children rather than appending to them. */
		dom: { content: (el, node) => {
			el.children = [];
			el.content = node;
		} },
		'aether-proxy.common': ap,
		'aether-proxy.model.overview': modelMod
	}, { window: Object.assign({
		setTimeout: () => {}, clearTimeout: () => {},
		localStorage: { getItem: () => null, setItem: () => {} }
	}, overrides.window ?? {}), document: { addEventListener() {}, removeEventListener() {} } });
}

/* Expected text for a translated template with its %s filled in. */
function tr(msgid, ...args) {
	let s = po[msgid] ?? msgid;

	for (const a of args)
		s = s.replace('%s', a);

	return s;
}

test('scenario 7a: every documented state has its text; waiting_network and dns_failsafe', () => {
	const cases = {
		stopped: '已停止',
		starting: '启动中',
		running: '运行中',
		degraded: '降级',
		failsafe: '故障放行',
		error: '启动失败'
	};

	for (const [state, zh] of Object.entries(cases))
		assert.equal(build({ ok: true, state }).state_text, zh, `state text of ${state}`);

	assert.equal(build({ ok: true, state: 'starting', waiting_network: true }).state_text, '等待网络');
	assert.equal(build({ ok: true, state: 'starting' }).state_text, '启动中');

	assert.equal(build({ ok: true, state: 'running', dns_failsafe: true }).dns_failsafe, true);
	assert.equal(build({ ok: true, state: 'running' }).dns_failsafe, false);
});

test('scenario 7b: button availability per state', () => {
	const cases = {
		stopped: { start: true, restart: false, stop: false },
		error: { start: true, restart: false, stop: false },
		starting: { start: false, restart: true, stop: true },
		running: { start: false, restart: true, stop: true },
		degraded: { start: false, restart: true, stop: true },
		failsafe: { start: false, restart: true, stop: true }
	};

	for (const [state, buttons] of Object.entries(cases))
		assert.deepEqual(build({ ok: true, state }).buttons, buttons, `buttons in ${state}`);
});

test('scenario 7c: health probe texts and their relative time', () => {
	let vm = build({ ok: true, state: 'running', last_probe: { ok: true, latency_ms: 123, at: NOW - 30 } });
	assert.equal(vm.probe_text, tr('Healthy, %s ms', 123));
	assert.equal(vm.probe_since_text, tr('%s seconds ago', 30));

	vm = build({ ok: true, state: 'running', last_probe: { ok: false, at: NOW - 90 } });
	assert.equal(vm.probe_text, tr('Probe failed'));
	assert.equal(vm.probe_since_text, tr('%s minutes ago', 1));

	vm = build({ ok: true, state: 'running' });
	assert.equal(vm.probe_text, tr('Not probed yet'));
	assert.equal(vm.probe_since_text, null);
});

test('scenario 7d: state duration buckets (seconds, minutes, hours, days)', () => {
	let vm = build({ ok: true, state: 'running', since: NOW - 45 });
	assert.equal(vm.state_duration_text, tr('For %s seconds', 45));

	vm = build({ ok: true, state: 'running', since: NOW - 150 });
	assert.equal(vm.state_duration_text, tr('For %s minutes', 2));

	vm = build({ ok: true, state: 'running', since: NOW - 7200 });
	assert.equal(vm.state_duration_text, tr('For %s hours', 2));

	vm = build({ ok: true, state: 'running', since: NOW - 3 * 86400 });
	assert.equal(vm.state_duration_text, tr('For %s days', 3));
	assert.equal(build({ ok: true, state: 'running' }).state_duration_text, null);
});

test('scenario 7e: node option label fallback, DNS explanation and own component version', () => {
	let vm = build({ ok: true, state: 'running', node_id: 'n_ab', node_ip: '203.0.113.10', dns_tier: 'T1' }, null, { n_ab: 'My Node' });
	assert.deepEqual(vm.node_options, [ { value: 'n_ab', text: 'My Node（当前）' } ]);
	assert.equal(vm.node_ip, '203.0.113.10');
	assert.equal(vm.dns_text, '经节点解析（正常）');
	assert.equal(vm.components[0].version, '0.1.0-r2');

	vm = build({ ok: true, state: 'running', node_id: 'n_ab', node_ip: '203.0.113.10' }, null, {});
	assert.equal(vm.current_node, 'n_ab');
	assert.deepEqual(dashboardModel().node_options({ n_ab: '' }, vm.current_node),
		[ { value: 'n_ab', text: 'n_ab（当前）' } ]);

	vm = build({ ok: true, state: 'stopped', dns_tier: null }, { ok: false, code: 'RPC_FAILED' });
	assert.equal(vm.node_text, '还没有节点，请到节点页添加或导入');
	assert.equal(vm.dns_text, null);
	assert.equal(vm.components[0].version, null);
});

test('scenario 8a: every notice kind becomes one line carrying its args', () => {
	const notices = [
		{ code: 'COMPONENT_MISSING', args: { component: 'chinadns-ng' } },
		{ code: 'UPDATE_AVAILABLE', args: { package: 'xray-core', available: '26.10.1' } },
		{ code: 'IPV6_PRESENT', args: { iface: 'br-lan' } },
		{ code: 'DNSMASQ_EXTRA_SERVERS', args: { servers: [ 'server=8.8.8.8', 'server=9.9.9.9' ] } }
	];

	const vm = build({ ok: true, state: 'running', notices });

	assert.equal(vm.notices.length, 4);
	assert.ok(vm.notices[0].includes('chinadns-ng'), vm.notices[0]);
	assert.ok(vm.notices[1].includes('xray-core') && vm.notices[1].includes('26.10.1'), vm.notices[1]);
	/* docs/03 wording must survive translation */
	assert.ok(vm.notices[2].includes('br-lan'), vm.notices[2]);
	assert.equal(vm.notices[2], tr('A global IPv6 address is present on %s: clients may still connect directly over IPv6, consider disabling the LAN IPv6 assignment.', 'br-lan'));
	assert.ok(vm.notices[3].includes('server=8.8.8.8') && vm.notices[3].includes('server=9.9.9.9'), vm.notices[3]);
	assert.equal(vm.notices[3], tr('dnsmasq configuration contains server= lines that this service did not write: %s.',
		'server=8.8.8.8; server=9.9.9.9'));
	assert.equal(vm.notices[3], 'dnsmasq 配置中有不是本服务写入的 server= 行：server=8.8.8.8; server=9.9.9.9。');

	/* the same wording the docs quote for the confirm-free parts */
	assert.equal(po['A global IPv6 address is present on %s: clients may still connect directly over IPv6, consider disabling the LAN IPv6 assignment.']
		.includes('客户端仍可能通过 IPv6 直连，建议关闭 LAN 的 IPv6 分配'), true);
});

test('scenario 8b: unknown notice codes still produce a line naming the code, without throwing', () => {
	const vm = build({ ok: true, state: 'running', notices: [ { code: 'SOME_NEW_CODE', args: { x: 1 } } ] });

	assert.equal(vm.notices.length, 1);
	assert.ok(vm.notices[0].includes('SOME_NEW_CODE'), vm.notices[0]);

	/* missing or malformed notices never throw either */
	const vm2 = build({ ok: true, state: 'running', notices: [ { code: 'SOME_NEW_CODE' }, {} ] });
	assert.equal(vm2.notices.length, 2);
	const vm3 = build({ ok: true, state: 'running' });
	assert.deepEqual(vm3.notices, []);
});

test('scenario 8c: status failure -> error message, all buttons disabled', () => {
	const vm = build({ ok: false, code: 'RPC_FAILED', detail: 'boom' });

	assert.equal(vm.ok, false);
	assert.ok(vm.error.includes('RPC_FAILED'), vm.error);
	assert.ok(vm.error.includes('boom'), vm.error);
	assert.deepEqual(vm.buttons, { start: false, restart: false, stop: false });
	assert.deepEqual(vm.notices, []);
	assert.equal(vm.state_text, null);
	/* Failed status still falls back to the UCI selection; no nodes gives guidance. */
	assert.equal(vm.current_node, null);
	assert.equal(vm.node_text, '还没有节点，请到节点页添加或导入');
});

test('T8.11a scenario 1: main.enabled=1 keeps the old buttons; =0 disables start/restart in every state', () => {
	const states = [ 'stopped', 'error', 'starting', 'running', 'degraded', 'failsafe' ];
	const enabled_buttons = {
		stopped: { start: true, restart: false, stop: false },
		error: { start: true, restart: false, stop: false },
		starting: { start: false, restart: true, stop: true },
		running: { start: false, restart: true, stop: true },
		degraded: { start: false, restart: true, stop: true },
		failsafe: { start: false, restart: true, stop: true }
	};

	for (const state of states) {
		/* enabled=true must be identical to the pre-switch behaviour */
		assert.deepEqual(
			build({ ok: true, state }, null, null, null, true).buttons,
			enabled_buttons[state],
			`buttons in ${state} with enabled=1`);

		const off = build({ ok: true, state }, null, null, null, false).buttons;

		assert.equal(off.start, false, `start disabled in ${state} with enabled=0`);
		assert.equal(off.restart, false, `restart disabled in ${state} with enabled=0`);
		/* stop still follows the state: the service may run since before the switch was turned off */
		assert.equal(off.stop, enabled_buttons[state].stop, `stop in ${state} with enabled=0`);
	}
});

test('T8.11a scenario 2: disabled notice, enable note and the new stop confirmation come from the model', () => {
	const note = 'Once enabled the service starts at boot; turning it off stops the service '
		+ 'immediately and all traffic goes out directly.';
	const notice = 'The service is not enabled: turn on the Enable switch '
		+ 'and it will start automatically.';
	const confirm_id = 'Stopping the service leaves all traffic going out directly. '
		+ 'This is only temporary: restarting the router or saving the settings of this '
		+ 'service again starts it; to disable it for good, turn off Enable above.';

	let vm = build({ ok: true, state: 'running' }, null, null, null, false);

	assert.equal(vm.enabled, false);
	assert.equal(vm.enabled_note, tr(note));
	assert.equal(vm.disabled_notice, tr(notice));

	vm = build({ ok: true, state: 'running' }, null, null, null, true);

	assert.equal(vm.enabled, true);
	assert.equal(vm.disabled_notice, null);
	assert.equal(vm.enabled_note, tr(note));

	/* the confirmation keeps both meanings the doc requires: temporary and the switch */
	assert.ok(vm.stop_confirmation.includes('暂时'), vm.stop_confirmation);
	assert.ok(vm.stop_confirmation.includes('启用'), vm.stop_confirmation);
	assert.equal(vm.stop_confirmation, tr(confirm_id));
	assert.equal(vm.stop_confirmation, '停止服务后所有流量直连。这只是暂时停止：'
		+ '重启路由器或下次保存本服务的设置时会再次启动；要长期停用请关闭『启用』。');
});

test('T8.11a scenario 3a: the switch reflects main.enabled at load; unset counts as 0', async () => {
	for (const [ raw, expected ] of [ [ '1', true ], [ '0', false ], [ undefined, false ] ]) {
		const page = loadView({ uci: { get: () => raw } });
		const data = await page.load();

		assert.equal(data[2].enabled, expected, `main.enabled=${raw} loads as ${expected}`);

		page.enabled = data[2].enabled;
		const box = findTag(page.enableSwitch('note'), 'input');
		/* The compact switch now sits beside the title, without a visible note. */
		assert.match(page.enableSwitch('note').attrs.style, /align-items:\s*center/);

		assert.ok(box, 'the switch renders an input');
		assert.equal(box.attrs.checked, expected ? 'checked' : null, `checked attribute for main.enabled=${raw}`);
	}
});

test('T8.11a scenario 3b: toggling writes UCI, saves and applies with rollback, and never calls service', async (t) => {
	const saved = globalThis.confirm;
	globalThis.confirm = () => true;
	t.after(() => { globalThis.confirm = saved; });
	const order = [];
	const rpcCalls = [];
	const page = loadView({
		rpcCalls,
		uci: {
			set: (cfg, sec, opt, val) => order.push([ 'set', cfg, sec, opt, val ]),
			save: () => { order.push([ 'save' ]); return Promise.resolve(); }
		},
		ui: { changes: { apply: (rollback) => { order.push([ 'apply', rollback ]); } } }
	});

	page.vm = build({ ok: true, state: 'running' });
	await page.handleEnable(true);
	assert.deepEqual(order, [ [ 'set', 'aetherproxy', 'main', 'enabled', '1' ], [ 'save' ], [ 'apply', true ] ]);
	assert.equal(page.enabled, true);
	assert.ok(!rpcCalls.includes('service'), 'turning the switch on must not call the service method');

	order.length = 0;
	await page.handleEnable(false);
	assert.deepEqual(order, [ [ 'set', 'aetherproxy', 'main', 'enabled', '0' ], [ 'save' ], [ 'apply', true ] ]);
	assert.equal(page.enabled, false);
	assert.ok(!rpcCalls.includes('service'), 'turning the switch off must not call the service method');
});

test('T8.11a scenario 4: static checks — switch wiring, no service from the switch, '
	+ 'no rpc.declare/cbi-button-reset, po complete', () => {
	const src = fs.readFileSync(VIEW, 'utf8');

	assert.doesNotMatch(src, /rpc\s*\.\s*declare/);
	assert.doesNotMatch(src, /cbi-button-reset/);
	assert.match(src, /uci\.set\('aetherproxy', 'main', 'enabled'/);
	assert.match(src, /ui\.changes\.apply\(true\)/);

	/* the toggle handler must not call the service method itself */
	const handler = /handleEnable: function[\s\S]*?\n\t},/.exec(src);

	assert.ok(handler, 'handleEnable exists');
	assert.doesNotMatch(handler[0], /ap\.call\(/);

	for (const id of [
		'Enable',
		'Once enabled the service starts at boot; turning it off stops the service '
			+ 'immediately and all traffic goes out directly.',
		'The service is not enabled: turn on the Enable switch '
			+ 'and it will start automatically.',
		'Stopping the service leaves all traffic going out directly. '
			+ 'This is only temporary: restarting the router or saving the settings of this '
			+ 'service again starts it; to disable it for good, turn off Enable above.'
	]) {
		assert.ok(po[id], 'po has an entry for "' + id + '"');
		assert.ok(po[id].length > 0, 'po translation for "' + id + '" is non-empty');
	}
});

/* The legacy structural assertions inspect the one-argument spelling. Remove
 * only literal translation contexts; i18n.test.js validates them separately. */
function structuralSource(file) {
	return fs.readFileSync(file, 'utf8')
		.replace(/(_\('(?:[^'\\]|\\.)*'), 'aether-proxy'\)/g, '$1)');
}

test('scenario 9: static view checks — model only, stop button negative and confirmed, no business fields', () => {
	const src = structuralSource(VIEW);

	/* the view goes through ap and the model, never through rpc */
	assert.doesNotMatch(src, /rpc\s*\.\s*declare/);
	assert.match(src, /'require aether-proxy\.common as ap'/);
	assert.match(src, /'require aether-proxy\.model\.overview as model'/);
	assert.match(src, /\bmodel\.build\(/);
	assert.match(src, /ap\.poll\(/);

	/* no business field of the rpc results is read; only the model's output
	   (vm.*) and the service reply's ok/code/detail (docs/10 tells the view to
	   show them after a service call) */
	assert.doesNotMatch(src,
		/\b(status|res|data)\s*\.\s*(state|notices|dns_tier|dns_failsafe|waiting_network|since|last_probe|last_error|node_id|node_ip|components|updates_available)\b/);

	/* stop: cbi-button-negative plus a confirm(); start/restart the normal buttons */
	assert.match(src, /_\('Stop'\),\s*'cbi-button-negative'/);
	assert.match(src, /'stop' && !confirm\(/);
	assert.doesNotMatch(src, /cbi-button-reset/);

	/* 5s poll, service via ap.call, notification on failure */
	assert.match(src, /this\.startPolling\(interval\)/);
	assert.equal(loadView().readInterval(), 5000, 'default remains the original 5s poll');
	assert.match(src, /ap\.call\('service', \{ action: action \}\)/);
	assert.match(src, /ui\.addNotification\(/);
});

function dashboardModel() {
	return loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: {} });
}

function findAll(node, tag, out = []) {
	if (!node || typeof node != 'object')
		return out;
	if (node.tag == tag)
		out.push(node);
	for (const child of node.children ?? [])
		findAll(child, tag, out);
	findAll(node.content, tag, out);
	return out;
}

test('T8.11a review: service buttons are clickable and stop asks with the model text first', async () => {
	const rpcCalls = [];
	const asked = [];
	let answer = false;
	const saved = globalThis.confirm;
	globalThis.confirm = (text) => { asked.push(text); return answer; };
	try {
		const page = loadView({ rpcCalls });
		page.content = E('div', {}, []);
		page.labels = {};
		page.enabled = true;
		page.refresh({ ok: true, state: 'running' });
		const buttons = findAll(page.buttonBar(page.vm.buttons), 'button');
		// Order and classes from buttonBar: start, restart (cbi-button-apply), stop (cbi-button-negative).
		assert.equal(buttons.length, 3);
		const restart = buttons[1];
		const stop = buttons.find(b => b.attrs.class.includes('cbi-button-negative'));
		assert.equal(typeof restart.attrs.click, 'function', 'restart has a click handler');
		assert.equal(typeof stop.attrs.click, 'function', 'stop has a click handler');

		await stop.attrs.click();
		assert.deepEqual(asked, [ page.vm.stop_confirmation ]);
		assert.ok(!rpcCalls.includes('service'), 'cancelled stop calls nothing');

		answer = true;
		await stop.attrs.click();
		assert.ok(rpcCalls.includes('service'), 'confirmed stop calls service');
	}
	finally {
		globalThis.confirm = saved;
	}
});

function readings(at_ms, proxy_tx, proxy_rx, wan_tx, wan_rx, dev = 'eth1') {
	return { ok: true, at_ms, proxy: { tx_bytes: proxy_tx, rx_bytes: proxy_rx },
		wan: { dev, tx_bytes: wan_tx, rx_bytes: wan_rx }, connections: { proxy: 3, total: 10 } };
}

test('T8.12c scenario 1a: rates, direct clamp, units and connections', () => {
	const model = dashboardModel();
	const before = readings(1000, 100, 200, 500, 600);
	const after = readings(3000, 103, 200 + 3072, 500 + 3 * 1048576, 600 + 1024);
	const vm = model.traffic(before, after);
	assert.deepEqual(vm.proxy, { tx: '1.5 B/s', rx: '1.5 KB/s' });
	assert.deepEqual(vm.total, { tx: '1.5 MB/s', rx: '512.0 B/s' });
	assert.deepEqual(vm.direct, { tx: '1.5 MB/s', rx: '0.0 B/s' });
	assert.deepEqual(vm.connections, { proxy: '3', total: '10' });
	assert.deepEqual(model.traffic(null, {}).connections, { proxy: '–', total: '–' });
	// Units step at 1024, not 1000: 1000 B/s stays in bytes.
	const edge = model.traffic(readings(0, 0, 0, 0, 0), readings(1000, 1000, 1023, 1024, 0));
	assert.deepEqual(edge.proxy, { tx: '1000.0 B/s', rx: '1023.0 B/s' });
	assert.equal(edge.total.tx, '1.0 KB/s');
});

test('T8.12c scenario 1b: first sample, nulls, resets, device and clock changes invalidate affected rates', () => {
	const model = dashboardModel();
	const before = readings(1000, 100, 200, 500, 600);
	const after = readings(2000, 200, 400, 1500, 2600);
	for (const previous of [ null, readings(2000, 100, 200, 500, 600),
		readings(3000, 100, 200, 500, 600) ]) {
		const vm = model.traffic(previous, after);
		for (const kind of [ 'proxy', 'total', 'direct' ])
			assert.deepEqual(vm[kind], { tx: '–', rx: '–' });
	}
	for (const group of [ 'proxy', 'wan' ]) {
		for (const direction of [ 'tx', 'rx' ]) {
			for (const sample of [ 'previous', 'current' ]) {
				const p = structuredClone(before), c = structuredClone(after);
				(sample === 'previous' ? p : c)[group][direction + '_bytes'] = null;
				const vm = model.traffic(p, c);
				assert.equal(vm[group === 'wan' ? 'total' : 'proxy'][direction], '–');
				assert.equal(vm.direct[direction], '–');
			}
			const c = structuredClone(after);
			c[group][direction + '_bytes'] = 1;
			const vm = model.traffic(before, c);
			assert.equal(vm[group === 'wan' ? 'total' : 'proxy'][direction], '–');
			assert.equal(vm.direct[direction], '–');
		}
	}
	const changed = model.traffic(before, { ...after, wan: { ...after.wan, dev: 'pppoe-wan' } });
	assert.deepEqual(changed.proxy, { tx: '100.0 B/s', rx: '200.0 B/s' });
	assert.deepEqual(changed.total, { tx: '–', rx: '–' });
	assert.deepEqual(changed.direct, { tx: '–', rx: '–' });
});

test('T8.12c scenario 2: refresh options and storage parsing including exceptions and Off', () => {
	const model = dashboardModel();
	assert.deepEqual(model.refresh_options(), [
		{ value: '2', text: '2 秒' }, { value: '5', text: '5 秒（默认）' },
		{ value: '10', text: '10 秒' }, { value: '30', text: '30 秒' }, { value: '0', text: '关闭' }
	]);
	for (const value of [ '2', '5', '10', '30', '0' ]) {
		const page = loadView({ window: { localStorage: { getItem: (key) => {
			assert.equal(key, 'aether-proxy.refresh');
			return value;
		} } } });
		assert.equal(page.readInterval(), Number(value) * 1000);
	}
	for (const value of [ null, '', '7', '5000', '05', 'false' ])
		assert.equal(model.refresh_interval(value), 5000);
	const saved = console.warn;
	const warnings = [];
	console.warn = (...args) => warnings.push(args);
	try {
		const page = loadView({ window: { localStorage: {
			getItem: () => { throw new Error('blocked'); },
			setItem: () => { throw new Error('blocked'); }
		} } });
		assert.equal(page.readInterval(), 5000);
		page.setInterval('0');
		assert.equal(warnings.length, 2, 'storage failures are reported, not swallowed');
		assert.equal(page.poller, null);
	}
	finally {
		console.warn = saved;
	}
});

test('T8.12c scenario 3: probe wording and freshness', () => {
	const model = dashboardModel();
	assert.equal(model.probe_result({ ok: true, latency_ms: 12 }), tr('Healthy, %s ms', 12));
	assert.equal(model.probe_result({ ok: false }), tr('Probe failed'));
	assert.equal(model.probe_result({ code: 'TIMEOUT' }), '检测未在 15 秒内完成');
	assert.equal(model.probe_result({ code: 'NOT_RUNNING' }), '服务未运行');
	assert.equal(model.probe_result({ code: 'CMD_FAILED', detail: 'ubus' }), 'CMD_FAILED: ubus');
	assert.deepEqual(model.probe_completion({ last_probe: { at: 9, ok: true } }, 10), { done: false });
	assert.deepEqual(model.probe_completion({}, 10), { done: false });
	assert.deepEqual(model.probe_completion({ last_probe: { at: 10, ok: false } }, 10),
		{ done: true, text: tr('Probe failed') });
});

test('T8.12c scenario 4a: render, sequential serialized refresh, interval replacement, storage and manual refresh',
	async () => {
	const calls = [], polls = [], writes = [];
	let release;
	const page = loadView({
		ap: {
			call: async (method) => {
				calls.push(method);
				if (method === 'status') {
					if (release !== undefined)
						await new Promise((resolve) => { release = resolve; });
					return { ok: true, state: 'running' };
				}
				return method === 'stats' ? readings(calls.length * 1000, 1, 2, 3, 4) : { ok: true };
			},
			poll: (fn, ms) => {
				const poll = { fn, ms, stopped: false, stop() { this.stopped = true; } };
				polls.push(poll);
				return poll;
			}
		},
		window: { localStorage: { getItem: () => null, setItem: (...args) => writes.push(args) } }
	});
	const data = await page.load();
	assert.ok(calls.indexOf('stats') > calls.indexOf('status'));
	const root = page.render(data);
	await page.componentRequest;
	assert.equal(findTag(root, 'h2').children, '以太跃迁');
	assert.equal(polls[0].ms, 5000);
	const selects = findAll(root, 'select');
	selects[0].attrs.change({ target: { value: '10' } });
	assert.equal(polls[0].stopped, true);
	assert.equal(polls[1].ms, 10000);
	selects[0].attrs.change({ target: { value: '0' } });
	assert.equal(polls[1].stopped, true);
	assert.equal(page.poller, null);
	assert.deepEqual(writes, [ [ 'aether-proxy.refresh', '10' ], [ 'aether-proxy.refresh', '0' ] ]);
	calls.length = 0;
	release = true;
	const manual = findAll(root, 'button').find((b) => b.children === '刷新');
	const first = manual.attrs.click();
	const second = page.fetchRefresh();
	assert.equal(first, second, 'manual and poll requests share the in-flight promise');
	assert.deepEqual(calls, [ 'status' ], 'stats waits for status');
	release();
	await first;
	assert.deepEqual(calls, [ 'status', 'stats' ]);
});

test('T8.12c scenario 4b: node selection switches via UCI save and rollback apply', async () => {
	const order = [];
	const page = loadView({
		uci: {
			sections: (cfg, type, cb) => {
				if (type === 'node') {
					cb({ '.name': 'n_a', label: 'Alpha' });
					cb({ '.name': 'n_b' });
				}
			},
			get: (cfg, sec, opt) => opt === 'node' ? 'n_a' : '1',
			set: (...args) => order.push([ 'set', ...args ]),
			save: async () => { order.push([ 'save' ]); }
		},
		ui: { changes: { apply: (rollback) => order.push([ 'apply', rollback ]) } }
	});
	const root = page.render(await page.load());
	const nodes = findAll(root, 'select')[1];
	assert.equal(nodes.children[0].children, 'Alpha（当前）');
	assert.equal(nodes.children[0].attrs.selected, 'selected');
	assert.equal(nodes.children[1].children, 'n_b');
	const use = findAll(root, 'button').find((b) => b.children === '使用此节点');
	assert.equal(use.disabled, true, 'current node cannot be applied again');
	nodes.value = 'n_b';
	nodes.attrs.change();
	assert.equal(use.disabled, false, 'another node can be applied');
	nodes.value = 'n_a';
	nodes.attrs.change();
	assert.equal(use.disabled, true, 'reselecting the current node disables apply again');
	nodes.value = 'n_b';
	nodes.attrs.change();
	await use.attrs.click();
	assert.deepEqual(order, [ [ 'set', 'aetherproxy', 'main', 'node', 'n_b' ], [ 'save' ], [ 'apply', true ] ]);

	const emptyPage = loadView();
	const emptyRoot = emptyPage.render(await emptyPage.load());
	const emptyUse = findAll(emptyRoot, 'button').find((b) => b.children === '使用此节点');
	assert.equal(emptyUse, undefined, 'an empty node list has no apply button');
	assert.equal(findAll(emptyRoot, 'select').length, 1, 'only the refresh selector remains');
});

function timerQueue() {
	const timers = [];
	return {
		timers,
		setTimeout: (fn, ms) => {
			const timer = { fn, ms, cleared: false };
			timers.push(timer);
			return timer;
		},
		clearTimeout: (timer) => { if (timer) timer.cleared = true; },
		run: async (ms) => {
			const timer = timers.find((t) => t.ms === ms && !t.cleared);
			assert.ok(timer, `pending ${ms}ms timer exists`);
			timer.cleared = true;
			await timer.fn();
		}
	};
}

test('T8.12c scenario 4c: latency button waits for a fresh probe, repeats every second and disables while busy',
	async () => {
	const clock = timerQueue(), calls = [];
	let count = 0;
	const page = loadView({ window: clock, ap: {
		call: async (method) => {
			calls.push(method);
			return method === 'probe_now' ? { ok: true, requested_at: 10 }
				: { ok: true, last_probe: { at: ++count === 1 ? 9 : 10, ok: true, latency_ms: 42 } };
		}
	} });
	page.labels = {};
	const controls = page.probeControls();
	const pending = findAll(controls, 'button').find((b) => b.children === '测延迟').attrs.click();
	assert.equal(page.probeButton.disabled, true);
	await Promise.resolve();
	await clock.run(1000);
	assert.equal(page.probeMessage.content, undefined, 'stale result cannot finish the probe');
	await clock.run(1000);
	await pending;
	assert.deepEqual(calls, [ 'probe_now', 'status', 'status' ]);
	assert.equal(page.probeMessage.content, tr('Healthy, %s ms', 42));
	assert.equal(page.probeButton.disabled, false);
	assert.ok(clock.timers.every((t) => t.cleared));
});

test('T8.12c scenario 4d: latency deadline wins over a late RPC; NOT_RUNNING and other errors are shown', async () => {
	const clock = timerQueue();
	let release;
	const page = loadView({ window: clock, ap: {
		call: (method) => method === 'probe_now' ? Promise.resolve({ ok: true, requested_at: 10 })
			: new Promise((resolve) => { release = resolve; })
	} });
	page.labels = {};
	page.probeControls();
	const pending = page.handleProbe();
	await Promise.resolve();
	const rpc = clock.run(1000);
	await clock.run(15000);
	await pending;
	assert.equal(page.probeMessage.content, '检测未在 15 秒内完成');
	assert.equal(page.probeButton.disabled, false);
	release({ ok: true, last_probe: { at: 10, ok: true, latency_ms: 1 } });
	await rpc;
	assert.equal(page.probeMessage.content, '检测未在 15 秒内完成', 'late reply cannot overwrite timeout');
	assert.ok(clock.timers.every((t) => t.cleared));
	for (const [code, text] of [ [ 'NOT_RUNNING', '服务未运行' ], [ 'CMD_FAILED', 'CMD_FAILED: ubus' ] ]) {
		const errorPage = loadView({ ap: { call: async () => ({ ok: false, code, detail: 'ubus' }) } });
		errorPage.labels = {};
		errorPage.probeControls();
		await errorPage.handleProbe();
		assert.equal(errorPage.probeMessage.content, text);
		assert.equal(errorPage.probeButton.disabled, false);
	}
});

test('T8.12c service refresh: action schedules serialized status/stats even with automatic refresh off', async () => {
	const clock = timerQueue(), calls = [];
	const page = loadView({ window: clock, ap: { call: async (method, params) => {
		calls.push([ method, params ]);
		return method === 'status' ? { ok: true, state: 'running' }
			: method === 'stats' ? readings(1000, 1, 2, 3, 4) : { ok: true };
	} } });
	page.content = E('div', {});
	page.labels = {};
	page.enabled = true;
	page.startPolling(0);
	await page.handleService('restart');
	assert.deepEqual(calls, [ [ 'service', { action: 'restart' } ] ]);
	await clock.run(1500);
	await page.refreshing;
	assert.deepEqual(calls.map((call) => call[0]), [ 'service', 'status', 'stats' ]);
	assert.equal(page.vm.state_text, '运行中');
	assert.equal(page.previousStats.at_ms, 1000);
	assert.equal(page.poller, null);
});

test('T10.3 scenario 1: state levels, duration buckets, missing since and DNS failsafe', () => {
	const levels = {
		stopped: 'neutral', starting: 'neutral', running: 'ok',
		degraded: 'warn', failsafe: 'warn', error: 'error', future: 'neutral'
	};
	for (const [state, level] of Object.entries(levels)) {
		const vm = build({ ok: true, state, waiting_network: true, dns_failsafe: true });
		assert.equal(vm.state_level, level, state);
		assert.equal(vm.state_duration_text, null, state);
		assert.equal(vm.dns_failsafe, true, state);
	}
	for (const [age, text] of [ [ 45, '已持续 45 秒' ], [ 150, '已持续 2 分钟' ],
		[ 7200, '已持续 2 小时' ], [ 3 * 86400, '已持续 3 天' ] ])
		assert.equal(build({ ok: true, state: 'running', since: NOW - age }).state_duration_text, text);
});

test('T10.3 scenario 2: known reasons, unknown code and null last_error', () => {
	const reasons = {
		NODE_RESOLVE_FAILED: '节点地址解析失败',
		CONFIG_INVALID: '配置无效，详见日志页',
		START_FAILED: '启动失败，详见日志页',
		FUTURE_ERROR: 'FUTURE_ERROR'
	};
	for (const [last_error, text] of Object.entries(reasons))
		assert.equal(build({ ok: true, state: 'error', last_error }).error_text, text);
	assert.equal(build({ ok: true, last_error: null }).error_text, null);
});

/* Inspect every string, including nested components and button descriptions. */
function allStrings(value) {
	if (typeof value === 'string')
		return [ value ];
	if (!value || typeof value !== 'object')
		return [];
	return Object.values(value).flatMap(allStrings);
}

test('T10.3 scenario 3: DNS explanations, visibility and no raw tier codes in model strings', () => {
	const tiers = {
		T1: '经节点解析（正常）',
		T2: '直连境外 DNS（启动中，或代理不健康）',
		T3: '仅用国内 DNS（境外 DNS 都不通，结果可能被污染）',
		future: 'future'
	};
	for (const [dns_tier, text] of Object.entries(tiers)) {
		for (const state of [ 'starting', 'running', 'degraded', 'failsafe', 'stopped', 'error', 'unknown' ]) {
			const vm = build({ ok: true, state, dns_tier });
			assert.equal(vm.dns_text, ['stopped', 'error', 'unknown'].includes(state) ? null : text);
			for (const s of allStrings(vm))
				assert.doesNotMatch(s, /T[123]/);
		}
	}
	assert.equal(build({ ok: true, state: 'running', dns_tier: null }).dns_text, null);
});

test('T10.3 scenario 4: node labels, sorted current options, switch guard and probe levels', () => {
	const model = dashboardModel();
	assert.deepEqual(build({ ok: true, state: 'running', node_id: 'n_a' }, null,
		{ n_a: 'Alpha' }).node_options, [ { value: 'n_a', text: 'Alpha（当前）' } ]);
	assert.equal(build({ ok: true, state: 'running', node_id: 'n_a' }).current_node, 'n_a');
	assert.equal(build({ ok: true }).node_text, '还没有节点，请到节点页添加或导入');
	assert.deepEqual(model.node_options({ n_z: 'Zulu', n_a: 'Alpha', n_b: '' }, 'n_a'), [
		{ value: 'n_a', text: 'Alpha（当前）' }, { value: 'n_b', text: 'n_b' }, { value: 'n_z', text: 'Zulu' }
	]);
	assert.deepEqual(model.node_options(null, null), []);
	assert.equal(model.can_switch('n_a', 'n_a'), false);
	assert.equal(model.can_switch('n_b', 'n_a'), true);
	assert.equal(model.can_switch('', 'n_a'), false);
	for (const [probe, level] of [ [ { ok: true }, 'ok' ], [ { ok: false }, 'error' ], [ null, 'neutral' ] ])
		assert.equal(build({ ok: true, last_probe: probe }).probe_level, level);
});

test('T10.3 scenario 5 / T10.4: own component first, version failure null, installed components in fixed order', () => {
	const inventory = { ok: true, components: {
		xray: { found: true, version: '26.9.30', path: '/usr/bin/xray' },
		'chinadns-ng': { found: true, version: '2025.06.20', path: '/usr/bin/chinadns-ng' }
	} };
	const vm = build({ ok: true }, null, null, null, null, null, inventory);
	assert.deepEqual(vm.components, [
		{ name: 'aether-proxy', version: '0.1.0-r2', path: null },
		{ name: 'xray', version: '26.9.30', path: '/usr/bin/xray' },
		{ name: 'chinadns-ng', version: '2025.06.20', path: '/usr/bin/chinadns-ng' }
	]);
	assert.equal(build({ ok: true }, { ok: false }).components[0].version, null);
	assert.deepEqual(build({ ok: false }, { ok: false }, null, NOW, true, null, { ok: false }).components, [
		{ name: 'aether-proxy', version: null, path: null },
		{ name: 'xray', version: null, path: null },
		{ name: 'chinadns-ng', version: null, path: null }
	]);
});

function visibleText(node) {
	if (typeof node === 'string')
		return node;
	if (!node || typeof node !== 'object')
		return '';
	return visibleText(node.content) + (Array.isArray(node.children)
		? node.children.map(visibleText).join('') : visibleText(node.children));
}

function sections(root) {
	return findAll(root, 'div').filter((el) => el.attrs.class === 'cbi-section');
}

/* The node controls are the last row of the merged runtime section. */
function nodeRow(root) {
	return sections(root).find((s) => s.children[0].children === '运行状态').children.at(-1);
}

function renderStatus(status, version = { ok: true, version: '0.2.0-r6' }, enabled = true) {
	const page = loadView();
	const root = page.render([ { reply: status, stats: readings(1000, 0, 0, 0, 0) }, version,
		{ labels: { n_a: 'Alpha', n_b: 'Beta' }, node: 'n_a', enabled } ]);
	return { page, root };
}

test('T10.3 scenario 6a: ordered sections, title refresh controls, absent notices and removed subscriptions', () => {
	const status = { ok: true, state: 'running', notices: [
		{ code: 'COMPONENT_MISSING', args: { component: 'xray' } },
		{ code: 'UPDATE_AVAILABLE', args: { package: 'xray-core', available: '27' } }
	] };
	const { root } = renderStatus(status);
	assert.deepEqual(sections(root).map((s) => s.children[0].children),
		[ '运行状态', '流量与连接', '组件版本' ]);
	const title = root.children[0];
	assert.equal(findAll(title, 'h2')[0].children, '以太跃迁');
	assert.equal(findAll(title, 'select').length, 1);
	assert.equal(findAll(title, 'button')[0].children, '刷新');
	assert.ok(visibleText(title).includes('自动刷新'));
	const noticeItems = findAll(root, 'li');
	assert.equal(noticeItems.length, 2);
	assert.ok(noticeItems.every((li) => li.attrs.class === 'alert-message warning'));
	assert.ok(visibleText(noticeItems[0]).includes('xray'));
	assert.doesNotMatch(visibleText(root), /更新订阅|服务状态、待处理提示与启停控制/);
	assert.doesNotMatch(fs.readFileSync(VIEW, 'utf8'), /sub_update/);
	const clean = renderStatus({ ok: true, state: 'running' }).root;
	assert.deepEqual(sections(clean).map((s) => s.children[0].children),
		[ '运行状态', '流量与连接', '组件版本' ]);
	const failure = renderStatus({ ok: false, code: 'TIMEOUT', detail: 'offline' }, undefined, false).root;
	const pending = failure.children[1];
	assert.doesNotMatch(visibleText(pending), /待处理提示/);
	assert.ok(findAll(pending, 'div').some((n) => n.attrs.class === 'alert-message error'
		&& visibleText(n).includes('TIMEOUT: offline')));
	assert.ok(findAll(pending, 'div').some((n) => n.attrs.class === 'alert-message warning'
		&& visibleText(n).includes('服务未启用')));
});

test('T10.3 scenario 6b: state and probe colors use theme variables, neutral has no color', () => {
	const colors = {
		ok: 'var(--success-color-high, #2f855a)', warn: 'var(--warning-color, #b7791f)',
		error: 'var(--error-color-high, #c53030)', neutral: ''
	};
	for (const [state, level] of [ [ 'running', 'ok' ], [ 'degraded', 'warn' ], [ 'failsafe', 'warn' ],
		[ 'error', 'error' ], [ 'stopped', 'neutral' ], [ 'starting', 'neutral' ], [ 'future', 'neutral' ] ]) {
		for (const [probe, probeLevel] of [ [ { ok: true }, 'ok' ], [ { ok: false }, 'error' ], [ null, 'neutral' ] ]) {
			const { root } = renderStatus({ ok: true, state, last_probe: probe });
			const word = findAll(root, 'strong')[0];
			assert.match(word.attrs.style, /font-size: 1\.6em/);
			assert.equal(word.attrs.style.includes('color:'), level !== 'neutral');
			if (level !== 'neutral')
				assert.ok(word.attrs.style.includes(colors[level]));
			const text = probe ? (probe.ok ? tr('Healthy, %s ms', '?') : tr('Probe failed'))
				: tr('Not probed yet');
			const result = findAll(nodeRow(root), 'span').find((n) => visibleText(n) === text);
			assert.ok(result, 'health result is in the runtime node row');
			assert.equal(result.attrs.style, probeLevel === 'neutral' ? '' : 'color:' + colors[probeLevel]);
		}
	}
});

test('T10.3 scenario 6c: reason, DNS, address, traffic table, connection tooltip and own version', () => {
	const { page, root } = renderStatus({ ok: true, state: 'running', since: NOW,
		dns_tier: 'T1', dns_failsafe: true, node_id: 'n_a', node_ip: '203.0.113.10',
		last_error: 'NODE_RESOLVE_FAILED' }, { ok: false });
	const blocks = sections(root);
	assert.ok(visibleText(blocks[0]).includes('已持续'));
	assert.ok(visibleText(blocks[0]).includes('原因：节点地址解析失败'));
	assert.ok(visibleText(blocks[0]).includes('境外域名解析：经节点解析（正常）'));
	const reason = findAll(blocks[0], 'div').find((n) => visibleText(n) === '原因：节点地址解析失败');
	assert.equal(reason.attrs.style, 'color:var(--error-color-high, #c53030)');
	const fallback = findAll(blocks[0], 'span').find((n) => visibleText(n) === 'DNS 已回退到原配置');
	assert.equal(fallback.attrs.style, 'color:var(--warning-color, #b7791f)');
	const address = findAll(nodeRow(root), 'span').find((n) => n.children === '节点地址 203.0.113.10');
	assert.ok(address);
	assert.equal(address.attrs.title, undefined);
	assert.ok(!findAll(nodeRow(root), 'span').some((n) => n.attrs.style === 'font-size: 1.2em'));
	const table = findAll(blocks[1], 'table')[0];
	assert.deepEqual(table.children.map((row) => row.children.map((cell) => cell.children)), [
		[ '', '上传', '下载' ], [ '代理', '–', '–' ], [ '直连', '–', '–' ], [ '合计（WAN 口）', '–', '–' ]
	]);
	const connections = findAll(blocks[1], 'span');
	assert.equal(visibleText(connections[0]), '代理连接 3');
	assert.equal(visibleText(connections[1]), '总连接 10');
	assert.equal(connections[1].attrs.title, '系统连接跟踪表（conntrack）中的连接总数');
	assert.doesNotMatch(visibleText(root), /T[123]|conntrack|aether-proxy 版本/);
	const componentTable = findAll(blocks[2], 'table')[0];
	assert.equal(componentTable.attrs.style, 'font-size: 0.9em');
	assert.deepEqual(componentTable.children[1].children.map((c) => c.children), [ 'aether-proxy', '–', '–' ]);
	page.refresh({ ok: true, state: 'stopped', dns_tier: 'T2' });
	assert.doesNotMatch(visibleText(root), /境外域名解析|原因：/);
});

test('T10.3 scenario 6d: polling preserves enable, node selection, probe button and result nodes', () => {
	const { page, root } = renderStatus({ ok: true, state: 'running' });
	const enable = findAll(root, 'input')[0];
	const nodes = findAll(root, 'select')[1];
	const probeButton = page.probeButton;
	const probeMessage = page.probeMessage;
	nodes.value = 'n_b';
	nodes.attrs.change();
	probeButton.disabled = true;
	probeMessage.content = '检测中';
	page.refresh({ ok: true, state: 'degraded' }, readings(2000, 1024, 2048, 4096, 8192));
	assert.equal(findAll(root, 'input')[0], enable);
	assert.equal(findAll(root, 'select')[1], nodes);
	assert.equal(nodes.value, 'n_b');
	assert.equal(page.probeButton, probeButton);
	assert.equal(probeButton.disabled, true);
	assert.equal(page.probeMessage, probeMessage);
	assert.equal(probeMessage.content, '检测中');
	const rows = findAll(sections(root)[1], 'table')[0].children;
	assert.deepEqual(rows[1].children.map((c) => c.children), [ '代理', '1.0 KB/s', '2.0 KB/s' ]);
});

test('T10.3 scenario 7: relative font sizes, theme-only colors and no theme-specific label modifiers', () => {
	const src = fs.readFileSync(VIEW, 'utf8');
	assert.doesNotMatch(src, /font-size:\s*\d+(?:\.\d+)?px/);
	const withoutFallbacks = src.replace(/var\(--[\w-]+,\s*#[a-f\d]{3,8}\)/gi, '');
	assert.doesNotMatch(withoutFallbacks, /#[a-f\d]{3,8}\b/i);
	assert.doesNotMatch(src, /label\s+(success|warning|danger|notice|important)\b/);
	assert.doesNotMatch(src, /rpc\s*\.\s*declare|innerHTML|cbi-button-reset/);
});

test('T10.4 scenario 4a: configured-node fallback, runtime precedence, unknown status and hidden inactive IP', () => {
	const labels = { n_a: 'Alpha', n_b: 'Beta' };
	for (const node_id of [ undefined, null, '' ]) {
		const vm = build({ ok: true, state: 'stopped', node_id, node_ip: 'stale' },
			null, labels, NOW, true, 'n_a');
		assert.equal(vm.current_node, 'n_a');
		assert.equal(vm.node_options[0].text, 'Alpha（当前）');
		assert.equal(vm.node_ip, null);
	}
	assert.equal(build({ ok: true, state: 'running', node_id: 'n_b' },
		null, labels, NOW, true, 'n_a').current_node, 'n_b');
	assert.equal(build({ ok: true }, null, labels, NOW, true, 'n_unknown').current_node, 'n_unknown');
	for (const node of [ undefined, null, '' ])
		assert.equal(build({ ok: true, node_id: '' }, null, labels, NOW, true, node).current_node, null);
	assert.equal(build({ ok: false }, null, labels, NOW, true, 'n_a').current_node, 'n_a');
	for (const state of [ 'stopped', 'error', 'unknown' ])
		assert.equal(build({ ok: true, state, node_ip: 'stale' }).node_ip, null);
	for (const state of [ 'starting', 'running', 'degraded', 'failsafe' ])
		assert.equal(build({ ok: true, state, node_ip: '203.0.113.10' }).node_ip, '203.0.113.10');
});

test('T10.4 scenario 4b: probe phrases without full stops, disabled notice and empty selection guard', () => {
	const model = dashboardModel();
	for (const [probe, text] of [ [ { ok: true, latency_ms: 12 }, '正常，12 ms' ],
		[ { ok: false }, '检测失败' ], [ null, '尚未检测' ] ]) {
		assert.equal(build({ ok: true, last_probe: probe }).probe_text, text);
		if (probe) {
			assert.equal(model.probe_result(probe), text);
			assert.deepEqual(model.probe_completion({ last_probe: { ...probe, at: 10 } }, 10),
				{ done: true, text });
		}
	}
	assert.equal(build({ ok: true }, null, null, NOW, false).disabled_notice,
		'服务未启用：打开『启用』开关后会自动启动');
	for (const empty of [ undefined, null, '' ])
		assert.equal(model.can_switch(empty, 'n_a'), false);
	assert.doesNotMatch(fs.readFileSync(MODEL, 'utf8'), /TODO\(design\)/);
});

test('T10.4 scenario 4c: three installed-component rows, missing versions, missing binaries and failed calls', () => {
	const inventory = { ok: true, components: {
		xray: { found: true, path: '/usr/bin/xray', version: null },
		'chinadns-ng': { found: false, path: null, version: null }
	} };
	const rows = build({ ok: false }, null, null, NOW, true, null, inventory).components;
	assert.deepEqual(rows, [
		{ name: 'aether-proxy', version: '0.1.0-r2', path: null },
		{ name: 'xray', version: null, path: '/usr/bin/xray' },
		{ name: 'chinadns-ng', version: null, path: '未找到' }
	]);
	const cells = findAll(loadView().componentTable(rows), 'tr').map((row) => row.children.map((c) => c.children));
	assert.deepEqual(cells.slice(1), [
		[ 'aether-proxy', '0.1.0-r2', '–' ], [ 'xray', '–', '/usr/bin/xray' ], [ 'chinadns-ng', '–', '未找到' ]
	]);
	for (const failure of [ null, { ok: false, code: 'TIMEOUT' } ]) {
		const result = build({ ok: true, components: inventory.components },
			null, null, NOW, true, null, failure).components;
		assert.equal(result.length, 3);
		assert.deepEqual(result.slice(1), [
			{ name: 'xray', version: null, path: null }, { name: 'chinadns-ng', version: null, path: null }
		]);
	}
});

test('T10.4 scenario 5 / T10.5: defer components once, preserve inventory during polling and align flex controls',
	async () => {
	const calls = [], polls = [];
	const inventory = { ok: true, components: {
		xray: { found: true, path: '/usr/bin/xray', version: '26.9.30' },
		'chinadns-ng': { found: false, path: null, version: null }
	} };
	const page = loadView({
		ap: {
			call: async (method) => {
				calls.push(method);
				return method === 'components' ? inventory : method === 'version'
					? { ok: true, version: '0.2.0-r6' } : { ok: true, state: 'stopped' };
			},
			poll: (fn) => { polls.push(fn); return { stop() {} }; }
		},
		uci: {
			sections: (cfg, type, cb) => { if (type === 'node') cb({ '.name': 'n_a', label: 'Alpha' }); },
			get: (cfg, sec, opt) => opt === 'node' ? 'n_a' : '1'
		}
	});
	const data = await page.load();
	assert.equal(calls.filter((m) => m === 'components').length, 0);
	const root = page.render(data);
	await page.componentRequest;
	assert.equal(calls.filter((m) => m === 'components').length, 1);
	assert.equal(page.vm.current_node, 'n_a', 'view passes UCI main.node to the model');
	await polls[0]();
	await page.fetchRefresh();
	assert.equal(calls.filter((m) => m === 'components').length, 1, 'poll/manual refresh must not rediscover versions');
	assert.deepEqual(page.vm.components.slice(1).map((c) => c.path), [ '/usr/bin/xray', '未找到' ]);
	const title = root.children[0];
	assert.match(title.attrs.style, /margin-bottom:\s*1em/);
	const label = findAll(title, 'label').find((el) => visibleText(el).includes('自动刷新'));
	assert.ok(findAll(label, 'span').some((n) => n.children === '自动刷新'
		&& /white-space:\s*nowrap/.test(n.attrs.style)));
	assert.equal(findAll(label, 'select').length, 1, 'label and select share the flex container');
	assert.match(label.attrs.style, /gap:\s*0\.5em/);
	for (const tag of [ 'div', 'label' ]) {
		for (const element of findAll(root, tag)) {
			if (/display:\s*flex/.test(element.attrs.style ?? ''))
				assert.match(element.attrs.style, /align-items:\s*(center|flex-end)/);
		}
	}
});

test('T10.4 scenario 6: every inline display:flex explicitly sets align-items; no status.components', () => {
	const source = fs.readFileSync(VIEW, 'utf8');
	const styles = [ ...source.matchAll(/['"]([^'"\n]*display:\s*flex[^'"\n]*)['"]/g) ];
	assert.ok(styles.length >= 8, 'all remaining flex declarations are examined');
	for (const [, style] of styles)
		/* docs/10 「样式」 requires an explicit value, usually center. */
		assert.match(style, /align-items:\s*(center|flex-end)/);
	assert.doesNotMatch(source, /\bstatus\s*\.\s*components/);
});

test('T10.5 scenario 1a: effective node drives sorted options, current suffix and switch guard', () => {
	const model = dashboardModel();
	const labels = { n_b: 'Beta', n_a: 'Alpha' };
	const cases = [
		...['starting', 'running', 'degraded', 'failsafe'].map((state) =>
			[ { ok: true, state, node_id: 'n_b' }, 'n_b' ]),
		...[ 'stopped', 'error', 'unknown' ].map((state) => [ { ok: true, state, node_id: 'n_b' }, 'n_a' ]),
		[ { ok: false, code: 'TIMEOUT', node_id: 'n_b' }, 'n_a' ],
		[ null, 'n_a' ],
		[ { ok: true, state: 'running', node_id: '' }, 'n_a' ]
	];
	for (const [status, current] of cases) {
		const vm = build(status, null, labels, NOW, true, 'n_a');
		assert.equal(vm.current_node, current);
		assert.equal(vm.node_text, null, 'nonempty options replace the old large node name');
		assert.deepEqual(vm.node_options.map((o) => o.value), [ 'n_a', 'n_b' ]);
		assert.equal(vm.node_options.find((o) => o.value === current).text,
			(current === 'n_a' ? 'Alpha' : 'Beta') + '（当前）');
		assert.equal(vm.node_options.filter((o) => o.text.endsWith('（当前）')).length, 1);
		assert.equal(model.can_switch(current, vm.current_node), false);
		assert.equal(model.can_switch(current === 'n_a' ? 'n_b' : 'n_a', vm.current_node), true);
	}
	for (const status of [ { ok: true, state: 'running' }, { ok: false } ]) {
		const vm = build(status);
		assert.equal(vm.node_text, '还没有节点，请到节点页添加或导入');
		assert.deepEqual(vm.node_options, []);
	}
});

test('T10.5 scenario 1b: address text requires an active service and nonempty runtime IP', () => {
	for (const state of [ 'starting', 'running', 'degraded', 'failsafe', 'stopped', 'error', 'unknown' ]) {
		for (const node_ip of [ undefined, null, '', '203.0.113.10' ]) {
			const vm = build({ ok: true, state, node_ip });
			const visible = ['starting', 'running', 'degraded', 'failsafe'].includes(state) && !!node_ip;
			assert.equal(vm.node_address_text, visible ? '节点地址 203.0.113.10' : null);
		}
	}
	assert.equal(build({ ok: false, state: 'running', node_ip: 'stale' }).node_address_text, null);
});

test('T10.5 scenario 1c: component pending, successful and failed states determine both cells', () => {
	const model = dashboardModel();
	const pending = model.component_rows({ ok: true, version: '0.2.0-r6' }, undefined);
	assert.deepEqual(pending, [
		{ name: 'aether-proxy', version: '0.2.0-r6', path: null },
		{ name: 'xray', version: '读取中…', path: '读取中…' },
		{ name: 'chinadns-ng', version: '读取中…', path: '读取中…' }
	]);
	const inventory = { ok: true, components: {
		xray: { found: true, version: '26.9.30', path: '/usr/bin/xray' },
		'chinadns-ng': { found: true, version: '2025.08.09', path: '/usr/bin/chinadns-ng' }
	} };
	assert.deepEqual(model.component_rows(null, inventory).slice(1), [
		{ name: 'xray', version: '26.9.30', path: '/usr/bin/xray' },
		{ name: 'chinadns-ng', version: '2025.08.09', path: '/usr/bin/chinadns-ng' }
	]);
	for (const failure of [ null, { ok: false, code: 'RPC_FAILED' }, { ok: false, code: 'TIMEOUT' } ])
		assert.deepEqual(model.component_rows(null, failure).slice(1), [
			{ name: 'xray', version: null, path: null }, { name: 'chinadns-ng', version: null, path: null }
		]);
});

function componentCells(root) {
	const section = sections(root).find((s) => s.children[0].children === '组件版本');
	return findAll(section, 'tr').slice(2).map((row) => row.children.map((cell) => cell.children));
}

test('T10.5 scenario 2a: post-render inventory updates only the table and is never reissued on refresh', async () => {
	const calls = [], polls = [];
	let resolveInventory;
	const page = loadView({ ap: {
		call: (method) => {
			calls.push(method);
			if (method === 'components')
				return new Promise((resolve) => { resolveInventory = resolve; });
			return Promise.resolve(method === 'version' ? { ok: true, version: '0.2.0-r6' }
				: { ok: true, state: 'running' });
		},
		poll: (fn) => { polls.push(fn); return { stop() {} }; }
	}, uci: {
		sections: (cfg, type, cb) => {
			if (type === 'node') {
				cb({ '.name': 'n_a', label: 'Alpha' });
				cb({ '.name': 'n_b', label: 'Beta' });
			}
		},
		get: (cfg, sec, opt) => opt === 'node' ? 'n_a' : '1'
	} });
	const data = await page.load();
	assert.ok(!calls.includes('components'), 'slow inventory cannot block load');
	const root = page.render(data);
	assert.ok(!calls.includes('components'), 'request starts only after synchronous render returns');
	assert.deepEqual(componentCells(root), [
		[ 'xray', '读取中…', '读取中…' ], [ 'chinadns-ng', '读取中…', '读取中…' ]
	]);
	const blocks = sections(root).slice(0, -1);
	const tables = findAll(root, 'table');
	const nodes = findAll(blocks[0], 'select')[0];
	nodes.value = 'n_b';
	nodes.attrs.change();
	page.probeMessage.content = '检测中';
	await Promise.resolve();
	assert.equal(typeof resolveInventory, 'function');
	assert.deepEqual(componentCells(root)[0], [ 'xray', '读取中…', '读取中…' ]);
	resolveInventory({ ok: true, components: {
		xray: { found: true, version: '26.9.30', path: '/usr/bin/xray' },
		'chinadns-ng': { found: false, version: null, path: null }
	} });
	await page.componentRequest;
	assert.deepEqual(componentCells(root), [
		[ 'xray', '26.9.30', '/usr/bin/xray' ], [ 'chinadns-ng', '–', '未找到' ]
	]);
	sections(root).slice(0, -1).forEach((block, i) => assert.equal(block, blocks[i]));
	assert.equal(findAll(root, 'table')[0], tables[0], 'traffic table is not replaced');
	assert.notEqual(findAll(root, 'table')[1], tables[1], 'component table alone is replaced');
	assert.equal(findAll(blocks[0], 'select')[0], nodes);
	assert.equal(nodes.value, 'n_b');
	assert.equal(page.probeMessage.content, '检测中');
	await polls[0]();
	await page.fetchRefresh();
	assert.equal(calls.filter((m) => m === 'components').length, 1);
	assert.equal(componentCells(root)[0][1], '26.9.30');
});

test('T10.5 scenario 2b: failed post-render inventory replaces all four loading cells with dashes', async () => {
	for (const failure of [ null, { ok: false, code: 'RPC_FAILED' }, { ok: false, code: 'TIMEOUT' } ]) {
		const page = loadView({ ap: {
			call: async (method) => method === 'components' ? failure : { ok: true, state: 'stopped' },
			poll: () => ({ stop() {} })
		} });
		const root = page.render(await page.load());
		assert.deepEqual(componentCells(root), [
			[ 'xray', '读取中…', '读取中…' ], [ 'chinadns-ng', '读取中…', '读取中…' ]
		]);
		await page.componentRequest;
		assert.deepEqual(componentCells(root), [ [ 'xray', '–', '–' ], [ 'chinadns-ng', '–', '–' ] ]);
	}
});

test('T10.5 scenario 2c / T10.6: node groups retain runtime selection, UCI fallback, address and no large name', () => {
	const { page, root } = renderStatus({ ok: true, state: 'running', node_id: 'n_b',
		node_ip: '203.0.113.10', last_probe: { ok: true, latency_ms: 12, at: NOW - 30 } });
	const nodeBlock = nodeRow(root);
	const row = nodeBlock;
	assert.equal(row.children.length, 2, 'left selector group and right probe group');
	const [first, second] = row.children;
	const select = findAll(first, 'select')[0];
	const button = findAll(first, 'button')[0];
	assert.equal(select.value, 'n_b', 'runtime selection overrides configured n_a');
	assert.equal(select.children[1].children, 'Beta（当前）');
	assert.equal(button.disabled, true);
	select.value = 'n_a';
	select.attrs.change();
	assert.equal(button.disabled, false, 'guard compares against runtime, not UCI');
	assert.match(visibleText(second), /节点地址 203\.0\.113\.10.*正常，12 ms.*测延迟/);
	assert.ok(findAll(second, 'small')[0].children.includes('前'), 'probe age stays in the right group');
	assert.doesNotMatch(visibleText(second), /Alpha|Beta/);
	assert.ok(!findAll(nodeBlock, 'span').some((s) => /font-size:\s*1\.2em/.test(s.attrs.style ?? '')));
	assert.ok(!findAll(nodeBlock, 'span').some((s) => s.attrs.title));
	page.refresh({ ok: true, state: 'stopped', node_id: 'n_b', node_ip: 'stale' });
	let updated = nodeRow(root);
	assert.equal(findAll(updated, 'select')[0].value, 'n_a');
	assert.equal(findAll(updated, 'select')[0].children[0].children, 'Alpha（当前）');
	assert.equal(findAll(updated, 'button')[0].disabled, true);
	assert.doesNotMatch(visibleText(updated), /节点地址|stale/);
	page.refresh({ ok: false, code: 'TIMEOUT' });
	updated = nodeRow(root);
	assert.equal(findAll(updated, 'select')[0].value, 'n_a', 'failed status selects the configured node');
	assert.equal(findAll(updated, 'button')[0].disabled, true);
});

test('T10.5 scenario 2d: no nodes renders guidance instead of selector and apply button', async () => {
	const page = loadView();
	const root = page.render(await page.load());
	const block = nodeRow(root);
	assert.equal(visibleText(block.children[0]), '还没有节点，请到节点页添加或导入');
	assert.equal(findAll(block, 'select').length, 0);
	assert.deepEqual(findAll(block, 'button').map((b) => b.children), [ '测延迟' ]);
	await page.componentRequest;
});

test('T10.6 scenario 1a: WAN label and tooltip include the device only when available', () => {
	const model = dashboardModel();
	for (const [wan, title] of [
		[ { dev: 'pppoe-wan' }, 'WAN 接口 pppoe-wan 的全部流量，含路由器自身' ],
		[ null, 'WAN 接口的全部流量，含路由器自身' ],
		[ {}, 'WAN 接口的全部流量，含路由器自身' ],
		[ { dev: '' }, 'WAN 接口的全部流量，含路由器自身' ]
	]) {
		const traffic = model.traffic(null, { wan });
		assert.equal(traffic.total_label, '合计（WAN 口）');
		assert.equal(traffic.total_title, title);
	}
	assert.equal(model.traffic(null, null).total_title, 'WAN 接口的全部流量，含路由器自身');
});

function trafficStatuses() {
	return [
		...['stopped', 'error', 'future', undefined].map((state) => [ { ok: true, state }, true ]),
		[ { ok: false, code: 'TIMEOUT', state: 'running' }, true ],
		[ null, true ],
		...['starting', 'running', 'degraded', 'failsafe'].map((state) => [ { ok: true, state }, false ])
	];
}

/* WAN still advances when the service's nft table is absent. In particular,
   this must not turn other applications' proxy traffic into our direct rate. */
function inactiveReadings(at_ms, tx, rx) {
	return { ...readings(at_ms, 0, 0, tx, rx), proxy: null };
}

const TRAFFIC_NOTE = '服务未运行，无法区分代理与直连';

test('T10.6 scenario 1b: inactive or failed status explains unavailable rates without treating WAN as direct', () => {
	const model = dashboardModel();
	for (const [status, inactive] of trafficStatuses()) {
		assert.equal(build(status).traffic_note, inactive ? TRAFFIC_NOTE : null);
		if (!inactive)
			continue;
		const traffic = model.traffic(inactiveReadings(1000, 100, 200), inactiveReadings(2000, 1124, 2248));
		assert.deepEqual(traffic.total, { tx: '1.0 KB/s', rx: '2.0 KB/s' });
		assert.deepEqual(traffic.proxy, { tx: '–', rx: '–' });
		assert.deepEqual(traffic.direct, { tx: '–', rx: '–' });
	}
});

test('T10.6 scenario 2a: WAN row title and small inactive explanation precede connections, absent when active', () => {
	for (const [status, inactive] of trafficStatuses()) {
		const { page, root } = renderStatus(status);
		page.previousStats = inactiveReadings(1000, 100, 200);
		page.refresh(status, inactiveReadings(2000, 1124, 2248));
		const block = sections(root).find((s) => s.children[0].children === '流量与连接');
		const table = block.children[1];
		const total = table.children[3];
		assert.deepEqual(total.children.slice(1).map((c) => c.children), [ '1.0 KB/s', '2.0 KB/s' ]);
		assert.equal(visibleText(total.children[0]), inactive ? '合计（WAN 口）' + TRAFFIC_NOTE : '合计（WAN 口）');
		assert.equal(total.children[0].attrs.title, 'WAN 接口 eth1 的全部流量，含路由器自身');
		for (const row of table.children.slice(1, 3))
			assert.deepEqual(row.children.slice(1).map((c) => c.children), [ '–', '–' ]);
		/* the inactive note lives in the WAN row's label cell, not below the table */
		assert.equal(block.children.length, 3);
		if (inactive) {
			const small = total.children[0].children.find((c) => c.tag === 'small');
			assert.equal(visibleText(small), TRAFFIC_NOTE);
		}
		assert.equal(visibleText(block.children.at(-1)), '代理连接 3总连接 10');
		assert.equal(visibleText(block).includes(TRAFFIC_NOTE), inactive);
	}
});

test('T10.6 scenario 2b: single wrapping outer node row contains left controls and ordered right probe group', () => {
	const { root } = renderStatus({ ok: true, state: 'running', node_id: 'n_a', node_ip: '203.0.113.10',
		last_probe: { ok: true, latency_ms: 12, at: NOW - 30 } });
	const row = nodeRow(root);
	for (const rule of [ /display:\s*flex/, /align-items:\s*center/, /justify-content:\s*space-between/,
		/flex-wrap:\s*wrap/, /gap:\s*0\.5em\s+1em/ ])
		assert.match(row.attrs.style, rule);
	assert.equal(row.children.length, 2);
	const [left, right] = row.children;
	assert.deepEqual(left.children.map((c) => c.tag), [ 'select', 'button' ]);
	assert.equal(left.children[1].children, '使用此节点');
	/* themes give select width:100%, which wraps the button onto the next line */
	assert.match(left.children[0].attrs.style ?? '', /width:\s*auto/);
	assert.equal(right.children.length, 4);
	assert.equal(right.children[0].children, '节点地址 203.0.113.10');
	assert.equal(right.children[1].children, '正常，12 ms');
	assert.equal(right.children[1].attrs.style, 'color:var(--success-color-high, #2f855a)');
	assert.equal(right.children[2].tag, 'small');
	assert.match(right.children[2].children, /前$/);
	assert.deepEqual(right.children[3].children.map((c) => c.tag), [ 'button', 'span' ]);
	assert.equal(right.children[3].children[0].children, '测延迟');
	assert.equal(right.children[3].children[1].attrs['aria-live'], 'polite');
});

test('T10.6 scenario 2c: no nodes replaces only the left group; inactive address is omitted on the right', async () => {
	const page = loadView();
	const root = page.render(await page.load());
	page.refresh({ ok: true, state: 'stopped', node_ip: 'stale', last_probe: { ok: false, at: NOW - 30 } });
	const row = nodeRow(root);
	assert.equal(row.children.length, 2);
	assert.equal(visibleText(row.children[0]), '还没有节点，请到节点页添加或导入');
	assert.equal(findAll(row.children[0], 'select').length, 0);
	assert.equal(findAll(row.children[0], 'button').length, 0);
	const right = row.children[1];
	assert.equal(right.children.length, 3, 'result, relative time and probe controls without address');
	assert.equal(right.children[0].children, '检测失败');
	assert.equal(right.children[1].tag, 'small');
	assert.equal(findAll(right, 'button')[0].children, '测延迟');
	assert.doesNotMatch(visibleText(right), /节点地址|stale/);
	await page.componentRequest;
});

test('T10.9 scenario 1: disable confirmation and enable tooltip come from the model even on status failure', () => {
	for (const status of [ { ok: true, state: 'running' }, { ok: false, code: 'TIMEOUT' } ]) {
		for (const enabled of [ true, false ]) {
			const vm = build(status, null, null, NOW, enabled);
			assert.equal(vm.disable_confirmation,
				'关闭后服务立即停止，所有流量直连，开机也不再自动启动。确定关闭吗？');
			assert.equal(vm.enabled_note, '启用后开机自动启动；关闭会立即停止服务，所有流量直连');
		}
	}
});

test('T10.9 scenario 2: title left group has heading then tooltip-only enable; right group has refresh controls',
	() => {
	const { page, root } = renderStatus({ ok: true, state: 'running' });
	const title = root.children[0];
	assert.equal(title.children.length, 2);
	const [left, right] = title.children;
	assert.deepEqual(left.children.map((n) => n.tag), [ 'h2', 'label' ]);
	assert.equal(visibleText(left.children[0]), '以太跃迁');
	assert.equal(visibleText(left.children[1]), '启用');
	assert.match(left.attrs.style, /align-items:\s*center/);
	assert.match(left.children[1].attrs.style, /align-items:\s*center/);
	assert.equal(left.children[1].attrs.title, page.vm.enabled_note);
	assert.equal(findAll(left, 'input')[0].attrs.title, page.vm.enabled_note);
	assert.equal(findAll(right, 'label').length, 1);
	assert.equal(visibleText(findAll(right, 'span')[0]), '自动刷新');
	assert.equal(findAll(right, 'select').length, 1);
	assert.equal(findAll(right, 'button')[0].children, '刷新');
	assert.ok(!visibleText(root).includes(page.vm.enabled_note));
	assert.equal(findAll(root, 'input').length, 1, 'only one enable switch, in the title');
});

test('T10.9 scenario 3: disable cancel restores checkbox without writes; confirm saves 0; enable skips confirm',
	async (t) => {
	const saved = globalThis.confirm;
	t.after(() => { globalThis.confirm = saved; });
	for (const [initial, answer] of [ [ true, false ], [ true, true ], [ false, false ] ]) {
		const order = [], asked = [], calls = [];
		const page = loadView({
			rpcCalls: calls,
			uci: {
				set: (...args) => order.push([ 'set', ...args ]),
				save: async () => { order.push([ 'save' ]); }
			},
			ui: { changes: { apply: (rollback) => order.push([ 'apply', rollback ]) } }
		});
		const root = page.render([ { reply: { ok: true, state: 'running' } }, null,
			{ labels: {}, enabled: initial } ]);
		/* A sentinel proves the handler uses the model field, not copied wording. */
		page.vm.disable_confirmation = 'model confirmation';
		globalThis.confirm = (text) => {
			asked.push(text);
			assert.deepEqual(order, [], 'confirmation precedes any UCI change');
			return answer;
		};
		const box = findAll(root, 'input')[0];
		box.checked = !initial;
		await box.attrs.change({ target: box });
		assert.deepEqual(asked, initial ? [ page.vm.disable_confirmation ] : []);
		const cancelled = initial && !answer;
		assert.equal(box.checked, cancelled ? true : !initial);
		assert.equal(page.enabled, box.checked);
		assert.deepEqual(order, cancelled ? [] : [
			[ 'set', 'aetherproxy', 'main', 'enabled', initial ? '0' : '1' ], [ 'save' ], [ 'apply', true ]
		]);
		await page.componentRequest;
		assert.ok(!calls.includes('service'), 'the reload trigger remains responsible for start/stop');
		page.refresh({ ok: true, state: 'running' });
		assert.equal(findAll(root, 'input')[0], box, 'refresh preserves the title switch');
	}
});

test('T10.9 scenario 4: banners follow title before first section with original severity and order; clean has none',
	() => {
	const { page, root } = renderStatus({ ok: false, code: 'TIMEOUT' }, undefined, false);
	assert.equal(root.children[0].children[0].children[0].tag, 'h2');
	assert.equal(root.children[1], page.content, 'banners occupy the content immediately after the title');
	let parts = page.content.content.children;
	assert.deepEqual(parts.map((n) => n.attrs.class), [
		'alert-message error', 'alert-message warning', 'cbi-section', 'cbi-section', 'cbi-section'
	]);
	assert.ok(visibleText(parts[0]).includes('TIMEOUT'));
	assert.ok(visibleText(parts[1]).includes('服务未启用'));
	page.refresh({ ok: true, state: 'running', notices: [
		{ code: 'COMPONENT_MISSING', args: { component: 'xray' } },
		{ code: 'UPDATE_AVAILABLE', args: { package: 'xray-core', available: '27' } }
	] });
	parts = page.content.content.children;
	assert.equal(parts[0].attrs.class, 'alert-message warning', 'disabled banner remains first');
	assert.equal(parts[1].tag, 'ul');
	assert.ok(visibleText(parts[1].children[0]).includes('xray'));
	assert.ok(visibleText(parts[1].children[1]).includes('27'));
	assert.ok(parts[1].children.every((n) => n.attrs.class === 'alert-message warning'));
	assert.equal(parts[2], sections(root)[0]);
	assert.doesNotMatch(visibleText(root), /待处理提示/);
	const clean = renderStatus({ ok: true, state: 'running' });
	assert.equal(clean.page.content.content.children[0], sections(clean.root)[0]);
	assert.equal(visibleText(sections(clean.root)[0].children[0]), '运行状态');
	assert.equal(findAll(clean.root, 'div').filter((n) => /alert-message/.test(n.attrs.class ?? '')).length, 0);
});

test('T10.9 scenario 5: one runtime block has state/buttons, optional details and node row before traffic/components',
	() => {
	for (const [last_error, dns_tier] of [ [ null, null ], [ 'CONFIG_INVALID', null ],
		[ null, 'T1' ], [ 'CONFIG_INVALID', 'T1' ] ]) {
		const { page, root } = renderStatus({ ok: true, state: 'running', since: NOW,
			dns_failsafe: true, last_error, dns_tier });
		const blocks = sections(root);
		assert.deepEqual(blocks.map((n) => visibleText(n.children[0])), [ '运行状态', '流量与连接', '组件版本' ]);
		const block = blocks[0];
		const [left, right] = block.children[1].children;
		assert.equal(findAll(left, 'strong')[0].children, '运行中');
		assert.ok(visibleText(left).includes('已持续'));
		assert.ok(visibleText(left).includes('DNS 已回退到原配置'));
		assert.deepEqual(findAll(right, 'button').map(visibleText), [ '启动', '重启', '停止' ]);
		assert.equal(findAll(block.children[1], 'input').length, 0);
		assert.match(block.children[1].attrs.style, /justify-content:\s*space-between/);
		const hasDetails = !!(last_error || dns_tier);
		assert.equal(block.children.length, hasDetails ? 4 : 3, 'heading, state, optional details, node row');
		if (hasDetails) {
			const details = block.children[2];
			assert.equal(visibleText(details).includes('原因：配置无效'), !!last_error);
			assert.equal(visibleText(details).includes('境外域名解析：经节点解析（正常）'), !!dns_tier);
			assert.equal(details.children.length, Number(!!last_error) + Number(!!dns_tier));
		}
		assert.equal(block.children.at(-1), nodeRow(root));
		assert.equal(findAll(nodeRow(root), 'select')[0], findAll(page.nodeControl, 'select')[0]);
		assert.ok(!findAll(root, 'h3').some((n) => [ '状态', '当前节点', '待处理提示' ].includes(visibleText(n))));
	}
});

test('T8.12c scenario 6: safe DOM, guarded storage and all Dashboard translations', () => {
	const src = fs.readFileSync(VIEW, 'utf8');
	assert.doesNotMatch(src, /rpc\s*\.\s*declare|cbi-button-reset|innerHTML/);
	for (const operation of [ 'getItem', 'setItem' ])
		assert.match(src, new RegExp('try \\{[^}]*localStorage\\.' + operation + '[^}]*\\}\\s*catch'));
	for (const file of [ MODEL, VIEW ]) {
		const source = fs.readFileSync(file, 'utf8');
		for (const match of source.matchAll(/_\('([^'\n]*)', 'aether-proxy'\)/g))
			assert.ok(po[match[1]], `translation exists for ${match[1]}`);
	}
});
