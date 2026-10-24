'use strict';

/* docs/10 r17 / T10.58: SDK modal save stages the child map, reloads and
 * resets its parent, then closes. Empty optional Values are valid in the SDK;
 * application preflight must run before any parse() can stage another field. */
const test = require('node:test');
const assert = require('node:assert/strict');
const { element: E } = require('./loader');
const types = require('./form-sdk');
const { harness, sdkSave } = require('./required-modal');
globalThis._ = text => text;
globalThis.E = E;
String.prototype.format = function(...args) {
	let index = 0;
	return this.replace(/%s/g, () => String(args[index++]));
};

test('T10.58 reproduction: SDK modal Save accepts only a name and Trojan protocol', async () => {
	const writes = [], sequence = [];
	const map = {
		config: 'aetherproxy', data: {
			get: () => undefined,
			set: (config, id, field, value) => writes.push([field, value]),
			unset: () => {}
		},
		parent: { load: async () => sequence.push('load'), reset: async () => sequence.push('reset') },
		lookupOption: () => []
	};
	const section = { map };
	const options = ['label', 'protocol', 'address', 'port', 'password'].map(field => new types.Value(section, field));
	options[0].inputs.new = 'Name only';
	options[1].inputs.new = 'trojan';
	map.save = async (callback, silent) => {
		assert.equal(callback, null);
		assert.equal(silent, true);
		for (const option of options)
			await option.parse('new');
	};
	const grid = { handleModalCancel: async () => sequence.push('close') };
	await sdkSave.call(grid, map, {});
	assert.deepEqual(writes, [['label', 'Name only'], ['protocol', 'trojan']]);
	assert.deepEqual(sequence, ['load', 'reset', 'close']);
});

const RED = 'var(--error-color-high, #c53030)';
const starred = h => h.modal.children[0].children
	.filter(o => o.requiredMarker && o.requiredMarker.style.display !== 'none').map(o => o.option);
const errors = h => h.modal.root.querySelectorAll('.alert-message');

test('T10.58 scenario 1: Trojan name-only Save keeps modal open, stages nothing and lists/red-borders all omissions',
async () => {
	const h = await harness('node');
	h.set('label', 'Name only');
	h.set('protocol', 'trojan');
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.sequence, []);
	assert.equal(errors(h).length, 1);
	assert.deepEqual(errors(h)[0].querySelectorAll('li').map(li => li.textContent), [
		'Address is required.', 'Port is required.', 'Password is required.'
	]);
	for (const field of ['address', 'port', 'password'])
		assert.equal(h.option(field).input.style.borderColor, RED, field + ': theme-independent error border');
	const previous = errors(h)[0];
	await h.save();
	assert.equal(errors(h).length, 1, 'repeated Save replaces, never stacks errors');
	assert.notEqual(errors(h)[0], previous);
	assert.equal(previous.parentNode, null);
	assert.match(h.modal.root.textContent, /Fields marked with \* are required/);
});

test('T10.58 scenario 2: switching all protocols and security immediately refreshes exact required stars', async () => {
	const h = await harness('node');
	for (const protocol of ['vless', 'vmess', 'trojan', 'shadowsocks', 'vmess']) {
		h.set('protocol', protocol);
		const credential = ['vless', 'vmess'].includes(protocol) ? 'uuid' : 'password';
		assert.deepEqual(starred(h), ['protocol', 'address', 'port', credential,
			...(protocol === 'shadowsocks' ? ['method'] : [])]);
	}
	h.set('security', 'reality');
	assert.deepEqual(starred(h), ['protocol', 'address', 'port', 'uuid', 'sni', 'reality_pbk']);
	assert.equal(h.option('sni').requiredMarker.style.color, RED);
	h.set('security', 'tls');
	assert.equal(h.option('sni').isActive('row'), true, 'TLS shows SNI but does not require it');
	assert.equal(h.option('sni').requiredMarker.style.display, 'none');
	assert.equal(h.option('reality_pbk').isActive('row'), false);
});

