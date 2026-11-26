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
const shared = { proxy_username: 'fixture-shared-user', proxy_password: 'fixture-shared-secret' };
const legacy = {
	socks_username: 'fixture-socks-user', socks_password: 'fixture-socks-secret', socks_listen: '192.0.2.2',
	http_username: 'fixture-http-user', http_password: 'fixture-http-secret', http_listen: '192.0.2.3'
};
const page = (main = {}, status) => renderPage('advanced', false, undefined, { data: { main }, status });
const migrationCalls = h => h.calls.filter(c => /^(proxy_(username|password)|(socks|http)_(username|password|listen))$/.test(c[3]));

test('T16.112: render, unrelated save and native reset never backfill defaults or automatic LAN addresses', async () => {
	const h = await page();
	assert.deepEqual(h.calls, []);
	await h.parse(); assert.deepEqual(h.calls, []);
	input(h, 'log_level', 'debug'); await h.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'log_level', 'debug']]);
	assert.equal(get(h, 'socks_port').default, '1080');
	assert.equal(get(h, 'http_port').default, '8080');
	assert.equal(get(h, 'proxy_address'), undefined);
	assert.match(get(h, '_proxy_lan').cfgvalue('main'), /lan.*192\.0\.2\.1/);
	for (const method of ['handleReset', 'handleSave', 'handleSaveApply']) assert.equal(h.view[method], undefined);
	for (const field of Object.keys(legacy)) assert.equal(get(h, field), undefined);
});

test('T16.112: independent enable/disable flags retain one shared credential pair', async () => {
	for (const protocol of ['socks', 'http'])
		for (const otherEnabled of ['0', '1'])
			for (const enabled of ['0', '1']) {
				const other = protocol === 'socks' ? 'http' : 'socks';
				const h = await page({ ...shared, [protocol + '_enabled']: enabled, [other + '_enabled']: otherEnabled });
				input(h, protocol + '_enabled', enabled === '0' ? '1' : '0');
				await h.parse();
				assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', protocol + '_enabled', enabled === '0' ? '1' : '0']]);
			}
});

test('T16.112: absent/failed status permits other settings when off, but either enabled proxy errors explicitly', async () => {
	for (const status of [{ ok: false, code: 'RPC_FAILED' }, {}, { explicit_lan: { interface: 'lan', addresses: [] } },
		async () => { throw new Error('fixture transport failure'); }]) {
		const h = await page(shared, status);
		input(h, 'log_level', 'debug'); await h.parse();
		assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'log_level', 'debug']]);
		for (const protocol of ['socks', 'http']) {
			input(h, protocol + '_enabled', '1'); h.calls.length = 0;
			assert.match(get(h, protocol + '_enabled').validate('main', '1'), /No usable IPv4/);
			await assert.rejects(h.parse(), /No usable IPv4/); assert.deepEqual(h.calls, []);
			input(h, protocol + '_enabled', '0');
		}
	}
});

test('T16.112: CONFIG_INVALID retains live LAN candidates while unrelated fields are repaired', async () => {
	const h = await page({ ...shared, socks_enabled: '1', boot_wait_timeout: '999' }, {
		ok: false, code: 'CONFIG_INVALID',
		explicit_lan: { interface: 'lan', addresses: ['192.0.2.1'] }
	});
	input(h, 'boot_wait_timeout', '120');
	await h.parse();
	assert.deepEqual(h.calls, [['unset', 'aetherproxy', 'main', 'boot_wait_timeout']]);
	assert.equal(h.data.main.socks_enabled, '1');
});

test('T16.112: multiple candidates are used verbatim with exactly one shared selection; stale/free-form addresses rejected', async () => {
	// Odd-looking fixture intentionally proves the UI has no second address filter.
	const addresses = ['192.0.2.4', '198.51.100.9'];
	const h = await page({ ...shared, socks_enabled: '1', http_enabled: '1' }, { explicit_lan: { interface: 'lan', addresses } });
	assert.deepEqual(get(h, 'proxy_address').keylist, ['', ...addresses]);
	assert.equal(h.options.filter(o => o.option === 'proxy_address').length, 1);
	for (const invalid of ['', '192.0.2.99', '0.0.0.0']) {
		input(h, 'proxy_address', invalid);
		await assert.rejects(h.parse(), /Select one of/); assert.deepEqual(h.calls, []);
	}
	input(h, 'proxy_address', addresses[1]); await h.parse();
	assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'proxy_address', addresses[1]]]);
	const singleton = await page({ ...shared, socks_enabled: '1', proxy_address: '192.0.2.99' });
	await singleton.parse();
	assert.deepEqual(singleton.calls, [['unset', 'aetherproxy', 'main', 'proxy_address']]);
	const verbatim = await page({}, { explicit_lan: { interface: 'lan', addresses: ['127.0.0.1', '0.0.0.0'] } });
	assert.deepEqual(get(verbatim, 'proxy_address').keylist, ['', '127.0.0.1', '0.0.0.0']);
});

