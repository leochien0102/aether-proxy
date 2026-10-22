'use strict';

/* T10.30: exercise the real modal option declarations and validators (docs/10
 * 「节点编辑框新字段」). The double records depends() including !reverse and
 * exposes live form values through Map.lookupOption(), as the SDK does.
 * T10.33 adds long-key input/write and preserved dropdown rendering checks.
 * No SDK, backend or browser is required to run these regression tests. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, element } = require('./loader');
const { widgetTypes, inputOf } = require('./node-input-widgets');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = (text, context) => {
	assert.equal(context, 'aether-proxy');
	assert.ok(po[text], 'translated: ' + text);
	return po[text];
};
globalThis.E = element;
String.prototype.format = function(...args) {
	let index = 0;
	return this.replace(/%s/g, () => args[index++]);
};

// Independent docs/05 inventory: grouped concurrency/socket rows expand to eleven UCI options.
const NEW_FIELDS = {
	grpc_multi_mode: ['Flag', [{ transport: 'grpc' }]],
	ws_heartbeat: ['Value', [{ transport: 'ws' }]],
	xhttp_extra: ['TextValue', [{ transport: 'xhttp' }]],
	ech_config_list: ['TextValue', [{ security: 'tls' }]],
	reality_pqv: ['TextValue', [{ security: 'reality' }]],
	mux: ['Flag', [{ flow: /^xtls-rprx-vision(-udp443)?$/, '!reverse': true }]],
	mux_concurrency: ['Value', [{ mux: '1' }]],
	mux_xudp_concurrency: ['Value', [{ mux: '1' }]],
	mux_xudp_udp443: ['ListValue', [{ mux: '1' }]],
	tcp_fast_open: ['Flag', []],
	tcp_mptcp: ['Flag', []]
};
function harness() {
	const live = {}, stored = {}, options = new Map();
	const form = widgetTypes();
	form.Map = class {
		constructor(config) {
			this.config = config;
			this.data = { set: (config, id, field, value) => {
				assert.equal(config, 'aetherproxy');
				assert.equal(id, 'n_edit');
				stored[field] = value;
			} };
		}
		lookupOption(field, id) {
			assert.equal(id, 'n_edit');
			return options.has(field) ? [options.get(field), id] : null;
		}
		section() {
			const map = this;
			return {
				option(kind, field, title) {
					const o = Object.assign(Object.create(kind.prototype), {
						kind: Object.keys(form).find(key => form[key] === kind),
						field, option: field, title, map, deps: [],
						depends(field, value) {
							this.deps.push(typeof field === 'string' ? { [field]: value } : field);
						},
						formvalue: () => live[field]
					});
					Object.defineProperty(o, 'choices', {
						get: () => o.keylist?.map((key, i) => [key, o.vallist[i]]) ?? []
					});
					options.set(field, o);
					return o;
				}
			};
		}
	};
	const model = loadModule(path.join(RES, 'aether-proxy/model/nodes.js'),
		{ baseclass: { extend: o => o } }, {});
	const page = loadModule(path.join(RES, 'view/aether-proxy/nodes.js'), {
		view: { extend: o => o }, form,
		uci: { get: (config, id, field) => stored[field] }, ui: {}, dom: {},
		'aether-proxy.common': {}, 'aether-proxy.model.nodes': model
	}, {});
	page.buildMap();
	return { options, live, stored, model };
}
// SDK dependencies are OR across objects, AND within one, with !reverse negating the result.
function visible(option, values) {
	return !option.deps.length || option.deps.some(dep => {
		const equal = Object.entries(dep).filter(([key]) => key !== '!reverse')
			.every(([key, value]) => value instanceof RegExp
				? values[key] != null && value.test(values[key]) : values[key] === value);
		return dep['!reverse'] ? !equal : equal;
	});
}

test('T10.30 scenario 1: new modal fields use docs/05 names, widget types and exact dependencies', () => {
	const { options } = harness();
	for (const [field, [kind, deps]] of Object.entries(NEW_FIELDS)) {
		const o = options.get(field);
		assert.ok(o, field + ' exists');
		assert.equal(o.kind, kind, field + ' widget');
		assert.equal(o.modalonly, true, field + ' never adds a table column');
		assert.deepEqual(o.deps, deps, field + ' depends');
		if (deps[0]?.transport || deps[0]?.security) {
			const key = deps[0].transport ? 'transport' : 'security';
			const values = key === 'transport' ? ['raw', 'grpc', 'ws', 'xhttp', 'httpupgrade']
				: ['none', 'tls', 'reality'];
			for (const value of values)
				assert.equal(visible(o, { [key]: value }), value === deps[0][key], field + ': ' + value);
		}
	}
	for (const protocol of ['vless', 'vmess', 'trojan', 'shadowsocks']) {
		for (const field of ['mux', 'tcp_fast_open', 'tcp_mptcp'])
			assert.equal(visible(options.get(field), { protocol }), true, field + ' for ' + protocol);
	}
	assert.equal(options.get('flow').description, 'Vision 不支持多路复用。');
	assert.equal(options.get('path').description, 'WebSocket 的 early data 写在路径里，如 /path?ed=2048。');
	assert.ok(!options.has('uot'), 'Shadowsocks has no UDP over TCP option');
});

test('T10.30 scenario 2: Vision hides Mux and validation rejects enabled Mux using live or stored flow', () => {
	const { options, live, stored } = harness();
	const mux = options.get('mux');
	assert.equal(visible(mux, { flow: 'xtls-rprx-vision' }), false);
	assert.equal(visible(mux, { flow: '' }), true);
	assert.equal(visible(mux, {}), true);
	stored.flow = 'xtls-rprx-vision';
	assert.equal(mux.validate('n_edit', '1'), 'Vision 流控不能同时开启多路复用');
	assert.equal(mux.validate('n_edit', '0'), true);
	assert.equal(mux.validate('n_edit', ''), true);
	live.flow = '';
	assert.equal(mux.validate('n_edit', '1'), true, 'clearing live flow overrides the stored Vision value');
	stored.flow = '';
	live.flow = 'xtls-rprx-vision';
	assert.equal(mux.validate('n_edit', '1'), 'Vision 流控不能同时开启多路复用');
	for (const field of ['mux_concurrency', 'mux_xudp_concurrency', 'mux_xudp_udp443']) {
		for (const value of ['0', '', undefined])
			assert.equal(visible(options.get(field), { mux: value }), false, field + ' hidden when off');
		assert.equal(visible(options.get(field), { mux: '1' }), true, field + ' shown when on');
	}
});

test('T10.30 scenario 3: XHTTP extra accepts only JSON objects or empty input with Chinese errors', () => {
	const extra = harness().options.get('xhttp_extra');
	for (const value of ['{"a":1}', '{}', '{"nested":{"b":[1]}}', '', undefined, null])
		assert.equal(extra.validate('n_edit', value), true, String(value));
	for (const value of ['[1]', 'null', '"x"', '{bad', '1', 'true', ' '])
		assert.equal(extra.validate('n_edit', value), '须为 JSON 对象', value);
});

test('T10.30 scenario 4: heartbeat and concurrency use exact LuCI ranges and non-writing placeholders', () => {
	const { options } = harness();
	assert.equal(options.get('ws_heartbeat').datatype, 'range(1,3600)');
	for (const [field, placeholder] of [['mux_concurrency', '8'], ['mux_xudp_concurrency', '16']]) {
		assert.equal(options.get(field).datatype, 'range(-1,1024)');
		assert.equal(options.get(field).placeholder, placeholder);
		assert.equal(options.get(field).default, undefined, 'empty uses Xray defaults, not stored values');
	}
	assert.deepEqual(options.get('mux_xudp_udp443').choices, [
		['', '默认（拒绝）'], ['reject', '拒绝'], ['allow', '允许'], ['skip', '不经多路复用']
	]);
});

test('T10.30 scenario 5: parse cleanup includes every new option and the node table columns are unchanged', () => {
	const { options, model } = harness();
	for (const field of Object.keys(NEW_FIELDS))
		assert.ok(model.node_fields.includes(field), field + ' is cleared before parsing');
	assert.equal(new Set(model.node_fields).size, model.node_fields.length, 'no duplicate cleanup fields');
	assert.deepEqual([...options.values()].filter(o => o.modalonly === false).map(o => o.field),
		['_select', '_label', '_protocol', '_transport_security', '_source', '_current', '_probe']);
});

for (const field of ['reality_pqv', 'ech_config_list']) {
	test(`T10.33 scenario 1: ${field} wraps at four rows, counts live input and saves without whitespace`, () => {
		const { options, stored } = harness();
		const option = options.get(field);
		assert.equal(option.kind, 'TextValue');
		assert.equal(option.rows, 4);
		assert.equal(option.wrap, true);
		const original = 'A'.repeat(2600) + '=+/';
		const widget = option.renderWidget('n_edit', 0, original);
		const input = inputOf(widget);
		const count = widget.children[1];
		assert.equal(input.tag, 'textarea');
		assert.equal(input.rows, 4);
		assert.equal(input.wrap, 'soft');
		assert.equal(input.value, original, 'opening the modal preserves long opaque strings');
		assert.equal(count.textContent, '2603 个字符');
		assert.equal(stored[field], undefined, 'rendering does not stage a write');
		for (const [value, expected] of [
			[' ab\tcd\r\nEF +/=\u00a0', 'abcdEF+/='],
			[' \n\t\r\u00a0', ''],
			[original.slice(0, 1300) + '\n ' + original.slice(1300), original],
			['', '']
		]) {
			input.value = value;
			input.input({ currentTarget: input });
			assert.equal(count.textContent, `${expected.length} 个字符`);
			option.write('n_edit', input.value);
			assert.equal(stored[field], expected, 'write removes all whitespace, not punctuation');
		}
		const reopened = option.renderWidget('n_edit', 0, 'Y Z');
		inputOf(reopened).value = 'XYZ';
		inputOf(reopened).input({ currentTarget: inputOf(reopened) });
		assert.equal(reopened.children[1].textContent, '3 个字符');
		assert.equal(count.textContent, '0 个字符', 'each modal owns its count element');
	});
}

test('T10.33 scenario 2: Flow has three choices and fingerprint has nine choices including translated empty values',
() => {
	const { options } = harness();
	const flow = options.get('flow');
	assert.equal(flow.kind, 'ListValue');
	assert.equal(flow.title, '流控');
	assert.deepEqual(flow.choices, [
		['', '无'], ['xtls-rprx-vision', 'xtls-rprx-vision'],
		['xtls-rprx-vision-udp443', 'xtls-rprx-vision-udp443']
	]);
	const fingerprint = options.get('fingerprint');
	assert.equal(fingerprint.kind, 'ListValue');
	assert.deepEqual(fingerprint.choices, [
		['', '不设'], ...['chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random', 'randomized']
			.map(value => [value, value])
	]);
	assert.deepEqual(flow.deps, [{ protocol: 'vless' }]);
	assert.deepEqual(fingerprint.deps, [{ security: 'tls' }, { security: 'reality' }]);
	for (const option of [flow, fingerprint]) {
		assert.equal(option.modalonly, true);
		assert.equal(option.renderWidget('n_edit', 0, '').value, '');
		for (const [value] of option.choices)
			assert.equal(option.renderWidget('n_edit', 0, value).value, value);
	}
});

for (const [field, legacy, other] of [['flow', 'xtls-rprx-direct', 'old-flow'], ['fingerprint', '360', 'unsafe']]) {
	test(`T10.33 scenario 2: ${field} preserves selected ${legacy} only for the node being rendered`, () => {
		const { options, stored } = harness();
		const option = options.get(field);
		const choices = structuredClone(option.choices);
		const widget = option.renderWidget('n_edit', 0, legacy);
		assert.equal(widget.value, legacy);
		assert.equal(widget.children.length, choices.length + 1);
		assert.equal(widget.children.at(-1).value, legacy);
		assert.equal(widget.children.at(-1).textContent, legacy);
		assert.equal(widget.children.at(-1).selected, true);
		option.write('n_edit', widget.value);
		assert.equal(stored[field], legacy, 'editing and saving never silently replace an old value');
		assert.deepEqual(option.choices, choices, 'base option is not changed by another node');
		const second = option.renderWidget('n_other', 0, other);
		assert.equal(second.value, other);
		assert.equal(second.children.length, choices.length + 1);
		assert.ok(!second.children.some(child => child.value === legacy));
		for (const value of ['', undefined, null]) {
			const normal = option.renderWidget('n_normal', 0, value);
			assert.equal(normal.value, '');
			assert.equal(normal.children.length, choices.length, 'no stale legacy choices on another node');
		}
		option.write('n_edit', '');
		assert.equal(stored[field], '', 'the explicit empty choice can clear the value');
	});
}

test('T10.33 scenario 3: both Vision flows hide Mux and reject enabled Mux against live and stored values', () => {
	for (const flow of ['xtls-rprx-vision', 'xtls-rprx-vision-udp443']) {
		const { options, live, stored } = harness();
		const mux = options.get('mux');
		assert.equal(visible(mux, { flow }), false, flow + ' hides Mux');
		stored.flow = flow;
		assert.equal(mux.validate('n_edit', '1'), 'Vision 流控不能同时开启多路复用');
		for (const value of ['0', ''])
			assert.equal(mux.validate('n_edit', value), true);
		live.flow = '';
		assert.equal(visible(mux, { flow: live.flow }), true, 'empty flow shows Mux');
		assert.equal(mux.validate('n_edit', '1'), true, 'live empty overrides stored Vision');
		stored.flow = '';
		live.flow = flow;
		assert.equal(mux.validate('n_edit', '1'), 'Vision 流控不能同时开启多路复用');
	}
	const { options, live } = harness();
	for (const flow of ['', undefined, 'xtls-rprx-direct', 'prefix-xtls-rprx-vision', 'xtls-rprx-vision-extra']) {
		live.flow = flow;
		assert.equal(visible(options.get('mux'), { flow }), true, 'only the two exact Vision values hide Mux');
		assert.equal(options.get('mux').validate('n_edit', '1'), true);
	}
});