for (const protocol of ['vless', 'vmess', 'trojan', 'shadowsocks']) {
	test('T10.58 scenario 3: complete ' + protocol + ' saves and ignores hidden credentials/security fields',
	async () => {
		const h = await harness('node');
		for (const [field, value] of Object.entries({
			label: 'Complete', protocol, address: '192.168.1.2', port: '443',
			...(['vless', 'vmess'].includes(protocol) ? { uuid: 'uuid' } : { password: 'secret' }),
			...(protocol === 'shadowsocks' ? { method: 'aes-128-gcm' } : {})
		}))
			h.set(field, value);
		await h.save();
		assert.equal(h.open, false);
		assert.deepEqual(errors(h), []);
		assert.deepEqual(h.sequence, [['save', null, true], ['load'], ['reset'], ['close', true]]);
		assert.equal(h.data.row.protocol, protocol);
		assert.equal(h.data.row.address, '192.168.1.2');
		assert.equal(h.data.row.port, '443');
		assert.equal(h.data.row.reality_pbk, undefined);
		assert.equal(h.data.row.sni, undefined);
	});
}

test('T10.58 scenario 2: existing protocol/REALITY stars are correct on first render, before any change event',
async () => {
	for (const protocol of ['vless', 'vmess', 'trojan', 'shadowsocks']) {
		const h = await harness('node', { protocol, security: 'reality' });
		const credential = ['vless', 'vmess'].includes(protocol) ? 'uuid' : 'password';
		assert.deepEqual(starred(h), ['protocol', 'address', 'port', credential,
			...(protocol === 'shadowsocks' ? ['method'] : []), 'sni', 'reality_pbk']);
	}
});

test('T10.58 scenarios 2-3: REALITY omissions block, live correction clears borders and permits Save', async () => {
	const h = await harness('node', { protocol: 'vless', address: '192.168.1.2', port: '443', uuid: 'uuid' });
	h.set('security', 'reality');
	await h.save();
	assert.deepEqual(errors(h)[0].querySelectorAll('li').map(li => li.textContent), [
		'SNI is required.', 'REALITY public key is required.'
	]);
	assert.deepEqual(h.calls, [], 'even the security-layer change is not staged');
	h.set('sni', 'edge.example');
	h.set('reality_pbk', 'a'.repeat(43));
	assert.equal(h.option('sni').input.style.borderColor, '');
	assert.equal(h.option('reality_pbk').input.style.borderColor, '');
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(errors(h), []);
	assert.equal(h.data.row.sni, 'edge.example');
});

test('T10.58 scenario 3: unchanged existing node modal Save preserves T10.54 zero writes', async () => {
	for (const security of ['none', 'tls', 'reality']) {
		const saved = { protocol: 'vless', address: '192.168.1.2', port: '443', uuid: 'uuid', security,
			...(security === 'reality' ? { sni: 'edge.example', reality_pbk: 'a'.repeat(43) } : {}) };
		const h = await harness('node', saved);
		await h.save();
		assert.equal(h.open, false, security);
		assert.deepEqual(h.calls, [], security + ': no set/unset for unchanged effective values');
		assert.deepEqual(h.data.row, saved);
	}
});

test('T10.58 scenario 4: added subscription with empty URL blocks; filling URL saves; unchanged URL writes nothing',
async () => {
	const h = await harness('subscription');
	h.grid.map.addedSection = 'row';
	h.set('name', 'New subscription');
	assert.deepEqual(starred(h), ['url']);
	await h.save();
	assert.equal(h.open, true);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.sequence, []);
	assert.equal(h.grid.map.addedSection, 'row');
	assert.equal(errors(h)[0].textContent, 'Subscription URL is required.');
	assert.equal(h.option('url').input.style.borderColor, RED);
	assert.match(h.modal.root.textContent, /Fields marked with \* are required/);
	h.set('url', 'https://example.test/sub');
	assert.equal(h.option('url').input.style.borderColor, '');
	await h.save();
	assert.equal(h.open, false);
	assert.equal(h.data.row.url, 'https://example.test/sub');
	assert.equal(h.grid.map.addedSection, undefined);
	h.calls.length = 0;
	await h.openModal();
	await h.save();
	assert.equal(h.open, false);
	assert.deepEqual(h.calls, [], 'existing subscription stays unchanged');
});

test('T10.58 scenarios 1/4: whitespace is empty and missing protocol is itself reported', async () => {
	const h = await harness('node');
	h.set('address', '  ');
	await h.save();
	assert.match(errors(h)[0].textContent, /Protocol is required/);
	assert.match(errors(h)[0].textContent, /Address is required/);
	assert.deepEqual(h.calls, []);
	const sub = await harness('subscription');
	sub.set('url', '\t ');
	await sub.save();
	assert.equal(sub.open, true);
	assert.match(errors(sub)[0].textContent, /Subscription URL is required/);
	assert.deepEqual(sub.calls, []);
});
