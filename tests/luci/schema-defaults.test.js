'use strict';

/* T10.41 / docs/10 "r13 修正：页面默认值与 schema 一致".
 * Load real page/model modules, recording option declarations rather than
 * duplicating their defaults. The backend schema is read by the minimum ucode
 * interpreter, not parsed with a JS regexp or copied into another field table.
 * Option types deliberately supply no implicit Flag default: pages must set it.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadModule, element: E } = require('./loader');
const { renderList, parseList } = require('./dynamic-list');

const ROOT = path.resolve(__dirname, '../..');
const RES = path.join(ROOT, 'luci-app-aether-proxy/htdocs/luci-static/resources');
globalThis._ = text => text;
globalThis.E = E;
String.prototype.format = function(...args) {
	let index = 0;
	return this.replace(/%s/g, () => String(args[index++]));
};

function read_schema() {
	const reply = spawnSync(path.join(ROOT, 'tests/host/ucode'), ['-e',
		"import { SCHEMA, SS_METHODS } from 'aetherproxy.schema'; import * as C from 'aetherproxy.const'; " +
		"printf('%.J', { schema: SCHEMA, ss_methods: SS_METHODS, version: C.VERSION });"],
	{ cwd: ROOT, encoding: 'utf8' });
	assert.equal(reply.error, undefined);
	assert.equal(reply.status, 0, reply.stderr);
	assert.equal(reply.stderr, '');
	return JSON.parse(reply.stdout);
}
const backend = read_schema();
const schema = backend.schema;

/* The declaration recorder need not render GridSection rows or start RPC.
 * Section ownership and ucisection are retained: host.enabled must not be
 * compared with main.enabled, and the advanced page's probe fields are not main.
 */
function recorder() {
	const options = [];
	class Option {
		constructor(section, field) {
			this.section = section;
			this.option = field;
			this.rmempty = true;
		}
		value() { return this; }
		depends() {}
		formvalue() { return undefined; }
		getUIElement() { return null; }
	}
	const form = {};
	for (const kind of ['Value', 'Flag', 'ListValue', 'RichListValue', 'DynamicList', 'TextValue', 'DummyValue'])
		form[kind] = class extends Option {};
	class Section {
		constructor(name) { this.name = name; this.children = []; }
		static extend(methods) {
			return class extends this { constructor(...args) { super(...args); Object.assign(this, methods); } };
		}
		tab() {}
		option(kind, field) {
			const option = new kind(this, field);
			option.kind = kind;
			this.children.push(option);
			options.push(option);
			return option;
		}
		taboption(tab, ...args) { return this.option(...args); }
	}
	form.NamedSection = Section;
	form.GridSection = Section;
	form.Map = class {
		constructor() { this.children = []; }
		section(kind, name) {
			const section = new kind(name);
			this.children.push(section);
			return section;
		}
		render() { return Promise.resolve(E('form')); }
		renderContents() { return Promise.resolve(E('div')); }
	};
	const uci = {
		load: () => Promise.resolve(), get: () => undefined, sections: () => []
	};
	const env = { window: { setTimeout() {} }, document: {} };
	const modules = {
		baseclass: { extend: object => object }, view: { extend: object => object }, form, uci,
		ui: { createHandlerFn: () => () => {} },
		dom: { content: (node, children) => node.replaceChildren(...children) },
		network: {}, 'tools.widgets': { DeviceSelect: form.DynamicList },
		'aether-proxy.common': { call: async () => ({ ok: true, version: backend.version }) },
		'aether-proxy.subscriptions-block': {}
	};
	for (const name of fs.readdirSync(path.join(RES, 'aether-proxy/model')).sort())
		if (name.endsWith('.js'))
			modules['aether-proxy.model.' + name.slice(0, -3)] = loadModule(
				path.join(RES, 'aether-proxy/model', name), modules, env);
	const load = relative => loadModule(path.join(RES, relative), modules, env);
	return { form, options, load };
}