test('T16.112: safe legacy pairs prefill only masked shared fields and migrate on valid save', async () => {
	for (const old of [
		{ ...legacy, http_username: legacy.socks_username, http_password: legacy.socks_password },
		{ socks_username: legacy.socks_username, socks_password: legacy.socks_password },
		{ http_username: legacy.socks_username, http_password: legacy.socks_password }
	]) {
		const h = await page({ ...old, socks_enabled: '1' });
		assert.equal(get(h, '_proxy_credential_source'), undefined);
		assert.equal(get(h, 'proxy_password').password, true);
		assert.equal(get(h, 'proxy_password').formvalue('main'), legacy.socks_password);
		assert.deepEqual(h.calls, [], 'loading/prefilling is read only');
		await h.parse();
		assert.deepEqual(h.calls.slice(0, 2), [
			['set', 'aetherproxy', 'main', 'proxy_username', legacy.socks_username],
			['set', 'aetherproxy', 'main', 'proxy_password', legacy.socks_password]
		]);
		assert.deepEqual(h.calls.slice(2).map(c => [c[0], c[3]]).sort(), Object.keys(old).map(k => ['unset', k]).sort());
	}
});

test('T16.112: different/partial legacy pairs stay invisible and untouched while both proxies are off', async () => {
	for (const old of [legacy, { socks_username: 'fixture-a', http_password: 'fixture-b' },
		{ socks_username: 'fixture-a', http_username: 'fixture-b' }]) {
		const h = await page(old);
		assert.equal(get(h, 'proxy_username').formvalue('main'), '');
		assert.equal(get(h, 'proxy_password').formvalue('main'), '');
		const source = get(h, '_proxy_credential_source');
		assert.deepEqual(source.keylist, ['', 'socks', 'http']);
		for (const value of Object.values(old)) assert.ok(!source.vallist.join().includes(value));
		input(h, 'log_level', 'debug'); await h.parse();
		assert.deepEqual(migrationCalls(h), []);
		input(h, 'socks_enabled', '1'); h.calls.length = 0;
		await assert.rejects(h.parse(), /Legacy proxy credentials differ/);
		assert.deepEqual(h.calls, []);
	}
});

test('T16.112: choosing either complete old source or entering a new pair resolves conflict only on save', async () => {
	for (const source of ['socks', 'http', '']) {
		const h = await page({ ...legacy, socks_enabled: '1', http_enabled: '1' });
		input(h, '_proxy_credential_source', source);
		if (!source) {
			input(h, 'proxy_username', shared.proxy_username);
			input(h, 'proxy_password', shared.proxy_password);
		}
		assert.deepEqual(h.calls, [], 'selection/typing cannot migrate');
		assert.equal(get(h, 'proxy_password').formvalue('main'), source ? '' : shared.proxy_password);
		await h.parse();
		assert.deepEqual(h.calls.slice(0, 2), ['username', 'password'].map(key =>
			['set', 'aetherproxy', 'main', 'proxy_' + key, source ? legacy[source + '_' + key] : shared['proxy_' + key]]));
		assert.deepEqual(h.calls.slice(2).map(c => c[3]).sort(), Object.keys(legacy).sort());
		assert.ok(h.calls.slice(2).every(c => c[0] === 'unset'));
	}
});

