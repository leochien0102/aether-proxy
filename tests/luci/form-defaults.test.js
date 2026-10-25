'use strict';

/* T10.54 / docs/10 r16: first demonstrate the SDK Flag regression independently
 * of the application wrapper, then exercise real declarations across pages. */
const test = require('node:test');
const assert = require('node:assert/strict');
const { Flag } = require('./form-sdk');

test('T10.54 reproduction: SDK Flag saves both untouched DNS defaults', async () => {
	const calls = [];
	const section = { map: { config: 'aetherproxy', data: {
		get: () => undefined,
		set: (...args) => calls.push(['set', ...args]),
		unset: (...args) => calls.push(['unset', ...args])
	} } };
	for (const [field, fallback] of [['direct_dns_enabled', '0'], ['allow_china_fallback', '1']]) {
		const option = new Flag(section, field);
		option.default = fallback;
		option.rmempty = false;
		assert.equal(option.formvalue('dns'), fallback, 'untouched checkbox exposes the displayed value');
		await option.parse('dns');
	}
	assert.deepEqual(calls, [
		['set', 'aetherproxy', 'dns', 'direct_dns_enabled', '0'],
		['set', 'aetherproxy', 'dns', 'allow_china_fallback', '1']
	]);
});

const path = require('node:path');
const { loadModule } = require('./loader');
const { renderPage, RES } = require('./form-defaults-harness');
const adapter = loadModule(path.join(RES, 'aether-proxy/form-defaults.js'),
	{ baseclass: { extend: o => o } }, { window: {}, document: {} });
const pages = ['rules', 'updates', 'advanced', 'subscriptions', 'access', 'nodes'];

for (const page of pages) {
	for (const explicit of [false, true]) {
		test('T10.54 unchanged ' + page + ' with ' + (explicit ? 'explicit defaults' : 'absent defaults') +
			': every option parses without set/unset', async () => {
			const h = await renderPage(page, explicit);
			await h.parse();
			assert.deepEqual(h.calls, []);
		});
	}
	test('T10.54 gate detects one unwrapped option on ' + page, async () => {
		let omitted = false;
		const broken = { equal: adapter.equal, section(section, fallbacks, behaviors) {
			const candidate = section.children.find(o => o.default != null && !o.option.startsWith('_'));
			const remaining = section.children.filter(o => omitted || o !== candidate);
			adapter.section({ children: remaining }, fallbacks, behaviors);
			if (candidate)
				omitted = true;
		} };
		const h = await renderPage(page, false, broken);
		await h.parse();
		assert.equal(omitted, true);
		assert.throws(() => assert.deepEqual(h.calls, []), /Expected values to be strictly deep-equal/);
	});
}

test('T10.54 DNS absent and explicit Flags stay untouched with SDK parse', async () => {
	for (const explicit of [false, true]) {
		const h = await renderPage('rules', explicit);
		for (const field of ['direct_dns_enabled', 'allow_china_fallback']) {
			const o = h.options.find(o => o.option == field);
			assert.equal(o.formvalue('dns'), o.default);
			await o.parse('dns');
		}
		assert.deepEqual(h.calls, []);
	}
});

test('T10.54 mutation: directly calling original Flag parse breaks the no-write gate', async () => {
	const broken = { equal: adapter.equal, section(section, fallbacks, behaviors) {
		const original = new Map(section.children.map(o => [o, o.parse]));
		adapter.section(section, fallbacks, behaviors);
		for (const o of section.children)
			if (o instanceof Flag)
				o.parse = original.get(o);
	} };
	const h = await renderPage('rules', false, broken);
	await h.parse();
	assert.ok(h.calls.some(call => call[3] == 'direct_dns_enabled'));
	assert.ok(h.calls.some(call => call[3] == 'allow_china_fallback'));
	assert.throws(() => assert.deepEqual(h.calls, []), /Expected values to be strictly deep-equal/);
});

test('T10.54 changed Flag, Value and select delete defaults and write nondefaults', async () => {
	for (const [page, field, section, saved, fallback, other] of [
		['rules', 'allow_china_fallback', 'dns', '0', '1', '0'],
		['rules', 'dns_probe_domain', 'dns', 'old.example', 'www.google.com', 'new.example'],
		['rules', 'mode', 'main', 'global', 'bypass_cn', 'gfw'],
		['updates', 'data_minute', 'update', '12', '30', '15'],
		['advanced', 'timeout', 'probe', '10', '5', '6'],
		['subscriptions', 'interval_hours', 'sub', '12', '24', '72']
	]) {
		const h = await renderPage(page);
		const o = h.options.find(o => o.option == field && o.section.name == (section == 'probe' ? 'main' : section));
		const id = o.section.name;
		h.setSaved(section, field, saved);
		o.inputs[id] = fallback;
		await o.parse(id);
		assert.deepEqual(h.calls, [['unset', 'aetherproxy', section, field]], page + ': default deletes');
		h.calls.length = 0;
		h.setSaved(section, field, fallback);
		o.inputs[id] = other;
		await o.parse(id);
		assert.deepEqual(h.calls, [['set', 'aetherproxy', section, field, other]], page + ': override writes');
	}
});

