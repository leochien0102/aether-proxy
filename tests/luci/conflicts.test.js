'use strict';

/* T10.52: startup-attempt pairing, shared conflict names, enabled notices and
 * PRECHECK_FAILED presentation. The daemon event order is asserted separately
 * so a model change cannot silently pair conflicts from an older attempt.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo } = require('./loader');

const ROOT = path.resolve(__dirname, '../..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const PO = path.join(APP, 'po/zh_Hans/aether-proxy.po');
const OVERVIEW = path.join(RES, 'aether-proxy/model/overview.js');
const LOGS = path.join(RES, 'aether-proxy/model/logs.js');
const CONFLICTS = path.join(RES, 'aether-proxy/model/conflicts.js');
const VIEW = path.join(RES, 'view/aether-proxy/overview.js');
const po = parsePo(fs.readFileSync(PO, 'utf8'));
globalThis._ = text => po[text] ?? text;

const baseclass = { extend: value => value };
const conflicts = loadModule(CONFLICTS, { baseclass }, {});
const logs = loadModule(LOGS, { baseclass, 'aether-proxy.model.conflicts': conflicts }, {});
const overview = loadModule(OVERVIEW, {
	baseclass,
	'aether-proxy.model.logs': logs,
	'aether-proxy.model.conflicts': conflicts
}, {});

const NOW = 1760400000;
const event = (code, args, ts = NOW) => ({ code, args, ts,
	level: code === 'START_RETRY' ? 'warn' : 'error' });

function attempt(missing, attemptNumber = 3, retryAt = NOW, inSecs = 300) {
	return [
		event('PRECHECK_FAILED', { missing }, retryAt - 2),
		event('START_FAILED', { step: 'precheck', detail: 'failed' }, retryAt - 1),
		event('START_RETRY', { attempt: attemptNumber, in_secs: inSecs }, retryAt)
	];
}

function build(events, now = NOW, status = {}) {
	return overview.build({ state: 'error', last_error: 'START_FAILED', ...status },
		{ ok: true, version: 'test' }, {}, now, true, null, null,
		events == null || events.ok === false ? events : { ok: true, events });
}

test('T10.52 scenario 1: current conflict and retry countdown use the paired daemon attempt', () => {
	const events = attempt(['conflict:ssr-plus']);
	assert.equal(build(events).error_text,
		'检测到 ShadowSocksR Plus+ 正在运行，请先在它的页面停用，再启动。'
		+ '将在约 300 秒后第 3 次重试。');
	assert.equal(build(events, NOW + 17).error_text,
		'检测到 ShadowSocksR Plus+ 正在运行，请先在它的页面停用，再启动。'
		+ '将在约 283 秒后第 3 次重试。');
	assert.equal(build(events, NOW + 300).error_text,
		'检测到 ShadowSocksR Plus+ 正在运行，请先在它的页面停用，再启动。'
		+ '即将第 3 次重试。');
});

test('T10.52 scenario 2: mixed precheck details are all shown and two plugins use plural wording', () => {
	const vm = build(attempt([
		'conflict:ssr-plus', 'conflict:passwall2',
		'conflict-check:nft list tables failed (2)', 'component:xray'
	]));
	assert.equal(vm.error_text,
		'检测到 ShadowSocksR Plus+、PassWall 2 正在运行，请先在它们的页面停用，再启动。'
		+ '无法检查其他代理插件：nft list tables failed (2)。'
		+ '启动前检查未通过：component:xray。将在约 300 秒后第 3 次重试。');
});

test('T10.52 scenario 2: an older conflict cannot leak into the latest attempt', () => {
	const events = [
		...attempt(['conflict:ssr-plus'], 1, NOW - 60, 30),
		...attempt(['component:xray'], 2, NOW, 60)
	];
	assert.equal(build(events).error_text,
		'启动前检查未通过：component:xray。将在约 60 秒后第 2 次重试。');
	assert.doesNotMatch(build(events).error_text, /ShadowSocksR/);
});

test('T10.52 scenario 2: a latest precheck failure without its own PRECHECK_FAILED stops at the previous retry', () => {
	/* Review addition: the START_RETRY boundary, not the nearest older precheck,
	   delimits the latest attempt. */
	const older = attempt(['conflict:ssr-plus'], 1, NOW - 60, 30);
	const events = [ ...older, event('START_FAILED', { step: 'precheck' }) ];
	assert.equal(build(events).error_text, '启动失败，详见日志页');
});

test('T10.52 scenario 2: non-precheck, absent and failed event reads keep the original wording', () => {
	const fallback = '启动失败，详见日志页';
	for (const events of [
		[],
		[event('START_FAILED', { step: 'render' })],
		[event('PRECHECK_FAILED', { missing: ['conflict:ssr-plus'] }),
			event('START_FAILED', { step: 'reload:precheck' })],
		{ ok: false, code: 'TIMEOUT' },
		null
	])
		assert.equal(build(events).error_text, fallback);
});

