'use strict';

// T11.3: actual cloned modal options, required/format preflight and retained old values.
const test = require('node:test');
const assert = require('node:assert/strict');
const { harness } = require('./required-modal');
globalThis._ = text => text;
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
const key = Buffer.alloc(32, 1).toString('base64');
const base = { protocol: 'wireguard', address: 'wg.example', port: '51820',
	secret_key: key, peer_public_key: key, local_address: ['10.7.0.2/24'] };

test('T11.3 WireGuard protocol and protocol-specific modal options', async () => {
	const h = await harness('node', base);
	assert.equal(h.model.build([{ '.name': 'row', ...base }]).rows[0].protocol, 'WireGuard');
	assert.ok(h.option('protocol').input.children.some(o => o.value === 'wireguard'));
	for (const field of ['address', 'port', 'secret_key', 'peer_public_key', 'local_address', 'preshared_key', 'keepalive'])
		assert.equal(h.option(field).isActive('row'), true, field);
	for (const field of ['transport', 'security', 'mux', 'tcp_fast_open', 'tcp_mptcp'])
		assert.equal(h.option(field).isActive('row'), false, field);
	assert.equal(h.option('secret_key').password, true);
	assert.equal(h.option('preshared_key').password, true);
});
for (const field of ['secret_key', 'peer_public_key', 'local_address'])
	test('T11.3 missing ' + field + ' blocks modal before writes', async () => {
		const data = { ...base };
		delete data[field];
		const h = await harness('node', data);
		await h.save();
		assert.equal(h.open, true);
		assert.deepEqual(h.calls, []);
		assert.equal(h.modal.root.textContent.includes(key), false);
	});
for (const field of ['secret_key', 'peer_public_key', 'preshared_key'])
	test('T11.3 malformed ' + field + ' blocks modal without credential detail', async () => {
		const h = await harness('node', { ...base, [field]: 'credential-sentinel' });
		await h.save();
		assert.equal(h.open, true);
		assert.deepEqual(h.calls, []);
		assert.equal(h.modal.root.textContent.includes('credential-sentinel'), false);
	});
test('T11.3 valid PSK and keepalive zero save; switching keeps WireGuard and legacy values', async () => {
	const h = await harness('node', { ...base, preshared_key: key, keepalive: '0',
		transport: 'ws', security: 'tls', mux: '1', password: 'old-secret', uuid: 'old-id' });
	await h.save();
	assert.equal(h.open, false);
	assert.equal(h.data.row.mux, '1', 'WireGuard must not delete inactive Mux');
	assert.deepEqual(h.calls, [], 'opening and saving existing valid values must not write defaults');
	const switched = await harness('node', { ...h.data.row });
	switched.set('protocol', 'vmess');
	assert.equal(switched.option('secret_key').isActive('row'), false);
	await switched.save();
	assert.equal(switched.open, false);
	assert.equal(switched.data.row.secret_key, key);
	assert.equal(switched.data.row.preshared_key, key);
	assert.equal(switched.data.row.keepalive, '0');
	assert.equal(switched.data.row.password, 'old-secret');
	assert.equal(switched.data.row.transport, 'ws');
});
for (const keepalive of ['-1', '65536', '1.5'])
	test('T11.3 invalid keepalive ' + keepalive + ' blocks modal before writes', async () => {
		const h = await harness('node', { ...base, keepalive });
		await h.save();
		assert.equal(h.open, true);
		assert.deepEqual(h.calls, []);
	});
test('T11.3 live switch validates new required keys', async () => {
	const h = await harness('node', { protocol: 'vmess', address: 'wg.example', port: '51820', uuid: 'old-id' });
	h.set('protocol', 'wireguard');
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
});

test('T11.3 key and tunnel-address format boundaries', async () => {
	const h = await harness('node', base);
	for (const value of ['', key, Buffer.alloc(32).toString('base64')])
		assert.equal(h.model.validate_wireguard_key('row', value), true);
	for (const value of [key.trimEnd() + '\n', key.slice(0, -1), 'A'.repeat(44), '/'.repeat(43) + '='])
		assert.notEqual(h.model.validate_wireguard_key('row', value), true);
	for (const value of ['', '10.0.0.2', '10.0.0.2/24', '0.0.0.0/0'])
		assert.equal(h.model.validate_local_address('row', value), true);
	for (const value of ['::1', '10.0.0.2/33', '10.0.0.256', '10.0.0.2/-1'])
		assert.notEqual(h.model.validate_local_address('row', value), true);
});