test('T10.54 DNS lists show defaults, save unchanged without writes, delete defaults and write overrides', async () => {
	for (const field of ['china_dns', 'direct_dns', 'trust_dns']) {
		const h = await renderPage('rules');
		const o = h.options.find(o => o.option == field);
		assert.deepEqual(o.formvalue('dns'), o.default);
		await o.parse('dns');
		assert.deepEqual(h.calls, []);
		h.setSaved('dns', field, ['4.4.4.4']);
		await o.parse('dns');
		assert.deepEqual(h.calls, [['unset', 'aetherproxy', 'dns', field]]);
		h.calls.length = 0;
		o.formvalue = () => ['9.9.9.9'];
		await o.parse('dns');
		assert.deepEqual(h.calls, [['set', 'aetherproxy', 'dns', field, ['9.9.9.9']]]);
		h.calls.length = 0;
		o.formvalue = () => [];
		await assert.rejects(o.parse('dns'), /must not be empty|invalid input/);
		assert.deepEqual(h.calls, []);
	}
});

test('T10.54 optional channel list deletes its default, writes overrides and allows clearing', async () => {
	const h = await renderPage('updates');
	const o = h.options.find(o => o.option == 'channel_urls');
	h.setSaved('update', 'channel_urls', ['https://example.test/channel/']);
	o.inputs.update = [o.placeholder];
	await o.parse('update');
	assert.deepEqual(h.calls, [['unset', 'aetherproxy', 'update', 'channel_urls']]);
	h.calls.length = 0;
	o.inputs.update = ['https://other.test/channel/'];
	await o.parse('update');
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'update', 'channel_urls', ['https://other.test/channel/']]]);
	h.calls.length = 0;
	o.inputs.update = [];
	await o.parse('update');
	assert.deepEqual(h.calls, [['unset', 'aetherproxy', 'update', 'channel_urls']]);
});

test('T10.54 changed MAC still suggests a name but untouched unnamed hosts remain untouched', async () => {
	const h = await renderPage('access');
	h.view.candidates = [{ mac: 'aa:bb:cc:dd:ee:01', name: 'laptop' }];
	await h.parse();
	assert.deepEqual(h.calls, []);
	const modal = h.modal('host');
	modal.options.find(o => o.option == 'mac').inputs.host = ['aa:bb:cc:dd:ee:01'];
	await modal.parse();
	assert.deepEqual(h.options.find(o => o.option == 'mac').inputs.host, ['aa:bb:cc:dd:ee:ff']);
	assert.ok(h.calls.some(c => c[0] == 'set' && c[3] == 'name' && c[4] == 'laptop'));
	assert.ok(h.calls.some(c => c[0] == 'set' && c[3] == 'mac'));
});

test('T10.54 placeholder fallbacks use current UA and protocol, not a static hint', async () => {
	const subscriptions = await renderPage('subscriptions');
	const ua = subscriptions.options.find(o => o.option == 'user_agent' && o.section.name == 'sub');
	subscriptions.setSaved('sub', 'user_agent', 'custom');
	subscriptions.view.defaultUA = 'aether-proxy/new-version';
	ua.inputs.sub = subscriptions.view.defaultUA;
	await ua.parse('sub');
	assert.deepEqual(subscriptions.calls, [['unset', 'aetherproxy', 'sub', 'user_agent']]);
	for (const protocol of ['vmess', 'shadowsocks']) {
		const nodes = await renderPage('nodes');
		const method = nodes.options.find(o => o.option == (protocol == 'vmess' ? 'method_vmess' : 'method'));
		nodes.options.find(o => o.option == 'protocol').inputs.node = protocol;
		nodes.setSaved('node', 'method', 'old');
		method.inputs.node = 'auto';
		if (protocol == 'vmess') {
			await method.parse('node');
			assert.deepEqual(nodes.calls, [['unset', 'aetherproxy', 'node', 'method']]);
		}
		else {
			await assert.rejects(method.parse('node'), /invalid input value/);
			assert.deepEqual(nodes.calls, [], 'SS cannot save the VMess auto method');
		}
	}
});

test('T10.54 single-item UCI list scalars do not count as edits', async () => {
	const h = await renderPage('rules');
	const o = h.options.find(o => o.option == 'direct_dns');
	h.setSaved('dns', 'direct_dns', 'tcp://9.9.9.9');
	await o.parse('dns');
	assert.deepEqual(h.calls, []);
});

test('T10.54 trusted DNS TCP aliases preserve both default and nondefault explicit configuration', async () => {
	for (const addresses of [['8.8.8.8', '1.1.1.1'], ['9.9.9.9']]) {
		const h = await renderPage('rules');
		const o = h.options.find(o => o.option == 'trust_dns');
		h.setSaved('dns', 'trust_dns', addresses.map(ip => 'tcp://' + ip));
		o.formvalue = () => addresses;
		await o.parse('dns');
		assert.deepEqual(h.calls, []);
	}
});