test('T10.52 scenario 3: all verified and standalone conflict names share one mapping', () => {
	assert.deepEqual(Object.fromEntries([
		'ssr-plus', 'passwall', 'passwall2', 'homeproxy', 'openclash', 'nikki', 'clash', 'mihomo', 'future'
	].map(name => [name, conflicts.display_name(name)])), {
		'ssr-plus': 'ShadowSocksR Plus+', passwall: 'PassWall', passwall2: 'PassWall 2',
		homeproxy: 'HomeProxy', openclash: 'OpenClash', nikki: 'Nikki',
		clash: 'clash', mihomo: 'mihomo', future: 'future'
	});
});

function notice(plugin, boot, configured) {
	return build([], NOW, { state: 'running', last_error: null,
		notices: [{ code: 'CONFLICT_ENABLED', args: { plugin, boot, configured } }] }).notices[0];
}

test('T10.52 scenario 4 / T10.55 scenario 4: CONFLICT_ENABLED ignores boot and advises only configured plugins', () => {
	const base = 'PassWall 没在运行，但仍处于启用状态，配置变化或重启路由器时可能被重新拉起，'
		+ '与 Aether Proxy 冲突。';
	const configured = '请在它的页面里停用。';
	assert.equal(notice('passwall', false, false), base);
	assert.equal(notice('passwall', true, false), base);
	assert.equal(notice('passwall', false, true), base + configured);
	assert.equal(notice('passwall', true, true), base + configured);
	for (const boot of [false, true])
		for (const enabled of [false, true])
			assert.doesNotMatch(notice('passwall', boot, enabled), /开机自启|启动项|Unhandled notice/);
	const notices = build([], NOW, { state: 'running', last_error: null, notices: [
		{ code: 'CONFLICT_ENABLED', args: { plugin: 'ssr-plus', boot: true, configured: false } },
		{ code: 'CONFLICT_ENABLED', args: { plugin: 'nikki', boot: false, configured: true } }
	] }).notices;
	assert.equal(notices.length, 2);
	assert.ok(notices[0].startsWith('ShadowSocksR Plus+'));
	assert.ok(notices[1].startsWith('Nikki'));
	assert.ok(notices.every(text => !text.includes('Unhandled notice')));
});

test('T10.52 scenario 5: PRECHECK_FAILED formats conflicts but preserves original hover args', () => {
	const args = { missing: [
		'conflict:ssr-plus', 'conflict:clash', 'conflict:future',
		'conflict-check:nft failed', 'component:xray'
	] };
	const item = event('PRECHECK_FAILED', args);
	assert.equal(logs.message(item),
		'预检失败：缺少 与 ShadowSocksR Plus+ 冲突、与 clash 冲突、与 future 冲突、'
		+ '无法检查其他代理插件（nft failed）、component:xray');
	const row = logs.events({ ok: true, events: [item] }).rows[0];
	assert.equal(row.text, logs.message(item));
	assert.equal(row.title, JSON.stringify(args));
});

test('T10.52 scenario 6: only error startup reads warn events; switch and startup share one call', async () => {
	const calls = [];
	const ap = { call: async (method, params) => { calls.push([method, params]); return { ok: true, events: [] }; } };
	const page = loadModule(VIEW, {
		view: { extend: value => value }, uci: {}, ui: {}, dom: {},
		'aether-proxy.common': ap,
		'aether-proxy.model.overview': overview
	}, { window: {}, document: {} });
	await page.diagnosticEvents({ state: 'running', node_id: 'n_a' }, 'n_a', 'bypass_cn');
	assert.deepEqual(calls, [], 'non-error matching status needs no events');
	await page.diagnosticEvents({ state: 'error', last_error: 'START_FAILED' }, 'n_a', 'bypass_cn');
	assert.deepEqual(calls, [['events', { since: Math.floor(Date.now() / 1000) - 600, level: 'warn' }]]);
	calls.length = 0;
	await page.diagnosticEvents({ state: 'running', node_id: 'n_a', mode: 'bypass_cn' }, 'n_b', 'bypass_cn');
	assert.equal(calls.length, 1);
	assert.equal(calls[0][1].level, 'error');

	const both = { ...overview, startup_events_needed: () => true, switch_pending: () => true };
	const shared = loadModule(VIEW, {
		view: { extend: value => value }, uci: {}, ui: {}, dom: {},
		'aether-proxy.common': ap,
		'aether-proxy.model.overview': both
	}, { window: {}, document: {} });
	calls.length = 0;
	await shared.diagnosticEvents({ state: 'error' }, 'n_b', 'global');
	assert.equal(calls.length, 1, 'combined reasons issue one events request');
	assert.equal(calls[0][1].level, 'warn');
});

test('T10.52 event pairing cites the backend append order and keeps one view events call site', () => {
	const daemon = fs.readFileSync(path.join(ROOT, 'aether-proxy/src/lib/daemon.uc'), 'utf8');
	const precheck = daemon.indexOf("log.event('error', 'PRECHECK_FAILED', { missing });");
	const failed = daemon.indexOf("log.event('error', 'START_FAILED', { step: result.step, detail: result.detail });");
	const retry = daemon.indexOf("log.event('warn', 'START_RETRY', { attempt, in_secs: delay });");
	assert.ok(precheck >= 0 && failed > precheck && retry > failed,
		'daemon appends PRECHECK_FAILED, START_FAILED, then START_RETRY');
	const source = fs.readFileSync(VIEW, 'utf8');
	assert.equal([...source.matchAll(/ap\.call\('events'/g)].length, 1);
});
