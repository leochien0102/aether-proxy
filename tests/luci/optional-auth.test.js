'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { renderPage } = require('./form-defaults-harness');
const old = { socks_username: 'fixture-a', socks_password: 'fixture-b',
	http_username: 'fixture-c', http_password: 'fixture-d' };
const make = main => renderPage('advanced', false, undefined, { data: { main } });
const get = (h, key) => h.options.find(o => o.option === key);
const input = (h, key, value) => { get(h, key).inputs.main = value; };
const staged = h => {
	const result = { ...h.data.main };
	for (const [op, config, section, key, value] of h.calls) {
		if (section !== 'main') continue;
		if (op === 'set') result[key] = value;
		else if (op === 'unset') delete result[key];
	}
	return result;
};
function clear(h) {
	for (const key of ['proxy_username', 'proxy_password', '_proxy_credential_source']) {
		const o = get(h, key);
		if (!o) continue;
		o.getUIElement = () => ({ setValue: value => input(h, key, value) });
		o.triggerValidation = () => {};
	}
	const button = get(h, '_proxy_clear_credentials').renderWidget();
	assert.equal(button.attrs.type, 'button');
	button.attrs.click();
}

test('T16.117: fresh off plus new complete credentials persists 0 and reopens off', async () => {
	const h = await make({});
	input(h, 'proxy_username', 'fixture-new-user'); input(h, 'proxy_password', 'fixture-new-secret');
	await h.parse();
	const saved = staged(h);
	assert.equal(saved.proxy_auth_enabled, '0');
	assert.equal(saved.proxy_username, 'fixture-new-user');
	assert.equal(saved.proxy_password, 'fixture-new-secret');
	const reopened = await make(saved);
	assert.equal(get(reopened, 'proxy_auth_enabled').formvalue('main'), '0');
});

test('T16.117: clear then choose a legacy source respects the last choice', async () => {
	for (const source of ['socks', 'http']) {
		const h = await make(old);
		clear(h); input(h, '_proxy_credential_source', source);
		await h.parse();
		const saved = staged(h);
		assert.equal(saved.proxy_auth_enabled, '1');
		assert.equal(saved.proxy_username, old[source + '_username']);
		assert.equal(saved.proxy_password, old[source + '_password']);
		assert.ok(Object.keys(old).every(k => !(k in saved)));
	}
});

test('T16.117: default auth off; explicit on requires both fields even with listeners off', async () => {
	for (const enabled of ['0', '1']) {
		const h = await make({ socks_enabled: enabled, http_enabled: enabled });
		assert.equal(get(h, 'proxy_auth_enabled').formvalue('main'), '0');
		await h.parse(); assert.deepEqual(h.calls, []);
		input(h, 'proxy_auth_enabled', '1');
		await assert.rejects(h.parse(), /Authentication requires both/);
		assert.deepEqual(h.calls, []);
		input(h, 'proxy_username', 'fixture-user');
		await assert.rejects(h.parse(), /Authentication requires both/);
		assert.deepEqual(h.calls, []);
		input(h, 'proxy_password', 'fixture-secret');
		await h.parse();
		assert.equal(staged(h).proxy_auth_enabled, '1');
	}
});

test('T16.117: button clears only form, never auth or storage; failed save/reset preserve legacy conflict', async () => {
	const h = await make(old);
	assert.equal(get(h, 'proxy_auth_enabled').formvalue('main'), '1');
	clear(h);
	assert.equal(get(h, 'proxy_auth_enabled').formvalue('main'), '1');
	assert.deepEqual(h.calls, []);
	await assert.rejects(h.parse(), /Authentication requires both/);
	assert.deepEqual(h.calls, []); assert.deepEqual(h.data.main, old);
	const reset = await make(old);
	assert.equal(get(reset, 'proxy_auth_enabled').formvalue('main'), '1');
	await assert.rejects(reset.parse(), /Legacy proxy credentials/);
	assert.deepEqual(reset.calls, []);
	input(h, 'proxy_auth_enabled', '0'); input(h, 'timeout', '31');
	await assert.rejects(h.parse()); assert.deepEqual(h.calls, []);
	input(h, 'timeout', ''); await h.parse();
	const saved = staged(h);
	assert.equal(saved.proxy_auth_enabled, '0');
	assert.ok(Object.keys(old).every(k => !(k in saved)));
	const reopened = await make(saved);
	assert.equal(get(reopened, 'proxy_auth_enabled').formvalue('main'), '0');
	assert.equal(get(reopened, 'proxy_username').formvalue('main'), '');
	assert.equal(get(reopened, 'proxy_password').formvalue('main'), '');
});

test('T16.117: native Map.reset redraw without load cancels clear intent before saving auth off', async () => {
	const h = await make(old);
	const map = h.sections[0].map;
	let redraws = 0;
	map.renderContents = () => {
		redraws++;
		for (const o of h.options)
			o.inputs.main = o.cfgvalue('main') ?? o.default ?? '';
		return Promise.resolve();
	};
	clear(h);
	await assert.rejects(h.parse(), /Authentication requires both/);
	assert.deepEqual(h.calls, []);
	await map.reset();
	assert.equal(redraws, 1, 'native reset redraws without load');
	await assert.rejects(h.parse(), /Legacy proxy credentials/);
	assert.deepEqual(h.calls, []);
	input(h, 'proxy_auth_enabled', '0'); await h.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'proxy_auth_enabled', '0']]);
	assert.deepEqual(Object.fromEntries(Object.keys(old).map(k => [k, staged(h)[k]])), old);
});

test('T16.117: explicit off retains unedited legacy conflict but suppresses migration inference', async () => {
	const h = await make(old);
	input(h, 'proxy_auth_enabled', '0'); await h.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'proxy_auth_enabled', '0']]);
	const reopened = await make(staged(h));
	assert.equal(get(reopened, 'proxy_auth_enabled').formvalue('main'), '0');
	assert.deepEqual(Object.fromEntries(Object.keys(old).map(k => [k, reopened.data.main[k]])), old);
});