test('T16.112: partial replacement/source, credential errors or another tab failure never migrate', async () => {
	for (const bad of ['incomplete', 'source-partial', 'username', 'password', 'other-tab']) {
		const old = bad === 'source-partial' ? { socks_username: 'fixture-partial', http_username: 'fixture-other' } : legacy;
		const h = await page({ ...old, socks_enabled: '1' });
		if (bad === 'source-partial') input(h, '_proxy_credential_source', 'socks');
		else {
			input(h, 'proxy_username', bad === 'username' ? 'fixture:invalid' : shared.proxy_username);
			if (bad !== 'incomplete') input(h, 'proxy_password', bad === 'password' ? 'fixture\ninvalid' : shared.proxy_password);
		}
		if (bad === 'other-tab') input(h, 'timeout', '31');
		await assert.rejects(h.parse()); assert.deepEqual(migrationCalls(h), []);
		assert.deepEqual(Object.fromEntries(Object.keys(old).map(k => [k, h.data.main[k]])), old);
	}
	const reset = await page(legacy);
	await reset.parse(); assert.deepEqual(reset.calls, [], 'fresh/native revert view must not migrate unresolved pairs');
});

test('T16.112: common username/password byte limits, required fields and enabled-only port conflicts', async () => {
	const m = model();
	for (const field of ['proxy_username', 'proxy_password']) {
		assert.equal(m.validate(field, '', {}), true);
		assert.notEqual(m.validate(field, '', { socks_enabled: '1' }), true);
		assert.equal(m.validate(field, '测'.repeat(85)), true);
		for (const value of ['测'.repeat(86), 'x'.repeat(256), '\0fixture', 'fixture\x7f', '\ud800']) {
			const error = m.validate(field, value); assert.notEqual(error, true); assert.ok(!error.includes(value));
		}
	}
	assert.notEqual(m.validate('proxy_username', 'fixture:invalid'), true);
	for (const port of ['53', '31053', '31080', '31081', '31082', '31083', '8080'])
		assert.notEqual(m.validate('socks_port', port, { socks_enabled: '1', http_enabled: '1', http_port: '8080' }), true);
	assert.equal(m.validate('socks_port', '8080', { socks_enabled: '1', http_enabled: '0', http_port: '8080' }), true);
	const h = await page({ ...shared, socks_enabled: '1', http_enabled: '1' });
	input(h, 'socks_port', '8080'); await assert.rejects(h.parse(), /Port conflicts/); assert.deepEqual(migrationCalls(h), []);
	input(h, 'http_enabled', '0'); await h.parse(); assert.deepEqual(migrationCalls(h), []);
});

test('T16.112: partial new credentials never borrow old values, and closed proxies retain shared credentials', async () => {
	const h = await page({ ...legacy, proxy_username: shared.proxy_username, socks_enabled: '1' });
	assert.equal(get(h, 'proxy_password').formvalue('main'), '');
	await assert.rejects(h.parse(), /Required/); assert.deepEqual(migrationCalls(h), []);
	const closed = await page({ ...shared, socks_enabled: '1' });
	input(closed, 'socks_enabled', '0'); await closed.parse();
	assert.deepEqual(migrationCalls(closed), []);
});

test('T16.112: editing either shared field preserves the other, clearing enabled credentials fails without reviving storage', async () => {
	for (const key of ['username', 'password']) {
		const h = await page({ ...shared, socks_enabled: '1' });
		input(h, 'proxy_' + key, 'fixture-replacement');
		await h.parse();
		assert.deepEqual(h.calls, [['set', 'aetherproxy', 'main', 'proxy_' + key, 'fixture-replacement']]);
	}
	for (const fields of [['username'], ['password'], ['username', 'password']]) {
		const h = await page({ ...shared, socks_enabled: '1' });
		for (const key of fields) input(h, 'proxy_' + key, '');
		await assert.rejects(h.parse(), /Required/);
		assert.deepEqual(migrationCalls(h), []);
	}
});

test('T16.112: reuse only existing status call; native handlers, credential visibility warning and LuCI summaries remain untouched', async () => {
	const source = fs.readFileSync(path.join(RES, 'view/aether-proxy/advanced.js'), 'utf8');
	assert.doesNotMatch(source, /rpc\.declare|console\.|addNotification|handleSave|handleReset/);
	assert.deepEqual([...source.matchAll(/ap\.call\(([^)]+)\)/g)].map(m => m[1]), ["'status'"]);
	assert.match(source, /After clicking Save, anyone authorized to view LuCI Pending Changes/);
	const common = fs.readFileSync(path.join(RES, 'aether-proxy/common.js'), 'utf8');
	assert.doesNotMatch(common, /displayChanges|setLocalData\(['"]preload/);
});