test('T10.54 scalar and array MACs cannot autofill an untouched unnamed host', async () => {
	for (const saved of ['aa:bb:cc:dd:ee:ff', ['aa:bb:cc:dd:ee:ff']]) {
		const h = await renderPage('access');
		h.setSaved('host', 'mac', saved);
		h.view.candidates = [{ mac: 'aa:bb:cc:dd:ee:ff', name: 'laptop' }];
		const modal = h.modal('host');
		await modal.parse();
		assert.deepEqual(h.calls, []);
	}
});

test('T10.54 entering an absent placeholder fallback is still the current effective value', async () => {
	const h = await renderPage('updates');
	const hour = h.options.find(o => o.option == 'data_hour');
	hour.inputs.update = '4';
	await hour.parse('update');
	assert.deepEqual(h.calls, []);
});

test('T10.54 cloned access modal clears conflicting game mode when changing to Direct', async () => {
	const h = await renderPage('access');
	h.setSaved('host', 'policy', 'proxy');
	h.setSaved('host', 'udp', '1');
	const modal = h.modal('host');
	modal.options.find(o => o.option == 'policy').inputs.host = 'direct';
	modal.options.find(o => o.option == 'udp').inputs.host = '1';
	assert.deepEqual(h.view.validateModal(modal.map).errors, [], 'precheck permits the safe cleaned configuration');
	await modal.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'host', 'policy', 'direct'],
		['unset', 'aetherproxy', 'host', 'udp']]);
});

test('T10.54 cloned node modal clears Mux when selecting Vision but retains inactive transport values', async () => {
	const h = await renderPage('nodes');
	h.setSaved('node', 'mux', '1');
	h.setSaved('node', 'ws_heartbeat', '20');
	const modal = h.modal('node');
	modal.options.find(o => o.option == 'flow').inputs.node = 'xtls-rprx-vision';
	modal.options.find(o => o.option == 'mux').inputs.node = '1';
	await modal.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'node', 'flow', 'xtls-rprx-vision'],
		['unset', 'aetherproxy', 'node', 'mux']]);
	assert.equal(modal.options.find(o => o.option == 'ws_heartbeat').cfgvalue('node'), '20');
});

test('T10.54 inactive node fields retain explicit values and invalid unchanged input is rejected', async () => {
	const h = await renderPage('nodes');
	const o = h.options.find(o => o.option == 'xhttp_extra');
	h.setSaved('node', 'xhttp_extra', 'not-json');
	o.inputs.node = 'not-json';
	o.active = false;
	await o.parse('node');
	assert.deepEqual(h.calls, []);
	o.active = true;
	await assert.rejects(o.parse('node'), /invalid input/);
	assert.deepEqual(h.calls, []);
});

/* Review additions (design lead, 2026-10-24; option A agreed with the backend). */
test('T10.54 review: VLESS+Vision changed to Trojan deletes the hidden flow, so Mux can be enabled', async () => {
	const h = await renderPage('nodes');
	h.setSaved('node', 'protocol', 'vless');
	h.setSaved('node', 'flow', 'xtls-rprx-vision');
	const modal = h.modal('node');
	const option = key => modal.options.find(o => o.option == key);
	option('protocol').inputs.node = 'trojan';
	option('mux').inputs.node = '1';
	assert.equal(option('flow').isActive('node'), false, 'flow is VLESS-only');
	assert.equal(option('mux').isActive('node'), true, 'a hidden flow counts as no value (SDK)');
	assert.equal(option('mux').validate('node', '1'), true, 'a hidden Vision flow cannot block Mux');
	await modal.parse();
	assert.ok(h.calls.some(c => c[0] == 'unset' && c[3] == 'flow'), 'hidden conflicting flow is deleted');
	assert.ok(h.calls.some(c => c[0] == 'set' && c[3] == 'mux' && c[4] == '1'));
});

test('T10.54 review: an active Vision flow still blocks Mux', async () => {
	const h = await renderPage('nodes');
	h.setSaved('node', 'protocol', 'vless');
	const modal = h.modal('node');
	const option = key => modal.options.find(o => o.option == key);
	option('protocol').inputs.node = 'vless';
	option('flow').inputs.node = 'xtls-rprx-vision';
	assert.notEqual(option('mux').validate('node', '1'), true);
});

test('T10.54 review: reordering a list is a change and is written', async () => {
	const h = await renderPage('rules');
	h.setSaved('dns', 'china_dns', [ '223.5.5.5', '114.114.114.114' ]);
	const o = h.options.find(o => o.option == 'china_dns');
	o.inputs.dns = [ '114.114.114.114', '223.5.5.5' ];
	await o.parse('dns');
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'dns', 'china_dns', [ '114.114.114.114', '223.5.5.5' ]]]);
});
