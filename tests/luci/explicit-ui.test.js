'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { renderPage, RES } = require('./form-defaults-harness');
const { loadModule } = require('./loader');
const model = () => loadModule(path.join(RES, 'aether-proxy/model/advanced.js'),
	{ baseclass: { extend: o => o } }, { window: {}, document: {} });
const get = (h, field) => h.options.find(o => o.option === field);
const input = (h, field, value) => { get(h, field).inputs.main = value; };
const shared = { proxy_username: 'fixture-shared-user', proxy_password: 'fixture-shared-secret' };
const legacy = { socks_username: 'fixture-socks-user', socks_password: 'fixture-socks-secret', socks_listen: '192.0.2.2',
	http_username: 'fixture-http-user', http_password: 'fixture-http-secret', http_listen: '192.0.2.3' };
const page = (main = {}, status) => renderPage('advanced', false, undefined, { data: { main }, status });
const credentials = h => h.calls.filter(c => /^(proxy_(username|password)|(socks|http)_(username|password|listen))$/.test(c[3]));

test('explicit UI: default listeners and authentication off, unrelated save does not backfill', async () => {
	const h = await page(); await h.parse(); assert.deepEqual(h.calls, []);
	assert.equal(get(h, 'proxy_auth_enabled').formvalue('main'), '0');
	assert.equal(get(h, 'socks_port').default, '1080'); assert.equal(get(h, 'http_port').default, '8080');
	assert.equal(get(h, 'proxy_address'), undefined);
	assert.match(get(h, '_proxy_lan').cfgvalue('main'), /lan.*192\.0\.2\.1/);
	input(h, 'log_level', 'debug'); await h.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'log_level', 'debug']]);
	for (const method of ['handleReset', 'handleSave', 'handleSaveApply']) assert.equal(h.view[method], undefined);
});

test('explicit UI: listener changes preserve shared authentication and credentials', async () => {
	for (const protocol of ['socks', 'http']) for (const enabled of ['0', '1']) {
		const h = await page({ ...shared, proxy_auth_enabled: '1', [protocol + '_enabled']: enabled });
		input(h, protocol + '_enabled', enabled === '0' ? '1' : '0'); await h.parse();
		assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', protocol + '_enabled', enabled === '0' ? '1' : '0']]);
	}
});

test('explicit UI: LAN lookup failures still gate listeners, not authentication settings', async () => {
	for (const status of [{}, { explicit_lan: { addresses: [] } }, async () => { throw new Error('fixture'); }]) {
		const h = await page({ ...shared, proxy_auth_enabled: '1' }, status);
		input(h, 'log_level', 'debug'); await h.parse(); h.calls.length = 0;
		input(h, 'socks_enabled', '1');
		await assert.rejects(h.parse(), /No usable IPv4/); assert.deepEqual(h.calls, []);
	}
});

test('explicit UI: exact multi-address selection, stale selection and port conflict rules unchanged', async () => {
	const h = await page({ socks_enabled: '1', http_enabled: '1' }, { explicit_lan: { interface: 'lan', addresses: ['192.0.2.4', '198.51.100.9'] } });
	assert.deepEqual(get(h, 'proxy_address').keylist, ['', '192.0.2.4', '198.51.100.9']);
	for (const value of ['', '0.0.0.0', '192.0.2.99']) {
		input(h, 'proxy_address', value); await assert.rejects(h.parse(), /Select one of/); assert.deepEqual(h.calls, []);
	}
	input(h, 'proxy_address', '192.0.2.4'); input(h, 'socks_port', '8080');
	await assert.rejects(h.parse(), /Port conflicts/); assert.deepEqual(h.calls, []);
});

