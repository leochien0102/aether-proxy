'use strict';

// T9.41 D-F2: real SDK datatype contract plus actual modal/save and backend parity.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { harness, RES } = require('./required-modal');
const { loadModule, element } = require('./loader');
const types = require('./form-sdk');
const ROOT = path.resolve(__dirname, '../..');
globalThis._ = text => text;
String.prototype.format = function(...args) { let i = 0; return this.replace(/%[sdf]/g, () => args[i++]); };
const BASE = { protocol: 'vmess', address: '192.168.1.2', port: '443', uuid: 'id', transport: 'ws', mux: '1' };
const BOUNDS = { port: [1, 65535], ws_heartbeat: [1, 3600], mux_concurrency: [-1, 1024],
	mux_xudp_concurrency: [-1, 1024], data_hour: [0, 23], data_minute: [0, 59] };
function values(min, max) {
	return [...new Set([String(min - 1), String(min), '0', '1', String(max), String(max + 1),
		'1.5', ' 1', '1 ', ' ', '1\n', '+1', '01', '000000001', '0000000001', '-00000001',
		null, undefined, ''])];
}
function backend(field, inputs) {
	const rows = inputs.map(value => field.startsWith('data_') ? { update: { [field]: value } }
		: { nodes: { ['n_' + 'a'.repeat(32)]: { ...BASE, [field]: value } } });
	const p = spawnSync(path.join(ROOT, 'tests/host/ucode'), ['-e',
		"import * as c from 'aetherproxy.config'; import * as x from 'aetherproxy.render.outbound'; " +
		"printf('%.J', map(" + JSON.stringify(rows) + ", raw => { let r=c.normalize(raw); " +
		"if (r.ok && length(keys(r.snapshot.nodes))) r.outbound=x.build_outbound(values(r.snapshot.nodes)[0]); " +
		"return r; }));"], { cwd: ROOT, encoding: 'utf8' });
	assert.equal(p.status, 0, p.stderr);
	return JSON.parse(p.stdout);
}
async function updateOptions(saved) {
	const options = {}, data = { ...saved }, calls = [];
	const section = { children: [], map: { config: 'aetherproxy', data: {
		get: (c, s, f) => data[f], set: (c, s, f, v) => { calls.push(['set', f, v]); data[f] = v; },
		unset: (c, s, f) => { calls.push(['unset', f]); delete data[f]; }
	} }, option(Kind, field) {
		const o = new Kind(this, field);
		this.children.push(o);
		options[field] = o;
		return o;
	} };
	const view = loadModule(path.join(RES, 'view/aether-proxy/updates.js'), {
		view: { extend: o => o }, form: { ...types, Map: class {
			section() { return section; } render() { return Promise.resolve(element('form')); }
		} }, uci: {}, ui: {}, 'aether-proxy.common': {}, 'aether-proxy.model.updates': {}
	}, { window: { setTimeout() {} }, document: {} });
	view.show_inventory = () => {};
	globalThis.E = element;
	await view.render();
	return { options, data, calls };
}

for (const version of ['24.10.8', '25.12.5']) {
	test('T9.41 SDK ' + version + ': port includes zero and range uses decimal parsing', t => {
		const file = `/workspace/openwrt/sdk-spike/sdk-${version}/feeds/luci/modules/luci-base/`
			+ 'htdocs/luci-static/resources/validation.js';
		if (!fs.existsSync(file)) return t.skip('read-only SDK not available');
		const sdk = loadModule(file, { baseclass: { extend: o => o } }, { window: {}, document: {} });
		for (const [datatype, args, inputs] of [['port', [], ['-1', '0', '1', '65535', '65536', '01', '1.5']],
			['range', [-1, 1024], ['-2', '-1', '0', '1024', '1025', '1.5', ' 1', '1\n']]]) {
			for (const value of inputs) {
				const ctx = { value, factory: sdk, assert: c => !!c };
				const expected = sdk.types[datatype].apply(ctx, args);
				const o = new types.Value({ map: {} }, 'x');
				o.datatype = datatype === 'range' ? 'range(-1,1024)' : 'port';
				o.formvalue = () => value;
				assert.equal(o.isValid('row'), expected, datatype + ' ' + JSON.stringify(value));
			}
		}
	});
}
for (const [field, [min, max]] of Object.entries(BOUNDS)) {
	test('T9.41 number parity/save ' + field + ': bounds decimal whitespace leading-zero null missing empty',
	async () => {
		const inputs = values(min, max), results = backend(field, inputs);
		for (const [i, value] of inputs.entries()) {
			const result = results[i];
			const h = field.startsWith('data_') ? await updateOptions({ [field]: '2' }) : await harness('node', BASE);
			const o = h.options?.[field] ?? h.option(field);
			// Distinguish missing and explicit null at the validation boundary, without widget fallback.
			o.formvalue = () => value;
			const valid = o.isValid('row') && !(field === 'port' && (value == null || value === ''));
			assert.equal(valid, result.ok, field + ' ' + JSON.stringify(value));
			if (!result.ok) {
				if (h.save) {
					await h.save();
					assert.equal(h.open, true);
					assert.deepEqual(h.calls, []);
					assert.ok(h.modal.root.querySelectorAll('.alert-message').length);
				} else {
					await assert.rejects(o.parse('update'));
					assert.deepEqual(h.calls, []);
				}
			} else {
				await o.parse(field.startsWith('data_') ? 'update' : 'row');
				const stored = h.data.row ?? h.data;
				if (value == null || value === '') assert.equal(stored[field], undefined);
				else assert.equal(stored[field], value);
				const normalized = field.startsWith('data_') ? result.snapshot.update[field]
					: result.snapshot.nodes['n_' + 'a'.repeat(32)][field];
				assert.equal(normalized, value == null || value === '' ?
					(field === 'data_hour' ? 4 : field === 'data_minute' ? null : undefined) : +value);
				if (result.outbound) {
					const applied = { port: result.outbound.settings.port,
						ws_heartbeat: result.outbound.streamSettings.wsSettings.heartbeatPeriod,
						mux_concurrency: result.outbound.mux.concurrency,
						mux_xudp_concurrency: result.outbound.mux.xudpConcurrency };
					assert.equal(applied[field], normalized, 'applied Xray value ' + field);
				}
			}
		}
	});
}
