'use strict';

/* Overview model/view tests (docs/tasks/m8.md T8.4, T8.11a, T8.12c;
 * m10.md T10.3–T10.6, T10.9, T10.11, T10.13, T10.17, T10.20, T10.22–T10.24, T10.38).
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

const { loadModule, parsePo, element } = require('./loader.js');
const { actionRow } = require('./button-layout');

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

globalThis.E = element;

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

function build(status, version, labels, now, enabled, configuredNode, components, events) {
	const model = dashboardModel();

	return model.build(status, version ?? { ok: true, version: '0.1.0-r2' }, labels ?? {}, now ?? NOW,
		enabled, configuredNode, components, events);
}

/* Load view/aether-proxy/overview.js with doubles for the modules it requires,
   the way T8.9b loads the updates view for its job-flow test. Each test sees
   the recorded rpc calls and the order of uci/ui operations. */
function loadView(overrides = {}) {
	const rpcCalls = overrides.rpcCalls ?? [];
	const ap = overrides.ap ?? {
		confirm: overrides.confirm ?? (async () => true),
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
		unload: () => {},
		sections: () => {},
		get: () => undefined,
		set: () => {},
		save: () => Promise.resolve(),
		changes: async () => ({})
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
	const modelMod = dashboardModel();

	return loadModule(VIEW, {
		view: { extend: (o) => o },
		uci: uciDouble,
		ui: uiDouble,
		/* dom.content replaces children rather than appending to them. */
		dom: { content: (el, node) => {
			el.children = Array.isArray(node) ? node : [];
			el.content = Array.isArray(node) ? undefined : node;
			overrides.onContent?.(el);
		} },
		'aether-proxy.common': ap,
		'aether-proxy.model.overview': modelMod
	}, { window: Object.assign({
		setTimeout: () => {}, clearTimeout: () => {},
		localStorage: { getItem: () => null, setItem: () => {} },
		addEventListener() {}, removeEventListener() {}
	}, overrides.window ?? {}), document: overrides.document ?? {
		addEventListener() {}, removeEventListener() {}
	} });
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
		stopping: '停止中',
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
		stopping: { start: false, restart: false, stop: false },
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
	assert.equal(vm.error_detail, 'boom');
	assert.ok(!vm.error.includes('boom'), 'raw diagnostics stay out of the summary');
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

		assert.equal(data.enabled, expected, `main.enabled=${raw} loads as ${expected}`);

		page.enabled = data.enabled;
		const box = findTag(page.enableSwitch('note'), 'input');
		/* The compact switch now sits beside the title, without a visible note. */
		assert.match(page.enableSwitch('note').attrs.style, /align-items:\s*center/);

		assert.ok(box, 'the switch renders an input');
		assert.equal(box.attrs.checked, expected ? 'checked' : null, `checked attribute for main.enabled=${raw}`);
	}
});

