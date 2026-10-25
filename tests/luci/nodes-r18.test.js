'use strict';

/* T10.61 / docs/10 r18: real option/model modules with SDK-like cloned modal
 * maps, active dependencies, aliased storage and change-aware parse. All error
 * checks run before any child-map save so earlier fields cannot leak into UCI. */
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { harness } = require('./required-modal');
globalThis._ = text => text;
String.prototype.format = function(...args) {
	let index = 0;
	return this.replace(/%s/g, () => String(args[index++]));
};
const base = { protocol: 'vmess', address: '192.168.1.2', port: '443', uuid: 'id' };
const alert = h => h.modal.root.querySelectorAll('.alert-message');
const choices = o => o.input.children.map(child => child.value);

// Valid/invalid tables are also sent to config.normalize, never inferred from its source text.
const FORMATS = {
	address: {
		good: ['0.0.0.0', '255.255.255.255', 'example.org', '_srv.a_b', 'a-b._',
			'a'.repeat(63) + '.org', ['a'.repeat(63), 'b'.repeat(63), 'c'.repeat(63), 'd'.repeat(61)].join('.')],
		bad: ['1.2.3.999', '01.2.3.4', '1.2.3', 'example.org.', '-a.org', 'a-.org', 'a..org',
			'a'.repeat(64) + '.org', ['a'.repeat(63), 'b'.repeat(63), 'c'.repeat(63), 'd'.repeat(62)].join('.'),
			'::1', '2001:db8::1', 'edge.org\n', '1.2.3.4\n']
	},
	uuid: {
		good: ['00112233-4455-6677-8899-aabbccddeeff', '00112233445566778899AABBCCDDEEFF',
			'a'.repeat(30), '汉'.repeat(10), 'é'.repeat(15), '😀'.repeat(7) + 'ab', 'short id',
			'--00112233445566778899aabbccddeeff--'],
		bad: ['a'.repeat(31), 'a'.repeat(37), 'g'.repeat(32), 'z'.repeat(36),
			'汉'.repeat(10) + 'a', '😀'.repeat(8), 'a'.repeat(32) + '\n']
	},
	reality_pbk: {
		good: ['a'.repeat(43), 'A_-' + '9'.repeat(40)],
		bad: ['a'.repeat(42), 'a'.repeat(44), 'a'.repeat(42) + '=', 'a'.repeat(42) + '+', 'a'.repeat(43) + '\n']
	},
	reality_sid: {
		good: ['ab', '0123456789ABCDEF', '00ff'],
		bad: ['a', '0123456789abcdef00', 'gg', 'ab\n']
	},
	pinned_cert_sha256: {
		good: ['a'.repeat(64), Array(32).fill('AB').join(':'), ' , ' + 'A'.repeat(64) + ',, ' + 'f'.repeat(64) + ' '],
		bad: ['a'.repeat(63), 'a'.repeat(65), 'g'.repeat(64), 'a'.repeat(64) + ',bad']
	}
};

// UUID intentionally follows docs/05 ahead of T9.37; every other rule already exists in config.uc.
function backend_accepts(field, value) {
	const root = path.resolve(__dirname, '../..');
	const node = { ...base, [field]: value };
	const script = "import * as config from 'aetherproxy.config'; " +
		`let r = config.normalize({ nodes: { n_${'a'.repeat(32)}: ${JSON.stringify(node)} } }); ` +
		"printf('%.J', r);";
	const reply = spawnSync(path.join(root, 'tests/host/ucode'), ['-e', script], { cwd: root, encoding: 'utf8' });
	assert.equal(reply.status, 0, reply.stderr);
	return JSON.parse(reply.stdout).ok;
}

for (const [field, table] of Object.entries(FORMATS)) {
	test('T10.61 scenario ' + (field === 'address' ? '5' : field === 'uuid' ? '6' : '7') +
		': ' + field + ' accepts and rejects every boundary, with empty values deferred', async () => {
		const h = await harness('node', base);
		const option = h.option(field);
		for (const value of ['', null, undefined, ...table.good])
			assert.equal(option.validate('row', value), true, field + ': valid ' + JSON.stringify(value));
		for (const value of table.bad) {
			const result = option.validate('row', value);
			assert.equal(typeof result, 'string', field + ': invalid ' + JSON.stringify(value));
			assert.ok(result.length > 0);
		}
		if (field !== 'uuid')
			for (const [values, expected] of [[table.good, true], [table.bad, false]])
				for (const value of values)
					assert.equal(backend_accepts(field, value), expected,
						field + ': backend parity ' + JSON.stringify(value));
	});
}

test('T10.61 scenario 1: SS has nine methods and required empty choice; VMess has five and auto is not written',
async () => {
	const h = await harness('node', { ...base, protocol: 'shadowsocks', password: 'secret' });
	const ss = h.option('method'), vmess = h.option('method_vmess');
	assert.deepEqual(choices(ss), ['', ...h.model.ss_methods]);
	assert.equal(ss.input.children[0].textContent, '-- Please choose --');
	assert.equal(ss.input.value, '');
	assert.deepEqual(choices(vmess), ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'none', 'zero']);
	assert.equal(ss.ucioption, 'method');
	assert.equal(vmess.ucioption, 'method');
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
	assert.match(alert(h)[0].textContent, /Encryption method is required/);
	assert.equal(ss.input.style.borderColor, 'var(--error-color-high, #c53030)');
	h.set('protocol', 'vmess');
	assert.equal(vmess.input.value, 'auto');
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(h.calls, [['set', 'protocol', 'vmess']], 'new VMess default must not create method');
	assert.equal(h.data.row.method, undefined);
	const edited = await harness('node', { ...base, method: 'aes-128-gcm' });
	edited.set('method_vmess', 'auto');
	await edited.save();
	assert.deepEqual(edited.calls, [['unset', 'method']]);
	assert.equal(edited.data.row.method, undefined);
});

