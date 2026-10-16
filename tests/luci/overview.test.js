'use strict';

/* Scenario tests 7-9 for the overview page (docs/tasks/m8.md T8.4).
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

function build(status, version, labels, now) {
	const model = loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });

	return model.build(status, version ?? { ok: true, version: '0.1.0-r2' }, labels ?? {}, now ?? NOW);
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
	assert.equal(vm.probe_text, tr('Healthy, %s ms.', 123));
	assert.equal(vm.probe_since_text, tr('%s seconds ago', 30));

	vm = build({ ok: true, state: 'running', last_probe: { ok: false, at: NOW - 90 } });
	assert.equal(vm.probe_text, tr('Probe failed.'));
	assert.equal(vm.probe_since_text, tr('%s minutes ago', 1));

	vm = build({ ok: true, state: 'running' });
	assert.equal(vm.probe_text, tr('Not probed yet.'));
	assert.equal(vm.probe_since_text, null);
});

test('scenario 7d: relative time buckets (seconds, minutes, hours, days)', () => {
	let vm = build({ ok: true, state: 'running', since: NOW - 45 });
	assert.equal(vm.state_since_text, tr('%s seconds ago', 45));

	vm = build({ ok: true, state: 'running', since: NOW - 150 });
	assert.equal(vm.state_since_text, tr('%s minutes ago', 2));

	vm = build({ ok: true, state: 'running', since: NOW - 7200 });
	assert.equal(vm.state_since_text, tr('%s hours ago', 2));

	vm = build({ ok: true, state: 'running', since: NOW - 3 * 86400 });
	assert.equal(vm.state_since_text, tr('%s days ago', 3));
});

test('scenario 7e: node shows the UCI label, falling back to the section name; dns tier and version', () => {
	let vm = build({ ok: true, state: 'running', node_id: 'n_ab', node_ip: '203.0.113.10', dns_tier: 'T1' }, null, { n_ab: 'My Node' });
	assert.equal(vm.node_text, 'My Node');
	assert.equal(vm.node_ip, '203.0.113.10');
	assert.equal(vm.dns_tier_text, 'T1');
	assert.equal(vm.own_version, '0.1.0-r2');

	vm = build({ ok: true, state: 'running', node_id: 'n_ab', node_ip: '203.0.113.10' }, null, {});
	assert.equal(vm.node_text, 'n_ab');

	vm = build({ ok: true, state: 'stopped', dns_tier: null }, { ok: false, code: 'RPC_FAILED' });
	assert.equal(vm.node_text, null);
	assert.equal(vm.dns_tier_text, null);
	assert.equal(vm.own_version, null);
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
});

test('scenario 9: static view checks — model only, stop button negative and confirmed, no business fields', () => {
	const src = fs.readFileSync(VIEW, 'utf8');

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
	assert.match(src, /}, 5000\)/);
	assert.match(src, /ap\.call\('service', \{ action: action \}\)/);
	assert.match(src, /ui\.addNotification\(/);
});
