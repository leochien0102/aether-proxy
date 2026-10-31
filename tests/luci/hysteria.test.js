'use strict';

// T11.8: actual cloned modal validation, fixed layers and retained inactive settings.
const test = require('node:test');
const assert = require('node:assert/strict');
const { harness } = require('./required-modal');
globalThis._ = text => text;
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
const base = {
	protocol: 'hysteria', address: '192.0.2.1', port: '443', hysteria_auth: 'credential-sentinel'
};

test('T11.8 Hysteria protocol, auth and TLS controls; inactive transport/Mux', async () => {
	const h = await harness('node', { ...base, transport: 'ws', security: 'reality', mux: '1',
		flow: 'xtls-rprx-vision', path: '/old', header_type: 'http', mux_concurrency: '8' });
	assert.equal(h.model.build([{ '.name': 'row', ...base }]).rows[0].protocol, 'Hysteria');
	assert.ok(h.option('protocol').input.children.some(o => o.value === 'hysteria'));
	for (const field of ['address', 'port', 'hysteria_auth', 'hysteria_udp_idle_timeout',
		'sni', 'alpn', 'fingerprint', 'pinned_cert_sha256', 'verify_name'])
		assert.equal(h.option(field).isActive('row'), true, field);
	for (const field of ['transport', 'security', 'host', 'path', 'header_type', 'mux',
		'mux_concurrency', 'mux_xudp_concurrency', 'mux_xudp_udp443', 'tcp_fast_open', 'tcp_mptcp'])
		assert.equal(h.option(field).isActive('row'), false, field);
	assert.equal(h.option('hysteria_auth').password, true);
	await h.save();
	assert.equal(h.open, false);
	assert.equal(h.data.row.transport, 'hysteria');
	assert.equal(h.data.row.security, 'tls');
	assert.equal(h.data.row.mux, '1');
	assert.equal(h.data.row.flow, 'xtls-rprx-vision');
	assert.equal(h.data.row.path, '/old');
	assert.equal(h.data.row.header_type, 'http');
	assert.equal(h.data.row.mux_concurrency, '8');
});

test('T11.8 minimal defaults save without materializing defaults', async () => {
	const h = await harness('node', base);
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(h.calls, []);
});

for (const patch of [{ hysteria_auth: '' }, { hysteria_udp_idle_timeout: '1' },
	{ hysteria_udp_idle_timeout: '601' }, { hysteria_udp_idle_timeout: '2.5' }])
	test('T11.8 invalid modal ' + JSON.stringify(patch), async () => {
		const h = await harness('node', { ...base, ...patch });
		await h.save();
		assert.equal(h.open, true);
		assert.deepEqual(h.calls, []);
		assert.equal(h.modal.root.textContent.includes('credential-sentinel'), false);
	});

for (const value of ['2', '600'])
	test('T11.8 timeout boundary ' + value, async () => {
		const h = await harness('node', { ...base, hysteria_udp_idle_timeout: value });
		await h.save();
		assert.equal(h.open, false);
	});

test('T11.8 switching away retains auth, timeout and old Mux', async () => {
	const h = await harness('node', { ...base, hysteria_udp_idle_timeout: '60', mux: '1', uuid: 'old-id' });
	h.set('protocol', 'vmess');
	await h.save();
	assert.equal(h.open, false);
	assert.equal(h.data.row.hysteria_auth, base.hysteria_auth);
	assert.equal(h.data.row.hysteria_udp_idle_timeout, '60');
	assert.equal(h.data.row.mux, '1');
});

test('T11.8 live switch requires auth before any writes, then saves fixed layers', async () => {
	const h = await harness('node', {
		protocol: 'vmess', address: '192.0.2.1', port: '443', uuid: 'old-id', transport: 'ws', security: 'none'
	});
	h.set('protocol', 'hysteria');
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
	h.set('hysteria_auth', base.hysteria_auth);
	await h.save();
	assert.equal(h.open, false);
	assert.equal(h.data.row.transport, 'hysteria');
	assert.equal(h.data.row.security, 'tls');
	assert.equal(h.data.row.uuid, 'old-id');
});
