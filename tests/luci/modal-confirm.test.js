'use strict';

/* T10.14: themed confirmations and the five asynchronous action boundaries
 * from docs/10 「UI 规则」. Deferred answers catch both missing awaits and
 * cancellation paths that accidentally mutate UCI or dispatch a job. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, createRpc } = require('./loader');

const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = (text, context) => {
	assert.equal(context, 'aether-proxy');
	assert.ok(po[text], 'translation exists: ' + text);
	return po[text];
};
globalThis.E = (tag, attrs, children) => {
	if (typeof attrs === 'string' || Array.isArray(attrs)) {
		children = attrs;
		attrs = {};
	}
	return {
		tag, attrs: attrs ?? {}, children: children ?? [],
		replaceChildren(...nodes) { this.children = nodes; }
	};
};
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};

function deferred() {
	let resolve;
	const promise = new Promise(done => { resolve = done; });
	return { promise, resolve };
}

function model(name) {
	const modules = { baseclass: { extend: props => props } };
	if (name === 'overview')
		modules['aether-proxy.model.logs'] = model('logs');
	return loadModule(path.join(RES, 'aether-proxy/model', name + '.js'), modules, {});
}

for (const destructive of [ true, false, undefined ]) {
	for (const answer of [ true, false ]) {
		test(`T10.14 scenario 1: modal destructive=${destructive}, answer=${answer}, hide before resolve`,
			async (t) => {
			const events = [];
			let modal;
			const Module = loadModule(path.join(RES, 'aether-proxy/common.js'), {
				rpc: createRpc(),
				baseclass: { extend: props => {
					function Class() {}
					Class.prototype = props;
					return Class;
				} },
				ui: {
					showModal: (title, children) => { modal = { title, children }; events.push('show'); },
					hideModal: () => events.push('hide')
				}
			}, {});
			const ap = new Module();
			/* Observe the resolve invocation itself: a .then callback alone would
			 * run after hideModal even if the implementation called resolve first. */
			const NativePromise = Promise;
			const constructor = t.mock.method(globalThis, 'Promise', function(executor) {
				return new NativePromise((resolve, reject) => executor(value => {
					events.push('resolve');
					resolve(value);
				}, reject));
			});
			const pending = ap.confirm({ title: 'Title', text: '<plain body>', ok: 'Proceed', destructive });
			constructor.mock.restore();
			const outcomes = [];
			pending.then(value => outcomes.push(value));
			assert.equal(modal.title, 'Title');
			assert.equal(modal.children[0].tag, 'p');
			assert.equal(modal.children[0].children, '<plain body>');
			const row = modal.children[1];
			assert.equal(row.tag, 'div');
			assert.equal(row.attrs.class, 'right');
			const buttons = row.children.filter(child => child.tag === 'button');
			assert.deepEqual(buttons.map(button => button.children), [ '取消', 'Proceed' ]);
			assert.equal(buttons[0].attrs.class, 'cbi-button');
			assert.equal(buttons[1].attrs.class,
				'cbi-button ' + (destructive ? 'cbi-button-remove' : 'cbi-button-action'));
			await Promise.resolve();
			assert.deepEqual(outcomes, [], 'the result stays pending until a button is clicked');
			buttons[answer ? 1 : 0].attrs.click();
			assert.deepEqual(events, [ 'show', 'hide', 'resolve' ], 'hideModal precedes the resolve invocation');
			assert.equal(await pending, answer);
			assert.deepEqual(outcomes, [ answer ]);
			assert.deepEqual(events, [ 'show', 'hide', 'resolve' ]);
		});
	}
}

/* GridSection's inherited remove stages a UCI deletion. Record the inherited
 * call too, so losing this/section_id/event across await cannot go unnoticed. */
function formDouble(effects, uci) {
	return {
		Map: class {
			section() {
				return this.grid ??= {
					option: () => ({ value() {}, depends() {} }),
					super(method, args) {
						assert.equal(method, 'handleRemove');
						effects.push([ 'super', ...args ]);
						uci.remove('aetherproxy', args[0]);
					}
				};
			}
			render() { return Promise.resolve(E('div')); }
		}
	};
}

function view(name, ap, uci, effects) {
	return loadModule(path.join(RES, 'view/aether-proxy', name + '.js'), {
		view: { extend: props => props },
		form: formDouble(effects, uci), uci,
		ui: {
			createHandlerFn: (self, fn) => typeof fn === 'function' ? fn.bind(self) : () => {},
			changes: { apply: async rollback => { effects.push([ 'apply', rollback ]); } },
			addNotification: () => { effects.push([ 'notification' ]); }
		},
		dom: { content: (element, children) => { element.children = children; } },
		'aether-proxy.common': ap,
		['aether-proxy.model.' + name]: model(name)
	}, { window: { setTimeout: () => { effects.push([ 'timer' ]); } } });
}

