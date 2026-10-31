'use strict';

// T11.1: use the real model/view with cloned modal fields and unsaved protocol changes.
const test = require('node:test');
const assert = require('node:assert/strict');
const { harness } = require('./required-modal');
globalThis._ = text => text;
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
const base = { protocol: 'socks', address: 'edge.example', port: '1080' };

test('T11.1 SOCKS protocol name and modal credential fields', async () => {
	const h = await harness('node', base);
	assert.equal(h.model.build([{ '.name': 'row', ...base }]).rows[0].protocol, 'SOCKS');
	assert.ok(h.option('protocol').input.children.some(o => o.value === 'socks'));
	for (const field of ['address', 'port', 'username', 'password'])
		assert.equal(h.option(field).isActive('row'), true, field);
	assert.ok(h.model.node_fields.includes('username'));
});

for (const auth of [{}, { username: 'alice', password: 'test-secret' }])
	test('T11.1 SOCKS modal accepts ' + (auth.username ? 'auth' : 'no auth'), async () => {
		const h = await harness('node', { ...base, ...auth });
		await h.save();
		assert.equal(h.open, false);
	});

for (const missing of ['username', 'password'])
	test('T11.1 SOCKS modal rejects missing ' + missing + ' before writes', async () => {
		const auth = { username: 'alice', password: 'test-secret' };
		delete auth[missing];
		const h = await harness('node', { ...base, ...auth });
		await h.save();
		assert.equal(h.open, true);
		assert.deepEqual(h.calls, []);
		assert.ok(h.modal.root.querySelectorAll('.alert-message').length);
		assert.equal(h.option(missing).input.style.borderColor, 'var(--error-color-high, #c53030)');
	});

test('T11.1 switching protocols keeps inactive username and old credentials', async () => {
	const h = await harness('node', { ...base, username: 'alice', password: 'test-secret', uuid: 'old-id' });
	h.set('protocol', 'vmess');
	assert.equal(h.option('username').isActive('row'), false);
	assert.equal(h.option('password').isActive('row'), false);
	await h.save();
	assert.equal(h.open, false);
	assert.equal(h.data.row.username, 'alice');
	assert.equal(h.data.row.password, 'test-secret');
	assert.equal(h.data.row.uuid, 'old-id');
});