test('T8.11a scenario 3b: toggling writes UCI, saves and applies with rollback, and never calls service', async () => {
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
	const handler = /handleEnable: async function[\s\S]*?\n\t},/.exec(src);

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
	assert.match(src, /action == 'stop' && !await ap\.confirm\(/);
	assert.doesNotMatch(src, /cbi-button-reset/);

	/* 5s poll, service via ap.call, notification on failure */
	assert.match(src, /this\.startPolling\(this\.interval\)/);
	assert.equal(loadView().readInterval(), 5000, 'default remains the original 5s poll');
	assert.match(src, /ap\.call\('service', \{ action: action \}\)/);
	assert.match(src, /ui\.addNotification\(/);
});

function conflictsModel() {
	return loadModule(path.join(RES, 'aether-proxy', 'model', 'conflicts.js'),
		{ baseclass: { extend: (o) => o } }, { window: {}, document: {} });
}

function logsModel() {
	return loadModule(path.join(RES, 'aether-proxy', 'model', 'logs.js'), {
		baseclass: { extend: (o) => o }, 'aether-proxy.model.conflicts': conflictsModel()
	}, { window: {}, document: {} });
}

function dashboardModel() {
	return loadModule(MODEL, {
		baseclass: { extend: (o) => o }, 'aether-proxy.model.logs': logsModel(),
		'aether-proxy.model.conflicts': conflictsModel()
	}, { window: {}, document: {} });
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
	const page = loadView({ rpcCalls, confirm: async (options) => { asked.push(options.text); return answer; } });
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

test('T10.23 scenario 2 / T10.24: real latency model distinguishes results from request errors', () => {
	const model = dashboardModel();
	const cases = [
		[{ ok: true, code: 204, latency_ms: 12 }, '正常，12 ms（GitHub，手动）'],
		[{ ok: false, code: 'PROBE_TIMEOUT' }, '检测超时（GitHub，手动）'],
		[{ ok: false, code: 'PROBE_FAILED' }, '检测失败（GitHub，手动）'],
		[{ ok: false, code: 'PROBE_FAILED', http_code: 503 }, '返回 HTTP 503（GitHub，手动）'],
		[{ ok: false, code: 'NOT_RUNNING' }, null],
		[{ ok: false, code: 'TIMEOUT', detail: '35s' }, null],
		[{ ok: false, code: 'CMD_FAILED', detail: 'ubus' }, null]
	];
	for (const [reply, text] of cases)
		assert.equal(model.manual_probe(reply, 'GitHub', {}, NOW)?.text ?? null, text);
	assert.equal(model.probe_completion, undefined, 'no last_probe completion logic remains');
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
	assert.deepEqual(calls, [], 'load reads only UCI');
	const root = page.render(data);
	await page.initialRequest;
	await page.componentRequest;
	assert.ok(calls.indexOf('stats') > calls.indexOf('status'));
	assert.equal(findTag(root, 'h2').textContent, '以太跃迁');
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
	const manual = findAll(root, 'button').find((b) => b.textContent === '刷新');
	const first = manual.attrs.click();
	const second = page.fetchRefresh();
	assert.equal(first, second, 'manual and poll requests share the in-flight promise');
	assert.deepEqual(calls, [ 'status' ], 'stats waits for status');
	release();
	await first;
	assert.deepEqual(calls, [ 'status', 'stats' ]);
});

test('T10.23 scenario 4: overview selection uses node_use, reloads UCI then refreshes status', async t => {
	// Keep the exact events.since assertion stable when the async flow crosses a second boundary.
	t.mock.method(Date, 'now', () => NOW * 1000);
	const order = [];
	const page = loadView({
		ap: {
			call: async (method, params) => {
				order.push([method, params]);
				return method === 'status' ? { ok: true, state: 'running', node_id: 'n_a' } : { ok: true };
			},
			poll: () => ({ stop() {} })
		},
		uci: {
			sections: (cfg, type, cb) => {
				if (type === 'node') {
					cb({ '.name': 'n_a', label: 'Alpha' });
					cb({ '.name': 'n_b' });
				}
			},
			get: (cfg, sec, opt) => opt === 'node' ? (order.some(c => c[0] === 'node_use') ? 'n_b' : 'n_a') : '1',
			load: async config => { order.push(['load', config]); },
			unload: config => { order.push(['unload', config]); },
			set: () => assert.fail('node switch must not set session UCI'),
			save: () => assert.fail('node switch must not save session UCI'),
			changes: () => assert.fail('node switch must not inspect staged changes')
		},
		ui: { changes: { apply: () => assert.fail('node switch must not apply session UCI') } }
	});
	const root = page.render(await page.load());
	await page.initialRequest;
	await page.sitesRequest;
	order.length = 0;
	const nodes = findAll(root, 'select')[1];
	assert.equal(nodes.children[0].textContent, 'Alpha（当前）');
	assert.equal(nodes.children[0].attrs.selected, 'selected');
	assert.equal(nodes.children[1].textContent, 'n_b');
	const use = findAll(root, 'button').find((b) => b.textContent === '应用');
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
	assert.deepEqual(order, [ ['node_use', { id: 'n_b' }], ['unload', 'aetherproxy'],
		['load', 'aetherproxy'], ['status', undefined], ['stats', undefined],
		['events', { since: Math.floor(Date.now() / 1000) - 600, level: 'error' }] ]);
	assert.equal(page.vm.switch_notice, '正在切换到「n_b」…');
	assert.equal(use.disabled, true, 'pending switch stays locked after node_use completes');
	assert.equal(nodes.disabled, true);

	const emptyPage = loadView();
	const emptyRoot = emptyPage.render(await emptyPage.load());
	const emptyUse = findAll(emptyRoot, 'button').find((b) => b.textContent === '应用');
	assert.equal(emptyUse, undefined, 'an empty node list has no apply button');
	assert.equal(findAll(emptyRoot, 'select').length, 2, 'refresh and site selectors remain');
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

const SITES = { ok: true, sites: [
	{ name: 'google', label: 'Google' }, { name: 'github', label: 'GitHub' }
] };

test('T10.23 scenario 1: sites load after render, stay disabled until reply, labels and first default', async () => {
	const h = deferredPage('0');
	const { page, calls } = h;
	const root = page.render(await page.load());
	assert.deepEqual(calls, []);
	assert.equal(page.probeSites.disabled, true);
	assert.equal(page.probeButton.disabled, true);
	await Promise.resolve();
	await h.reply('status', { ok: true, state: 'running' });
	assert.equal(page.probeButton.disabled, true, 'running alone is insufficient without sites');
	await h.reply('probe_sites', SITES);
	assert.deepEqual(page.probeSites.children.map(option => [option.value, option.textContent]),
		[['google', 'Google'], ['github', 'GitHub']]);
	assert.equal(page.probeSites.value, 'google');
	assert.equal(page.probeSites.disabled, false);
	assert.equal(page.probeButton.disabled, false);
	assert.ok(visibleText(root).includes('检测真实延迟'));
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await page.initialRequest;
	const refresh = page.fetchRefresh();
	await h.reply('status', { ok: true, state: 'running' });
	await h.reply('stats', readings(2000, 0, 0, 0, 0));
	await refresh;
	assert.equal(calls.filter(call => call.method === 'probe_sites').length, 1);
});

test('T10.23 scenario 1 / T10.24: site failure keeps controls disabled with error and retry', async () => {
	for (const reply of [{ ok: false, code: 'TIMEOUT' }, { ok: true, sites: [] },
		{ ok: true, sites: [null] }, { ok: true, sites: [{ name: 'github' }] }, null]) {
		const h = deferredPage('0');
		const { page } = h;
		page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', { ok: true, state: 'running' });
		await h.reply('probe_sites', reply);
		assert.equal(page.probeSites.disabled, true);
		assert.equal(page.probeButton.disabled, true);
		assert.equal(visibleText(page.probeMessage), `读取站点列表失败（${reply?.code ?? 'RPC_FAILED'}）重试`);
		assert.equal(visibleText(page.probeSites), '读取失败');
		assert.equal(findAll(page.probeMessage, 'button').length, 1);
	}
});

test('T10.23 scenario 1: sites arriving before status cannot enable the probe early', async () => {
	const h = deferredPage('0');
	const { page } = h;
	page.render(await page.load());
	await Promise.resolve();
	await h.reply('probe_sites', SITES);
	assert.equal(page.probeSites.disabled, false);
	assert.equal(page.probeButton.disabled, true);
	await h.reply('status', { ok: true, state: 'degraded' });
	assert.equal(page.probeButton.disabled, false);
});

test('T10.23 scenario 3: only running/degraded with sites enables real latency', async () => {
	const { page } = renderStatus({ ok: true, state: 'running' });
	page.siteOptions = dashboardModel().probe_sites(SITES).options;
	for (const state of ['running', 'degraded', 'starting', 'failsafe', 'stopped', 'error', 'unknown']) {
		page.refresh({ ok: true, state });
		assert.equal(page.probeButton.disabled, !['running', 'degraded'].includes(state), state);
	}
	page.refresh({ ok: false, code: 'TIMEOUT' });
	assert.equal(page.probeButton.disabled, true);
});

test('T8.12c service refresh: stop schedules serialized status/stats even with automatic refresh off', async () => {
	const clock = timerQueue(), calls = [];
	const page = loadView({ window: clock, confirm: async () => true, ap: {
		confirm: async () => true, call: async (method, params) => {
		calls.push([ method, params ]);
		return method === 'status' ? { ok: true, state: 'running' }
			: method === 'stats' ? readings(1000, 1, 2, 3, 4) : { ok: true };
	} } });
	page.content = E('div', {});
	page.labels = {};
	page.enabled = true;
	page.startPolling(0);
	page.refresh({ state: 'running' });
	await page.handleService('stop');
	assert.deepEqual(calls, [ [ 'service', { action: 'stop' } ] ]);
	await clock.run(1500);
	await page.refreshing;
	assert.deepEqual(calls.map((call) => call[0]), [ 'service', 'status', 'stats' ]);
	assert.equal(page.vm.state_text, '运行中');
	assert.equal(page.previousStats.at_ms, 1000);
	assert.equal(page.poller, null);
});

test('T10.3 scenario 1: state levels, duration buckets, missing since and DNS failsafe', () => {
	const levels = {
		stopped: 'neutral', starting: 'busy', stopping: 'busy', running: 'ok',
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
		assert.equal(build({ ok: true, state: 'running', last_probe: probe }).probe_level, level);
});

test('T10.3 scenario 5 / T10.4: own component first, version failure null, installed components in fixed order', () => {
	const inventory = { ok: true, components: {
		xray: { found: true, version: '26.9.30', path: '/usr/bin/xray' },
		'chinadns-ng': { found: true, version: '2025.06.20', path: '/usr/bin/chinadns-ng' }
	} };
	const vm = build({ ok: true }, null, null, null, null, null, inventory);
	assert.deepEqual(vm.components, [
		{ name: 'aether-proxy', version: '0.1.0-r2', path: '/usr/bin/aether-proxy' },
		{ name: 'xray', version: '26.9.30', path: '/usr/bin/xray' },
		{ name: 'chinadns-ng', version: '2025.06.20', path: '/usr/bin/chinadns-ng' }
	]);
	assert.equal(build({ ok: true }, { ok: false }).components[0].version, null);
	assert.deepEqual(build({ ok: false }, { ok: false }, null, NOW, true, null, { ok: false }).components, [
		{ name: 'aether-proxy', version: null, path: '/usr/bin/aether-proxy' },
		{ name: 'xray', version: '读取失败', path: '' },
		{ name: 'chinadns-ng', version: '读取失败', path: '' }
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

/* T10.65 groups the runtime rows in one column, independently of the heading. */
function runtimeRows(root) {
	return sections(root)[0].children[1];
}

/* The node controls remain the last row, with or without the details row. */
function nodeRow(root) {
	return runtimeRows(root).children.at(-1);
}

function renderStatus(status, version = { ok: true, version: '0.2.0-r6' }, enabled = true) {
	/* Inject settled data after the skeleton; pending background reads cannot
	   overwrite the snapshot used by the existing presentation assertions. */
	const page = loadView({ ap: { call: () => new Promise(() => {}) } });
	const root = page.render({ labels: { n_a: 'Alpha', n_b: 'Beta' }, node: 'n_a', enabled });
	page.version = version;
	page.updateComponents();
	page.refresh(status, readings(1000, 0, 0, 0, 0));
	return { page, root };
}

/* Banner assertions ignore the stable region wrappers, not their order. */
function pageParts(page) {
	return page.content.children.flatMap((region) =>
		region === page.noticeContent ? region.children : sections(region));
}

test('T10.3 scenario 6a: ordered sections, title refresh controls, absent notices and removed subscriptions', () => {
	const status = { ok: true, state: 'running', notices: [
		{ code: 'COMPONENT_MISSING', args: { component: 'xray' } },
		{ code: 'UPDATE_AVAILABLE', args: { package: 'xray-core', available: '27' } }
	] };
	const { root } = renderStatus(status);
	assert.deepEqual(sections(root).map((s) => s.children[0].textContent),
		[ '运行状态', '流量与连接', '组件版本' ]);
	const title = root.children[0];
	assert.equal(findAll(title, 'h2')[0].textContent, '以太跃迁');
	assert.equal(findAll(title, 'select').length, 1);
	assert.equal(findAll(title, 'button')[0].textContent, '刷新');
	assert.ok(visibleText(title).includes('自动刷新'));
	const noticeItems = findAll(root, 'li');
	assert.equal(noticeItems.length, 2);
	assert.ok(noticeItems.every((li) => li.attrs.class === 'alert-message warning'));
	assert.ok(visibleText(noticeItems[0]).includes('xray'));
	assert.doesNotMatch(visibleText(root), /更新订阅|服务状态、待处理提示与启停控制/);
	assert.doesNotMatch(fs.readFileSync(VIEW, 'utf8'), /sub_update/);
	const clean = renderStatus({ ok: true, state: 'running' }).root;
	assert.deepEqual(sections(clean).map((s) => s.children[0].textContent),
		[ '运行状态', '流量与连接', '组件版本' ]);
	const failure = renderStatus({ ok: false, code: 'TIMEOUT', detail: 'offline' }, undefined, false).root;
	const pending = failure.children[1];
	assert.doesNotMatch(visibleText(pending), /待处理提示/);
	assert.ok(findAll(pending, 'div').some((n) => n.attrs.class === 'alert-message error'
		&& n.children[0] === '读取状态失败（TIMEOUT），稍后自动重试'
		&& findTag(n, 'pre').textContent === 'offline'));
	assert.ok(findAll(pending, 'div').some((n) => n.attrs.class === 'alert-message warning'
		&& visibleText(n).includes('服务未启用')));
});

test('T10.3 scenario 6b: state and probe colors use theme variables, neutral has no color', () => {
	const colors = {
		ok: 'var(--success-color-high, #2f855a)', warn: 'var(--warning-color, #b7791f)',
		error: 'var(--error-color-high, #c53030)', busy: 'var(--primary-color-high, #2b6cb0)', neutral: ''
	};
	for (const [state, level] of [ [ 'running', 'ok' ], [ 'degraded', 'warn' ], [ 'failsafe', 'warn' ],
		[ 'error', 'error' ], [ 'stopped', 'neutral' ], [ 'starting', 'busy' ], [ 'stopping', 'busy' ],
		[ 'future', 'neutral' ] ]) {
		for (const [probe, probeLevel] of [ [ { ok: true }, 'ok' ], [ { ok: false }, 'error' ], [ null, 'neutral' ] ]) {
			const { root } = renderStatus({ ok: true, state, last_probe: probe });
			const word = findAll(root, 'strong')[0];
			assert.match(word.attrs.style, /font-size: 1\.6em/);
			assert.equal(word.attrs.style.includes('color:'), level !== 'neutral');
			if (level !== 'neutral')
				assert.ok(word.attrs.style.includes(colors[level]));
			const visible = ['running', 'degraded', 'failsafe'].includes(state);
			const text = !visible ? '延迟：–' : probe ? (probe.ok ? tr('Healthy, %s ms', '?') : tr('Probe failed'))
				: tr('Not probed yet');
			const result = findAll(nodeRow(root), 'span').find((n) => visibleText(n) === text);
			assert.ok(result, 'health result is in the runtime node row');
			assert.equal(result.attrs.style, !visible || probeLevel === 'neutral' ? '' : 'color:' + colors[probeLevel]);
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
	const address = findAll(nodeRow(root), 'span').find((n) => n.textContent === '节点地址 203.0.113.10');
	assert.ok(address);
	assert.equal(address.attrs.title, undefined);
	assert.ok(!findAll(nodeRow(root), 'span').some((n) => n.attrs.style === 'font-size: 1.2em'));
	const table = findAll(blocks[1], 'table')[0];
	assert.deepEqual(table.children.map((row) => row.children.map((cell) => cell.textContent)), [
		[ '', '上传', '下载' ], [ '代理', '–', '–' ], [ '直连', '–', '–' ], [ '合计（WAN 口）', '–', '–' ]
	]);
	const connections = findAll(blocks[1], 'span');
	assert.equal(visibleText(connections[0]), '代理连接 3');
	assert.equal(visibleText(connections[1]), '总连接 10');
	assert.equal(connections[1].attrs.title, '系统连接跟踪表（conntrack）中的连接总数');
	assert.doesNotMatch(visibleText(root), /T[123]|conntrack|aether-proxy 版本/);
	const componentTable = findAll(blocks[2], 'table')[0];
	assert.equal(componentTable.attrs.style, 'font-size: 0.9em');
	assert.deepEqual(componentTable.children[1].children.map((c) => c.textContent),
		[ 'aether-proxy', '–', '/usr/bin/aether-proxy' ]);
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
	page.probing = true;
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
	assert.deepEqual(rows[1].children.map((c) => c.textContent), [ '代理', '1.0 KB/s', '2.0 KB/s' ]);
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
	assert.equal(build({ ok: true, state: 'starting', node_ip: 'stale' }).node_ip, null);
	for (const state of [ 'running', 'degraded', 'failsafe' ])
		assert.equal(build({ ok: true, state, node_ip: '203.0.113.10' }).node_ip, '203.0.113.10');
});

test('T10.4 scenario 4b: probe phrases without full stops, disabled notice and empty selection guard', () => {
	const model = dashboardModel();
	for (const [probe, text] of [ [ { ok: true, latency_ms: 12 }, '正常，12 ms' ],
		[ { ok: false }, '检测失败' ], [ null, '尚未检测' ] ]) {
		assert.equal(build({ ok: true, state: 'running', last_probe: probe }).probe_text, text);
		/* Monitor health retains its wording, independently of real latency. */
	}
	assert.equal(build({ ok: true }, null, null, NOW, false).disabled_notice,
		'服务未启用：打开『启用』开关后会自动启动');
	for (const empty of [ undefined, null, '' ])
		assert.equal(model.can_switch(empty, 'n_a'), false);
	assert.doesNotMatch(fs.readFileSync(MODEL, 'utf8'), /probe_completion/);
});

test('T10.4 scenario 4c: three installed-component rows, missing versions, missing binaries and failed calls', () => {
	const inventory = { ok: true, components: {
		xray: { found: true, path: '/usr/bin/xray', version: null },
		'chinadns-ng': { found: false, path: null, version: null }
	} };
	const rows = build({ ok: false }, null, null, NOW, true, null, inventory).components;
	assert.deepEqual(rows, [
		{ name: 'aether-proxy', version: '0.1.0-r2', path: '/usr/bin/aether-proxy' },
		{ name: 'xray', version: null, path: '/usr/bin/xray' },
		{ name: 'chinadns-ng', version: null, path: '未找到' }
	]);
	const cells = findAll(loadView().componentTable(rows), 'tr').map((row) => row.children.map((c) => c.textContent));
	assert.deepEqual(cells.slice(1), [
		[ 'aether-proxy', '0.1.0-r2', '/usr/bin/aether-proxy' ],
		[ 'xray', '–', '/usr/bin/xray' ], [ 'chinadns-ng', '–', '未找到' ]
	]);
	for (const failure of [ null, { ok: false, code: 'TIMEOUT' } ]) {
		const result = build({ ok: true, components: inventory.components },
			null, null, NOW, true, null, failure).components;
		assert.equal(result.length, 3);
		assert.deepEqual(result.slice(1), [
			{ name: 'xray', version: '读取失败', path: '' },
			{ name: 'chinadns-ng', version: '读取失败', path: '' }
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
	await page.initialRequest;
	assert.equal(calls.filter((m) => m === 'components').length, 1);
	assert.equal(page.vm.current_node, 'n_a', 'view passes UCI main.node to the model');
	await polls[0]();
	await page.fetchRefresh();
	assert.equal(calls.filter((m) => m === 'components').length, 1, 'poll/manual refresh must not rediscover versions');
	assert.deepEqual(page.vm.components.slice(1).map((c) => c.path), [ '/usr/bin/xray', '未找到' ]);
	const title = root.children[0];
	assert.match(title.attrs.style, /margin-bottom:\s*1em/);
	const label = findAll(title, 'label').find((el) => visibleText(el).includes('自动刷新'));
	assert.ok(findAll(label, 'span').some((n) => n.textContent === '自动刷新'
		&& /white-space:\s*nowrap/.test(n.attrs.style)));
	assert.equal(findAll(label, 'select').length, 1, 'label and select share the flex container');
	assert.match(label.attrs.style, /gap:\s*0\.5em/);
	for (const tag of [ 'div', 'label' ]) {
		for (const element of findAll(root, tag)) {
			if (/display:\s*flex/.test(element.attrs.style ?? ''))
				assert.match(element.attrs.style, /flex-direction:\s*column/.test(element.attrs.style)
					? /align-items:\s*stretch/ : /align-items:\s*(center|flex-end)/);
		}
	}
});

test('T10.4 scenario 6: every inline display:flex explicitly sets align-items; no status.components', () => {
	const source = fs.readFileSync(VIEW, 'utf8');
	const styles = [ ...source.matchAll(/['"]([^'"\n]*display:\s*flex[^'"\n]*)['"]/g) ];
	assert.ok(styles.length >= 8, 'all remaining flex declarations are examined');
	for (const [, style] of styles)
		/* docs/10 「样式」 requires an explicit value, usually center. */
		assert.match(style, /flex-direction:\s*column/.test(style)
			? /align-items:\s*stretch/ : /align-items:\s*(center|flex-end)/);
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
			const visible = ['running', 'degraded', 'failsafe'].includes(state) && !!node_ip;
			assert.equal(vm.node_address_text, visible ? '节点地址 203.0.113.10' : null);
		}
	}
	assert.equal(build({ ok: false, state: 'running', node_ip: 'stale' }).node_address_text, null);
});

test('T10.5 scenario 1c: component pending, successful and failed states determine both cells', () => {
	const model = dashboardModel();
	const pending = model.component_rows({ ok: true, version: '0.2.0-r6' }, undefined);
	assert.deepEqual(pending, [
		{ name: 'aether-proxy', version: '0.2.0-r6', path: '/usr/bin/aether-proxy' },
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
			{ name: 'xray', version: '读取失败', path: '' },
			{ name: 'chinadns-ng', version: '读取失败', path: '' }
		]);
});

function componentCells(root) {
	const section = sections(root).find((s) => s.children[0].textContent === '组件版本');
	return findAll(section, 'tr').slice(2).map((row) => row.children.map((cell) => cell.textContent));
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
	await page.initialRequest;
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

test('T10.5 scenario 2b / T10.13: failed post-render inventory shows failures instead of loading cells', async () => {
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
		assert.deepEqual(componentCells(root), [
			[ 'xray', '读取失败', '' ],
			[ 'chinadns-ng', '读取失败', '' ]
		]);
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
	assert.equal(select.children[1].textContent, 'Beta（当前）');
	assert.equal(button.disabled, true);
	select.value = 'n_a';
	select.attrs.change();
	assert.equal(button.disabled, true, 'T10.24 locks a runtime/configured mismatch without a failure reason');
	assert.equal(select.disabled, true);
	assert.match(visibleText(second), /节点地址 203\.0\.113\.10.*正常，12 ms.*检测真实延迟/);
	assert.ok(findAll(second, 'small')[0].textContent.includes('前'), 'probe age stays in the right group');
	assert.doesNotMatch(visibleText(second), /Alpha|Beta/);
	assert.ok(!findAll(nodeBlock, 'span').some((s) => /font-size:\s*1\.2em/.test(s.attrs.style ?? '')));
	assert.ok(!findAll(nodeBlock, 'span').some((s) => s.attrs.title));
	page.refresh({ ok: true, state: 'stopped', node_id: 'n_b', node_ip: 'stale' });
	let updated = nodeRow(root);
	assert.equal(findAll(updated, 'select')[0].value, 'n_a');
	assert.equal(findAll(updated, 'select')[0].children[0].textContent, 'Alpha（当前）');
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
	assert.equal(findAll(block, 'select').length, 1, 'the site selector remains');
	assert.deepEqual(findAll(block, 'button').map((b) => b.textContent), [ '检测真实延迟' ]);
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
		const block = sections(root).find((s) => s.children[0].textContent === '流量与连接');
		const table = block.children[1];
		const total = table.children[3];
		assert.deepEqual(total.children.slice(1).map((c) => c.textContent), [ '1.0 KB/s', '2.0 KB/s' ]);
		assert.equal(visibleText(total.children[0]), inactive ? '合计（WAN 口）' + TRAFFIC_NOTE : '合计（WAN 口）');
		assert.equal(total.children[0].attrs.title, 'WAN 接口 eth1 的全部流量，含路由器自身');
		for (const row of table.children.slice(1, 3))
			assert.deepEqual(row.children.slice(1).map((c) => c.textContent), [ '–', '–' ]);
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
	assert.deepEqual(left.children.map((c) => c.tag), [ 'div', 'div' ]);
	assert.equal(findAll(left, 'button')[0].textContent, '应用');
	assert.equal(left.children[1].children[0].children[0], '默认模式');
	/* The mode label, select and Apply now wrap together (T10.48). */
	assert.match(left.children[1].attrs.style, /flex-wrap:\s*nowrap/);
	assert.match(findAll(left, 'select')[0].attrs.style ?? '', /width:\s*auto/);
	assert.equal(right.children.length, 4);
	assert.equal(right.children[0].textContent, '节点地址 203.0.113.10');
	assert.equal(right.children[1].textContent, '正常，12 ms');
	assert.equal(right.children[1].attrs.style, 'color:var(--success-color-high, #2f855a)');
	assert.equal(right.children[2].tag, 'small');
	assert.match(right.children[2].textContent, /前$/);
	assert.deepEqual(right.children[3].children.map((c) => c.tag), [ 'select', 'button', 'span' ]);
	assert.equal(visibleText(right.children[3].children[2]), '', 'no separate result beside the button');
	assert.equal(right.children[3].children[1].textContent, '检测真实延迟');
	assert.equal(right.children[3].children[2].attrs['aria-live'], 'polite');
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
	assert.equal(right.children[0].textContent, '延迟：–');
	assert.equal(right.children[1].tag, 'small');
	assert.equal(right.children[1].textContent, '');
	assert.equal(findAll(right, 'button')[0].textContent, '检测真实延迟');
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
	assert.equal(findAll(right, 'button')[0].textContent, '刷新');
	assert.ok(!visibleText(root).includes(page.vm.enabled_note));
	assert.equal(findAll(root, 'input').length, 1, 'only one enable switch, in the title');
});

test('T10.9 scenario 3: disable cancel restores checkbox without writes; confirm saves 0; enable skips confirm',
	async () => {
	for (const [initial, answer] of [ [ true, false ], [ true, true ], [ false, false ] ]) {
		const order = [], asked = [], calls = [];
		const page = loadView({
			rpcCalls: calls,
			confirm: async (options) => {
				asked.push(options.text);
				assert.deepEqual(order, [], 'confirmation precedes any UCI change');
				return answer;
			},
			uci: {
				set: (...args) => order.push([ 'set', ...args ]),
				save: async () => { order.push([ 'save' ]); }
			},
			ui: { changes: { apply: (rollback) => order.push([ 'apply', rollback ]) } }
		});
		const root = page.render({ labels: {}, enabled: initial });
		/* A sentinel proves the handler uses the model field, not copied wording. */
		page.vm.disable_confirmation = 'model confirmation';
		const box = findAll(root, 'input')[0];
		box.checked = !initial;
		await box.attrs.change({ target: box });
		assert.deepEqual(asked, initial ? [ 'model confirmation' ] : []);
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
	let parts = pageParts(page);
	assert.deepEqual(parts.map((n) => n.attrs.class), [
		'alert-message error', 'alert-message warning', 'cbi-section', 'cbi-section', 'cbi-section'
	]);
	assert.ok(visibleText(parts[0]).includes('TIMEOUT'));
	assert.ok(visibleText(parts[1]).includes('服务未启用'));
	page.refresh({ ok: true, state: 'running', notices: [
		{ code: 'COMPONENT_MISSING', args: { component: 'xray' } },
		{ code: 'UPDATE_AVAILABLE', args: { package: 'xray-core', available: '27' } }
	] });
	parts = pageParts(page);
	assert.equal(parts[0].attrs.class, 'alert-message warning', 'disabled banner remains first');
	assert.equal(parts[1].tag, 'ul');
	assert.ok(visibleText(parts[1].children[0]).includes('xray'));
	assert.ok(visibleText(parts[1].children[1]).includes('27'));
	assert.ok(parts[1].children.every((n) => n.attrs.class === 'alert-message warning'));
	assert.equal(parts[2], sections(root)[0]);
	assert.doesNotMatch(visibleText(root), /待处理提示/);
	const clean = renderStatus({ ok: true, state: 'running' });
	assert.equal(pageParts(clean.page)[0], sections(clean.root)[0]);
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
		assert.equal(block.children.length, 2, 'heading and runtime column');
		const rows = runtimeRows(root).children;
		const [left, right] = rows[0].children;
		assert.equal(findAll(left, 'strong')[0].textContent, '运行中');
		assert.ok(visibleText(left).includes('已持续'));
		assert.ok(visibleText(left).includes('DNS 已回退到原配置'));
		assert.deepEqual(findAll(right, 'button').map(visibleText), [ '启动', '重启', '停止' ]);
		assert.equal(findAll(rows[0], 'input').length, 0);
		assert.match(rows[0].attrs.style, /justify-content:\s*space-between/);
		const hasDetails = !!(last_error || dns_tier);
		assert.equal(rows.length, hasDetails ? 3 : 2, 'state, optional details, node row');
		if (hasDetails) {
			const details = rows[1];
			assert.equal(visibleText(details).includes('原因：配置无效'), !!last_error);
			assert.equal(visibleText(details).includes('境外域名解析：经节点解析（正常）'), !!dns_tier);
			assert.equal(details.children.length, Number(!!last_error) + Number(!!dns_tier));
		}
		assert.equal(rows.at(-1), nodeRow(root));
		assert.equal(findAll(nodeRow(root), 'select')[0], findAll(page.nodeControl, 'select')[0]);
		assert.ok(!findAll(root, 'h3').some((n) => [ '状态', '当前节点', '待处理提示' ].includes(visibleText(n))));
	}
});

test('T10.11 scenario 1: active-state node mismatch matrix, inactive states and empty sides', () => {
	const model = dashboardModel();
	for (const state of [ 'starting', 'running', 'degraded', 'failsafe', 'stopped', 'error', 'unknown' ]) {
		for (const configured of [ 'n_a', 'n_b', '', null, undefined ]) {
			for (const runtime of [ 'n_a', '', null, undefined ]) {
				const status = { ok: true, state, node_id: runtime };
				const pending = ['starting', 'running', 'degraded', 'failsafe'].includes(state)
					&& configured === 'n_b' && runtime === 'n_a';
				assert.equal(model.switch_pending(status, configured), pending,
					`${state}: configured=${configured}, runtime=${runtime}`);
				const vm = build(status, null, {}, NOW, true, configured);
				assert.equal(vm.switch_notice, pending ? '正在切换到「n_b」…' : null);
			}
		}
	}
	for (const status of [ null, { ok: false, state: 'running', node_id: 'n_a' } ]) {
		assert.equal(model.switch_pending(status, 'n_b'), false);
		assert.equal(build(status, null, {}, NOW, true, 'n_b').switch_notice, null);
	}
});

/* Deliberately not timestamp-sorted: neither RPC order nor unrelated newer
   errors may determine the explanation of an incomplete switch. */
function switchEvents() {
	return [
		{ ts: NOW - 30, code: 'NODE_RESOLVE_FAILED', args: { node: 'n_b', domain: 'new.example' } },
		{ ts: NOW - 20, code: 'START_FAILED', args: { step: 'precheck', detail: 'ignore startup' } },
		{ ts: NOW - 5, code: 'CMD_FAILED', args: { cmd: 'unrelated' } },
		{ ts: NOW - 90, code: 'CONFIG_INVALID', args: { field: 'main.node', reason: 'old failure' } }
	];
}

function switchModel(events, labels = { n_a: 'Alpha', n_b: 'Beta' }) {
	return build({ ok: true, state: 'running', node_id: 'n_a' }, null, labels, NOW, true, 'n_b', null, events);
}

function failedSwitchText(configured, current, reason, age) {
	return `切换到「${configured}」未生效，服务仍在使用「${current}」。原因：${reason}（${age}）。`
		+ '可以点「重启」用配置的节点重新启动（会短暂中断代理），或到日志页查看详情。';
}

function logText(event, labels = { n_a: 'Alpha', n_b: 'Beta' }) {
	return logsModel().events({ ok: true, events: [ event ] }, null, '', '',
		{ nodes: labels, subscriptions: {} }).rows[0].text;
}

const SWITCH_REASON_CASES = [
	[ 'NODE_RESOLVE_FAILED', { node: 'n_b', domain: 'new.example', lkg_ip: null } ],
	[ 'CONFIG_INVALID', { field: 'main.node', reason: 'missing' } ],
	[ 'PRECHECK_FAILED', { missing: [ 'xray', 'chinadns-ng' ] } ],
	[ 'RENDER_INVALID', { artifact: 'xray.json', detail: 'invalid' } ],
	[ 'START_FAILED', { step: 'reload:xray', detail: 'failed' } ]
];

for (const [code, args] of SWITCH_REASON_CASES) {
	test(`T10.11 scenario 2a/3: latest ${code} shares the log description, labels and relative age`, () => {
		const event = { ts: NOW - 120, code, args };
		const reply = { ok: true, events: [
			{ ts: NOW - 5, code: 'CMD_FAILED', args: {} },
			event,
			{ ts: NOW - 180, code: 'NODE_RESOLVE_FAILED', args: { domain: 'older.example' } }
		] };
		assert.equal(switchModel(reply).switch_notice,
			failedSwitchText('Beta', 'Alpha', logText(event), '2 分钟前'));
		assert.equal(switchModel(reply, { n_b: '' }).switch_notice,
			failedSwitchText('n_b', 'n_a', logText(event, { n_b: '' }), '2 分钟前'));
	});
}

test('T10.11 scenario 2b: unsorted events choose newest allowed failure, not startup or unrelated errors', () => {
	const events = switchEvents();
	for (const ordered of [ events, [...events].reverse() ]) {
		assert.equal(switchModel({ ok: true, events: ordered }).switch_notice,
			failedSwitchText('Beta', 'Alpha', logText(events[0]), '30 秒前'));
	}
	for (const step of [ 'precheck', 'reload', 'prefix:reload:xray', '', null, 123, undefined ]) {
		assert.equal(switchModel({ ok: true, events: [
			{ ts: NOW - 1, code: 'START_FAILED', args: { step } }
		] }).switch_notice, '正在切换到「Beta」…');
	}
	assert.equal(switchModel({ ok: true, events: [
		{ ts: NOW - 1, code: 'START_FAILED' }
	] }).switch_notice, '正在切换到「Beta」…');
});

test('T10.11 scenario 2c/3: no matching event or failed events read gives pending text and label fallback', () => {
	for (const reply of [ undefined, null, { ok: false, code: 'RPC_FAILED', events: switchEvents() },
		{ ok: true, events: [] }, { ok: true, events: [ { ts: NOW, code: 'UNRELATED' } ] } ]) {
		assert.equal(switchModel(reply).switch_notice, '正在切换到「Beta」…');
		assert.equal(switchModel(reply, {}).switch_notice, '正在切换到「n_b」…');
	}
});

/* Real load/render/refresh entry points, with a mutable runtime node and clock.
   The selected UCI node stays n_b throughout, just as after save & apply. */
function switchPage(reply) {
	const calls = [], polls = [], notifications = [];
	const runtime = { node: 'n_b' };
	const page = loadView({
		ap: {
			call: async (method, params) => {
				calls.push([ method, params ]);
				if (method === 'status')
					return { ok: true, state: 'running', node_id: runtime.node, node_ip: '203.0.113.10' };
				if (method === 'stats')
					return readings(calls.length * 1000, 10, 20, 30, 40);
				if (method === 'version')
					return { ok: true, version: '0.2.0-r7' };
				if (method === 'events')
					return reply;
				if (method === 'probe_sites')
					return SITES;
				return { ok: true, components: {} };
			},
			poll: (fn) => { polls.push(fn); return { stop() {} }; }
		},
		uci: {
			sections: (cfg, type, cb) => {
				if (type === 'node') {
					cb({ '.name': 'n_a', label: 'Alpha' });
					cb({ '.name': 'n_b', label: 'Beta' });
				}
			},
			get: (cfg, sec, opt) => opt === 'node' ? 'n_b' : '1'
		},
		ui: { addNotification: (...args) => notifications.push(args) }
	});
	return { page, calls, polls, notifications, runtime };
}

test('T10.11 scenario 4a: equal nodes skip events; every mismatched refresh fetches errors; recovery clears banner',
	async (t) => {
	let now = NOW;
	t.mock.method(Date, 'now', () => now * 1000);
	const { page, calls, polls, runtime } = switchPage({ ok: true, events: switchEvents() });
	const root = page.render(await page.load());
	await page.componentRequest;
	await page.initialRequest;
	assert.equal(calls.filter(([method]) => method === 'events').length, 0, 'initial equal nodes skip events');
	await page.fetchRefresh();
	assert.equal(calls.filter(([method]) => method === 'events').length, 0, 'equal refresh skips events');
	runtime.node = 'n_a';
	const manual = findAll(root, 'button').find((b) => b.textContent === '刷新');
	for (const refresh of [ () => manual.attrs.click(), polls[0] ]) {
		now += 10;
		calls.length = 0;
		await refresh();
		assert.deepEqual(calls, [ [ 'status', undefined ], [ 'stats', undefined ],
			[ 'events', { since: now - 600, level: 'error' } ] ]);
		const parts = pageParts(page);
		assert.equal(parts[0].attrs.class, 'alert-message warning');
		assert.equal(parts[1], sections(root)[0], 'banner is before runtime section');
		assert.equal(visibleText(parts[0]),
			failedSwitchText('Beta', 'Alpha', logText(switchEvents()[0]), `${now - NOW + 30} 秒前`));
		assert.equal(findAll(nodeRow(root), 'select')[0].value, 'n_a', 'runtime remains preselected');
		assert.equal(findAll(nodeRow(root), 'option')[0].textContent, 'Alpha（当前）');
	}
	runtime.node = 'n_b';
	calls.length = 0;
	await page.fetchRefresh();
	assert.deepEqual(calls.map(([method]) => method), [ 'status', 'stats' ]);
	assert.equal(page.vm.switch_notice, null);
	assert.equal(pageParts(page)[0], sections(root)[0]);
	assert.equal(findAll(nodeRow(root), 'select')[0].value, 'n_b');
});

test('T10.11 scenario 4b: initial mismatch fetches one events response after rendering the skeleton', async (t) => {
	t.mock.method(Date, 'now', () => NOW * 1000);
	const { page, calls, runtime } = switchPage({ ok: true, events: switchEvents() });
	runtime.node = 'n_a';
	const root = page.render(await page.load());
	await page.componentRequest;
	await page.initialRequest;
	assert.deepEqual(calls.filter(([method]) => method === 'events'),
		[ [ 'events', { since: NOW - 600, level: 'error' } ] ]);
	assert.equal(pageParts(page)[0].attrs.class, 'alert-message warning');
	assert.ok(visibleText(root).includes('切换到「Beta」未生效'));
});

test('T10.11 scenario 5: failed events reads show pending warning without errors or losing other regions',
	async (t) => {
	t.mock.method(Date, 'now', () => NOW * 1000);
	for (const reply of [ null, { ok: false, code: 'RPC_FAILED', detail: 'offline' },
		{ ok: false, code: 'TIMEOUT' } ]) {
		const { page, calls, notifications, runtime } = switchPage(reply);
		runtime.node = 'n_a';
		const root = page.render(await page.load());
		await page.componentRequest;
		await page.initialRequest;
		for (let refresh = 0; refresh < 2; refresh++) {
			const banner = pageParts(page)[0];
			assert.equal(banner.attrs.class, 'alert-message warning');
			assert.equal(visibleText(banner), '正在切换到「Beta」…');
			assert.deepEqual(notifications, []);
			assert.doesNotMatch(visibleText(root), /RPC_FAILED|TIMEOUT|offline/);
			assert.deepEqual(sections(root).map((s) => visibleText(s.children[0])),
				[ '运行状态', '流量与连接', '组件版本' ]);
			assert.equal(findAll(root, 'strong')[0].textContent, '运行中');
			assert.ok(visibleText(nodeRow(root)).includes('节点地址 203.0.113.10'));
			assert.equal(componentCells(root).length, 2);
			await page.fetchRefresh();
		}
		assert.equal(calls.filter(([method]) => method === 'events').length, 3);
	}
});

/* T10.24 merges display only; no status request or backend health mutation. */
const LATENCY_RESULTS = [
	[{ ok: true, code: 204, latency_ms: 208 }, '正常，208 ms（GitHub，手动）'],
	[{ ok: false, code: 'PROBE_TIMEOUT' }, '检测超时（GitHub，手动）'],
	[{ ok: false, code: 'PROBE_FAILED' }, '检测失败（GitHub，手动）'],
	[{ ok: false, code: 'PROBE_FAILED', http_code: 500 }, '返回 HTTP 500（GitHub，手动）'],
	[{ ok: false, code: 'NOT_RUNNING' }, null],
	[{ ok: false, code: 'RPC_FAILED', detail: 'disconnected' }, null],
	[{ ok: false, code: 'TIMEOUT', detail: '35s' }, null]
];

for (const [reply, text] of LATENCY_RESULTS) {
	test(`T10.23 scenario 2/6 / T10.24: ${text ?? reply.code} updates only health display or notification`,
		async (t) => {
		let now = NOW + 999999;
		t.mock.method(Date, 'now', () => now * 1000);
		const h = deferredPage('0');
		const { page, calls, notifications } = h;
		const root = page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', { ok: true, state: 'running',
			last_probe: { at: NOW, ok: true, latency_ms: 42 } });
		await h.reply('stats', readings(1000, 1, 2, 3, 4));
		await h.reply('probe_sites', SITES);
		await page.initialRequest;
		calls.length = 0;
		page.probeSites.value = 'github';
		const health = page.vm.probe_text;
		const pending = page.probeButton.attrs.click();
		assert.equal(page.probeButton.disabled, true);
		assert.equal(visibleText(page.probeButton), '检测中…');
		assert.equal(page.probeButton.attrs.click(), undefined, 'busy clicks do not send a second request');
		assert.deepEqual(calls.map(({ method, params }) => [method, params]), [['probe_url', { site: 'github' }]]);
		page.probeSites.value = 'google';
		await h.reply('probe_url', reply);
		await pending;
		assert.equal(visibleText(page.probeMessage), '', 'no result beside the button');
		assert.equal(visibleText(page.probeButton), '检测真实延迟');
		assert.equal(page.probeButton.disabled, false);
		assert.equal(page.vm.probe_text, text ?? health);
		assert.equal(page.vm.probe_level, text ? (reply.ok ? 'ok' : 'error') : 'ok');
		const displayed = findAll(nodeRow(root), 'span').filter(el => visibleText(el) === (text ?? health));
		assert.equal(displayed.length, 1, 'exactly one health result');
		assert.equal(displayed[0].attrs.style, page.colorStyle(page.vm.probe_level));
		assert.deepEqual(notifications, text ? [] : [
			{ text: `检测真实延迟失败（${reply.code}）`, kind: 'error' }
		]);
		assert.equal(page.status.last_probe.latency_ms, 42, 'backend health snapshot is untouched');
		assert.deepEqual(calls.map(call => call.method), ['probe_url'], 'completion does not read status/stats');
		assert.equal(page.poller, null);
		now += 12;
		page.refresh({ ok: true, state: 'running', last_probe: { at: NOW, ok: true, latency_ms: 42 } });
		assert.equal(page.vm.probe_text, text ?? health, 'same monitor generation retains manual result');
		if (text)
			assert.equal(page.vm.probe_since_text, '12 秒前', 'manual age uses browser arrival time');
		page.refresh({ ok: true, state: 'running', last_probe: { at: NOW + 1, ok: false } });
		assert.equal(page.vm.probe_text, '检测失败', 'changed monitor generation replaces manual result');
		assert.equal(page.vm.probe_level, 'error');
	});
}

const INVENTORY_FAILURES = [
	[ { ok: false, code: 'RPC_FAILED', detail: 'disconnected' }, 'RPC_FAILED: disconnected' ],
	[ { ok: false, code: 'TIMEOUT' }, 'TIMEOUT' ],
	[ { ok: false }, 'RPC_FAILED' ],
	[ null, 'RPC_FAILED' ]
];

test('T10.13 scenario 3: inventory failures carry code/detail below table; unknown version stays a dash', () => {
	const model = dashboardModel();
	for (const [failure, text] of INVENTORY_FAILURES) {
		const rows = model.component_rows({ ok: true, version: '0.2.0-r8' }, failure);
		assert.equal(model.components_failed(failure), true);
		assert.deepEqual(rows.slice(1), [
			{ name: 'xray', version: '读取失败', path: '' },
			{ name: 'chinadns-ng', version: '读取失败', path: '' }
		]);
		const error = model.component_error(failure);
		assert.equal(error.text, `读取组件信息失败（${failure?.code ?? 'RPC_FAILED'}）`);
		assert.equal(error.detail, failure?.detail ?? null);
		assert.equal(text, (failure?.code ?? 'RPC_FAILED') + (error.detail ? ': ' + error.detail : ''));
		assert.deepEqual(rows[0], { name: 'aether-proxy', version: '0.2.0-r8', path: '/usr/bin/aether-proxy' });
	}
	assert.equal(model.components_failed(undefined), false, 'pending is not a failure');
	const inventory = { ok: true, components: { xray: { found: true, version: null, path: '/usr/bin/xray' } } };
	assert.equal(model.components_failed(inventory), false);
	const cells = findAll(loadView().componentTable(model.component_rows(null, inventory)), 'tr');
	assert.deepEqual(cells[2].children.map((c) => c.textContent), [ 'xray', '–', '/usr/bin/xray' ]);
});

function retryButtons(root) {
	/* Site-list retries are independent of component retries (T10.24). */
	const components = sections(root).find(section => visibleText(section.children[0]) === '组件版本');
	return findAll(components, 'button').filter((button) => visibleText(button) === '重试');
}

test('T10.13 scenario 4: retry resets both rows, reissues once, then succeeds without touching other controls',
	async () => {
	for (const [failure] of INVENTORY_FAILURES) {
		const attempts = failure?.code === 'TIMEOUT' ? 2 : 1;
		let requests = 0, resolveInventory;
		const page = loadView({ ap: {
			call: async (method) => {
				if (method !== 'components')
					return { ok: true, state: 'running' };
				requests++;
				return requests <= attempts ? failure : new Promise((resolve) => { resolveInventory = resolve; });
			},
			poll: () => ({ stop() {} })
		} });
		const root = page.render(await page.load());
		assert.equal(retryButtons(root).length, 0, 'no retry while initially reading');
		await page.componentRequest;
		assert.deepEqual(componentCells(root), [ [ 'xray', '读取失败', '' ], [ 'chinadns-ng', '读取失败', '' ] ]);
		const [retry] = retryButtons(root);
		assert.ok(retry);
		assert.equal(retry.attrs.class, 'cbi-button cbi-button-action');
		/* Wait for the status/UCI refresh before isolating the retry's DOM writes. */
		await page.initialRequest;
		const runtime = sections(root)[0], traffic = sections(root)[1], button = page.probeButton;
		const pending = retry.attrs.click();
		assert.deepEqual(componentCells(root), [
			[ 'xray', '读取中…', '读取中…' ], [ 'chinadns-ng', '读取中…', '读取中…' ]
		]);
		assert.equal(retryButtons(root).length, 0, 'old retry removed while reading');
		assert.equal(retry.attrs.click(), pending, 'repeated stale clicks share the in-flight request');
		await Promise.resolve();
		assert.equal(requests, attempts + 1);
		resolveInventory({ ok: true, components: {
			xray: { found: true, version: '26.9.30', path: '/usr/bin/xray' },
			'chinadns-ng': { found: true, version: '2025.08.09', path: '/usr/bin/chinadns-ng' }
		} });
		await pending;
		assert.deepEqual(componentCells(root), [
			[ 'xray', '26.9.30', '/usr/bin/xray' ], [ 'chinadns-ng', '2025.08.09', '/usr/bin/chinadns-ng' ]
		]);
		assert.equal(retryButtons(root).length, 0);
		assert.equal(sections(root)[0], runtime);
		assert.equal(sections(root)[1], traffic);
		assert.equal(page.probeButton, button);
		await page.fetchRefresh();
		assert.equal(requests, attempts + 1, 'normal refresh does not rediscover inventory');
		assert.equal(retryButtons(root).length, 0);
	}
});

test('T10.13 scenario 4: successful initial inventory has no retry; a failed retry remains retryable', async () => {
	for (const success of [ true, false ]) {
		let requests = 0;
		const page = loadView({ ap: {
			call: async (method) => {
				if (method === 'components') {
					requests++;
					return success ? { ok: true, components: {} } : { ok: false, code: 'TIMEOUT' };
				}
				return { ok: true, state: 'running' };
			},
			poll: () => ({ stop() {} })
		} });
		const root = page.render(await page.load());
		await page.componentRequest;
		assert.equal(retryButtons(root).length, success ? 0 : 1);
		if (!success) {
			await retryButtons(root)[0].attrs.click();
			assert.equal(requests, 4, 'each generation has two timeout attempts');
			assert.equal(retryButtons(root).length, 1);
			assert.deepEqual(componentCells(root), [
				[ 'xray', '读取失败', '' ], [ 'chinadns-ng', '读取失败', '' ]
			]);
		}
	}
});

/* Explicitly released RPC promises prove the skeleton and each independent
   region work even when every other backend response remains outstanding. */
function deferredPage(interval = '5', configured_node = 'n_a') {
	const calls = [], polls = [], writes = [], uciOps = [], notifications = [];
	const page = loadView({
		ap: {
			call: (method, params) => new Promise((resolve) => { calls.push({ method, params, resolve }); }),
			poll: (fn, ms) => {
				const poll = { fn, ms, stopped: false, stop() { this.stopped = true; } };
				polls.push(poll);
				return poll;
			}
		},
		onContent: (el) => writes.push(el),
		uci: {
			load: async (config) => { uciOps.push([ 'load', config ]); },
			sections: (config, type, cb) => {
				if (type === 'node') {
					cb({ '.name': 'n_a', label: 'Alpha' });
					cb({ '.name': 'n_b', label: 'Beta' });
				}
			},
			get: (config, section, option) => option === 'node' ? configured_node : '1',
			set: (...args) => uciOps.push([ 'set', ...args ]),
			save: async () => { uciOps.push([ 'save' ]); }
		},
		ui: {
			changes: { apply: (rollback) => uciOps.push([ 'apply', rollback ]) },
			addNotification: (title, body, kind) => notifications.push({ text: visibleText(body), kind })
		},
		window: { localStorage: { getItem: () => interval, setItem: () => {} } }
	});
	return {
		page, calls, polls, writes, uciOps, notifications,
		reply: async (method, reply) => {
			const call = calls.find((call) => call.method === method && !call.settled);
			assert.ok(call, `outstanding ${method} request exists`);
			call.settled = true;
			call.resolve(reply);
			/* Drain the promise-only request chains without using wall-clock timers. */
			for (let i = 0; i < 12; i++)
				await Promise.resolve();
		}
	};
}

function disabled(button) {
	return button.disabled;
}

function serviceButtons(root) {
	return findAll(runtimeRows(root).children[0], 'button');
}

function ownVersion(root) {
	return findAll(sections(root)[2], 'tr')[1].children[1].textContent;
}

test('T10.17 scenario 1: load reads only UCI and never starts RPC or polling', async () => {
	const { page, calls, polls, uciOps } = deferredPage();
	const data = await page.load();
	assert.deepEqual(uciOps, [ [ 'load', 'aetherproxy' ] ]);
	assert.deepEqual(calls, []);
	assert.deepEqual(polls, []);
	assert.deepEqual(data, { labels: { n_a: 'Alpha', n_b: 'Beta' }, node: 'n_a', mode: '1', enabled: true });
});

test('T10.17 scenario 2: all RPCs pending still renders complete placeholders and safe UCI controls', async () => {
	const { page, calls, polls, uciOps } = deferredPage();
	const root = page.render(await page.load());
	assert.deepEqual(calls, [], 'all requests are deferred beyond synchronous render');
	assert.deepEqual(sections(root).map((section) => visibleText(section.children[0])),
		[ '运行状态', '流量与连接', '组件版本' ]);
	assert.equal(findAll(root, 'strong')[0].textContent, '读取中…');
	assert.doesNotMatch(visibleText(sections(root)[0]), /原因：|境外域名解析：|已持续|节点地址|DNS 已回退/);
	assert.equal(page.vm.error, null, 'pending status is not a failed status');
	assert.equal(page.vm.traffic_note, null, 'pending does not falsely claim the service is stopped');
	const rows = findAll(sections(root)[1], 'tr').slice(1);
	for (const row of rows)
		assert.deepEqual(row.children.slice(1).map((cell) => cell.textContent), [ '–', '–' ]);
	assert.deepEqual(findAll(sections(root)[1], 'span').map(visibleText), [ '代理连接 –', '总连接 –' ]);
	assert.equal(ownVersion(root), '读取中…');
	assert.deepEqual(componentCells(root), [
		[ 'xray', '读取中…', '读取中…' ], [ 'chinadns-ng', '读取中…', '读取中…' ]
	]);
	assert.ok(serviceButtons(root).every(disabled));
	assert.equal(page.probeButton.disabled, true);
	const enable = findAll(root, 'input')[0];
	assert.equal(disabled(enable), false);
	assert.equal(typeof enable.attrs.change, 'function');
	const nodes = findAll(nodeRow(root), 'select')[0];
	assert.equal(nodes.value, 'n_a');
	assert.equal(nodes.children[0].textContent, 'Alpha（当前）');
	assert.equal(disabled(nodes), false);
	await Promise.resolve();
	assert.deepEqual(calls.map((call) => call.method), [ 'probe_sites', 'status', 'version', 'components' ]);
	assert.deepEqual(polls, [], 'no poll starts while the first status is pending');
	/* UCI-only enable remains a real action even with all three RPCs stuck. */
	page.enabled = false;
	await enable.attrs.change({ target: { checked: true } });
	assert.deepEqual(uciOps.slice(1), [
		[ 'set', 'aetherproxy', 'main', 'enabled', '1' ], [ 'save' ], [ 'apply', true ]
	]);
	assert.equal(findAll(root, 'strong')[0].textContent, '读取中…');
	assert.deepEqual(polls, []);
});

test('T10.17 scenario 3a: independent version, status and stats replies update only their own regions', async () => {
	const h = deferredPage('10');
	const { page, calls, polls, writes } = h;
	const root = page.render(await page.load());
	await Promise.resolve();
	const enable = findAll(root, 'input')[0];
	const nodes = findAll(nodeRow(root), 'select')[0];
	nodes.value = 'n_b';
	nodes.attrs.change();
	const runtime = sections(root)[0], traffic = sections(root)[1];
	writes.length = 0;
	await h.reply('version', { ok: true, version: '0.2.0-r10' });
	assert.equal(ownVersion(root), '0.2.0-r10');
	assert.deepEqual(writes, [ page.componentContent ]);
	assert.equal(sections(root)[0], runtime);
	assert.equal(sections(root)[1], traffic);
	assert.equal(findAll(root, 'strong')[0].textContent, '读取中…');
	assert.deepEqual(polls, []);
	await h.reply('probe_sites', SITES);
	await h.reply('status', { ok: true, state: 'running', node_id: 'n_a', dns_tier: 'T1',
		last_error: 'CONFIG_INVALID', last_probe: { ok: true, latency_ms: 42, at: NOW } });
	assert.equal(findAll(root, 'strong')[0].textContent, '运行中');
	assert.match(visibleText(sections(root)[0]), /原因：配置无效.*境外域名解析：经节点解析（正常）/);
	assert.deepEqual(serviceButtons(root).map(disabled), [ true, false, false ]);
	assert.equal(page.probeButton.disabled, false);
	assert.equal(polls.length, 1, 'first status starts polling without waiting for slower stats');
	assert.equal(polls[0].ms, 10000);
	assert.deepEqual(calls.map((call) => call.method), [ 'probe_sites', 'status', 'version', 'components', 'stats' ]);
	assert.equal(findAll(nodeRow(root), 'select')[0], nodes);
	assert.equal(nodes.value, 'n_b', 'first status preserves edits when the effective node is unchanged');
	assert.equal(findAll(root, 'input')[0], enable);
	const settledRuntime = sections(root)[0];
	writes.length = 0;
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await page.initialRequest;
	assert.equal(sections(root)[0], settledRuntime);
	assert.equal(findAll(nodeRow(root), 'select')[0], nodes);
	assert.ok(writes.includes(page.trafficContainer));
	assert.ok(!writes.includes(page.runtimeContent));
	assert.ok(!writes.includes(page.componentContent));
	assert.equal(visibleText(findAll(sections(root)[1], 'span')[0]), '代理连接 3');
	const next = polls[0].fn();
	await h.reply('status', { ok: true, state: 'stopped', node_id: 'n_a' });
	assert.deepEqual(serviceButtons(root).map(disabled), [ false, true, true ]);
	await h.reply('stats', readings(2000, 1024, 2048, 4096, 8192));
	await next;
	assert.deepEqual(findAll(sections(root)[1], 'tr')[1].children.slice(1).map((cell) => cell.textContent),
		[ '1.0 KB/s', '2.0 KB/s' ]);
	assert.equal(calls.filter((call) => call.method === 'version').length, 1);
	assert.equal(calls.filter((call) => call.method === 'components').length, 1);
});

test('T10.17 scenario 3b: deferred mismatch events follow T10.11 and update only the warning region', async (t) => {
	t.mock.method(Date, 'now', () => NOW * 1000);
	const h = deferredPage();
	const { page, calls, writes } = h;
	const root = page.render(await page.load());
	await Promise.resolve();
	assert.ok(!calls.some((call) => call.method === 'events'));
	await h.reply('status', { ok: true, state: 'running', node_id: 'n_b' });
	assert.equal(page.vm.switch_notice, '正在切换到「Alpha」…');
	assert.equal(findAll(nodeRow(root), 'select')[0].value, 'n_b');
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	const eventCall = calls.find((call) => call.method === 'events');
	assert.deepEqual(eventCall.params, { since: NOW - 600, level: 'error' });
	const blocks = sections(root);
	writes.length = 0;
	const event = { ts: NOW - 30, code: 'NODE_RESOLVE_FAILED', args: { domain: 'node.example' } };
	await h.reply('events', { ok: true, events: [ event ] });
	await page.initialRequest;
	assert.deepEqual(writes, [ page.noticeContent ]);
	assert.equal(visibleText(page.noticeContent),
		failedSwitchText('Alpha', 'Beta', logText(event), '30 秒前'));
	sections(root).forEach((section, i) => assert.equal(section, blocks[i]));
});

test('T10.17 scenario 4: status failure clears loading, keeps controls disabled and polling retries successfully',
	async () => {
	for (const failure of [ { ok: false, code: 'TIMEOUT', detail: 'offline' },
		{ ok: false, code: 'RPC_FAILED', detail: 'offline' }, null ]) {
		const h = deferredPage('2');
		const { page, polls } = h;
		const root = page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', failure);
		assert.equal(findAll(root, 'strong')[0].textContent, '–');
		assert.equal(page.noticeContent.children[0].children[0],
			`读取状态失败（${failure?.code ?? 'RPC_FAILED'}），稍后自动重试`);
		assert.ok(serviceButtons(root).every(disabled));
		assert.equal(page.probeButton.disabled, true);
		assert.equal(disabled(findAll(root, 'input')[0]), false);
		assert.equal(polls.length, 1);
		assert.equal(polls[0].ms, 2000);
		await h.reply('version', failure);
		assert.equal(ownVersion(root), '–', 'failed version is no longer pending');
		await h.reply('components', failure);
		if (failure?.code === 'TIMEOUT')
			await h.reply('components', failure);
		await h.reply('probe_sites', SITES);
		await h.reply('stats', failure);
		await page.initialRequest;
		assert.doesNotMatch(visibleText(root), /读取中…/);
		const retry = polls[0].fn();
		await h.reply('status', { ok: true, state: 'running', node_id: 'n_a' });
		assert.equal(findAll(root, 'strong')[0].textContent, '运行中');
		assert.doesNotMatch(visibleText(page.noticeContent), /读取状态失败/);
		assert.deepEqual(serviceButtons(root).map(disabled), [ true, false, false ]);
		assert.equal(page.probeButton.disabled, false);
		await h.reply('stats', readings(1000, 0, 0, 0, 0));
		await retry;
		assert.equal(polls.length, 1, 'recovery reuses the existing polling cadence');
	}
});

test('T10.17 scenario 4b: refreshing during a probe never enables it early or after a failed status', async () => {
	const h = deferredPage('0');
	const { page } = h;
	page.render(await page.load());
	await Promise.resolve();
	await h.reply('status', { ok: true, state: 'running' });
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await h.reply('probe_sites', SITES);
	await page.initialRequest;
	const probe = page.probeButton.attrs.click();
	assert.equal(page.probeButton.disabled, true);
	const refresh = page.fetchRefresh();
	await h.reply('status', { ok: true, state: 'running' });
	assert.equal(page.probeButton.disabled, true, 'successful refresh cannot enable a busy probe');
	await h.reply('stats', readings(2000, 0, 0, 0, 0));
	await refresh;
	const failed = page.fetchRefresh();
	await h.reply('status', { ok: false, code: 'RPC_FAILED' });
	await h.reply('stats', { ok: false, code: 'RPC_FAILED' });
	await failed;
	await h.reply('probe_url', { ok: false, code: 'NOT_RUNNING' });
	await probe;
	assert.equal(visibleText(page.probeMessage), '', 'NOT_RUNNING is a notification, not a result');
	assert.deepEqual(h.notifications, [{ text: '检测真实延迟失败（NOT_RUNNING）', kind: 'error' }]);
	assert.equal(page.probeButton.disabled, true, 'probe finalizer respects the latest failed status');
});

test('T10.17 scenario 3c: pending interval changes wait for status; Off keeps manual refresh usable', async () => {
	for (const value of [ '0', '2', '30' ]) {
		const h = deferredPage();
		const { page, polls } = h;
		const root = page.render(await page.load());
		findAll(root, 'select')[0].attrs.change({ target: { value } });
		assert.deepEqual(polls, []);
		await Promise.resolve();
		await h.reply('status', { ok: true, state: 'stopped' });
		assert.equal(polls.length, value === '0' ? 0 : 1);
		if (value !== '0')
			assert.equal(polls[0].ms, Number(value) * 1000);
		await h.reply('stats', readings(1000, 0, 0, 0, 0));
		await page.initialRequest;
		const manual = findAll(root, 'button').find((button) => visibleText(button) === '刷新');
		const refresh = manual.attrs.click();
		await h.reply('status', { ok: true, state: 'running' });
		await h.reply('stats', readings(2000, 1024, 1024, 2048, 2048));
		await refresh;
		assert.equal(findAll(root, 'strong')[0].textContent, '运行中');
	}
});

const COMPONENT_ERRORS = [
	{ ok: false, code: 'USAGE', detail: 'components takes no arguments' },
	{ ok: false, code: 'TIMEOUT' },
	null
];

for (const failure of COMPONENT_ERRORS) {
	const code = failure?.code ?? 'RPC_FAILED';
	test(`T10.20 scenario 1: ${code} component failure has empty paths, one tooltip reason and recoverable retry`,
		async () => {
		const h = deferredPage();
		const { page } = h;
		const root = page.render(await page.load());
		await Promise.resolve();
		await h.reply('components', failure);
		if (failure?.code === 'TIMEOUT')
			await h.reply('components', failure);
		assert.deepEqual(componentCells(root), [
			[ 'xray', '读取失败', '' ], [ 'chinadns-ng', '读取失败', '' ]
		]);
		assert.equal(page.componentContent.children.length, 2, 'one explanation row follows the table');
		const [table, reason] = page.componentContent.children;
		assert.equal(table.tag, 'table');
		assert.equal(reason.tag, 'div');
		assert.deepEqual(reason.children.map((child) => child.tag), [ 'span', 'button' ]);
		assert.equal(reason.children[0].textContent, `读取组件信息失败（${code}）`);
		assert.equal(reason.attrs.title, failure?.detail ?? null);
		assert.ok(!visibleText(table).includes(code), 'diagnostics never occupy a table cell');
		if (failure?.detail)
			assert.ok(!visibleText(page.componentContent).includes(failure.detail), 'detail is tooltip-only');
		const [retry] = retryButtons(root);
		assert.equal(retry.attrs.class, 'cbi-button cbi-button-action');
		const request = retry.attrs.click();
		assert.equal(page.componentContent.children.length, 1, 'reason and retry disappear while reading');
		assert.deepEqual(componentCells(root), [
			[ 'xray', '读取中…', '读取中…' ], [ 'chinadns-ng', '读取中…', '读取中…' ]
		]);
		await Promise.resolve();
		await h.reply('components', { ok: true, components: {
			xray: { found: true, version: '26.9.30', path: '/usr/bin/xray' },
			'chinadns-ng': { found: true, version: '2025.08.09', path: '/usr/bin/chinadns-ng' }
		} });
		await request;
		assert.equal(page.componentContent.children.length, 1, 'successful retry removes the entire reason row');
		assert.equal(retryButtons(root).length, 0);
		assert.deepEqual(componentCells(root), [
			[ 'xray', '26.9.30', '/usr/bin/xray' ], [ 'chinadns-ng', '2025.08.09', '/usr/bin/chinadns-ng' ]
		]);
	});
}

test('T10.27 scenario 1: component Retry has a spaced right-aligned row with failure text first', async () => {
	const h = deferredPage('0');
	const root = h.page.render(await h.page.load());
	await Promise.resolve();
	await h.reply('components', { ok: false, code: 'TIMEOUT', detail: 'offline' });
	await h.reply('components', { ok: false, code: 'TIMEOUT', detail: 'offline' });
	const content = h.page.componentContent;
	const reason = content.children[1].children[0];
	const row = actionRow(root, ['重试'], [reason]);
	assert.equal(reason.textContent, '读取组件信息失败（TIMEOUT）');
	assert.equal(row.attrs.title, 'offline');
	assert.equal(content.children.at(-1), row);
	assert.equal(content.children.at(-2).tag, 'table');
});

test('T10.20 scenario 2: own executable path is fixed while reading, after failure and after success', () => {
	const { page } = renderStatus({ ok: true, state: 'running' });
	for (const [version, inventory, text] of [
		[ undefined, undefined, '读取中…' ],
		[ { ok: false, code: 'TIMEOUT' }, null, '–' ],
		[ { ok: true, version: '0.2.0-r10' }, { ok: true, components: {} }, '0.2.0-r10' ]
	]) {
		page.version = version;
		page.components = inventory;
		page.updateComponents();
		const row = findAll(page.componentContent, 'tr')[1];
		assert.deepEqual(row.children.map((cell) => cell.textContent),
			[ 'aether-proxy', text, '/usr/bin/aether-proxy' ]);
	}
});

const STATUS_ERRORS = [
	{
		ok: false, code: 'CMD_FAILED',
		detail: 'Syntax error: Unexpected token\n at <script>alert(1)</script>\n  line 2'
	},
	{ ok: false, code: 'TIMEOUT' },
	{ ok: false, code: 'RPC_FAILED' }
];

for (const failure of STATUS_ERRORS) {
	test(`T10.20 scenario 3: ${failure.code} status failure has one summary and optional collapsed raw details`,
		async () => {
		const h = deferredPage();
		const { page, polls } = h;
		page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', failure);
		assert.equal(page.noticeContent.children.length, 1);
		const banner = page.noticeContent.children[0];
		assert.equal(banner.attrs.class, 'alert-message error');
		assert.equal(banner.children[0], `读取状态失败（${failure.code}），稍后自动重试`);
		assert.equal(banner.children.length, failure.detail ? 2 : 1);
		const details = findAll(banner, 'details');
		assert.equal(details.length, failure.detail ? 1 : 0);
		if (failure.detail) {
			assert.equal(banner.children[1], details[0], 'detail stays inside the banner');
			assert.equal(Object.hasOwn(details[0].attrs, 'open'), false, 'native details starts collapsed');
			assert.deepEqual(details[0].children.map((child) => child.tag), [ 'summary', 'pre' ]);
			assert.equal(details[0].children[0].textContent, '详情');
			assert.equal(details[0].children[1].textContent, failure.detail, 'multiline detail stays verbatim');
			assert.equal(findAll(details[0], 'script').length, 0, 'diagnostics are text, not markup');
		}
		else
			assert.equal(findAll(banner, 'pre').length, 0);
		await h.reply('stats', { ok: false, code: 'TIMEOUT' });
		await page.initialRequest;
		const retry = polls[0].fn();
		await h.reply('status', { ok: true, state: 'running' });
		assert.equal(page.noticeContent.children.length, 0, 'automatic recovery removes summary and details');
		assert.equal(page.vm.error_detail, null);
		await h.reply('stats', readings(1000, 0, 0, 0, 0));
		await retry;
	});
}

test('T10.22 scenario 1: empty or enabled-only changes go straight to the original disable confirmation',
	async () => {
	for (const changes of [ {}, { aetherproxy: [] },
		{ aetherproxy: [ [ 'set', 'main', 'enabled', '1' ] ] },
		{ aetherproxy: [ [ 'remove', 'main', 'enabled' ] ] } ]) {
		const asked = [], effects = [];
		const page = loadView({
			uci: {
				changes: async () => changes,
				set: (...args) => effects.push([ 'set', ...args ]),
				save: async () => { effects.push([ 'save' ]); }
			},
			confirm: async options => { asked.push(options); return true; },
			ui: { changes: { apply: rollback => effects.push([ 'apply', rollback ]) } }
		});
		page.enabled = true;
		page.vm = build({ ok: true, state: 'running' });
		await page.handleEnable(false);
		assert.deepEqual(asked, [ {
			title: '关闭「启用」', text: page.vm.disable_confirmation, ok: '关闭', destructive: true
		} ]);
		assert.deepEqual(effects, [
			[ 'set', 'aetherproxy', 'main', 'enabled', '0' ], [ 'save' ], [ 'apply', true ]
		]);
	}
});

test('T10.22 scenario 2: count records across configurations but exclude only the replaced enabled option', () => {
	const model = dashboardModel();
	assert.deepEqual(model.staged_confirmation({
		aetherproxy: [ [ 'set', 'main', 'enabled', '1' ], [ 'set', 'main', 'mode', 'global' ] ],
		network: [ [ 'set', 'wan', 'proto', 'dhcp' ], [ 'remove', 'lan', 'ipaddr' ] ],
		firewall: []
	}), {
		title: '还有未应用的更改',
		text: '还有 3 项未应用的更改（aetherproxy、network），会和本次操作一起应用。',
		ok: '一起应用', destructive: false
	});
	/* Section operations can have "enabled" in slot 2 without targeting that option. */
	for (const record of [ [ 'set', 'main', 'enabled' ], [ 'rename', 'main', 'enabled' ],
		[ 'remove', 'main' ], [ 'set', 'other', 'enabled', '1' ] ]) {
		assert.equal(model.staged_confirmation({ aetherproxy: [ record ] }).text,
			'还有 1 项未应用的更改（aetherproxy），会和本次操作一起应用。');
	}
	assert.equal(model.staged_confirmation({
		aetherproxy: [ [ 'set', 'main', 'enabled', '0' ] ],
		network: [ [ 'set', 'main', 'enabled', '1' ] ]
	}).text, '还有 1 项未应用的更改（network），会和本次操作一起应用。');
});

test('T10.22 scenario 3: enabling never reads changes or asks for confirmation', async () => {
	const effects = [];
	const page = loadView({
		uci: {
			changes: () => assert.fail('enabling must not read staged changes'),
			set: (...args) => effects.push([ 'set', ...args ]),
			save: async () => { effects.push([ 'save' ]); }
		},
		confirm: () => assert.fail('enabling must not ask for confirmation'),
		ui: { changes: { apply: rollback => effects.push([ 'apply', rollback ]) } }
	});
	page.enabled = false;
	const box = findTag(page.enableSwitch('note'), 'input');
	box.checked = true;
	await box.attrs.change({ target: box });
	assert.equal(box.checked, true);
	assert.equal(page.enabled, true);
	assert.deepEqual(effects, [
		[ 'set', 'aetherproxy', 'main', 'enabled', '1' ], [ 'save' ], [ 'apply', true ]
	]);
});

test('T10.22 defensive: failed changes read notifies, writes nothing and restores the switch', async () => {
	const error = new Error('uci changes failed');
	const notes = [];
	const page = loadView({
		uci: {
			changes: async () => { throw error; },
			set: () => assert.fail('failed read must not set UCI'),
			save: () => assert.fail('failed read must not save UCI')
		},
		confirm: () => assert.fail('failed read must not offer to apply'),
		ui: {
			changes: { apply: () => assert.fail('failed read must not apply') },
			addNotification: (title, body, kind) => notes.push({ body, kind })
		}
	});
	page.enabled = true;
	const box = findTag(page.enableSwitch('note'), 'input');
	box.checked = false;
	await box.attrs.change({ target: box });
	assert.equal(page.enabled, true);
	assert.equal(box.checked, true);
	/* the user is told why nothing happened, with the reason */
	assert.equal(notes.length, 1);
	assert.equal(notes[0].kind, 'error');
	assert.equal(notes[0].body.textContent, '读取未应用的更改失败，没有关闭『启用』：uci changes failed');
});

test('T10.23 scenario 4: overview node_use failure restores button, reports code/detail and never touches UCI',
	async () => {
	const calls = [], notes = [];
	const failedPage = loadView({
		ap: { call: (method, params) => new Promise(resolve => calls.push({ method, params, resolve })) },
		uci: {
			set: () => assert.fail('must not set UCI'), save: () => assert.fail('must not save UCI'),
			unload: () => assert.fail('failed switch must not unload UCI'),
			changes: () => assert.fail('must not inspect session changes')
		},
		ui: {
			addNotification: (title, body, kind) => notes.push({ body, kind }),
			changes: { apply: () => assert.fail('must not apply session changes') }
		}
	});
	failedPage.labels = { n_a: 'Alpha', n_b: 'Beta' };
	failedPage.content = E('div');
	failedPage.currentNode = 'n_a';
	failedPage.refresh({ ok: true, state: 'running', node_id: 'n_a' });
	const select = findAll(failedPage.nodeControl, 'select')[0];
	const button = findAll(failedPage.nodeControl, 'button')[0];
	select.value = 'n_b';
	select.attrs.change();
	const pending = button.attrs.click();
	assert.equal(button.disabled, true);
	assert.equal(await button.attrs.click(), undefined, 'duplicate switch is ignored');
	assert.equal(calls.length, 1);
	calls[0].resolve({ ok: false, code: 'FS_FAILED', detail: 'uci-commit' });
	await pending;
	assert.equal(button.disabled, false);
	assert.equal(notes[0].body.textContent, '切换节点失败（FS_FAILED）: uci-commit');
	assert.equal(notes[0].kind, 'error');
	assert.equal(failedPage.switching, false);
});

test('T10.23 defensive: overview UCI refresh rejection notifies and restores switch button without retry',
	async () => {
	const notes = [], calls = [];
	const page = loadView({
		ap: { call: async method => { calls.push(method); return { ok: true, reload: true }; } },
		uci: { unload: () => { throw new Error('UCI unavailable'); } },
		ui: { addNotification: (title, body, kind) => notes.push([body.textContent, kind]) }
	});
	page.content = E('div');
	page.labels = { n_a: 'Alpha', n_b: 'Beta' };
	page.refresh({ ok: true, state: 'running', node_id: 'n_a' });
	const select = findAll(page.nodeControl, 'select')[0];
	const button = findAll(page.nodeControl, 'button')[0];
	select.value = 'n_b';
	select.attrs.change();
	await button.attrs.click();
	assert.equal(button.disabled, false);
	assert.equal(page.switching, false);
	/* node_use succeeded; only the refresh failed, so it must not read as a failed switch */
	assert.deepEqual(notes, [['已切换节点，但刷新页面数据失败：UCI unavailable。请刷新页面。', 'warning']]);
	assert.deepEqual(calls, ['node_use']);
});

test('T10.23 scenario 4: overview reload:false only notifies when refreshed service is stopped/error', async () => {
	for (const state of ['stopped', 'error', 'running', 'degraded', 'starting', 'failsafe']) {
		const notes = [], order = [];
		let current = 'n_a';
		const page = loadView({
			ap: {
				call: async method => {
					order.push(method);
					if (method === 'node_use') {
						current = 'n_b';
						return { ok: true, reload: false };
					}
					return { ok: true, state, node_id: 'n_b' };
				}
			},
			uci: { get: (config, section, option) => option === 'node' ? current : '1' },
			ui: { addNotification: (title, body) => notes.push(body.textContent) }
		});
		page.labels = {};
		page.content = E('div');
		await page.handleNode('n_b');
		assert.equal(order[0], 'node_use');
		assert.ok(order.includes('status'));
		assert.deepEqual(notes, ['stopped', 'error'].includes(state) ? ['已设为当前节点，下次启动时使用'] : []);
	}
});

test('T10.23 scenario 4: node switch waits out older refresh and issues a new post-UCI status read', async () => {
	const h = deferredPage('0');
	const { page, calls } = h;
	page.render(await page.load());
	await Promise.resolve();
	const pending = page.handleNode('n_b');
	/* The original status is still pending when node_use succeeds. */
	await h.reply('node_use', { ok: true, reload: true });
	assert.equal(calls.filter(call => call.method === 'status').length, 1);
	await h.reply('status', { ok: true, state: 'running', node_id: 'n_a' });
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await page.initialRequest;
	assert.equal(calls.filter(call => call.method === 'status').length, 2);
	await h.reply('status', { ok: true, state: 'running', node_id: 'n_a' });
	await h.reply('stats', readings(2000, 0, 0, 0, 0));
	await pending;
	assert.equal(page.switching, false);
});

test('T10.24 scenario 1: first since is baseline; changed since rereads versions once with loading cells',
	async () => {
	const h = deferredPage('0');
	const { page, calls } = h;
	const root = page.render(await page.load());
	await Promise.resolve();
	await h.reply('status', { ok: true, state: 'running', since: 10 });
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await h.reply('version', { ok: true, version: 'old' });
	await h.reply('components', { ok: true, components: {
		xray: { found: true, version: 'old-xray', path: '/usr/bin/xray' }
	} });
	await page.initialRequest;
	const counts = () => ['version', 'components'].map(method => calls.filter(c => c.method === method).length);
	assert.deepEqual(counts(), [1, 1], 'first since does not rediscover versions');
	const unchanged = page.fetchRefresh();
	await h.reply('status', { ok: true, state: 'running', since: 10 });
	await h.reply('stats', readings(2000, 0, 0, 0, 0));
	await unchanged;
	assert.deepEqual(counts(), [1, 1], 'unchanged since does not rediscover versions');
	const restart = page.fetchRefresh();
	await h.reply('status', { ok: true, state: 'running', since: 20 });
	assert.deepEqual(counts(), [2, 2], 'changed since reissues each request once');
	assert.equal(ownVersion(root), '读取中…');
	assert.deepEqual(componentCells(root), [
		['xray', '读取中…', '读取中…'], ['chinadns-ng', '读取中…', '读取中…']
	]);
	await h.reply('stats', readings(3000, 0, 0, 0, 0));
	await restart;
	await h.reply('version', { ok: true, version: 'new' });
	await h.reply('components', { ok: true, components: {
		xray: { found: true, version: 'new-xray', path: '/usr/bin/xray' }
	} });
	assert.equal(ownVersion(root), 'new');
	assert.equal(componentCells(root)[0][1], 'new-xray');
	const again = page.fetchRefresh();
	await h.reply('status', { ok: true, state: 'running', since: 20 });
	await h.reply('stats', readings(4000, 0, 0, 0, 0));
	await again;
	assert.deepEqual(counts(), [2, 2]);
});

test('T10.24 scenario 1: failed status does not reset since; pre-restart inventory cannot overwrite new replies',
	async () => {
	const h = deferredPage('0');
	const { page } = h;
	const root = page.render(await page.load());
	await Promise.resolve();
	await h.reply('status', { ok: true, state: 'running', since: 1 });
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await page.initialRequest;
	const failure = page.fetchRefresh();
	await h.reply('status', { ok: false, code: 'RPC_FAILED' });
	await h.reply('stats', null);
	await failure;
	assert.equal(h.calls.filter(c => c.method === 'version').length, 1);
	const restart = page.fetchRefresh();
	await h.reply('status', { ok: true, state: 'running', since: 2 });
	const currentVersion = page.versionRequest, currentComponents = page.componentRequest;
	for (const [method, reply] of [
		['version', { ok: true, version: 'new' }],
		['components', { ok: true, components: { xray: { found: true, version: 'new' } } }]
	]) {
		const call = h.calls.filter(c => c.method === method).at(-1);
		call.settled = true;
		call.resolve(reply);
	}
	await Promise.all([currentVersion, currentComponents]);
	await h.reply('version', { ok: true, version: 'stale' });
	await h.reply('components', { ok: false, code: 'TIMEOUT' });
	assert.equal(ownVersion(root), 'new');
	assert.equal(componentCells(root)[0][1], 'new');
	await h.reply('stats', readings(2000, 0, 0, 0, 0));
	await restart;
});

test('T10.24 scenario 2: capture monitor generation on arrival; later RPC errors preserve manual result',
	async () => {
	const h = deferredPage('0');
	const { page } = h;
	page.render(await page.load());
	await Promise.resolve();
	await h.reply('status', { ok: true, state: 'running' });
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	await h.reply('probe_sites', SITES);
	await page.initialRequest;
	const first = page.handleProbe();
	/* The monitor advances while the request is in flight. The result must
	   remember the generation at arrival, not the one at button click. */
	page.refresh({ ok: true, state: 'running', last_probe: { at: NOW, ok: false } });
	await h.reply('probe_url', { ok: true, latency_ms: 17 });
	await first;
	page.refresh({ ok: true, state: 'running', last_probe: { at: NOW, ok: false } });
	assert.equal(page.vm.probe_text, '正常，17 ms（Google，手动）');
	for (const code of ['NOT_RUNNING', 'RPC_FAILED']) {
		const pending = page.handleProbe();
		await h.reply('probe_url', { ok: false, code });
		await pending;
		assert.equal(page.vm.probe_text, '正常，17 ms（Google，手动）');
		assert.equal(page.vm.probe_level, 'ok');
	}
	assert.deepEqual(h.notifications.map(note => note.text), [
		'检测真实延迟失败（NOT_RUNNING）', '检测真实延迟失败（RPC_FAILED）'
	]);
});

test('T10.24 scenario 3: pending site list contains only disabled Reading option', async () => {
	const { page } = deferredPage('0');
	page.render(await page.load());
	assert.equal(page.probeSites.children.length, 1);
	const option = page.probeSites.children[0];
	assert.equal(visibleText(option), '读取中…');
	assert.equal(option.disabled, true);
	assert.equal(page.probeSites.disabled, true);
	assert.equal(page.probeButton.disabled, true);
});

test('T10.24 scenario 3: valid saved site is selected; invalid or blocked storage falls back; changes persist',
	async (t) => {
	const warnings = [];
	t.mock.method(console, 'warn', (...args) => warnings.push(args));
	for (const saved of ['github', 'missing', null, 'throw']) {
		const writes = [];
		const page = loadView({
			ap: { call: async method => method === 'probe_sites' ? SITES
				: { ok: true, state: 'running' }, poll: () => ({ stop() {} }) },
			window: { localStorage: {
				getItem: key => {
					if (key !== 'aether-proxy.probe-site')
						return '0';
					if (saved === 'throw')
						throw new Error('blocked read');
					return saved;
				},
				setItem: (key, value) => {
					writes.push([key, value]);
					if (saved === 'throw')
						throw new Error('blocked write');
				}
			} }
		});
		page.render(await page.load());
		await page.sitesRequest;
		await page.initialRequest;
		assert.equal(page.probeSites.value, saved === 'github' ? 'github' : 'google');
		assert.equal(page.probeSites.children.filter(o => o.attrs.selected).length, 1);
		page.probeSites.value = 'github';
		page.probeSites.attrs.change({ target: page.probeSites });
		assert.deepEqual(writes, [['aether-proxy.probe-site', 'github']]);
		assert.equal(page.probeSites.disabled, false);
		assert.equal(page.probeButton.disabled, false, 'storage exceptions do not disable probing');
	}
	assert.equal(warnings.length, 2, 'both read and write exceptions are reported');
});

test('T10.24 scenario 3: failed, empty and malformed site lists can retry successfully without duplicate calls',
	async () => {
	for (const failure of [{ ok: false, code: 'TIMEOUT' }, { ok: true, sites: [] },
		{ ok: true, sites: [{ name: 'google' }] }]) {
		const h = deferredPage('0');
		const { page, calls } = h;
		page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', { ok: true, state: 'running' });
		await h.reply('probe_sites', failure);
		assert.equal(visibleText(page.probeSites), '读取失败');
		assert.equal(page.probeButton.disabled, true);
		const retry = findAll(page.probeMessage, 'button')[0];
		assert.equal(visibleText(retry), '重试');
		assert.equal(retry.attrs.class, 'cbi-button cbi-button-action');
		const pending = retry.attrs.click();
		assert.equal(retry.attrs.click(), pending, 'stale repeated clicks share the request');
		assert.equal(visibleText(page.probeSites), '读取中…');
		assert.equal(page.probeSites.disabled, true);
		assert.equal(visibleText(page.probeMessage), '');
		await Promise.resolve();
		assert.equal(calls.filter(c => c.method === 'probe_sites').length, 2);
		await h.reply('probe_sites', SITES);
		await pending;
		assert.equal(page.probeSites.value, 'google');
		assert.equal(page.probeSites.disabled, false);
		assert.equal(page.probeButton.disabled, false);
		assert.equal(visibleText(page.probeMessage), '');
		assert.equal(findAll(page.probeMessage, 'button').length, 0);
	}
});

test('T10.24 scenario 4: pending switch locks both controls; failure or completion restores them, not service actions',
	async () => {
	for (const recovery of ['failure', 'complete']) {
		const h = deferredPage('0', 'n_b');
		const { page, calls } = h;
		page.currentNode = 'n_b';
		const data = await page.load();
		const root = page.render({ ...data, node: 'n_b' });
		await Promise.resolve();
		await h.reply('status', { ok: true, state: 'running', node_id: 'n_a' });
		const nodes = findAll(page.nodeControl, 'select')[0];
		const use = findAll(page.nodeControl, 'button')[0];
		nodes.value = 'n_b';
		nodes.attrs.change();
		assert.equal(page.vm.switch_notice, '正在切换到「Beta」…');
		assert.equal(nodes.disabled, true);
		assert.equal(use.disabled, true);
		assert.equal(nodes.title, '正在切换节点，请稍候');
		assert.equal(use.title, '正在切换节点，请稍候');
		assert.deepEqual(serviceButtons(root).map(disabled), [true, false, false]);
		await use.attrs.click();
		assert.ok(!calls.some(c => c.method === 'node_use'), 'locked handler cannot submit another switch');
		await h.reply('stats', readings(1000, 0, 0, 0, 0));
		const event = { ts: NOW, code: 'NODE_RESOLVE_FAILED', args: { domain: 'node.example' } };
		await h.reply('events', { ok: true, events: recovery === 'failure' ? [event] : [] });
		await page.initialRequest;
		if (recovery === 'failure') {
			assert.ok(page.vm.switch_notice.includes('未生效'));
			assert.equal(nodes.disabled, false, 'late failure unlocks existing selector without recreating it');
			assert.equal(use.disabled, false);
			assert.equal(nodes.title, 'Beta');
			assert.equal(use.title, '');
			const poll = page.fetchRefresh();
			await h.reply('status', { ok: true, state: 'running', node_id: 'n_a' });
			assert.equal(findAll(page.nodeControl, 'select')[0].disabled, false,
				'next poll keeps the known failure reason until its own events arrive');
			assert.ok(page.vm.switch_notice.includes('未生效'));
			await h.reply('stats', readings(2000, 0, 0, 0, 0));
			await h.reply('events', { ok: true, events: [event] });
			await poll;
			assert.equal(findAll(page.nodeControl, 'select')[0].disabled, false);
		}
		else {
			assert.equal(nodes.disabled, true, 'no failure reason means switch is still pending');
			const refresh = page.fetchRefresh();
			await h.reply('status', { ok: true, state: 'running', node_id: 'n_b' });
			await h.reply('stats', readings(2000, 0, 0, 0, 0));
			await refresh;
			const selected = findAll(page.nodeControl, 'select')[0];
			const button = findAll(page.nodeControl, 'button')[0];
			assert.equal(page.vm.switch_notice, null);
			assert.equal(selected.disabled, false);
			assert.equal(selected.title, 'Beta');
			selected.value = 'n_a';
			selected.attrs.change();
			assert.equal(button.disabled, false, 'another node is selectable after completion');
		}
		assert.deepEqual(serviceButtons(root).map(disabled), [true, false, false]);
	}
});

test('T10.24 review: retrying with another node ignores the reason found for the previous target', async () => {
	const calls = [];
	let configured = 'n_b';
	const page = loadView({
		ap: {
			call: (method, params) => new Promise((resolve) => { calls.push({ method, params, resolve }); }),
			poll: () => ({ stop() {} })
		},
		uci: {
			load: async () => {},
			unload: () => {},
			sections: (config, type, cb) => {
				if (type === 'node')
					for (const [name, label] of [['n_a', 'Alpha'], ['n_b', 'Beta'], ['n_c', 'Gamma']])
						cb({ '.name': name, label });
			},
			get: (config, section, option) => option === 'node' ? configured : '1'
		},
		ui: { addNotification: () => {} },
		window: { localStorage: { getItem: () => '0', setItem: () => {} } }
	});
	const reply = async (method, value) => {
		const call = calls.find((c) => c.method === method && !c.settled);
		assert.ok(call, `outstanding ${method} request exists`);
		call.settled = true;
		call.resolve(value);
		for (let i = 0; i < 12; i++)
			await Promise.resolve();
	};
	page.render(await page.load());
	await Promise.resolve();
	const event = { ts: NOW, code: 'NODE_RESOLVE_FAILED', args: { domain: 'node.example' } };
	await reply('status', { ok: true, state: 'running', node_id: 'n_a' });
	await reply('stats', readings(1000, 0, 0, 0, 0));
	await reply('events', { ok: true, events: [event] });
	await page.initialRequest;
	assert.ok(page.vm.switch_notice.includes('未生效'), 'failure reason for Beta is shown');
	const nodes = findAll(page.nodeControl, 'select')[0];
	assert.equal(nodes.disabled, false, 'failure reason unlocks the selector for a retry');
	const switching = page.handleNode('n_c');
	configured = 'n_c';
	await reply('node_use', { ok: true, node: 'n_c', previous: 'n_b', reload: true });
	await reply('status', { ok: true, state: 'running', node_id: 'n_a' });
	assert.equal(page.vm.switch_notice, '正在切换到「Gamma」…', 'the old reason is not reported for Gamma');
	assert.equal(page.vm.switch_busy, true, 'controls stay locked for the new switch');
	await reply('stats', readings(2000, 0, 0, 0, 0));
	await reply('events', { ok: true, events: [event] });
	await switching;
	assert.equal(page.vm.switch_notice, '正在切换到「Gamma」…', 'Beta\'s failure event is older than the retry');
	assert.equal(findAll(page.nodeControl, 'select')[0].disabled, true);
	const later = { ts: NOW + 5, code: 'CONFIG_INVALID', args: {} };
	const poll = page.fetchRefresh();
	await reply('status', { ok: true, state: 'running', node_id: 'n_a' });
	await reply('stats', readings(3000, 0, 0, 0, 0));
	await reply('events', { ok: true, events: [event, later] });
	await poll;
	assert.ok(page.vm.switch_notice.includes('Gamma') && page.vm.switch_notice.includes('未生效'),
		'a newer failure is reported for Gamma');
	assert.equal(page.nodeControl.children[0].disabled, false);
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

/* Mode scenarios use real enum values on both UCI and runtime sides. The
   mutable pair represents a committed configuration ahead of an async reload. */
async function modePage(options = {}) {
	const calls = [], order = [], notes = [];
	const configured = { node: 'n_a', mode: 'bypass_cn', ...options.configured };
	const runtime = { ok: true, state: 'running', node_id: 'n_a', mode: 'bypass_cn', ...options.runtime };
	const h = { calls, order, notes, configured, runtime, events: options.events ?? { ok: true, events: [] } };
	const page = h.page = loadView({
		ap: {
			confirm: async () => true,
			call: async (method, params) => {
				calls.push([method, params]);
				order.push(method);
				if (method === 'node_use' || method === 'mode_use') {
					const reply = await (options.write?.(method, params) ?? { ok: true, reload: true });
					if (reply.ok) {
						configured.node = params.id ?? configured.node;
						configured.mode = params.mode ?? configured.mode;
					}
					return reply;
				}
				if (method === 'status')
					return { ...runtime };
				if (method === 'events')
					return typeof h.events === 'function' ? h.events() : h.events;
				if (method === 'probe_sites')
					return SITES;
				return { ok: true };
			},
			poll: () => ({ stop() {} })
		},
		uci: {
			load: async () => { order.push('load'); },
			unload: () => { order.push('unload'); options.unload?.(); },
			get: (config, section, option) => option === 'enabled' ? '1' : configured[option],
			sections: (config, type, cb) => {
				if (type === 'node')
					for (const [name, label] of [['n_a', 'Alpha'], ['n_b', 'Beta']])
						cb({ '.name': name, label });
			},
			set: () => assert.fail('node/mode apply must not stage session UCI'),
			save: () => assert.fail('node/mode apply must not save session UCI'),
			changes: () => assert.fail('node/mode apply must not read staged session changes')
		},
		ui: {
			changes: { apply: () => assert.fail('node/mode apply must not apply session changes') },
			addNotification: (title, body, kind) => notes.push({ text: visibleText(body), kind })
		},
		window: { localStorage: { getItem: () => '0', setItem: () => {} } }
	});
	h.root = page.render(await page.load());
	await Promise.all([page.initialRequest, page.sitesRequest, page.componentRequest, page.versionRequest]);
	h.controls = () => {
		const [node, mode] = findAll(page.nodeControl, 'select');
		return { node, mode, apply: findAll(page.nodeControl, 'button')[0] };
	};
	calls.length = 0;
	order.length = 0;
	return h;
}

const MODE_OPTIONS = [
	['bypass_cn', '绕过大陆'], ['gfw', '仅代理被墙网站（GFW）'], ['global', '全局（所有流量走代理）']
];

test('T10.38 scenario 1: effective mode is preselected while active; inactive and initial reads use UCI', async () => {
	for (const state of ['starting', 'running', 'degraded', 'failsafe', 'stopped', 'error', 'unknown']) {
		const h = await modePage({ configured: { mode: 'global' }, runtime: { state, mode: 'gfw' } });
		const { mode } = h.controls();
		const expected = ['starting', 'running', 'degraded', 'failsafe'].includes(state) ? 'gfw' : 'global';
		assert.equal(h.page.vm.current_mode, expected, state);
		assert.equal(mode.value, expected, state);
		assert.deepEqual(mode.children.map(option => [option.value, option.textContent]), MODE_OPTIONS);
		assert.equal(mode.children.find(option => option.attrs.selected)?.value, expected);
		assert.equal(h.page.vm.switch_busy, expected === 'gfw', 'only active mismatches are pending');
		assert.equal(mode.disabled, expected === 'gfw');
	}
	const defaults = await modePage({ configured: { mode: undefined }, runtime: { state: 'stopped' } });
	assert.equal(defaults.controls().mode.value, 'bypass_cn', 'unset UCI uses the schema default');
	const h = await modePage({ configured: { mode: 'gfw' } });
	h.page.refresh(undefined);
	assert.equal(h.controls().mode.value, 'gfw', 'initial skeleton reads the UCI mode');
	h.page.refresh({ ok: false, code: 'TIMEOUT' });
	assert.equal(h.controls().mode.value, 'gfw', 'failed status keeps the UCI fallback like node selection');
});

test('T10.38 conservative: missing active status.mode disables mode selection without inventing effective mode',
	async () => {
	const h = await modePage({ runtime: { mode: undefined } });
	assert.equal(h.page.vm.current_mode, null);
	assert.equal(h.page.vm.switch_notice, null, 'missing mode is not evidence of a pending reload');
	assert.equal(h.controls().mode.value, '');
	assert.equal(h.controls().mode.disabled, true);
	assert.equal(h.controls().apply.disabled, true);
	assert.deepEqual(h.calls, []);
});

for (const [kind, node, mode, expected] of [
	['unchanged', 'n_a', 'bypass_cn', null],
	['node', 'n_b', 'bypass_cn', ['node_use', { id: 'n_b' }]],
	['mode', 'n_a', 'gfw', ['mode_use', { mode: 'gfw' }]],
	['both', 'n_b', 'global', ['node_use', { id: 'n_b', mode: 'global' }]]
]) {
	test(`T10.38 scenario 2: Apply ${kind} dispatches exactly the intended RPC and never applies session changes`,
		async () => {
		let resolve;
		const h = await modePage({ write: () => new Promise(done => { resolve = done; }) });
		const { page } = h;
		const controls = h.controls();
		assert.equal(controls.apply.textContent, '应用');
		assert.equal(controls.apply.disabled, true, 'no effective selection change');
		controls.node.value = node;
		controls.mode.value = mode;
		controls.mode.attrs.change();
		assert.equal(controls.apply.disabled, expected == null);
		const pending = controls.apply.attrs.click();
		if (!expected) {
			await pending;
			assert.deepEqual(h.calls, []);
			return;
		}
		assert.deepEqual(h.calls, [expected]);
		assert.equal(controls.node.disabled, true);
		assert.equal(controls.mode.disabled, true);
		assert.equal(controls.apply.disabled, true);
		await controls.apply.attrs.click();
		assert.equal(h.calls.length, 1, 'duplicate click does not write twice');
		resolve({ ok: true, reload: true });
		await pending;
		assert.deepEqual(h.order, [expected[0], 'unload', 'load', 'status', 'stats', 'events']);
		assert.equal(page.vm.switch_busy, true, 'RPC returns before the reload takes effect');
		assert.deepEqual(h.calls.filter(([method]) => ['node_use', 'mode_use'].includes(method)), [expected]);
		const banner = kind === 'both' ? '正在切换到「Beta」，默认模式「全局（所有流量走代理）」…'
			: kind === 'mode' ? '正在切换默认模式到「仅代理被墙网站（GFW）」…' : '正在切换到「Beta」…';
		assert.equal(page.vm.switch_notice, banner);
	});
}

test('T10.38 scenario 2 / T10.48: effective mode changes rebase current labels but preserve unapplied selections',
	async () => {
	const h = await modePage();
	const before = h.controls();
	before.node.value = 'n_b';
	before.mode.value = 'global';
	before.node.attrs.change();
	await h.page.fetchRefresh();
	assert.equal(h.controls().node, before.node);
	assert.equal(h.controls().mode, before.mode);
	assert.equal(h.controls().node.value, 'n_b');
	assert.equal(h.controls().mode.value, 'global');
	assert.equal(h.controls().apply.disabled, false);
	h.configured.mode = 'gfw';
	h.page.currentMode = 'gfw';
	h.runtime.mode = 'gfw';
	await h.page.fetchRefresh();
	assert.notEqual(h.controls().mode, before.mode);
	assert.equal(h.page.vm.current_mode, 'gfw');
	assert.equal(h.controls().mode.value, 'global', 'T10.48 keeps unapplied edits across external changes');
	assert.equal(h.controls().node.value, 'n_b');
	assert.equal(h.controls().apply.disabled, false);
});

test('T10.38 scenario 3: mode-only mismatch locks both dropdowns and Apply; completion restores them, '
	+ 'not service actions',
	async () => {
	const h = await modePage({ configured: { mode: 'global' } });
	const { page, root } = h;
	let controls = h.controls();
	assert.equal(page.vm.switch_notice, '正在切换默认模式到「全局（所有流量走代理）」…');
	for (const control of Object.values(controls)) {
		assert.equal(control.disabled, true);
		assert.equal(control.title, '正在切换设置，请稍候');
	}
	assert.deepEqual(serviceButtons(root).map(disabled), [true, false, false]);
	await controls.apply.attrs.click();
	assert.deepEqual(h.calls, [], 'guard stops writes during a mode-only reload');
	await page.handleService('restart');
	await page.handleService('stop');
	assert.deepEqual(h.calls, [['service', { action: 'restart' }], ['service', { action: 'stop' }]]);
	h.runtime.mode = 'global';
	h.calls.length = 0;
	await page.fetchRefresh();
	assert.deepEqual(h.calls.map(([method]) => method), ['status', 'stats'], 'completion skips diagnostic events');
	assert.equal(page.vm.switch_notice, null);
	controls = h.controls();
	assert.equal(controls.node.disabled, false);
	assert.equal(controls.mode.disabled, false);
	assert.equal(controls.mode.value, 'global');
	controls.mode.value = 'gfw';
	controls.mode.attrs.change();
	assert.equal(controls.apply.disabled, false, 'another mode can be applied after completion');
	assert.deepEqual(serviceButtons(root).map(disabled), [true, false, false]);
});

for (const [code, args] of SWITCH_REASON_CASES) {
	test(`T10.38 scenario 3: mode-only ${code} explains failure and unlocks controls without transient relocking`,
		async t => {
		t.mock.method(Date, 'now', () => NOW * 1000);
		const event = { ts: NOW - 30, code, args };
		const h = await modePage({ configured: { mode: 'global' }, events: { ok: true, events: [event] } });
		const { page } = h;
		const controls = h.controls();
		assert.equal(page.vm.switch_notice, '切换默认模式到「全局（所有流量走代理）」未生效，'
			+ '服务仍在使用默认模式「绕过大陆」。原因：' + logText(event)
			+ '（30 秒前）。'
			+ '可以点「重启」用配置的设置重新启动（会短暂中断代理），或到日志页查看详情。');
		assert.equal(controls.node.disabled, false);
		assert.equal(controls.mode.disabled, false);
		controls.mode.value = 'gfw';
		controls.mode.attrs.change();
		assert.equal(controls.apply.disabled, false);
		let release;
		h.events = () => new Promise(resolve => { release = resolve; });
		const pending = page.fetchRefresh();
		/* Status now reloads the UCI cache before stats and diagnostic events. */
		for (let i = 0; i < 32; i++)
			await Promise.resolve();
		assert.equal(typeof release, 'function');
		assert.equal(controls.mode.disabled, false, 'status phase retains the known reason until events arrive');
		assert.ok(page.vm.switch_notice.includes('未生效'));
		release({ ok: true, events: [event] });
		await pending;
		assert.equal(controls.mode.disabled, false);
	});
}

test('T10.38 scenario 3: combined failure names both targets and effective values, with existing reason-code filtering',
	async () => {
	const event = { ts: NOW, code: 'CONFIG_INVALID', args: { field: 'main.mode', reason: 'invalid' } };
	const h = await modePage({ configured: { node: 'n_b', mode: 'global' }, events: { ok: true, events: [event] } });
	assert.ok(h.page.vm.switch_notice.startsWith('切换到「Beta」，默认模式「全局（所有流量走代理）」未生效，'
		+ '服务仍在使用「Alpha」，默认模式「绕过大陆」。原因：' + logText(event)));
	assert.equal(h.controls().mode.disabled, false);
	for (const events of [{ ok: true, events: [{ ts: NOW + 5, code: 'CMD_FAILED', args: {} }] },
		{ ok: true, events: [{ ts: NOW + 5, code: 'START_FAILED', args: { step: 'precheck' } }] },
		{ ok: false, code: 'TIMEOUT' }, null]) {
		h.events = events;
		await h.page.fetchRefresh();
		assert.equal(h.page.vm.switch_notice, '正在切换到「Beta」，默认模式「全局（所有流量走代理）」…');
		assert.equal(h.controls().mode.disabled, true);
	}
});

test('T10.38 scenario 3: a new mode switch ignores the previous target failure and accepts only newer reasons',
	async () => {
	const old = { ts: NOW, code: 'CONFIG_INVALID', args: {} };
	const h = await modePage({ configured: { mode: 'global' }, events: { ok: true, events: [old] } });
	const controls = h.controls();
	assert.ok(h.page.vm.switch_notice.includes('未生效'));
	controls.mode.value = 'gfw';
	controls.mode.attrs.change();
	await controls.apply.attrs.click();
	assert.equal(h.page.vm.switch_notice, '正在切换默认模式到「仅代理被墙网站（GFW）」…');
	assert.equal(h.page.vm.switch_busy, true);
	assert.equal(h.controls().mode.disabled, true);
	h.events = { ok: true, events: [old, { ts: NOW + 1, code: 'RENDER_INVALID', args: {} }] };
	await h.page.fetchRefresh();
	assert.ok(h.page.vm.switch_notice.includes('未生效'));
	assert.equal(h.controls().mode.disabled, false);
});

for (const kind of ['node', 'mode', 'both']) {
	test(`T10.38 scenario 4: ${kind} RPC failure reports code/detail and restores both dropdowns and Apply`,
		async () => {
		const h = await modePage({ write: () => ({ ok: false, code: 'FS_FAILED', detail: 'uci-commit' }) });
		const controls = h.controls();
		if (kind !== 'mode')
			controls.node.value = 'n_b';
		if (kind !== 'node')
			controls.mode.value = 'global';
		controls.mode.attrs.change();
		await controls.apply.attrs.click();
		assert.equal(controls.node.disabled, false);
		assert.equal(controls.mode.disabled, false);
		assert.equal(controls.apply.disabled, false);
		const prefix = kind === 'node' ? '切换节点' : kind === 'mode' ? '切换默认模式' : '切换节点与默认模式';
		assert.deepEqual(h.notes, [{ text: `${prefix}失败（FS_FAILED）: uci-commit`, kind: 'error' }]);
		assert.deepEqual(h.order, [kind === 'mode' ? 'mode_use' : 'node_use'],
			'failed write does not reload UCI/status');
	});
}

test('T10.38 scenario 4: reload:false mode and combined settings notify only when stopped/error', async () => {
	for (const state of ['stopped', 'error', 'running', 'starting', 'degraded', 'failsafe']) {
		for (const both of [false, true]) {
			const h = await modePage({ runtime: { state }, write: () => ({ ok: true, reload: false }) });
			const controls = h.controls();
			controls.mode.value = 'global';
			if (both)
				controls.node.value = 'n_b';
			controls.mode.attrs.change();
			await controls.apply.attrs.click();
			assert.deepEqual(h.notes, ['stopped', 'error'].includes(state)
				? [{ text: '设置已保存，下次启动时使用', kind: 'info' }] : []);
			assert.equal(h.calls.filter(([method]) => ['node_use', 'mode_use'].includes(method)).length, 1);
		}
	}
});

test('T10.38 scenario 4: successful mode write followed by refresh failure warns without retrying the write',
	async () => {
	const h = await modePage({ unload: () => { throw new Error('UCI unavailable'); } });
	const controls = h.controls();
	controls.mode.value = 'global';
	controls.mode.attrs.change();
	await controls.apply.attrs.click();
	assert.deepEqual(h.calls, [['mode_use', { mode: 'global' }]]);
	assert.deepEqual(h.notes, [{ text: '已切换设置，但刷新页面数据失败：UCI unavailable。请刷新页面。', kind: 'warning' }]);
	assert.equal(controls.mode.disabled, false);
	assert.equal(controls.apply.disabled, false);
});

test('T10.38 review: Apply compares with the effective mode, not the configured one', async () => {
	// A failed mode reload leaves UCI on gfw while the service still runs bypass_cn.
	const h = await modePage({
		configured: { mode: 'gfw' },
		events: { ok: true, events: [{ ts: Math.floor(Date.now() / 1000), code: 'CONFIG_INVALID', args: {} }] }
	});
	await h.page.fetchRefresh();
	assert.equal(h.page.vm.switch_busy, false, 'a failure reason unlocks the controls');
	assert.equal(h.page.vm.current_mode, 'bypass_cn');
	h.calls.length = 0;
	await h.page.handleNode('n_a', 'bypass_cn');
	assert.ok(!h.calls.some(([method]) => method === 'node_use' || method === 'mode_use'),
		'selecting the effective node and mode is not a change');
});

/* T10.43 uses a virtual clock, real success-shaped status replies (no ok), and
   event-only apply completion: LuCI apply() returns undefined even on success. */
function startupHarness(options = {}) {
	let now = 0;
	const timers = new Set();
	const listeners = new Map();
	const events = {
		addEventListener(name, fn) {
			if (!listeners.has(name))
				listeners.set(name, new Set());
			listeners.get(name).add(fn);
		},
		removeEventListener(name, fn) { listeners.get(name)?.delete(fn); },
		dispatch(name) {
			for (const fn of [...(listeners.get(name) ?? [])])
				fn();
		}
	};
	const clock = {
		...events,
		setTimeout(fn, ms) {
			const timer = { fn, at: now + ms };
			timers.add(timer);
			return timer;
		},
		clearTimeout(timer) { timers.delete(timer); },
		async advance(ms) {
			const target = now + ms;
			for (;;) {
				const next = [...timers].sort((a, b) => a.at - b.at)[0];
				if (!next || next.at > target)
					break;
				now = next.at;
				timers.delete(next);
				next.fn();
				for (let i = 0; i < 16; i++)
					await Promise.resolve();
			}
			now = target;
		}
	};
	const calls = [], polls = [], notes = [];
	const h = { clock, events, calls, polls, notes, status: { state: 'stopped' }, timers, listeners };
	h.page = loadView({
		document: events,
		window: { ...clock, localStorage: { getItem: () => '0', setItem() {} } },
		ap: {
			confirm: async () => true,
			call(method, params) {
				calls.push([method, params]);
				if (method === 'status')
					return Promise.resolve(options.status?.() ?? h.status);
				if (method === 'service')
					return Promise.resolve(options.service?.() ?? { ok: true });
				if (method === 'events')
					return Promise.resolve(options.events?.() ?? { ok: true, events: [] });
				return Promise.resolve({ ok: true });
			},
			poll(fn, ms) {
				const poll = { ms, stopped: false, stop() {
					this.stopped = true;
					clock.clearTimeout(this.timer);
				} };
				const tick = async () => {
					await fn();
					if (!poll.stopped)
						poll.timer = clock.setTimeout(tick, ms);
				};
				poll.timer = clock.setTimeout(tick, ms);
				polls.push(poll);
				return poll;
			}
		},
		uci: {
			save: options.save ?? (async () => {}),
			get: (config, section, option) => ({ enabled: '1', node: 'n_a', mode: 'bypass_cn' })[option],
			sections: (config, type, cb) => {
				for (const [id, label] of [['n_a', 'A very long node label'], ['n_b', 'Beta']])
					cb({ '.name': id, label });
			}
		},
		ui: {
			changes: { apply: options.apply ?? (() => {}) },
			addNotification: (title, body, kind) => notes.push({ text: visibleText(body), kind }),
			/* Real createHandlerFn returns undefined and re-enables on completion.
			   Service buttons must not delegate their disabled state to it. */
			createHandlerFn: (ctx, fn) => ev => {
				Promise.resolve(fn.call(ctx, ev)).finally(() => { if (ev?.target) ev.target.disabled = false; });
			}
		}
	});
	const page = h.page;
	page.labels = { n_a: 'A very long node label', n_b: 'Beta' };
	page.currentNode = 'n_a';
	page.currentMode = 'bypass_cn';
	page.enabled = true;
	page.content = E('div');
	page.startPolling(0);
	page.refresh(h.status);
	return h;
}

function runtimeButtons(page) {
	return findAll(page.runtimeContent, 'button').slice(0, 3);
}

for (const state of ['starting', 'running', 'degraded', 'failsafe', 'error']) {
	test(`T10.43 scenario 1: Start immediately waits, polls at 2s with refresh Off, then displays ${state}`,
		async () => {
		let finishService;
		const h = startupHarness({ service: () => new Promise(resolve => { finishService = resolve; }) });
		const { page, clock } = h;
		const start = runtimeButtons(page)[0];
		const pending = start.attrs.click({ target: start });
		assert.equal(page.vm.state_text, '启动中', 'feedback precedes the service reply');
		assert.equal(runtimeButtons(page)[0].disabled, true);
		assert.equal(runtimeButtons(page)[1].disabled, true);
		await clock.advance(2000);
		assert.equal(h.calls.filter(([method]) => method === 'status').length, 1,
			'status polling starts even while the service request is in flight');
		assert.equal(page.vm.state_text, '启动中');
		finishService({ ok: true });
		await pending;
		await start.attrs.click();
		assert.equal(h.calls.filter(([method]) => method === 'service').length, 1, 'stale double click is guarded');
		await clock.advance(1999);
		assert.equal(h.calls.filter(([method]) => method === 'status').length, 1);
		await clock.advance(1);
		assert.equal(h.calls.filter(([method]) => method === 'status').length, 2);
		assert.equal(page.vm.state_text, '启动中', 'stopped keeps waiting');
		h.status = { state, last_error: state === 'error' ? 'NODE_RESOLVE_FAILED' : null };
		await clock.advance(2000);
		assert.equal(page.vm.state_text, build(h.status).state_text);
		assert.deepEqual(page.vm.buttons, build(h.status).buttons);
		assert.deepEqual(runtimeButtons(page).map(disabled), Object.values(page.vm.buttons).map(value => !value));
		assert.equal(page.vm.error_text, state === 'error' ? '节点地址解析失败' : null);
		assert.equal(page.startup, null);
		assert.equal(page.poller, null, 'user refresh preference is unchanged');
		assert.ok(h.polls.every(poll => poll.ms === 2000 && poll.stopped));
		const count = h.calls.length;
		await clock.advance(60000);
		assert.equal(h.calls.length, count, 'outcome cancels startup polling and timeout');
	});
}

for (const reply of [{ state: 'stopped' }, { ok: false, code: 'TIMEOUT' }, { state: 'unknown' }]) {
	test(`T10.43 scenario 1: 60s deadline restores buttons after ${reply.state ?? reply.code}`, async () => {
		const h = startupHarness();
		await h.page.handleService('start');
		h.status = reply;
		await h.clock.advance(59999);
		assert.equal(h.page.vm.state_text, '启动中');
		assert.equal(runtimeButtons(h.page)[0].disabled, true);
		await h.clock.advance(1);
		assert.equal(h.page.vm.state_text, '启动没有完成，可到日志页查看原因');
		assert.equal(h.page.startup, null);
		assert.deepEqual(h.page.vm.buttons, build(reply).buttons, 'normal safety rules resume');
		assert.ok(h.polls[0].stopped);
		const count = h.calls.length;
		await h.clock.advance(10000);
		assert.equal(h.calls.length, count);
	});
}

test('T10.43 scenario 2: pre-acknowledgement running status cannot finish Restart', async () => {
	let finishService;
	const h = startupHarness({ service: () => new Promise(resolve => { finishService = resolve; }) });
	h.status = { state: 'running', since: 10 };
	h.page.refresh(h.status);
	const pending = h.page.handleService('restart');
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '停止中');
	assert.ok(h.page.startup);
	finishService({ ok: true });
	await pending;
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '停止中', 'acknowledgement alone cannot identify a new process');
	h.status = { state: 'running', since: 20 };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '运行中');
	assert.equal(h.page.startup, null);
});

test('T10.43 scenario 1: slow status cannot extend deadline or overwrite a retry', async () => {
	let resolve;
	const h = startupHarness({ status: () => new Promise(done => { resolve = done; }) });
	await h.page.handleService('start');
	await h.clock.advance(2000);
	await h.clock.advance(58000);
	assert.equal(h.page.vm.state_text, '启动没有完成，可到日志页查看原因');
	assert.equal(runtimeButtons(h.page)[0].disabled, false);
	await h.page.handleService('start');
	resolve({ state: 'running' });
	for (let i = 0; i < 16; i++)
		await Promise.resolve();
	assert.equal(h.page.vm.state_text, '启动中', 'late reply belongs to the previous wait');
	assert.ok(h.page.startup);
	h.events.dispatch('pagehide');
	assert.equal(h.page.startup, null);
	assert.equal(h.timers.size, 0, 'page exit cancels poll and deadline');
});

test('T10.43 scenario 1: service failure reports diagnostics and restores controls without waiting', async () => {
	const h = startupHarness({ service: () => ({ ok: false, code: 'CMD_FAILED', detail: 'init failed' }) });
	await h.page.handleService('start');
	assert.equal(h.page.vm.state_text, '已停止');
	assert.equal(runtimeButtons(h.page)[0].disabled, false);
	assert.equal(h.page.startup, null);
	assert.equal(h.timers.size, 0);
	assert.equal(h.notes.length, 1);
	assert.ok(h.notes[0].text.includes('CMD_FAILED') && h.notes[0].text.includes('init failed'));
});

test('T10.43 scenario 2: Restart ignores intermediate stopped and ordinary refresh cannot end waiting', async () => {
	const h = startupHarness();
	h.page.refresh({ state: 'running', since: 10 });
	await runtimeButtons(h.page)[1].attrs.click();
	assert.equal(h.page.vm.state_text, '停止中');
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '启动中');
	assert.ok(h.page.startup, 'stopped during restart is not completion');
	await h.page.fetchRefresh();
	assert.equal(h.page.vm.state_text, '启动中');
	h.status = { state: 'starting', since: 20, waiting_network: true };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '等待网络');
	assert.equal(h.page.startup, null);
	assert.deepEqual(h.calls.filter(([method]) => method === 'service'), [['service', { action: 'restart' }]]);
});

test('T10.43 scenario 3: Enable waits for uci-applied, not save or apply return; deadline starts on completion',
	async () => {
	let saved;
	const h = startupHarness({ save: () => new Promise(resolve => { saved = resolve; }) });
	h.page.enabled = false;
	const pending = h.page.handleEnable(true);
	await h.clock.advance(60000);
	assert.equal(h.page.startup, undefined, 'save in progress does not arm startup');
	saved();
	await pending;
	await h.clock.advance(60000);
	assert.equal(h.page.startup, undefined, 'apply returned undefined but has not completed');
	assert.deepEqual(h.calls, []);
	h.events.dispatch('uci-applied');
	assert.equal(h.page.vm.state_text, '启动中');
	assert.equal(runtimeButtons(h.page)[0].disabled, true);
	assert.equal(h.listeners.get('uci-applied').size, 0, 'completion listener is one-shot');
	await h.clock.advance(59999);
	assert.equal(h.page.vm.state_text, '启动中');
	await h.clock.advance(1);
	assert.equal(h.page.vm.state_text, '启动没有完成，可到日志页查看原因');
	assert.ok(!h.calls.some(([method]) => method === 'service'), 'Enable never calls service');
});

for (const result of ['cancelled', 'failed', 'save failed', 'apply throws']) {
	test(`T10.43 scenario 3: ${result} apply never enters startup waiting`, async () => {
		const h = startupHarness({
			save: async () => { if (result === 'save failed') throw new Error('save failed'); },
			apply: () => { if (result === 'apply throws') throw new Error('apply failed'); }
		});
		h.page.enabled = false;
		if (result === 'save failed' || result === 'apply throws')
			await assert.rejects(h.page.handleEnable(true), /failed/);
		else
			await h.page.handleEnable(true);
		/* Real LuCI cancel and failed apply emit no uci-applied event. */
		await h.clock.advance(120000);
		assert.equal(h.page.startup, undefined);
		assert.notEqual(h.page.vm.state_text, '启动中');
		assert.deepEqual(h.calls, []);
		h.events.dispatch('pagehide');
		assert.equal(h.listeners.get('uci-applied')?.size ?? 0, 0);
	});
}

test('T10.43 scenario 3: disabling or reverting clears dormant Enable intent', async () => {
	for (const action of ['disable', 'revert']) {
		const h = startupHarness();
		h.page.enabled = false;
		await h.page.handleEnable(true);
		if (action === 'disable')
			await h.page.handleEnable(false);
		else
			h.events.dispatch('uci-reverted');
		h.events.dispatch('uci-applied');
		assert.equal(h.page.startup, undefined, action);
		assert.equal(h.listeners.get('uci-applied').size, 0);
	}
});

test('T10.43 scenario 1: an older automatic status cannot replace a newer startup outcome', async () => {
	let release;
	const h = startupHarness({ status: () => h.calls.filter(([method]) => method === 'status').length === 1
		? new Promise(resolve => { release = resolve; }) : { state: 'running' } });
	const old = h.page.fetchRefresh();
	await h.page.handleService('start');
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '运行中');
	release({ state: 'stopped' });
	await old;
	assert.equal(h.page.vm.state_text, '运行中');
});

test('T10.43 scenario 1: late diagnostic events cannot overwrite a newer startup result', async () => {
	let release;
	const h = startupHarness({ events: () => new Promise(resolve => { release = resolve; }) });
	h.status = { state: 'running', node_id: 'n_b' };
	const old = h.page.fetchRefresh();
	for (let i = 0; i < 32; i++)
		await Promise.resolve();
	assert.equal(typeof release, 'function');
	assert.ok(h.page.vm.switch_notice);
	await h.page.handleService('restart');
	h.status = { state: 'running', node_id: 'n_a' };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.switch_notice, null);
	release({ ok: true, events: [{ ts: NOW, code: 'CONFIG_INVALID', args: {} }] });
	await old;
	assert.equal(h.page.vm.switch_notice, null);
	assert.equal(h.page.latestEvents, undefined);
});

test('T10.43 scenario 1: stale startup read cannot complete over a newer ordinary status', async () => {
	let release;
	let reads = 0;
	const h = startupHarness({ status: () => ++reads === 1
		? new Promise(resolve => { release = resolve; }) : { state: 'stopped' } });
	await h.page.handleService('start');
	await h.clock.advance(2000);
	await h.page.fetchRefresh();
	release({ state: 'running' });
	for (let i = 0; i < 16; i++)
		await Promise.resolve();
	assert.equal(h.page.vm.state_text, '启动中');
	assert.ok(h.page.startup, 'discarded completion does not strand a waiting display with no poller');
	h.events.dispatch('pagehide');
});

test('T10.43 scenario 4: node minimum is 16em clamped to narrow width, with wrapping flex groups', () => {
	const h = startupHarness();
	const nodes = findAll(h.page.nodeControl, 'select')[0];
	assert.match(nodes.attrs.style, /min-width:\s*min\(16em,\s*100%\)/);
	assert.match(nodes.attrs.style, /max-width:\s*24em/);
	assert.match(h.page.nodeControl.children[0].attrs.style, /max-width:\s*100%/);
	assert.equal(nodes.title, 'A very long node label');
	assert.match(nodes.attrs.style, /width:\s*auto/);
	assert.match(h.page.nodeControl.attrs.style, /flex-wrap:\s*wrap/);
	assert.match(h.page.nodeControl.attrs.style, /min-width:\s*0/);
	assert.match(h.page.nodeControl.attrs.style, /max-width:\s*100%/);
	assert.doesNotMatch(nodes.attrs.style, /\dpx/);
});

/* T10.48 keeps T10.43's virtual clock and exercises the entire restart timeline,
   not just isolated model states. No wall-clock sleeps or successful-ok fiction. */
test('T10.48 scenario 3: Restart stops, waits for startup, then shows the new starting and running states', async () => {
	const h = startupHarness();
	h.status = { state: 'running', since: 10 };
	h.page.refresh(h.status);
	await runtimeButtons(h.page)[1].attrs.click();
	assert.equal(h.page.vm.state_text, '停止中');
	assert.equal(h.page.startup.baseline, 10);
	assert.deepEqual(runtimeButtons(h.page).slice(0, 2).map(disabled), [true, true]);
	for (const reply of [
		{ state: 'stopping', since: 11 },
		...['starting', 'running', 'degraded', 'failsafe'].map(state => ({ state, since: 10 }))
	]) {
		h.status = reply;
		await h.clock.advance(2000);
		assert.equal(h.page.vm.state_text, '停止中', JSON.stringify(reply));
		assert.ok(h.page.startup);
		assert.deepEqual(runtimeButtons(h.page).slice(0, 2).map(disabled), [true, true]);
	}
	h.status = { state: 'stopped', since: 12 };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '启动中');
	assert.ok(h.page.startup);
	h.status = { state: 'starting', since: 13 };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '启动中');
	assert.equal(h.page.startup, null);
	h.status = { state: 'running', since: 14 };
	await h.page.fetchRefresh();
	assert.equal(h.page.vm.state_text, '运行中');
	assert.equal(h.timers.size, 0);
});

for (const state of ['starting', 'running', 'degraded', 'failsafe', 'error']) {
	test(`T10.48 scenario 3: a new ${state} since completes Restart even before service acknowledgement`, async () => {
		let finishService;
		const h = startupHarness({ service: () => new Promise(resolve => { finishService = resolve; }) });
		h.status = { state: 'running', since: 10 };
		h.page.refresh(h.status);
		const pending = h.page.handleService('restart');
		h.status = { state, since: 20, last_error: state === 'error' ? 'CONFIG_INVALID' : null };
		await h.clock.advance(2000);
		assert.equal(h.page.startup, null);
		assert.equal(h.page.vm.state_text, build(h.status).state_text);
		finishService({ ok: true });
		await pending;
		assert.equal(h.page.vm.state_text, build(h.status).state_text, 'late acknowledgement cannot restart waiting');
	});
}

test('T10.48 scenario 3: stopped before service acknowledgement already shows Starting', async () => {
	let finishService;
	const h = startupHarness({ service: () => new Promise(resolve => { finishService = resolve; }) });
	h.status = { state: 'running', since: 10 };
	h.page.refresh(h.status);
	const pending = h.page.handleService('restart');
	h.status = { state: 'stopping', since: 11 };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '停止中');
	h.status = { state: 'stopped', since: 12 };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '启动中', 'the old process is gone even before init returns');
	assert.ok(h.page.startup);
	finishService({ ok: true });
	await pending;
	assert.equal(h.page.vm.state_text, '启动中');
	h.events.dispatch('pagehide');
});

test('T10.48 scenario 3: acknowledged unknown status enters startup wait; failed reads do not reset its phase', async () => {
	const h = startupHarness();
	h.page.refresh({ state: 'running', since: 10 });
	await h.page.handleService('restart');
	h.status = { state: 'unknown' };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '启动中');
	h.status = { ok: false, code: 'TIMEOUT' };
	await h.clock.advance(2000);
	assert.equal(h.page.vm.state_text, '启动中');
	h.events.dispatch('pagehide');
	assert.equal(h.timers.size, 0);
});

test('T10.48 scenario 3: Restart never accepts the old running process and releases controls at 60 seconds', async () => {
	const h = startupHarness();
	h.status = { state: 'running', since: 10 };
	h.page.refresh(h.status);
	await h.page.handleService('restart');
	await h.clock.advance(59999);
	assert.equal(h.page.vm.state_text, '停止中');
	await h.clock.advance(1);
	assert.equal(h.page.vm.state_text, '启动没有完成，可到日志页查看原因');
	assert.equal(h.page.startup, null);
	assert.equal(runtimeButtons(h.page)[1].disabled, false);
	assert.equal(h.timers.size, 0);
});

test('T10.48 scenario 4: Stop reads stopping as the normal translated state, without a startup watcher', async () => {
	const h = startupHarness();
	h.page.refresh({ state: 'running', since: 10 });
	await runtimeButtons(h.page)[2].attrs.click();
	h.status = { state: 'stopping', since: 11 };
	await h.clock.advance(1500);
	assert.equal(h.page.vm.state_text, '停止中');
	assert.ok(!h.page.startup);
	assert.deepEqual(runtimeButtons(h.page).map(disabled), [true, true, true]);
	assert.deepEqual(h.calls.filter(([method]) => method === 'service'), [['service', { action: 'stop' }]]);
});

test('T10.52 scenario 1/6: error refresh reads warn events once and replaces the generic reason', async () => {
	const h = deferredPage('0');
	const { page, calls } = h;
	/* A previous switch floor must not remove the startup attempt, even when
	   daemon events share one-second timestamps. */
	page.reasonFloor = NOW;
	const root = page.render(await page.load());
	await Promise.resolve();
	await h.reply('status', { state: 'error', last_error: 'START_FAILED' });
	assert.ok(visibleText(root).includes('启动失败，详见日志页'), 'generic reason is safe while events are pending');
	await h.reply('stats', readings(1000, 0, 0, 0, 0));
	const eventCall = calls.find(call => call.method === 'events');
	assert.deepEqual(eventCall.params, {
		since: Math.floor(Date.now() / 1000) - 600,
		level: 'warn'
	});
	await h.reply('events', { ok: true, events: [
		{ code: 'PRECHECK_FAILED', level: 'error', ts: NOW - 2,
			args: { missing: ['conflict:ssr-plus'] } },
		{ code: 'START_FAILED', level: 'error', ts: NOW - 1,
			args: { step: 'precheck', detail: 'failed' } },
		{ code: 'START_RETRY', level: 'warn', ts: NOW,
			args: { attempt: 3, in_secs: 300 } }
	] });
	await page.initialRequest;
	assert.ok(visibleText(root).includes('检测到 ShadowSocksR Plus+ 正在运行，请先在它的页面停用，再启动。'));
	assert.equal(calls.filter(call => call.method === 'events').length, 1);
});

/* T10.62 (docs/10 r18): keep the older regression cases above, and exercise
   loading, retries and generation races with explicitly released replies. */
const RUNTIME_STATES = ['running', 'degraded', 'failsafe'];
const INACTIVE_STATES = ['starting', 'stopping', 'stopped', 'error'];

for (const state of [...RUNTIME_STATES, ...INACTIVE_STATES]) {
	test(`T10.62 scenario 1: ${state} gates probe result, age and address together`, () => {
		const visible = RUNTIME_STATES.includes(state);
		for (const ok of [true, false]) {
			for (const node_ip of ['203.0.113.10', undefined]) {
				const status = { state, node_ip, last_probe: { ok, latency_ms: 23, at: NOW - 30 } };
				const { page, root } = renderStatus(status);
				assert.equal(page.vm.node_ip, visible && node_ip ? node_ip : null);
				assert.equal(page.vm.node_address_text, visible && node_ip ? '节点地址 ' + node_ip : null);
				assert.equal(page.vm.probe_text, !visible ? null : ok ? '正常，23 ms' : '检测失败');
				assert.equal(!!page.vm.probe_since_text, visible);
				const right = nodeRow(root).children[1];
				assert.equal(visibleText(right).includes('节点地址'), visible && !!node_ip);
				assert.equal(findAll(right, 'small')[0].textContent !== '', visible);
				if (!visible) {
					assert.equal(right.children[0].textContent, '延迟：–');
					assert.doesNotMatch(visibleText(right), /正常|检测失败|秒前|分钟前/);
				}
			}
		}
	});
}

test('T10.62 scenario 2: manual success and failure disappear on leaving runtime states', async () => {
	for (const reply of [{ ok: true, latency_ms: 17 }, { ok: false, code: 'PROBE_TIMEOUT' }]) {
		const h = deferredPage('0');
		const { page } = h;
		const root = page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', { state: 'running', last_probe: { at: NOW } });
		await h.reply('probe_sites', SITES);
		const pending = page.handleProbe();
		await h.reply('probe_url', reply);
		await pending;
		for (const state of INACTIVE_STATES) {
			/* Reuse the same monitor timestamp: no generation change can hide
			   the missing state gate by accidentally clearing the manual result. */
			page.refresh({ state: 'running', last_probe: { at: NOW } });
			assert.match(page.vm.probe_text, /手动/);
			page.refresh({ state, node_ip: 'stale', last_probe: { at: NOW } });
			assert.equal(page.vm.probe_text, null);
			assert.equal(page.vm.probe_since_text, null);
			assert.doesNotMatch(visibleText(nodeRow(root)), /手动|节点地址|秒前/);
		}
	}
});

const TIMEOUT_REPLY = { ok: false, code: 'TIMEOUT', detail: 'busy device' };
const GOOD_INVENTORY = { ok: true, components: {
	xray: { found: true, version: 'r18-xray', path: '/usr/bin/xray' }
} };

test('T10.62 scenario 3: first TIMEOUT keeps loading; second success fills only components', async () => {
	const h = deferredPage('0');
	const { page, calls, writes } = h;
	const root = page.render(await page.load());
	await Promise.resolve();
	const request = page.componentRequest;
	writes.length = 0;
	await h.reply('components', TIMEOUT_REPLY);
	assert.equal(calls.filter(c => c.method === 'components').length, 2);
	assert.equal(page.componentRequest, request, 'retry belongs to the same generation');
	assert.equal(page.components, undefined);
	assert.deepEqual(componentCells(root), [
		['xray', '读取中…', '读取中…'], ['chinadns-ng', '读取中…', '读取中…']
	]);
	assert.equal(retryButtons(root).length, 0);
	assert.deepEqual(writes, [], 'first timeout never paints an error');
	await h.reply('components', GOOD_INVENTORY);
	await request;
	assert.equal(componentCells(root)[0][1], 'r18-xray');
	assert.deepEqual(writes, [page.componentContent]);
	assert.equal(page.componentRequest, null);
});

for (const failure of [TIMEOUT_REPLY, { ok: false, code: 'RPC_FAILED', detail: 'offline' },
	{ ok: false, code: 'USAGE' }, null]) {
	test(`T10.62 scenario 3: second ${failure?.code ?? 'null'} fails visibly; Retry gets a fresh budget`, async () => {
		const h = deferredPage('0');
		const { page, calls } = h;
		const root = page.render(await page.load());
		await Promise.resolve();
		await h.reply('components', TIMEOUT_REPLY);
		await h.reply('components', failure);
		assert.equal(calls.filter(c => c.method === 'components').length, 2);
		assert.equal(componentCells(root)[0][1], '读取失败');
		assert.equal(retryButtons(root).length, 1);
		assert.match(visibleText(page.componentContent), new RegExp(failure?.code ?? 'RPC_FAILED'));
		const request = retryButtons(root)[0].attrs.click();
		await Promise.resolve();
		await h.reply('components', TIMEOUT_REPLY);
		assert.equal(calls.filter(c => c.method === 'components').length, 4);
		assert.equal(componentCells(root)[0][1], '读取中…');
		await h.reply('components', GOOD_INVENTORY);
		await request;
		assert.equal(componentCells(root)[0][1], 'r18-xray');
		assert.equal(retryButtons(root).length, 0);
	});
}

test('T10.62 scenario 3: non-TIMEOUT initial failures are immediate and never auto-retried', async () => {
	for (const failure of [{ ok: false, code: 'RPC_FAILED' }, { ok: false, code: 'USAGE' }, null]) {
		const h = deferredPage('0');
		const root = h.page.render(await h.page.load());
		await Promise.resolve();
		await h.reply('components', failure);
		assert.equal(h.calls.filter(c => c.method === 'components').length, 1);
		assert.equal(componentCells(root)[0][1], '读取失败');
		assert.equal(retryButtons(root).length, 1);
	}
});

for (const oldRetry of [false, true]) {
	test(`T10.62 scenario 3: restart renews retry budget and discards old ${oldRetry ? 'retry' : 'first'} reply`,
		async () => {
		const h = deferredPage('0');
		const { page, calls } = h;
		const root = page.render(await page.load());
		await Promise.resolve();
		await h.reply('status', { state: 'running', since: 1 });
		await h.reply('stats', null);
		await page.initialRequest;
		if (oldRetry)
			await h.reply('components', TIMEOUT_REPLY);
		const oldRequest = page.componentRequest;
		const stale = calls.filter(c => c.method === 'components' && !c.settled).at(-1);
		const refresh = page.fetchRefresh();
		await h.reply('status', { state: 'running', since: 2 });
		const newRequest = page.componentRequest;
		assert.notEqual(newRequest, oldRequest);
		/* Target the new generation, not the older FIFO entry. */
		const first = calls.filter(c => c.method === 'components' && c !== stale).at(-1);
		first.settled = true;
		first.resolve(TIMEOUT_REPLY);
		for (let i = 0; i < 12; i++)
			await Promise.resolve();
		assert.equal(componentCells(root)[0][1], '读取中…');
		const count = calls.filter(c => c.method === 'components').length;
		stale.settled = true;
		stale.resolve(oldRetry ? GOOD_INVENTORY : TIMEOUT_REPLY);
		await oldRequest;
		assert.equal(page.componentRequest, newRequest, 'old finalizer cannot clear the new request');
		assert.equal(calls.filter(c => c.method === 'components').length, count, 'stale timeout cannot retry');
		assert.equal(componentCells(root)[0][1], '读取中…', 'stale success cannot replace loading');
		await h.reply('components', GOOD_INVENTORY);
		await newRequest;
		assert.equal(componentCells(root)[0][1], 'r18-xray');
		assert.equal(count, oldRetry ? 4 : 3, 'restart gets its own one-retry allowance');
		await h.reply('stats', null);
		await refresh;
	});
}

test('T10.62 scenario 4: real common queue sends sites/status/version/components in order with at most two',
	async t => {
	const sent = [];
	let inflight = 0, peak = 0;
	const ap = loadModule(path.join(RES, 'aether-proxy/common.js'), {
		baseclass: { extend: value => value }, ui: {},
		rpc: { declare: options => () => new Promise(resolve => {
			inflight++;
			peak = Math.max(peak, inflight);
			sent.push({ method: options.method, reply(value) {
				if (this.settled)
					return;
				this.settled = true;
				inflight--;
				resolve(value);
			} });
		}) }
	}, { window: {}, document: {} });
	/* Retain the production call/queue; only automatic polling is disabled. */
	ap.poll = () => ({ stop() {} });
	const page = loadView({ ap });
	await page.load();
	assert.equal(sent.length, 0, 'load never waits for sites');
	page.render({ labels: {}, enabled: true });
	assert.equal(sent.length, 0, 'render returns the skeleton before any RPC');
	const drain = async () => {
		for (let i = 0; i < 32; i++)
			await Promise.resolve();
	};
	/* Release production hard-timeout timers even when an order assertion fails. */
	t.after(async () => {
		for (let i = 0; i < 8; i++) {
			for (const call of sent)
				call.reply(null);
			await drain();
		}
	});
	await drain();
	assert.deepEqual(sent.map(c => c.method), ['probe_sites', 'status']);
	sent[0].reply(SITES);
	await drain();
	assert.deepEqual(sent.map(c => c.method), ['probe_sites', 'status', 'version']);
	assert.equal(page.probeSites.disabled, false, 'sites fill while status remains pending');
	sent[2].reply({ ok: true, version: 'r18' });
	await drain();
	assert.deepEqual(sent.map(c => c.method), ['probe_sites', 'status', 'version', 'components']);
	sent[3].reply(GOOD_INVENTORY);
	sent[1].reply({ state: 'running' });
	await drain();
	assert.equal(sent[4].method, 'stats');
	sent[4].reply(null);
	await Promise.all([page.initialRequest, page.sitesRequest, page.versionRequest, page.componentRequest]);
	assert.equal(inflight, 0);
	assert.equal(peak, 2);
});

/* T10.65 (docs/10 r19): inspect the actual column and its direct children,
   so empty detail wrappers or paragraph margins cannot masquerade as spacing. */
test('T10.65 scenario 1: runtime column uses one gap and omits absent details; detail texts are divs', () => {
	for (const [status, expected] of [
		[{ state: 'stopped' }, []],
		[{ state: 'error', last_error: 'CONFIG_INVALID' }, ['原因：配置无效，详见日志页']],
		[{ state: 'running', dns_tier: 'T1' }, ['境外域名解析：经节点解析（正常）']],
		[{ state: 'running', last_error: 'CONFIG_INVALID', dns_tier: 'T1' },
			['原因：配置无效，详见日志页', '境外域名解析：经节点解析（正常）']]
	]) {
		const { root } = renderStatus(status);
		const block = sections(root)[0];
		assert.equal(block.children.length, 2, 'only the heading and one column are in the section');
		const column = runtimeRows(root);
		assert.equal(column.tag, 'div');
		for (const rule of [/display:\s*flex/, /flex-direction:\s*column/, /align-items:\s*stretch/,
			/gap:\s*0\.75em(?:;|$)/])
			assert.match(column.attrs.style, rule);
		const rows = column.children;
		assert.equal(rows.length, expected.length ? 3 : 2, 'absent details do not consume another gap');
		assert.equal(rows[0].tag, 'div');
		assert.ok(findTag(rows[0], 'strong'));
		assert.deepEqual(findAll(rows[0], 'button').map(visibleText), ['启动', '重启', '停止']);
		assert.equal(rows.at(-1), nodeRow(root));
		assert.ok(findTag(rows.at(-1), 'select'));
		for (const row of rows)
			assert.doesNotMatch(row.attrs.style ?? '', /margin/);
		if (expected.length) {
			assert.deepEqual(rows[1].children.map(visibleText), expected);
			assert.ok(rows[1].children.every(child => child.tag === 'div'));
			assert.equal(findAll(rows[1], 'p').length, 0, 'theme paragraph margins never enter details');
			for (const child of rows[1].children)
				assert.doesNotMatch(child.attrs.style ?? '', /margin/);
		}
	}
});

test('T10.65 scenario 2: empty latency is labeled in both languages; runtime probe wording stays unchanged', t => {
	let chinese = false;
	t.mock.method(globalThis, '_', text => chinese ? (po[text] ?? text) : text);
	for (const language of [false, true]) {
		chinese = language;
		for (const state of INACTIVE_STATES) {
			const { root, page } = renderStatus({ state, node_ip: 'stale',
				last_probe: { ok: true, latency_ms: 23, at: NOW - 30 } });
			const result = nodeRow(root).children[1];
			assert.equal(result.children[0].textContent, chinese ? '延迟：–' : 'Latency: –', state);
			assert.equal(result.children[1].textContent, '', 'no stale probe age');
			assert.equal(page.vm.probe_text, null, 'the model still suppresses the old result');
			assert.doesNotMatch(visibleText(result), /stale|23/);
		}
		for (const state of RUNTIME_STATES) {
			for (const [last_probe, english, translated] of [
				[{ ok: true, latency_ms: 23 }, 'Healthy, 23 ms', '正常，23 ms'],
				[{ ok: false }, 'Probe failed', '检测失败'],
				[undefined, 'Not probed yet', '尚未检测']
			]) {
				const { root } = renderStatus({ state, last_probe });
				assert.equal(nodeRow(root).children[1].children[0].textContent,
					chinese ? translated : english, state);
			}
		}
	}
});

test('T10.65 scenario 3: the empty latency msgid is whole, contextual and has no edge whitespace', () => {
	const source = fs.readFileSync(VIEW, 'utf8');
	const latencyCall = /_\('([^']*Latency[^']*)', 'aether-proxy'\)/g;
	const ids = [...source.matchAll(latencyCall)].map(match => match[1]);
	assert.deepEqual(ids, ['Latency: –']);
	assert.equal(ids[0].trim(), ids[0]);
	assert.match(fs.readFileSync(PO, 'utf8'), /msgctxt "aether-proxy"\nmsgid "Latency: –"\nmsgstr "延迟：–"/);
});

/* T10.55: assert the rendered word, not just the model grade, so a missing
   busy color or stale stopped opacity cannot pass through a correct model. */
test('T10.55 scenarios 1/3: state words and scheme A colors reach the DOM; only stopped is dimmed', () => {
	for (const [state, text, level, color] of [
		['running', '运行中', 'ok', 'var(--success-color-high, #2f855a)'],
		['starting', '启动中', 'busy', 'var(--primary-color-high, #2b6cb0)'],
		['stopping', '停止中', 'busy', 'var(--primary-color-high, #2b6cb0)'],
		['degraded', '降级', 'warn', 'var(--warning-color, #b7791f)'],
		['failsafe', '故障放行', 'warn', 'var(--warning-color, #b7791f)'],
		['error', '启动失败', 'error', 'var(--error-color-high, #c53030)'],
		['stopped', '已停止', 'neutral', null],
		['future', 'future', 'neutral', null]
	]) {
		const { page, root } = renderStatus({ state });
		const word = findAll(root, 'strong')[0];
		assert.equal(word.textContent, text, state);
		assert.equal(page.vm.state_level, level, state);
		assert.equal(page.vm.state_dimmed, state === 'stopped', state);
		assert.equal(word.attrs.style.includes('color:'), color !== null, state);
		if (color)
			assert.ok(word.attrs.style.includes('color:' + color), state);
		assert.equal(/opacity:\s*0\.7\b/.test(word.attrs.style), state === 'stopped', state);
		/* Replacing a stopped render must remove its opacity, even for a
		   neutral unknown/pending/error result with no explicit color. */
		for (const status of [{ state: 'starting', waiting_network: true }, undefined, null]) {
			page.refresh({ state: 'stopped' });
			page.refresh(status);
			assert.equal(page.vm.state_dimmed, false);
			assert.doesNotMatch(findAll(root, 'strong')[0].attrs.style, /opacity/);
		}
	}
	const waiting = renderStatus({ state: 'starting', waiting_network: true });
	assert.equal(waiting.page.vm.state_text, '等待网络');
	assert.equal(waiting.page.vm.state_level, 'busy');
	assert.match(findAll(waiting.root, 'strong')[0].attrs.style, /var\(--primary-color-high, #2b6cb0\)/);
});

for (const action of ['start', 'restart', 'enable']) {
	test(`T10.55 scenarios 1/3: ${action} waiting uses the same blue undimmed state word`, async () => {
		const h = startupHarness();
		/* A stopped baseline catches inherited opacity during either wait. */
		if (action === 'enable') {
			h.page.enabled = false;
			await h.page.handleEnable(true);
			h.events.dispatch('uci-applied');
		}
		else
			await h.page.handleService(action);
		const word = findAll(h.page.runtimeContent, 'strong')[0];
		assert.equal(word.textContent, action === 'restart' ? '停止中' : '启动中');
		assert.equal(h.page.vm.state_level, 'busy');
		assert.match(word.attrs.style, /color:var\(--primary-color-high, #2b6cb0\)/);
		assert.doesNotMatch(word.attrs.style, /opacity/);
		assert.doesNotMatch(word.textContent, /正在|…/);
		h.events.dispatch('pagehide');
	});
}

/* T10.68 / docs/10 B19: runtime degradation is independent of the applied
 * default mode, so it must not lock selectors or look like a pending switch. */
const DEGRADED_NOTICE = '节点不可用，绕过大陆已临时按「仅代理被墙网站（GFW）」分流';
const DEGRADED_STATUS = {
	state: 'degraded', node_id: 'n_a', mode: 'bypass_cn',
	degraded_mode: 'gfw', degraded_since: NOW - 120
};

function degradedModel(status = DEGRADED_STATUS, mode = 'bypass_cn') {
	return dashboardModel().build(status, null, { n_a: 'Alpha', n_b: 'Beta' }, NOW,
		true, 'n_a', null, null, null, mode);
}

test('T10.68 scenario 1: degradation warning uses the mode label and its own duration buckets', () => {
	for (const [age, duration] of [[45, '45 秒'], [120, '2 分钟'], [7200, '2 小时'], [172800, '2 天']]) {
		const vm = degradedModel({ ...DEGRADED_STATUS, since: NOW - 900, degraded_since: NOW - age });
		assert.equal(vm.degradation_notice, DEGRADED_NOTICE + '（已持续 ' + duration + '）');
		assert.equal(vm.state_duration_text, '已持续 15 分钟', 'service and degradation clocks are independent');
	}
	for (const since of [undefined, null, '123', {}, false]) {
		const vm = degradedModel({ ...DEGRADED_STATUS, degraded_since: since });
		assert.equal(vm.degradation_notice, DEGRADED_NOTICE);
		assert.doesNotMatch(vm.degradation_notice, /已持续/);
	}
	// Only the documented override value is presented; unknown values stay silent (review).
	for (const other of ['global', 'bypass_cn', 'GFW', 1, true])
		assert.equal(degradedModel({ ...DEGRADED_STATUS, degraded_mode: other }).degradation_notice, null,
			JSON.stringify(other));
});

test('T10.68 scenario 1: null, old backend and failed status suppress the degradation warning', () => {
	const legacy = { ...DEGRADED_STATUS };
	delete legacy.degraded_mode;
	for (const status of [legacy, { ...DEGRADED_STATUS, degraded_mode: null },
		{ ...DEGRADED_STATUS, ok: false, code: 'TIMEOUT' }]) {
		assert.equal(degradedModel(status).degradation_notice, null);
		const { root } = renderStatus(status);
		assert.doesNotMatch(visibleText(root), /节点不可用，绕过大陆/);
	}
});

test('T10.68 scenario 1: view renders the warning on the state row with the DNS fallback warning color', () => {
	const { page, root } = renderStatus({ ...DEGRADED_STATUS, dns_failsafe: true });
	const row = runtimeRows(root).children[0];
	const warning = findAll(row, 'span').find(node => visibleText(node).startsWith(DEGRADED_NOTICE));
	const fallback = findAll(row, 'span').find(node => visibleText(node) === 'DNS 已回退到原配置');
	assert.ok(warning, 'warning is beside the state, not in a separate banner');
	assert.match(visibleText(warning), /已持续/);
	assert.equal(warning.attrs.style, fallback.attrs.style);
	assert.equal(warning.attrs.style, 'color:var(--warning-color, #b7791f)');
	page.refresh({ ...DEGRADED_STATUS, degraded_mode: null });
	assert.doesNotMatch(visibleText(root), /节点不可用，绕过大陆/);
});

test('T10.68 scenario 2: only applied versus configured mode controls switching during degradation', () => {
	for (const degraded_mode of ['gfw', null, undefined]) {
		const status = { ...DEGRADED_STATUS, degraded_mode };
		const same = degradedModel(status);
		assert.equal(same.switch_notice, null);
		assert.equal(same.switch_busy, false);
		assert.equal(same.current_mode, 'bypass_cn');
		assert.equal(same.current_node, 'n_a');
		const different = degradedModel(status, 'global');
		assert.equal(different.switch_notice, '正在切换默认模式到「全局（所有流量走代理）」…');
		assert.equal(different.switch_busy, true);
	}
});

test('T10.68 scenario 2: entering and leaving degradation preserve both selectors and user edits', () => {
	const page = loadView({ ap: { call: () => new Promise(() => {}) } });
	page.render({ labels: { n_a: 'Alpha', n_b: 'Beta' }, node: 'n_a', mode: 'bypass_cn', enabled: true });
	page.refresh({ ...DEGRADED_STATUS, degraded_mode: null });
	const [node, mode] = findAll(page.nodeControl, 'select');
	const apply = findAll(page.nodeControl, 'button')[0];
	assert.equal(node.value, 'n_a');
	assert.equal(mode.value, 'bypass_cn');
	assert.equal(apply.disabled, true);
	for (const degraded_mode of ['gfw', null]) {
		page.refresh({ ...DEGRADED_STATUS, degraded_mode });
		assert.equal(page.vm.switch_notice, null);
		assert.equal(node.disabled, false);
		assert.equal(mode.disabled, false);
		assert.equal(node.value, 'n_a');
		assert.equal(mode.value, 'bypass_cn');
		assert.equal(apply.disabled, true);
	}
	node.value = 'n_b';
	mode.value = 'global';
	mode.attrs.change();
	for (const degraded_mode of ['gfw', null]) {
		page.refresh({ ...DEGRADED_STATUS, degraded_mode });
		assert.equal(findAll(page.nodeControl, 'select')[0], node);
		assert.equal(findAll(page.nodeControl, 'select')[1], mode);
		assert.equal(node.value, 'n_b');
		assert.equal(mode.value, 'global');
		assert.equal(apply.disabled, false);
	}
});