async function page_options(page) {
	const h = recorder();
	const relative = page == 'subscriptions' ? 'aether-proxy/subscriptions-block.js' :
		'view/aether-proxy/' + page + '.js';
	const view = h.load(relative);
	if (page == 'access') {
		view.candidates = [];
		view.buildMap();
	}
	else if (page == 'nodes') {
		view.rowMap = {};
		view.buildMap();
	}
	else if (page == 'subscriptions') {
		view.root = E('div');
		await view.redraw();
		await view.read_version();
	}
	else {
		await view.render();
	}
	return h;
}

function widget_default(value) {
	if (Array.isArray(value))
		return value.map(widget_default);
	if (typeof value == 'boolean')
		return value ? '1' : '0';
	return value == null ? value : String(value);
}

const LIST_HINTS = [ 'updates: update.channel_urls' ];

function check_options(h, page) {
	const checked = [];
	for (const option of h.options) {
		const section = option.ucisection ?? option.section.name;
		const field = schema[section]?.find(field => field.name == (option.ucioption ?? option.option));
		if (!field) {
			assert.ok(option.option.startsWith('_'), page + ': unmapped configuration field ' +
				section + '.' + option.option);
			continue;
		}
		const label = page + ': ' + section + '.' + field.name;
		checked.push(section + '.' + field.name);
		if (option.kind == h.form.Flag && typeof field.default == 'boolean')
			assert.ok(Object.hasOwn(option, 'default'), label + ': Flag must declare its default');
		const protocol = option.option === 'method_vmess' ? 'vmess' : null;
		const effectiveDefault = protocol ? field.proto_default[protocol] : field.default;
		if (Object.hasOwn(option, 'default'))
			assert.deepEqual(option.default, widget_default(effectiveDefault), label + ': default differs from schema');
		/* A list whose empty value means "use the backend default" shows it as a
		 * hint instead, so Save never pins today's default (updates.channel_urls). */
		if (Array.isArray(field.default) && field.default.length > 0 && !LIST_HINTS.includes(label))
			assert.deepEqual(option.default, widget_default(field.default), label + ': list must show schema defaults');
		if (LIST_HINTS.includes(label)) {
			assert.equal(option.default, undefined, label + ': list fallback must be display-only');
			assert.equal(option.placeholder, widget_default(field.default).join(' '), label + ': list must hint schema defaults');
		}
		if ([h.form.ListValue, h.form.RichListValue].includes(option.kind) && field.default != null)
			assert.equal(option.default, widget_default(field.default), label + ': select must show schema default');
		/* T10.61 splits the method select by protocol. SS has no default;
		 * VMess displays auto, while change-aware parse keeps absent UCI absent. */
		if (field.name === 'method') {
			assert.equal(option.kind, h.form.ListValue, label + ': method must be a select');
			assert.equal(option.default, protocol ? field.proto_default[protocol] : undefined,
				label + ': method protocol default');
			continue;
		}
		for (const [protocol, value] of Object.entries(field.proto_default ?? {})) {
			const hint = field.protocols.length > 1 ? widget_default(value) + ' (' +
				({ vmess: 'VMess', vless: 'VLESS' }[protocol] ?? protocol) + ')' : widget_default(value);
			assert.equal(option.placeholder, hint, label + ': protocol default hint for ' + protocol);
			assert.equal(option.default, undefined, label + ': protocol default must not be materialized');
		}
		if (option.kind == h.form.Value && field.default != null && !Array.isArray(field.default)) {
			assert.equal(option.default, undefined, label + ': Value fallback must be display-only');
			assert.equal(option.placeholder,
				field.name == 'user_agent' ? 'Default (' + field.default + ')' : widget_default(field.default),
				label + ': Value must show the schema default');
		}
	}
	assert.ok(checked.length > 0, page + ': at least one schema field was checked');
	return checked;
}