test('explicit UI: compatible old credentials infer authentication on and migrate on valid save only', async () => {
	for (const old of [shared, { socks_username: shared.proxy_username, socks_password: shared.proxy_password },
		{ http_username: shared.proxy_username, http_password: shared.proxy_password }]) {
		const h = await page(old);
		assert.equal(get(h, 'proxy_auth_enabled').formvalue('main'), '1');
		assert.equal(get(h, 'proxy_password').formvalue('main'), shared.proxy_password);
		assert.equal(get(h, 'proxy_password').password, true); assert.deepEqual(h.calls, []);
		await h.parse();
		assert.ok(h.calls.some(c => c[0] === 'set' && c[3] === 'proxy_auth_enabled' && c[4] === '1'));
		if (!old.proxy_username) assert.equal(credentials(h).filter(c => c[0] === 'set').length, 2);
	}
});

test('explicit UI: conflicts remain fail closed with listeners off; old-source selection is whole-pair', async () => {
	for (const source of ['socks', 'http', '']) {
		const h = await page(legacy);
		assert.deepEqual(get(h, '_proxy_credential_source').keylist, ['', 'socks', 'http']);
		await assert.rejects(h.parse(), /Legacy proxy credentials/); assert.deepEqual(h.calls, []);
		if (source) input(h, '_proxy_credential_source', source);
		else { input(h, 'proxy_username', shared.proxy_username); input(h, 'proxy_password', shared.proxy_password); }
		await h.parse();
		assert.deepEqual(credentials(h).filter(c => c[0] === 'set').map(c => c[4]),
			source ? [legacy[source + '_username'], legacy[source + '_password']] : [shared.proxy_username, shared.proxy_password]);
		assert.equal(credentials(h).filter(c => c[0] === 'unset').length, Object.keys(legacy).length);
	}
});

test('explicit UI: partial replacements and other-tab failures never modify original credentials', async () => {
	for (const field of ['proxy_username', 'proxy_password']) {
		const h = await page(legacy); input(h, field, shared[field]);
		await assert.rejects(h.parse()); assert.deepEqual(h.calls, []); assert.deepEqual(h.data.main, legacy);
	}
	const h = await page(legacy); input(h, '_proxy_credential_source', 'socks'); input(h, 'timeout', '31');
	await assert.rejects(h.parse()); assert.deepEqual(credentials(h), []); assert.deepEqual(h.data.main, legacy);
});

test('explicit UI: explicit 0 suppresses legacy inference without erasing complete credentials', async () => {
	const h = await page({ ...shared, proxy_auth_enabled: '1' }); input(h, 'proxy_auth_enabled', '0');
	await h.parse(); assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'proxy_auth_enabled', '0']]);
	// A real Flag normalizes its displayed state to 0/1. Validate raw invalid
	// values in the pure model/backend, not by pretending a checkbox emits them.
	for (const flag of ['', 'false', '2'])
		assert.notEqual(model().validate('proxy_auth_enabled', flag), true);
});

test('explicit UI: model validates auth independently of listeners, byte limits and partial pairs', () => {
	const m = model();
	assert.equal(m.authentication({}), '0'); assert.equal(m.authentication(legacy), '1');
	assert.equal(m.authentication({ ...legacy, proxy_auth_enabled: '0' }), '0');
	for (const field of ['proxy_username', 'proxy_password']) {
		assert.equal(m.validate(field, '', { proxy_auth_enabled: '0' }), true);
		assert.notEqual(m.validate(field, '', { proxy_auth_enabled: '1' }), true);
		assert.equal(m.validate(field, '测'.repeat(85)), true);
		for (const value of ['测'.repeat(86), 'x'.repeat(256), '\0fixture', 'fixture\x7f', '\ud800'])
			assert.notEqual(m.validate(field, value), true);
	}
	assert.notEqual(m.validate('proxy_username', 'fixture:invalid'), true);
});

test('explicit UI: native handlers and pending-change warning remain intact', () => {
	const source = fs.readFileSync(path.join(RES, 'view/aether-proxy/advanced.js'), 'utf8');
	assert.doesNotMatch(source, /rpc\.declare|console\.|addNotification|handleSave|handleReset/);
	assert.match(source, /After clicking Save, anyone authorized to view LuCI Pending Changes/);
});
