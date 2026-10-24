'use strict';

/* Render real form declarations against the SDK save-path double (T10.54).
 * Rows/modal-only options are included, not just visible table columns. Schema
 * defaults are exported by the minimum supported ucode, never copied into tests.
 */
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const assert = require('node:assert/strict');
const { loadModule, element: E } = require('./loader');
const types = require('./form-sdk');
const ROOT = path.resolve(__dirname, '../..');
const RES = path.join(ROOT, 'luci-app-aether-proxy/htdocs/luci-static/resources');
const reply = spawnSync(path.join(ROOT, 'tests/host/ucode'), ['-e',
	"import { SCHEMA } from 'aetherproxy.schema'; import * as C from 'aetherproxy.const'; " +
	"printf('%.J', { schema: SCHEMA, version: C.VERSION });"], { cwd: ROOT, encoding: 'utf8' });
assert.equal(reply.status, 0, reply.stderr);
const { schema, version } = JSON.parse(reply.stdout);
const widgetValue = v => Array.isArray(v) ? v.map(String) : typeof v == 'boolean' ? v ? '1' : '0' : String(v);
const editable = options => options.filter(o => !o.option.startsWith('_'));

function configData(explicit) {
	const data = {
		main: {}, dns: {}, update: {}, probe: {}, sub: {},
		host: { mac: ['aa:bb:cc:dd:ee:ff'] },
		subscription: { url: 'https://example.test/sub' },
		node: { protocol: 'vless', address: '192.168.1.2', port: '443', uuid: 'test' }
	};
	if (explicit)
		for (const [section, fields] of Object.entries(schema))
			for (const field of fields)
				if (field.default != null)
					data[section][field.name] = widgetValue(field.default);
	return data;
}

function formDouble(uci, options, sections) {
	const form = { ...types };
	class Section {
		constructor(map, name) { this.map = map; this.name = name; this.children = []; sections.push(this); }
		static extend(methods) {
			return class extends this { constructor(...args) { super(...args); Object.assign(this, methods); } };
		}
		tab() {}
		option(kind, field) {
			const o = new kind(this, field);
			o.kind = kind;
			this.children.push(o);
			options.push(o);
			return o;
		}
		taboption(tab, ...args) { return this.option(...args); }
	}
	form.NamedSection = Section;
	form.GridSection = Section;
	form.Map = class {
		constructor(config) { this.config = config; this.data = uci; this.children = []; }
		section(kind, name) { const s = new kind(this, name); this.children.push(s); return s; }
		lookupOption(field) { return this.children.flatMap(s => s.children).filter(o => o.option == field); }
		render() { return Promise.resolve(E('form')); }
		renderContents() { return Promise.resolve(E('div')); }
	};
	return form;
}

function pageModules(form, uci, env, adapter) {
	const modules = {
		baseclass: { extend: o => o }, view: { extend: o => o }, form, uci,
		ui: { createHandlerFn: () => () => {} },
		dom: { content: (node, children) => node.replaceChildren(...children) },
		network: {}, 'tools.widgets': { DeviceSelect: form.DynamicList },
		'aether-proxy.common': { call: async () => ({ ok: true, version }) },
		'aether-proxy.subscriptions-block': {}
	};
	if (adapter)
		modules['aether-proxy.form-defaults'] = adapter;
	for (const name of fs.readdirSync(path.join(RES, 'aether-proxy/model')))
		if (name.endsWith('.js'))
			modules['aether-proxy.model.' + name.slice(0, -3)] = loadModule(
				path.join(RES, 'aether-proxy/model', name), modules, env);
	return modules;
}

async function declarePage(view, page) {
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
}

function initialInputs(options, data) {
	for (const o of editable(options)) {
		const id = o.section.name;
		if (o.option == 'trust_dns') {
			/* Composite rows expose one list to parse, as the real controls do. */
			const values = data.dns.trust_dns ?? o.default;
			o.widgets[id] = values.map(value => ({
				address: { getValue: () => value.replace(/^(tcp|udp):\/\//, '') },
				protocol: { getValue: () => value.startsWith('udp://') ? 'udp' : 'tcp' }
			}));
		}
		// load() caches cfgvalue; rendered inputs remain independent of later UCI writes.
		o.loaded = { [id]: o.cfgvalue(id) };
		o.inputs[id] = o.formvalue(id);
	}
}

function cloneModal(form, source, type) {
	const map = new form.Map('aetherproxy');
	const section = map.section(form.NamedSection, type);
	for (const original of editable(source.children).filter(o => o.modalonly !== false)) {
		const clone = section.option(original.kind, original.option);
		/* SDK cloneOptions copies own properties except structural ownership;
		 * saving must use the child map, not the source table's live widgets. */
		for (const key of Object.keys(original))
			if (!['map', 'section', 'option', 'title', 'description'].includes(key))
				clone[key] = original[key];
		clone.inputs = { ...original.inputs };
	}
	map.section = type;
	map.checkDepends = () => {};
	return { map, options: section.children, parse: async () => {
		for (const o of section.children)
			await o.parse(type);
	} };
}

async function renderPage(page, explicit = false, adapter) {
	globalThis._ = text => text;
	globalThis.E = E;
	String.prototype.format = function(...args) {
		let i = 0;
		return this.replace(/%s/g, () => String(args[i++]));
	};
	const calls = [], options = [], sections = [];
	const data = configData(explicit);
	const uci = {
		load: async () => {},
		get: (config, id, field) => field == null ? data[id] : data[id]?.[field],
		sections: (config, type) => type === 'host' || type === 'subscription' || type === 'node'
			? [{ '.name': type, '.type': type, ...data[type] }] : [],
		set: (...args) => calls.push(['set', ...args]),
		unset: (...args) => calls.push(['unset', ...args])
	};
	const form = formDouble(uci, options, sections);
	const env = { window: { setTimeout() {} }, document: {} };
	const modules = pageModules(form, uci, env, adapter);
	const view = loadModule(path.join(RES, page == 'subscriptions' ? 'aether-proxy/subscriptions-block.js'
		: 'view/aether-proxy/' + page + '.js'), modules, env);
	await declarePage(view, page);
	initialInputs(options, data);
	const parse = async () => {
		for (const o of editable(options))
			await o.parse(o.section.name);
	};
	const setSaved = (section, field, value) => {
		data[section][field] = value;
		for (const o of options.filter(o => o.option == field && (o.ucisection ?? o.section.name) == section))
			o.loaded[o.section.name] = value;
	};
	const modal = type => cloneModal(form, sections.find(s => s.name == type), type);
	return { options, calls, data, parse, form, view, sections, setSaved, modal };
}
module.exports = { renderPage, schema, version, RES };