test('T10.61 scenario 2: unknown saved methods display unchanged; SS blocks without writes, VMess saves without writes',
async () => {
	for (const protocol of ['shadowsocks', 'vmess']) {
		const h = await harness('node', { ...base, protocol, password: 'secret', method: 'legacy-method' });
		const option = h.option(protocol === 'vmess' ? 'method_vmess' : 'method');
		assert.equal(option.input.value, 'legacy-method');
		assert.equal(option.input.children.at(-1).textContent, 'legacy-method');
		assert.ok(!option.keylist.includes('legacy-method'), 'preserved value never pollutes shared choices');
		assert.deepEqual(h.calls, []);
		await h.save();
		assert.equal(h.open, protocol === 'shadowsocks');
		assert.deepEqual(h.calls, []);
		assert.equal(h.data.row.method, 'legacy-method');
		if (protocol === 'shadowsocks')
			assert.match(alert(h)[0].textContent, /Unsupported encryption method/);
	}
});

test('T10.61 scenario 3: switching SS and VMess preserves inactive aliases; Trojan preserves method with both hidden',
async () => {
	for (const [from, to, method] of [
		['shadowsocks', 'vmess', 'aes-128-gcm'], ['vmess', 'shadowsocks', 'aes-128-gcm'],
		['vmess', 'trojan', 'legacy-method'], ['shadowsocks', 'trojan', 'aes-256-gcm']
	]) {
		const h = await harness('node', { ...base, protocol: from, password: 'secret', method });
		h.set('protocol', to);
		assert.equal(h.option('method').isActive('row'), to === 'shadowsocks');
		assert.equal(h.option('method_vmess').isActive('row'), to === 'vmess');
		assert.equal(h.option('method').input.value, method);
		assert.equal(h.option('method_vmess').input.value, method);
		await h.save();
		assert.equal(h.open, false);
		assert.deepEqual(h.calls, [['set', 'protocol', to]]);
		assert.equal(h.data.row.method, method);
	}
	const h = await harness('node', { ...base, protocol: 'shadowsocks', password: 'secret', method: 'aes-256-gcm' });
	h.set('protocol', 'vmess');
	assert.equal(h.option('method_vmess').input.value, 'aes-256-gcm',
		'SS-only saved method displays as preserved VMess item');
	h.set('method_vmess', 'zero');
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(h.calls, [['set', 'protocol', 'vmess'], ['set', 'method', 'zero']]);
});

test('T10.61 scenario 8: Save collects formats and omissions before staging; correction replaces errors and saves',
async () => {
	const h = await harness('node', { protocol: 'vless', security: 'reality' });
	h.set('label', 'Not yet staged');
	h.set('address', '1.2.3.999');
	h.set('uuid', 'g'.repeat(32));
	h.set('reality_pbk', 'bad');
	h.set('reality_sid', 'a');
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.sequence, []);
	assert.equal(alert(h).length, 1);
	const text = alert(h)[0].textContent;
	for (const message of ['Port is required.', 'SNI is required.', 'Address: Must be a valid IPv4',
		'UUID: UUID must be', 'REALITY public key: REALITY public key must be', 'REALITY short ID: Short ID must be'])
		assert.ok(text.includes(message), message);
	const previous = alert(h)[0];
	await h.save();
	assert.equal(alert(h).length, 1);
	assert.equal(previous.parentNode, null);
	for (const [field, value] of Object.entries({ address: 'edge_name.org', port: '443', uuid: 'short id',
		sni: 'arbitrary SNI / !', reality_pbk: 'a'.repeat(43), reality_sid: 'aabb' }))
		h.set(field, value);
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(alert(h), []);
	assert.equal(h.data.row.label, 'Not yet staged');
});

test('T10.61 scenarios 7-8: hidden invalid fields are retained; opaque strings have no new validator', async () => {
	const saved = { ...base, security: 'none', transport: 'raw', reality_pbk: 'bad', reality_sid: 'odd',
		pinned_cert_sha256: 'bad', password: 'secret', sni: ' / ! ', path: '? !', host: ' / ?' };
	const h = await harness('node', saved);
	for (const field of ['sni', 'host', 'path', 'service_name', 'xhttp_mode', 'verify_name', 'reality_spx',
		'alpn', 'ech_config_list', 'reality_pqv'])
		assert.equal(h.option(field).validate, undefined, field + ' stays opaque');
	assert.equal(h.option('reality_pbk').isValid('row'), false, 'hidden value really is invalid');
	assert.equal(h.option('pinned_cert_sha256').isValid('row'), false);
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.data.row, saved);
});

test('T10.61 scenario 8: existing port/range/JSON errors also appear before modal save', async () => {
	const h = await harness('node', { ...base, transport: 'xhttp', mux: '1' });
	for (const [field, value] of Object.entries({ port: '65536', xhttp_extra: '[]', mux_concurrency: '1025',
		mux_xudp_concurrency: '-2' }))
		h.set(field, value);
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.sequence, []);
	for (const label of ['Port:', 'XHTTP extra settings (JSON):', 'Mux concurrency:', 'XUDP concurrency:'])
		assert.ok(alert(h)[0].textContent.includes(label), label);
});