for (const page of ['rules', 'subscriptions', 'access', 'advanced', 'updates', 'nodes']) {
	test('T10.41 scenarios 2-3: ' + page + ' option defaults agree with the ucode schema', async () => {
		const h = await page_options(page);
		const checked = check_options(h, page);
		if (page == 'subscriptions')
			for (const field of ['sub.interval_hours', 'sub.fetch_via', 'sub.user_agent', 'subscription.enabled'])
				assert.ok(checked.includes(field), field + ': common settings and row flag are recorded');
		if (page == 'advanced')
			for (const field of ['main.quic_block', 'probe.url', 'probe.timeout', 'dns.dnsmasq_instance'])
				assert.ok(checked.includes(field), field + ': per-option section overrides are recorded');
	});
}

/* T10.47: inspect the actual option objects, including DeviceSelect subclasses
 * and options created by helpers/loops, rather than matching validator text.
 * Visit every shipped form page and the extracted subscription block. */
function check_list_validators(h, page) {
	const checked = [];
	for (const option of h.options) {
		if (!(option instanceof h.form.DynamicList) || typeof option.validate != 'function')
			continue;
		const section = option.ucisection ?? option.section.name;
		const label = page + ': ' + section + '.' + option.option;
		assert.equal(option.validate(section, ''), true, label + ': empty add box must be valid');
		checked.push(label);
	}
	return checked;
}

test('T10.47 scenario 4: all form-page DynamicList validators including DeviceSelect accept the empty add box',
async () => {
	const checked = [];
	for (const page of ['rules', 'subscriptions', 'access', 'advanced', 'updates', 'nodes'])
		checked.push(...check_list_validators(await page_options(page), page));
	assert.deepEqual(checked.sort(), [
		'access: host.ip', 'access: host.mac',
		'advanced: main.boot_check_targets', 'advanced: main.lan_ifaces',
		'rules: dns.china_dns', 'rules: dns.direct_dns', 'updates: update.channel_urls'
	]);
});

test('T10.47 scenario 4: list gate rejects a validator that fails the empty add box', async () => {
	for (const page of ['rules', 'access', 'advanced', 'updates']) {
		const h = await page_options(page);
		const option = h.options.find(o => o instanceof h.form.DynamicList && typeof o.validate == 'function');
		const validate = option.validate;
		option.validate = function(section, value) {
			return value === '' ? 'invalid empty add box' : validate.call(this, section, value);
		};
		assert.throws(() => check_list_validators(h, page), /empty add box must be valid/);
	}
});

test('T10.47 scenario 4: illegal list values fail and required DNS/interface lists cannot save empty', async () => {
	const bad = { china_dns: 'invalid', direct_dns: 'invalid', channel_urls: 'ftp://host',
		boot_check_targets: '999.1.1.1:0', lan_ifaces: 123 };
	for (const page of ['rules', 'advanced', 'updates']) {
		const h = await page_options(page);
		for (const option of h.options.filter(o => o instanceof h.form.DynamicList && o.validate)) {
			const section = option.section.name;
			assert.notEqual(option.validate(section, bad[option.option]), true, page + ': ' + option.option);
			if (option.rmempty !== false)
				continue;
			const input = renderList(option, section, []);
			assert.equal(input.isValid(), true, 'add box is optional, not the complete list');
			const writes = [];
			assert.throws(() => parseList(option, section, input, undefined,
				value => writes.push(value), () => writes.push('remove')), /must not be empty/);
			assert.deepEqual(writes, []);
		}
	}
});

test('T10.41 scenario 2: gate rejects a wrong Flag default and a missing explicit default', async () => {
	const h = await page_options('access');
	const flag = h.options.find(option => option.option == 'enabled');
	flag.default = '0';
	assert.throws(() => check_options(h, 'access'), /host.enabled: default differs from schema/);
	delete flag.default;
	assert.throws(() => check_options(h, 'access'), /host.enabled: Flag must declare its default/);
});

test('T10.41 scenario 2: gate rejects missing rich-select defaults and wrong section ownership', async () => {
	const h = await page_options('advanced');
	const log = h.options.find(option => option.option == 'log_level');
	const original = log.default;
	delete log.default;
	assert.throws(() => check_options(h, 'advanced'), /main.log_level: select must show schema default/);
	log.default = original;
	h.options.find(option => option.option == 'expect_code').ucisection = 'main';
	assert.throws(() => check_options(h, 'advanced'), /unmapped configuration field main.expect_code/);
});

