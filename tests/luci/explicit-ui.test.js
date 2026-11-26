'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { renderPage, RES } = require('./form-defaults-harness');
const { loadModule } = require('./loader');
const model = () => loadModule(path.join(RES, 'aether-proxy/model/advanced.js'),
	{ baseclass: { extend: o => o } }, { window: {}, document: {} });
const get = (page, field) => page.options.find(o => o.option === field);
const input = (page, field, value) => { get(page, field).inputs.main = value; };
function saved(page, protocol, enabled) {
	for (const [suffix, value] of Object.entries({ enabled, listen: '192.0.2.1',
		port: protocol === 'socks' ? '1080' : '8080', username: 'demo-' + protocol, password: 'fixture-' + protocol })) {
		page.setSaved('main', protocol + '_' + suffix, value);
		input(page, protocol + '_' + suffix, value);
	}
}
function onlyProtocol(page, protocol) {
	assert.ok(page.calls.length);
	assert.ok(page.calls.every(c => c[2] === 'main' && c[3].startsWith(protocol + '_')),
		'untouched protocol and unrelated fields must not be written');
}

test('T16.111: absent/disabled listeners stay off on render and unrelated save', async () => {
	const page = await renderPage('advanced');
	assert.deepEqual(page.calls, []);
	await page.parse();
	assert.deepEqual(page.calls, []);
	input(page, 'log_level', 'debug');
	await page.parse();
	assert.deepEqual(page.calls, [['set', 'aetherproxy', 'main', 'log_level', 'debug']]);
});

test('T16.111: independent off/one/both/off transitions preserve all other credentials', async () => {
	for (const protocol of ['socks', 'http']) {
		for (const otherEnabled of ['0', '1']) {
			for (const enabled of ['0', '1']) {
				const page = await renderPage('advanced');
				const other = protocol === 'socks' ? 'http' : 'socks';
				saved(page, protocol, enabled);
				saved(page, other, otherEnabled);
				input(page, protocol + '_enabled', enabled === '0' ? '1' : '0');
				await page.parse();
				onlyProtocol(page, protocol);
				assert.deepEqual(page.calls, [['set', 'aetherproxy', 'main', protocol + '_enabled', enabled === '0' ? '1' : '0']]);
			}
		}
	}
});

test('T16.111: editing one protocol saves only its fields; discard/reload writes nothing', async () => {
	const page = await renderPage('advanced');
	saved(page, 'socks', '1'); saved(page, 'http', '1');
	input(page, 'socks_port', '1081'); input(page, 'socks_password', 'replacement-fixture');
	assert.deepEqual(page.calls, [], 'typing is not a UCI write');
	// Reset is inherited from view: re-render saved UCI, no custom publish/reset path.
	assert.equal(page.view.handleReset, undefined);
	assert.equal(page.view.handleSave, undefined);
	assert.equal(page.view.handleSaveApply, undefined);
	const reset = await renderPage('advanced');
	saved(reset, 'socks', '1'); saved(reset, 'http', '1');
	await reset.parse(); assert.deepEqual(reset.calls, []);
	await page.parse(); onlyProtocol(page, 'socks');
	assert.deepEqual(page.calls.map(c => c[3]), ['socks_port', 'socks_password']);
});

test('T16.111: required/invalid fields are correctable and errors never echo input', async () => {
	const page = await renderPage('advanced');
	input(page, 'http_enabled', '1');
	for (const suffix of ['listen', 'port', 'username', 'password'])
		assert.notEqual(get(page, 'http_' + suffix).validate('main', ''), true);
	await assert.rejects(page.parse(), /invalid input/);
	for (const [suffix, bad] of [['listen', '127.0.0.1'], ['port', '31081'],
		['username', 'fixture:invalid'], ['password', 'fixture\ninvalid']]) {
		const result = get(page, 'http_' + suffix).validate('main', bad);
		assert.notEqual(result, true); assert.ok(!result.includes(bad));
	}
	saved(page, 'http', '1');
	for (const suffix of ['listen', 'port', 'username', 'password'])
		assert.equal(get(page, 'http_' + suffix).validate('main', get(page, 'http_' + suffix).formvalue('main')), true);
	input(page, 'http_port', '8081');
	get(page, 'http_port').write = () => { throw new Error('fixture backend failure'); };
	await assert.rejects(page.parse(), /fixture backend failure/);
});

test('T16.111: IPv4, integer, UTF-8 credentials and cross-protocol conflict boundaries', () => {
	const m = model();
	for (const value of ['0.1.2.3', '127.1.2.3', '224.0.0.1', '255.255.255.255', '::1', 'host', '192.0.2.1/24', '01.2.3.4'])
		assert.notEqual(m.validate('socks_listen', value), true);
	assert.equal(m.validate('socks_listen', '192.0.2.1'), true);
	for (const value of ['0', '65536', '1.5', ' 1080', '+1080'])
		assert.notEqual(m.validate('socks_port', value), true);
	for (const value of ['1', '65535', '001080']) assert.equal(m.validate('socks_port', value), true);
	for (const port of ['53', '31053', '31080', '31081', '31082', '31083', '8080'])
		assert.notEqual(m.validate('socks_port', port, { socks_enabled: '1', http_enabled: '1', http_port: '8080' }), true);
	for (const field of ['socks_username', 'socks_password', 'http_username', 'http_password']) {
		assert.equal(m.validate(field, '测'.repeat(85)), true);
		for (const value of ['测'.repeat(86), 'x'.repeat(256), '\0fixture', 'fixture\x7f', '\ud800']) {
			const error = m.validate(field, value);
			assert.notEqual(error, true); assert.ok(!error.includes(value));
		}
	}
	assert.equal(m.validate('socks_username', 'fixture:allowed'), true);
	assert.notEqual(m.validate('http_username', 'fixture:invalid'), true);
});

test('T16.111: native password masking and no new RPC/summary/footer handlers', async () => {
	const page = await renderPage('advanced');
	for (const protocol of ['socks', 'http']) {
		const password = get(page, protocol + '_password');
		assert.equal(password.password, true);
		assert.equal(password.rmempty, false);
		assert.deepEqual(password.deplist, [{ [protocol + '_enabled']: '1' }]);
		assert.equal(get(page, protocol + '_enabled').default, '0');
	}
	const source = fs.readFileSync(path.join(RES, 'view/aether-proxy/advanced.js'), 'utf8');
	assert.doesNotMatch(source, /rpc\.declare|ap\.call|console\.|addNotification|handleSave|handleReset/);
});


test('T16.111: plugin leaves native change rendering and session preload untouched', () => {
	const source = fs.readFileSync(path.join(RES, 'aether-proxy/common.js'), 'utf8');
	assert.doesNotMatch(source, /displayChanges|setLocalData\(['"]preload/);
});
