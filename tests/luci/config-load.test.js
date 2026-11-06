'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadModule, scanRequires } = require('./loader.js');
const fs = require('node:fs');
global._ = text => text;
const RES = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');

/* Model uci.js loadPackage/load, not ap.call: the transport rejects with an
 * ordinary Error; loaded[config] retains its Promise even on rejection.
 * load() wraps cached package promises in Promise.all and returns config names.
 * unload is synchronous, returns undefined, and clears package state/cache.
 * No RPC_FAILED conversion, implicit eviction, or uncached failure shortcut. */
function setup(outcomes) {
	const calls = [];
	const loaded = {};
	const values = {};
	let requests = 0;
	const uci = {
		load(config) {
			calls.push('load');
			assert.equal(config, 'aetherproxy');
			if (!loaded[config]) {
				const outcome = outcomes[requests++];
				calls.push('request');
				loaded[config] = Promise.resolve().then(() => {
					if (outcome instanceof Error) throw outcome;
					values[config] = outcome || {};
				});
			}
			return Promise.all([ loaded[config] ]).then(() => [ config ]);
		},
		unload(config) {
			assert.equal(config, 'aetherproxy');
			calls.push('unload');
			delete loaded[config];
			delete values[config];
		},
		get: () => undefined,
		add: (config, type, name) => { calls.push('add:' + name); return name; },
		sections: () => [],
	};
	const ap = loadModule(process.env.AETHER_CONFIG_LOAD_MUTANT || path.join(RES, 'aether-proxy/common.js'), {
		baseclass: { extend: o => o }, rpc: { declare: () => () => {} }, ui: {}, uci
	}, {});
	return { ap, uci, calls, requests: () => requests };
}

function page(name, ap, uci, extras = {}) {
	const file = path.join(RES, 'view/aether-proxy', name + '.js');
	const modules = Object.fromEntries(scanRequires(fs.readFileSync(file, 'utf8')).map(r => [ r.name, {} ]));
	return loadModule(file, { ...modules, view: { extend: o => o },
		'aether-proxy.common': ap, uci, ...extras }, {
		L: { resolveDefault: (p, fallback) => p.catch(() => fallback) }
	});
}

const first = () => new Error('No related RPC reply');

test('config load: transient transport rejection clears cache before exactly one retry', async () => {
	const s = setup([ first(), {} ]);
	assert.deepEqual(await s.ap.load_config(), [ 'aetherproxy' ]);
	assert.deepEqual(s.calls, [ 'load', 'request', 'unload', 'load', 'request' ]);
});

test('config load: existing rejected cache is recovered on a later page visit', async () => {
	const error = first();
	const s = setup([ error, {} ]);
	await assert.rejects(s.uci.load('aetherproxy'), e => e === error);
	await assert.rejects(s.uci.load('aetherproxy'), e => e === error);
	assert.equal(s.requests(), 1, 'rejected package promise must remain cached');
	await s.ap.load_config();
	assert.equal(s.requests(), 2);
	assert.equal(s.calls.filter(c => c === 'unload').length, 1);
});

test('config load: persistent failure rejects with the exact second error and never retries twice', async () => {
	const second = new Error('still unavailable');
	const s = setup([ first(), second, {} ]);
	await assert.rejects(s.ap.load_config(), e => e === second);
	assert.deepEqual(s.calls, [ 'load', 'request', 'unload', 'load', 'request' ]);
	assert.equal(s.requests(), 2);
});

test('config load: first success neither unloads nor sends a duplicate request', async () => {
	const s = setup([ {} ]);
	assert.deepEqual(await s.ap.load_config(), [ 'aetherproxy' ]);
	assert.deepEqual(s.calls, [ 'load', 'request' ]);
});

test('config load: two concurrent views have bounded retries during persistent failure', async () => {
	const error = first();
	const s = setup([ error, error, error, error ]);
	const views = [ 'rules', 'logs' ].map(name => page(name, s.ap, s.uci));
	const results = await Promise.allSettled(views.map(v => v.load()));
	assert.ok(results.every(r => r.status === 'rejected' && r.reason === error));
	assert.equal(s.calls.filter(c => c === 'load').length, 4, 'each view gets at most two loads');
	assert.equal(s.calls.filter(c => c === 'unload').length, 2);
	assert.equal(s.requests(), 3, 'initial shared failure plus one fresh request per caller');
});

test('config load: two concurrent views recover after their shared initial failure', async () => {
	const s = setup([ first(), {}, {} ]);
	await Promise.all([ page('rules', s.ap, s.uci).load(), page('logs', s.ap, s.uci).load() ]);
	assert.equal(s.calls.filter(c => c === 'load').length, 4);
	assert.equal(s.requests(), 3);
});

test('config load: all six view loads use the helper and preserve auxiliary work', async () => {
	for (const name of [ 'overview', 'nodes', 'access', 'rules', 'updates', 'logs' ]) {
		const s = setup([ first(), {} ]);
		let helpers = 0, hints = 0;
		const ap = { ...s.ap, load_config: () => { helpers++; return s.ap.load_config(); } };
		const v = page(name, ap, s.uci, {
			'aether-proxy.subscriptions-block': { required_options: {} },
			network: { getHostHints: () => { hints++; return Promise.resolve({ host: 'hint' }); } }
		});
		const data = await v.load();
		assert.equal(helpers, 1, name);
		assert.equal(s.requests(), 2, name + ': no extra RPC after successful retry');
		assert.equal(s.calls.filter(c => c === 'add:sub').length, name === 'nodes' ? 1 : 0);
		assert.equal(hints, name === 'access' ? 1 : 0);
		if (name === 'access') assert.deepEqual(data[1], { host: 'hint' });
	}
});
