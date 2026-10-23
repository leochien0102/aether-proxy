'use strict';
// docs/10 r14: single-update availability is pure; pending hints win over saved disabled state.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadModule } = require('./loader');

globalThis._ = (text, context) => {
	assert.equal(context, 'aether-proxy');
	return text;
};
const model = loadModule(path.resolve(__dirname,
	'../../luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/model/subscriptions.js'),
	{ baseclass: { extend: value => value } }, {});

for (const enabled of [undefined, '1', '0']) {
	for (const pending of [false, true]) {
		for (const busy of [false, true]) {
			test(`T10.49 model: enabled=${enabled ?? 'default'} pending=${pending} busy=${busy} availability and hint`,
			() => {
				const subscription = { '.name': 's_a', enabled };
				assert.deepEqual(model.update_state(subscription, busy, pending), {
					can_update: !busy && !pending && enabled !== '0',
					hint: pending ? 'Please save and apply first' : enabled === '0' ? 'Subscription disabled' : ''
				});
				const vm = model.build([subscription], undefined, 0, busy);
				assert.equal(vm.rows[0].can_update, !busy && enabled !== '0');
				assert.equal(vm.can_update, !busy, 'Update all ignores individual saved enabled flags');
			});
		}
	}
}
