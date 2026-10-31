'use strict';

/* T10.26: manual node staging and share-link parsing (docs/10 「添加节点」),
 * plus the separate protocol columns. The form double follows the SDK's
 * GridSection addedSection + isSaving contract, including an unsuccessful
 * modal Save. No real UCI, backend parsing or browser is needed. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo, contentChildren } = require('./loader');
const { modalElement: element } = require('./modal-dom');
const { Value: SdkValue } = require('./form-sdk');
const { widgetTypes, inputOf } = require('./node-input-widgets');
const RES = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.resolve(RES, '../../../po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = (s, context) => {
	assert.equal(context, 'aether-proxy');
	assert.ok(po[s], 'translated: ' + s);
	return po[s];
};
globalThis.E = element;
String.prototype.format = function(...args) {
	let index = 0;
	return this.replace(/%s/g, () => args[index++]);
};
const model = loadModule(path.join(RES, 'aether-proxy/model/nodes.js'),
	{ baseclass: { extend: o => o } }, {});
// Independent docs/05 field inventory: an omission in the model must fail cleanup tests.
const NODE_FIELDS = [
	'label', 'protocol', 'address', 'port', 'secret_key', 'peer_public_key', 'local_address', 'preshared_key',
	'keepalive', 'uuid', 'username', 'password', 'method', 'flow', 'encryption',
	'transport', 'host', 'path', 'service_name', 'xhttp_mode', 'header_type', 'security',
	'sni', 'alpn', 'fingerprint', 'pinned_cert_sha256', 'verify_name',
	'reality_pbk', 'reality_sid', 'reality_spx', 'reality_pqv', 'ech_config_list',
	'grpc_multi_mode', 'ws_heartbeat', 'xhttp_extra', 'mux', 'mux_concurrency',
	'mux_xudp_concurrency', 'mux_xudp_udp443', 'tcp_fast_open', 'tcp_mptcp'
];
const flush = () => new Promise(resolve => setImmediate(resolve));
function find(root, predicate) {
	if (!root || typeof root !== 'object')
		return [];
	return (predicate(root) ? [root] : []).concat((root.children ?? []).flatMap(child => find(child, predicate)));
}
function button(root, label) {
	return find(root, node => node.tag === 'button' && node.textContent === label)[0];
}
function deferred() {
	let resolve;
	const promise = new Promise(done => { resolve = done; });
	return { promise, resolve };
}
function optionSection(map) {
	return {
		children: [],
		option(kind, field, title) {
			const option = Object.assign(Object.create(kind.prototype), {
				field, option: field, title, map, deplist: [],
				depends(field, value) { this.deplist.push(typeof field === 'string' ? { [field]: value } : field); }
			});
			this.children.push(option);
			return option;
		}
	};
}
function gridDouble(map, h) {
	const grid = optionSection(map);
	grid.renderMoreOptionsModal = async function(id) {
		const modal = optionSection(map);
		modal.children = this.children.filter(o => o.modalonly !== false)
			.map(o => Object.assign(Object.create(Object.getPrototypeOf(o)), o));
		this.addModalOptions(modal, id);
		h.modal = { id, section: modal, widgets: {} };
		// SDK passes the cloned map to handleModalSave; its live widgets are
		// independent of the parent map and isActive follows dependencies.
		h.modal.map = {
			config: map.config, data: map.data,
			section: id, children: [modal],
			lookupOption: field => modal.children.filter(o => o.field === field),
			findElement: (attr, cbid) => ({ querySelectorAll: () => [h.modal.widgets[cbid]] })
		};
		h.modal.node = E('div', {}, modal.children.map(o => {
			o.map = h.modal.map;
			o.cbid = () => o.field;
			o.formvalue = () => h.modal.widgets[o.field]?.value;
			o.cfgvalue = () => h.uci.get('aetherproxy', id, o.ucioption ?? o.field);
			o.isActive = () => SdkValue.prototype.isActive.call(o, id);
			o.getValidationError = () => SdkValue.prototype.getValidationError.call(o, id);
			o.isValid = () => SdkValue.prototype.isValid.call(o, id);
			const cfgvalue = h.uci.get('aetherproxy', id, o.ucioption ?? o.field);
			const widget = o.renderWidget ? o.renderWidget(id, 0, cfgvalue)
				: E('input', { value: cfgvalue ?? '' });
			h.modal.widgets[o.field] = o.field === '_share' ? widget : inputOf(widget);
			h.modal.widgets[o.field].style ??= {};
			return E('label', {}, [o.title, widget]);
		}));
		h.modal.map.root = h.modal.node;
	};
	grid.handleModalCancel = async function(modal, ev, isSaving) {
		h.calls.push(['grid.cancel', isSaving]);
		if (map.addedSection != null && !isSaving)
			h.uci.remove('aetherproxy', map.addedSection);
		delete map.addedSection;
		h.modal = null;
	};
	grid.handleModalSave = async function() {
		h.calls.push(['modal.save', null, true]);
		if (h.saveGate)
			await h.saveGate.promise;
		// Like LuCI, failed validation leaves the modal and addedSection intact.
		if (h.invalid)
			return;
		const modal = h.modal;
		for (const o of modal.section.children) {
			if (o.field !== '_share' && (!o.ucioption || o.isActive(modal.id)))
				o.write(modal.id, modal.widgets[o.field].value);
		}
		await this.handleModalCancel(modal, {}, true);
	};
	grid.super = function(method) {
		assert.equal(method, 'renderRowActions', 'must not skip native GridSection modal handlers');
		return E('td', {}, [E('div')]);
	};
	return grid;
}
function formDouble(h) {
	return { ...widgetTypes(), Map: class {
		constructor(config) { this.config = config; this.data = h.uci; }
		section() { this.grid = gridDouble(this, h); return this.grid; }
		lookupOption(field) {
			return [{ formvalue: () => h.modal?.widgets[field]?.value }];
		}
		async render() {
			const columns = this.grid.children.filter(o => o.modalonly === false);
			return E('form', {}, [
				E('tr', {}, columns.map(o => E('th', {}, o.title))),
				...h.uci.sections('aetherproxy', 'node').map(node => E('div', { sid: node['.name'] },
					columns.map(o => E('td', {}, o.textvalue(node['.name'])))))
			]);
		}
	} };
}
async function harness() {
	const h = { calls: [], rpc: [], modal: null };
	let randomByte = 0xaa;
	h.sections = [
		{ '.name': 'main', '.type': 'global', node: 'n_existing', mode: 'global' },
		{ '.name': 'n_existing', '.type': 'node', label: 'Existing', source: 'manual' }
	];
	h.uci = {
		load: async () => {},
		sections: (config, type) => h.sections.filter(s => !type || s['.type'] === type),
		get: (config, id, field) => {
			const section = h.sections.find(s => s['.name'] === id);
			return field == null ? section : section?.[field];
		},
		add: (config, type, id) => {
			h.calls.push(['add', config, type, id]);
			h.sections.push({ '.name': id, '.type': type });
			return id;
		},
		set: (config, id, field, value) => {
			h.calls.push(['set', config, id, field, value]);
			h.uci.get(config, id)[field] = value;
		},
		unset: (config, id, field) => {
			h.calls.push(['unset', config, id, field]);
			delete h.uci.get(config, id)[field];
		},
		remove: (config, id) => {
			h.calls.push(['remove', config, id]);
			h.sections = h.sections.filter(s => s['.name'] !== id);
		}
	};
	const ap = { call: async (method, params) => {
		h.rpc.push([method, params]);
		return h.reply;
	} };
	h.page = loadModule(path.join(RES, 'view/aether-proxy/nodes.js'), {
		view: { extend: o => o }, form: formDouble(h), uci: h.uci,
		ui: {
			createHandlerFn: (ctx, fn, ...args) => ev => {
				const target = ev.currentTarget;
				target.disabled = true;
				Promise.resolve((typeof fn === 'string' ? ctx[fn] : fn).apply(ctx, [...args, ev]))
					.finally(() => { target.disabled = false; });
			},
			changes: { apply: () => assert.fail('must not apply session changes') },
			addNotification: (...args) => h.calls.push(['notify', ...args])
		},
		dom: { content: (target, content) => contentChildren(target, content) },
		'aether-proxy.common': ap, 'aether-proxy.model.nodes': model,
		// Isolate node modal staging; progressive-lists exercises the real subscription map.
		'aether-proxy.subscriptions-block': { load: () => h.uci.load('aetherproxy'), render: async () => E('div') }
	}, { window: {
		setTimeout() {},
		crypto: { getRandomValues: bytes => {
			assert.equal(bytes.length, 16);
			return bytes.fill(++randomByte);
		} }
	} });
	await h.page.load();
	h.root = await h.page.render();
	return h;
}
async function add(h) {
	const addButton = button(h.root, '添加节点');
	assert.match(addButton.class, /cbi-button-add/);
	addButton.click({ currentTarget: addButton });
	await flush();
	return h.page.pendingAdd.id;
}
function share(h) {
	const widget = h.modal.widgets._share;
	return {
		input: find(widget, node => node.tag === 'input')[0],
		parse: button(widget, '解析'), error: widget.children[1]
	};
}
async function parse(h, uri, reply) {
	const controls = share(h);
	controls.input.value = uri;
	h.reply = reply;
	controls.parse.click({ currentTarget: controls.parse });
	await flush();
	return controls;
}

test('T10.26 scenario 1: UUID v4 lowercase node IDs set version/variant and retry collisions', () => {
	const bytes = new Uint8Array(16).fill(0xff);
	const id = model.new_id([], () => bytes);
	assert.equal(id, 'n_ffffffffffff4fffbfffffffffffffff');
	assert.match(id, /^n_[0-9a-f]{12}4[0-9a-f]{3}[89ab][0-9a-f]{15}$/);
	assert.ok(bytes.every(b => b === 0xff), 'must not mutate injected random bytes');
	let calls = 0;
	const next = model.new_id([id], () => ++calls === 1 ? bytes : new Uint8Array(16));
	assert.equal(calls, 2);
	assert.equal(next, 'n_00000000000040008000000000000000');
});

test('T10.26 scenario 2: Add opens a manual node modal; Cancel removes it and keeps the table unchanged', async () => {
	const h = await harness();
	const table = find(h.root, node => node.tag === 'form')[0];
	const before = structuredClone(h.sections);
	const id = await add(h);
	assert.match(id, /^n_[0-9a-f]{32}$/);
	assert.equal(h.uci.get('aetherproxy', id, 'source'), 'manual');
	assert.equal(h.page.nodeMap.addedSection, id);
	assert.equal(h.modal.id, id);
	assert.equal(h.modal.section.children[0].field, '_share', 'share link comes before all protocol fields');
	assert.match(h.modal.node.textContent, /^从分享链接填写/);
	assert.equal(find(h.root, node => node.sid === id).length, 0, 'new row is not drawn before Save');
	await h.page.nodeGrid.handleModalCancel(h.modal, {}, false);
	assert.equal(h.modal, null);
	assert.equal(h.page.pendingAdd, null);
	assert.equal(h.page.nodeMap.addedSection, undefined);
	assert.deepEqual(h.sections, before);
	assert.equal(find(h.root, node => node.tag === 'form')[0], table);
	assert.deepEqual(h.calls.filter(c => c[0] === 'remove'), [['remove', 'aetherproxy', id]]);
	assert.deepEqual(h.rpc, []);
});

test('T10.26 scenario 3: successful parsing replaces every protocol field, redraws values and allows edits',
async () => {
	const h = await harness();
	const id = await add(h);
	const node = h.uci.get('aetherproxy', id);
	for (const field of NODE_FIELDS)
		node[field] = field === 'alpn' ? ['old'] : 'old-' + field;
	const parsed = {
		label: 'Parsed', protocol: 'vless', address: 'edge.example', port: '443', uuid: 'uuid',
		transport: 'ws', host: 'ws.example', path: '/ws', security: 'tls', sni: 'tls.example',
		alpn: ['h2', 'http/1.1'], fingerprint: 'chrome', grpc_multi_mode: '1', ws_heartbeat: '30',
		xhttp_extra: '{"a":1}', ech_config_list: 'ech', reality_pqv: 'pqv', mux: '1',
		mux_concurrency: '8', mux_xudp_concurrency: '16', mux_xudp_udp443: 'allow',
		tcp_fast_open: '1', tcp_mptcp: '1'
	};
	const firstModal = h.modal;
	await parse(h, 'vless://opaque-backend-input', { ok: true, node: parsed });
	assert.deepEqual(h.rpc, [['node_parse', { uri: 'vless://opaque-backend-input' }]]);
	assert.notEqual(h.modal, firstModal);
	assert.equal(share(h).input.value, 'vless://opaque-backend-input');
	assert.deepEqual(node, { '.name': id, '.type': 'node', source: 'manual', ...parsed });
	const cleared = h.calls.filter(c => c[0] === 'unset').map(c => c[3]);
	assert.deepEqual(cleared, NODE_FIELDS);
	assert.equal(h.modal.widgets.label.value, 'Parsed');
	assert.deepEqual(h.modal.widgets.alpn.value, ['h2', 'http/1.1']);
	assert.equal(h.modal.widgets.password.value, '', 'old password is gone from redrawn form');
	for (const field of NODE_FIELDS.slice(NODE_FIELDS.indexOf('reality_pqv')))
		assert.equal(h.modal.widgets[field].value, parsed[field], field + ' is filled by parsing');
	const parsedAgain = {
		label: 'Second', protocol: 'trojan', address: 'other.example', port: '8443', password: 'new'
	};
	await parse(h, 'trojan://opaque', { ok: true, node: parsedAgain });
	assert.deepEqual(node, { '.name': id, '.type': 'node', source: 'manual', ...parsedAgain });
	assert.equal(h.modal.widgets.path.value, '', 'fields omitted by the second URI are cleared');
	h.modal.widgets.label.value = 'Edited after parsing';
	await h.page.nodeGrid.handleModalSave(h.modal.map);
	assert.equal(node.label, 'Edited after parsing');
	assert.match(h.root.textContent, /Edited after parsingTrojan/);
	assert.equal(h.rpc.length, 2, 'Save must not import the parsed node');
});

for (const reply of [
	{ ok: false, code: 'CONFIG_INVALID', detail: 'malformed' },
	{ ok: false, code: 'TIMEOUT', detail: 'node_parse did not answer' }
]) {
	test(`T10.26 scenario 3: ${reply.code} shows inline failure without changing UCI or unsaved widgets`, async () => {
		const h = await harness();
		await add(h);
		const before = structuredClone(h.sections), modal = h.modal;
		h.modal.widgets.label.value = 'Unsaved input';
		const callsBefore = h.calls.length;
		const controls = await parse(h, 'bad://input', reply);
		assert.equal(controls.error.textContent, '无法解析：' + reply.detail);
		assert.equal(h.modal, modal);
		assert.equal(h.modal.widgets.label.value, 'Unsaved input');
		assert.deepEqual(h.sections, before);
		assert.equal(h.calls.length, callsBefore, 'failed parse performs no UCI calls');
		assert.equal(controls.parse.disabled, false);
	});
}

test('T10.26 scenario 4: hand-filled Save stages the node without parsing, importing or applying', async () => {
	const h = await harness();
	h.page.importText.value = 'vless://unsaved-bulk-import';
	h.page.importDetails.open = true;
	h.page.importResult.textContent = 'Earlier import result';
	const id = await add(h);
	for (const [field, value] of Object.entries({
		label: 'Hand filled', protocol: 'shadowsocks', address: '192.0.2.1', port: '443',
		password: 'secret', method: 'aes-128-gcm'
	}))
		h.modal.widgets[field].value = value;
	await h.page.nodeGrid.handleModalSave(h.modal.map);
	assert.equal(h.uci.get('aetherproxy', id, 'source'), 'manual');
	assert.equal(h.uci.get('aetherproxy', id, 'label'), 'Hand filled');
	assert.equal(h.uci.get('aetherproxy', 'main', 'mode'), 'global', 'unrelated staged edit stays intact');
	assert.equal(h.page.pendingAdd, null);
	assert.equal(h.page.nodeMap.addedSection, undefined);
	assert.equal(h.modal, null);
	assert.match(h.root.textContent, /Hand filledShadowsocks/);
	assert.equal(h.page.importText.value, 'vless://unsaved-bulk-import');
	assert.equal(h.page.importDetails.open, true, 'modal Save preserves bulk-import expansion');
	assert.equal(h.page.importResult.textContent, 'Earlier import result');
	assert.equal(find(h.page.importDetails, node => node === h.page.importResult).length, 1);
	assert.deepEqual(h.rpc, []);
	assert.deepEqual(h.calls.filter(c => c[0] === 'remove'), []);
	assert.deepEqual(h.calls.filter(c => c[0] === 'modal.save'), [['modal.save', null, true]]);
	// A second add/cancel must not remove the previously saved node.
	await add(h);
	await h.page.nodeGrid.handleModalCancel(h.modal, {}, false);
	assert.ok(h.uci.get('aetherproxy', id));
});

test('T10.33 scenario 1/2: parsed legacy choices and long keys survive the Add modal Save path', async () => {
	const h = await harness();
	const id = await add(h);
	await parse(h, 'vless://opaque', { ok: true, node: {
		protocol: 'vless', address: 'edge.example', port: '443', uuid: 'legacy-uuid',
		flow: 'xtls-rprx-direct', fingerprint: '360',
		reality_pqv: 'AB\n CD', ech_config_list: 'EF\t GH'
	} });
	assert.equal(h.modal.widgets.flow.value, 'xtls-rprx-direct');
	assert.equal(h.modal.widgets.fingerprint.value, '360');
	h.modal.widgets.reality_pqv.value = 'AB \nCD+/=';
	h.modal.widgets.ech_config_list.value = '\tEF\r\nGH+/=';
	await h.page.nodeGrid.handleModalSave(h.modal.map);
	const saved = h.uci.get('aetherproxy', id);
	assert.equal(saved.flow, 'xtls-rprx-direct');
	assert.equal(saved.fingerprint, '360');
	assert.equal(saved.reality_pqv, 'ABCD+/=');
	assert.equal(saved.ech_config_list, 'EFGH+/=');
	assert.equal(h.rpc.length, 1, 'only Parse uses RPC; modal Save stages the normalized values');
});

test('T10.58 scenario 1: actual Add with only name/Trojan keeps pendingAdd and can still be cancelled', async () => {
	const h = await harness();
	const id = await add(h);
	h.modal.widgets.label.value = 'Name only';
	h.modal.widgets.protocol.value = 'trojan';
	const before = structuredClone(h.sections);
	const callCount = h.calls.length;
	await h.page.nodeGrid.handleModalSave(h.modal.map);
	assert.deepEqual(h.sections, before);
	assert.equal(h.calls.length, callCount, 'no save, write, notification or close is attempted');
	assert.equal(h.page.pendingAdd.id, id);
	assert.equal(h.page.nodeMap.addedSection, id);
	assert.equal(h.modal.id, id);
	assert.match(h.modal.node.textContent, /地址 为必填项。端口 为必填项。密码 为必填项。/);
	for (const field of ['address', 'port', 'password'])
		assert.equal(h.modal.widgets[field].style.borderColor, 'var(--error-color-high, #c53030)');
	await h.page.nodeGrid.handleModalCancel(h.modal, {}, false);
	assert.equal(h.uci.get('aetherproxy', id), undefined);
	assert.equal(h.page.pendingAdd, null);
});

test('T10.26 defensive: invalid Save keeps the new node editable and later Cancel still removes it', async () => {
	const h = await harness();
	const id = await add(h);
	Object.entries({ protocol: 'trojan', address: '192.168.1.2', port: '443', password: 'secret' })
		.forEach(([field, value]) => { h.modal.widgets[field].value = value; });
	h.invalid = true;
	await h.page.nodeGrid.handleModalSave(h.modal.map);
	assert.equal(h.page.pendingAdd.id, id);
	assert.equal(h.page.pendingAdd.saving, false);
	assert.equal(h.page.nodeMap.addedSection, id);
	assert.equal(h.modal.id, id);
	await h.page.nodeGrid.handleModalCancel(h.modal, {}, false);
	assert.equal(h.uci.get('aetherproxy', id), undefined);
});

test('T10.26 defensive: late Parse after Cancel cannot recreate the node or reopen its modal', async () => {
	const h = await harness();
	const id = await add(h);
	const reply = deferred();
	await parse(h, 'vless://pending', reply.promise);
	await h.page.nodeGrid.handleModalCancel(h.modal, {}, false);
	const callsBefore = h.calls.length;
	reply.resolve({ ok: true, node: { label: 'Late' } });
	await flush();
	assert.equal(h.calls.length, callsBefore);
	assert.equal(h.uci.get('aetherproxy', id), undefined);
	assert.equal(h.modal, null);
});

test('T10.26 defensive: Parse reply during Save is ignored without changing the form or UCI', async () => {
	const h = await harness();
	const id = await add(h);
	const reply = deferred();
	await parse(h, 'vless://pending', reply.promise);
	h.modal.widgets.label.value = 'Manual save wins';
	Object.entries({ protocol: 'trojan', address: '192.168.1.2', port: '443', password: 'secret' })
		.forEach(([field, value]) => { h.modal.widgets[field].value = value; });
	const modal = h.modal;
	h.saveGate = deferred();
	const saving = h.page.nodeGrid.handleModalSave(h.modal.map);
	assert.equal(h.page.pendingAdd.saving, true);
	const callsBefore = h.calls.length;
	reply.resolve({ ok: true, node: { label: 'Late parsed label' } });
	await flush();
	assert.equal(h.calls.length, callsBefore, 'no UCI mutation while modal Save is validating');
	assert.equal(h.modal, modal, 'no modal replacement while Save is running');
	assert.equal(h.modal.widgets.label.value, 'Manual save wins');
	h.saveGate.resolve();
	await saving;
	assert.equal(h.uci.get('aetherproxy', id, 'label'), 'Manual save wins');
});

test('T10.26 defensive: failed modal opening removes the new section and reports the error', async () => {
	const h = await harness();
	const before = structuredClone(h.sections);
	h.page.nodeGrid.renderMoreOptionsModal = async () => { throw new Error('modal unavailable'); };
	await h.page.handleAddNode();
	assert.deepEqual(h.sections, before);
	assert.equal(h.page.pendingAdd, null);
	assert.equal(h.page.nodeMap.addedSection, undefined);
	assert.equal(h.calls.at(-1)[0], 'notify');
	assert.match(h.calls.at(-1)[2].textContent, /操作失败：modal unavailable/);
});

test('T10.26 scenario 6: protocol names, unknown/missing values, transport defaults and translated column order',
async () => {
	const protocols = ['vless', 'vmess', 'trojan', 'shadowsocks', 'future', undefined, ''];
	const rows = model.build(protocols.map((protocol, i) => ({ '.name': 'n_' + i, protocol })), null, []).rows;
	assert.deepEqual(rows.map(r => r.protocol), ['VLESS', 'VMess', 'Trojan', 'Shadowsocks', 'future', '–', '–']);
	assert.ok(rows.every(row => row.transport_security === 'raw / none'));
	const configured = model.build([{ '.name': 'n_ws', transport: 'ws', security: 'tls' }], null, []).rows[0];
	assert.equal(configured.transport_security, 'ws / tls');
	const h = await harness();
	assert.deepEqual(find(h.root, node => node.tag === 'th').map(n => n.textContent),
		['', '名称', '协议', '传输 / 安全层', '来源', '选用', 'TCP 可达／延迟']);
	assert.doesNotMatch(h.root.textContent, /协议 \/ 传输 \/ 安全层/);
	for (const name of ['VLESS', 'VMess', 'Trojan', 'Shadowsocks'])
		assert.equal(po[name], name);
});