for (const answer of [ true, false ]) {
	for (const action of [ 'stop', 'disable', 'node', 'subscription', 'rollback' ]) {
		test(`T10.14 scenario 2: ${action}, answer=${answer}, no effects before answer`, async () => {
			const effects = [], asked = [], gate = deferred();
			const nodes = [
				{ '.name': 'current', source: 's_a' },
				{ '.name': 'owned', source: 's_a' },
				{ '.name': 'other', source: 's_b' },
				{ '.name': 'manual', source: 'manual' }
			];
			const uci = {
				sections: (config, type) => type === 'node' ? nodes : [ { '.name': 's_a' } ],
				get: () => 'current',
				set: (...args) => effects.push([ 'set', ...args ]),
				remove: (...args) => effects.push([ 'remove', ...args ]),
				save: async () => { effects.push([ 'save' ]); }
			};
			const ap = {
				job_progress: () => ({ stop() {} }),
				confirm: options => { asked.push(options); return gate.promise; },
				call: async (...args) => { effects.push([ 'call', ...args ]); return { ok: true }; },
				run_job: async (...args) => {
					effects.push([ 'job', ...args ]);
					return { result: { ok: true, from: '2', to: '1' } };
				}
			};
			const name = ['stop', 'disable'].includes(action) ? 'overview'
				: action === 'node' ? 'nodes' : action === 'subscription' ? 'subscriptions' : 'updates';
			const page = view(name, ap, uci, effects);
			let pending, box, expected, title, text, ok;
			if (action === 'stop' || action === 'disable') {
				page.enabled = true;
				page.vm = model('overview').build({ ok: true, state: 'running' });
				if (action === 'stop') {
					title = '停止服务';
					text = page.vm.stop_confirmation;
					ok = '停止';
					pending = page.handleService('stop');
					expected = [ [ 'call', 'service', { action: 'stop' } ], [ 'timer' ] ];
				}
				else {
					title = '关闭「启用」';
					text = page.vm.disable_confirmation;
					ok = '关闭';
					box = page.enableSwitch('note').children.find(child => child.tag === 'input');
					box.checked = false;
					pending = box.attrs.change({ target: box });
					expected = [ [ 'set', 'aetherproxy', 'main', 'enabled', '0' ], [ 'save' ], [ 'apply', true ] ];
				}
			}
			else if (action === 'node') {
				page.rowMap = { owned: { can_delete: true } };
				const section = page.buildMap().grid;
				const event = { currentTarget: {} };
				pending = section.handleRemove('owned', event);
				title = '删除节点';
				text = '确定要删除这个节点吗？';
				ok = '删除';
				expected = [ [ 'super', 'owned', event ], [ 'remove', 'aetherproxy', 'owned' ] ];
			}
			else if (action === 'subscription') {
				page.status = { ok: true, subs: {} };
				page.root = E('div');
				await page.redraw();
				pending = page.grid.handleRemove('s_a');
				title = '删除订阅';
				text = model('subscriptions').delete_plan('s_a', nodes, 'current').confirm;
				ok = '删除';
				expected = [
					[ 'remove', 'aetherproxy', 'owned' ],
					[ 'set', 'aetherproxy', 'current', 'source', 'manual' ],
					[ 'set', 'aetherproxy', 'current', 'stale', '0' ],
					[ 'remove', 'aetherproxy', 's_a' ]
				];
			}
			else {
				page.inventory = E('div');
				page.summary = E('p');
				page.progress = E('p');
				page.status = {};
				const row = { name: 'xray-core', confirmation: model('updates').confirmation('xray-core', '2', '1') };
				pending = page.package_button(row, 'rollback', true).attrs.click();
				title = '回滚 xray-core';
				text = row.confirmation;
				ok = '回滚';
				expected = [ [ 'job', 'update_package', [ 'xray-core', '--previous' ] ], [ 'call', 'status' ] ];
			}
			assert.deepEqual(asked, [ { title, text, ok, destructive: true } ]);
			await Promise.resolve();
			assert.deepEqual(effects, [], 'pending confirmation has no side effects');
			gate.resolve(answer);
			await pending;
			assert.deepEqual(effects, answer ? expected : []);
			if (box) {
				assert.equal(page.enabled, !answer);
				assert.equal(box.checked, !answer, 'cancel restores the switch to on');
			}
		});
	}
}
