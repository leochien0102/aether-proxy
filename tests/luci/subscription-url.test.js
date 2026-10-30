'use strict';

// T9.49 / docs/10 subscription preflight: compare live modal input with real config.normalize.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { harness, RES } = require('./required-modal');
const { loadModule } = require('./loader');
const ROOT = path.resolve(__dirname, '../..');
globalThis._ = text => text;
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};
const cases = [
	['http://example.com', true],
	['https://example.com/a?b=c', true],
	['https://user:pass@example.com:8443/p', true],
	['ftp://example.com/sub', false], ['http://', false], ['http:// host', false],
	['https://a b', false], ['http://a\n', false], ['', false],
	['HTTP://example.com', false], [' https://example.com', false],
	['https:///path', false], ['https://?q', false], ['https://#f', false],
	['https://a/p\tq', false], ['https://a/\r', false], ['https://a/\v', false],
	['https://a/\f', false], ['https://a/#x y', false],
	// These opaque authorities/escapes are accepted by the backend, not by every URL parser.
	['https://@/p', true], ['https://a:bad/%20?q=%0A#X', true],
	['https://EXAMPLE.com:443/Path?token=AbC%2f', true],
	['https://a/\u00a0', true], ['https://a/\u2028', true]
];
const label = value => JSON.stringify(value);
const ERROR = 'Enter an HTTP or HTTPS URL without whitespace';

for (const [value, accepted] of cases) {
	test(`T9.49 modal Save ${label(value)}: ${accepted ? 'preserves bytes' : 'blocks before writes'}`, async () => {
		const h = await harness('subscription', { name: 'Old', url: 'https://old.test/sub' });
		h.set('name', 'Changed before URL');
		h.set('url', value);
		await h.save();
		assert.equal(h.open, !accepted);
		if (accepted) {
			assert.equal(h.data.row.url, value);
			assert.ok(h.calls.some(call => call[0] === 'set' && call[1] === 'url' && call[2] === value));
			assert.equal(h.modal.root.querySelectorAll('.alert-message').length, 0);
		}
		else {
			assert.deepEqual(h.calls, [], 'not even earlier name is staged');
			assert.deepEqual(h.sequence, [], 'no map save/session write, reload or close');
			assert.equal(h.data.row.url, 'https://old.test/sub');
			assert.equal(h.option('url').input.style.borderColor, 'var(--error-color-high, #c53030)');
			assert.equal(h.modal.root.querySelector('.alert-message').textContent,
				value === '' ? 'Subscription URL is required.' : 'Subscription URL: ' + ERROR);
		}
	});
}

test('T9.49 backend parity: every input matches real ucode normalize and accepted bytes', async () => {
	const proc = spawnSync(path.join(ROOT, 'tests/host/ucode'), ['-e',
		"import * as c from 'aetherproxy.config'; printf('%.J', map(" + JSON.stringify(cases.map(c => c[0])) +
		", value => c.normalize({ subscriptions: { s_12345678: { url: value } } })));"],
		{ cwd: ROOT, encoding: 'utf8' });
	assert.equal(proc.status, 0, proc.stderr);
	const backend = JSON.parse(proc.stdout);
	const h = await harness('subscription');
	for (const [i, [value, accepted]] of cases.entries()) {
		assert.equal(backend[i].ok, accepted, label(value));
		h.set('url', value);
		assert.equal(value !== '' && h.option('url').isValid('row'), backend[i].ok, label(value));
		if (accepted)
			assert.equal(backend[i].snapshot.subscriptions.s_12345678.url, value);
		else
			assert.ok(backend[i].errors.some(e => e.field === 'subscription.s_12345678.url'));
	}
	assert.equal(h.option('url').validate('row', ''), true, 'empty format check defers to required');
});

test('T9.49 correction: rejected modal URL cannot reach subsequent Save or Save & Apply', async t => {
	// The page uses LuCI standard footer handlers. They see only staged UCI, never modal widgets.
	for (const apply of [false, true]) {
		const h = await harness('subscription', { url: 'https://old.test/sub' });
		h.set('url', 'ftp://bad.test');
		await h.save();
		assert.equal(h.open, true);
		assert.deepEqual(h.calls, []);
		assert.equal(h.data.row.url, 'https://old.test/sub', 'footer cannot apply rejected input');
		h.set('url', 'https://EXAMPLE.test/sub?token=AbC%2f');
		await h.save();
		assert.equal(h.open, false);
		// Exercise the default LuCI view footer with the map/save and apply boundary recorded.
		const fs = require('node:fs');
		const sdk = '/workspace/openwrt/sdk-spike/sdk-24.10.8/feeds/luci/modules/luci-base/'
			+ 'htdocs/luci-static/resources/luci.js';
		if (!fs.existsSync(sdk))
			return t.skip('read-only SDK not available for default footer handlers');
		const source = fs.readFileSync(sdk, 'utf8');
		const methods = ['handleSave', 'handleSaveApply'].map(name => {
			const start = source.indexOf('\n\t\t' + name + '(');
			assert.ok(start >= 0, name + ' exists in SDK');
			return source.slice(start, source.indexOf('\n\t\t},', start) + 5);
		}).join('\n');
		const calls = [];
		const view = new Function('DOM', 'classes', 'document', 'return ({' + methods + '});')({
			callClassMethod: async (node, method) => {
				assert.equal(node, h.view.map);
				assert.equal(method, 'save');
				calls.push(['save', h.data.row.url]);
			}
		}, { ui: { changes: { apply: () => calls.push(['apply']) } } },
		{ getElementById: () => ({ querySelectorAll: () => [h.view.map] }) });
		await view[apply ? 'handleSaveApply' : 'handleSave'].call(view, {});
		assert.deepEqual(calls, [['save', 'https://EXAMPLE.test/sub?token=AbC%2f'], ...(apply ? [['apply']] : [])]);
	}
});

test('T9.49 channel URL validation keeps its existing error text and empty-value behavior', () => {
	const updates = loadModule(path.join(RES, 'aether-proxy/model/updates.js'),
		{ baseclass: { extend: o => o } }, {});
	assert.equal(updates.validate_url('https://a/sub'), true);
	assert.equal(updates.validate_url('ftp://a'), ERROR);
	assert.equal(updates.validate_url(''), ERROR);
});