test('T10.41 scenario 3: overview Enable and mode use schema defaults without writing UCI', async () => {
	const h = recorder();
	const overview = h.load('view/aether-proxy/overview.js');
	const loaded = await overview.load();
	assert.equal(loaded.enabled, schema.main.find(field => field.name == 'enabled').default);
	assert.equal(loaded.mode, schema.main.find(field => field.name == 'mode').default);
	overview.enabled = loaded.enabled;
	const control = overview.enableSwitch('');
	assert.equal(control.children.find(node => node?.tag == 'input').checked, loaded.enabled);
	// There are no mutating UCI methods in this double: a write would throw.
});

/* T10.58: use the same ucode export, not a second hand-maintained schema.
 * Preserve protocols even when required is narrower (VMess/SS method). */
function check_required(h, page, rules) {
	const section = page === 'nodes' ? 'node' : 'subscription';
	const expected = {};
	for (const field of schema[section].filter(field => field.required || field.requires_when)) {
		expected[field.name] = {};
		for (const key of ['required', 'protocols', 'requires_when'])
			if (field[key] != null)
				expected[field.name][key] = field[key];
	}
	assert.deepEqual(rules, expected, section + ': required table differs from ucode schema');
	for (const field of Object.keys(rules))
		assert.ok(h.options.some(option => option.section.name === section && option.option === field
			&& option.kind !== h.form.DummyValue && option.modalonly === true),
			section + ': missing editable input ' + field);
}

for (const page of ['nodes', 'subscriptions']) {
	test('T10.58 scenario 5: ' + page + ' required table and editable inputs agree with exported ucode schema',
	async () => {
		const h = await page_options(page);
		const model = h.load('aether-proxy/model/' + page + '.js');
		check_required(h, page, model.required_fields);
	});
	test('T10.58 scenario 5: gate rejects wrong requirement, protocol, condition and missing input on ' + page,
	async () => {
		const h = await page_options(page);
		const model = h.load('aether-proxy/model/' + page + '.js');
		const table = model.required_fields;
		const mutations = page === 'nodes' ? [
			{ ...table, address: { required: false } },
			{ ...table, method: { ...table.method, required: true } },
			{ ...table, uuid: { ...table.uuid, protocols: ['vless'] } },
			{ ...table, sni: { requires_when: { field: 'security', value: 'tls' } } }
		] : [{ url: { required: false } }, { ...table, name: { required: true } }];
		for (const mutation of mutations)
			assert.throws(() => check_required(h, page, mutation), /required table differs from ucode schema/);
		const field = page === 'nodes' ? 'reality_pbk' : 'url';
		h.options.splice(h.options.findIndex(option => option.option === field), 1);
		assert.throws(() => check_required(h, page, table), /missing editable input/);
	});
}

test('T10.61 scenario 4: SS methods exactly match the ordered ucode export; mutation fails', async () => {
	const h = await page_options('nodes');
	const model = h.load('aether-proxy/model/nodes.js');
	const check = methods => assert.deepEqual(methods, backend.ss_methods, 'ordered SS_METHODS must match');
	check(model.ss_methods);
	assert.throws(() => check(['wrong', ...model.ss_methods.slice(1)]), /ordered SS_METHODS must match/);
	assert.throws(() => check(model.ss_methods.slice().reverse()), /ordered SS_METHODS must match/);
});

test('T10.41 scenario 2: the default gate covers every form page shipped in view/', () => {
	const views = path.join(RES, 'view/aether-proxy');
	const form_pages = fs.readdirSync(views).filter(file =>
		/'require form';/.test(fs.readFileSync(path.join(views, file), 'utf8'))).sort();
	assert.deepEqual(form_pages, ['access.js', 'advanced.js', 'nodes.js', 'rules.js', 'updates.js']);
});
