'use strict';

/* SDK 24.10.8 modal ownership/clone/frame/active/save contracts for T10.58.
 * This is a behavioral double, not copied SDK source. Parent and child maps
 * must be distinct: reading parent widgets would miss every unsaved edit. */
const path = require('node:path');
const assert = require('node:assert/strict');
const types = require('./form-sdk');
const { loadModule, contentChildren } = require('./loader');
const { modalElement: E } = require('./modal-dom');
const RES = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');

async function sdkSave(modalMap, ev) {
	let activeMap = modalMap;
	let saves = activeMap.save(null, true);
	while (activeMap.parent) {
		activeMap = activeMap.parent;
		const parent = activeMap;
		saves = saves.then(() => parent.load()).then(() => parent.reset());
	}
	return saves.then(() => this.handleModalCancel(modalMap, ev, true)).catch(() => {});
}

function widgetTypes() {
	const form = {};
	for (const [name, Kind] of Object.entries(types)) {
		form[name] = class extends Kind {};
		Object.assign(form[name].prototype, {
			cbid(id) { return id + '.' + this.option; },
			isActive(id) {
				const frame = this.map.findElement('data-field', this.cbid(id));
				return frame != null && !frame.classList.contains('hidden');
			},
			renderWidget(id, index, cfgvalue) {
				const select = name === 'ListValue';
				const value = cfgvalue ?? this.default ?? '';
				const input = E(select ? 'select' : name === 'TextValue' ? 'textarea' : 'input', {
					value
				}, select ? this.keylist.map((key, i) => E('option', { value: key }, this.vallist[i])) : []);
				input.value = value;
				this.input = input;
				return name === 'TextValue' ? E('div', {}, [input]) : input;
			},
			formvalue(id) {
				// SDK getUIElement cannot see a widget before its frame is mounted.
				return this.map.frames[this.cbid(id)]?.parentNode ? this.input?.value
					?? Kind.prototype.formvalue.call(this, id) : null;
			},
			renderFrame(id, in_table, index, nodes) {
				// Preserved-list render uses a temporary option; mounted widgets still belong to the real clone.
				this.input = ['input', 'select', 'textarea'].includes(nodes.tag) ? nodes
					: nodes.querySelector('input, select, textarea');
				const frame = E('div', { class: this.deplist.length ? 'cbi-value hidden' : 'cbi-value' }, [
					E('label', {}, this.title), E('div', {}, nodes)
				]);
				this.map.frames[this.cbid(id)] = frame;
				frame.addEventListener('widget-change', () => this.map.checkDepends());
				return frame;
			}
		});
	}
	return form;
}

function formDouble(h) {
	const form = widgetTypes();
	class Section {
		constructor(map, name) { this.map = map; this.name = name; this.children = []; }
		option(kind, field, title) {
			const option = new kind(this, field);
			Object.assign(option, { kind, title });
			this.children.push(option);
			return option;
		}
		async renderMoreOptionsModal(id) {
			const child = new form.Map('aetherproxy');
			const section = child.section(Section, id);
			child.parent = this.map;
			child.section = id;
			for (const original of this.children.filter(o => o.modalonly !== false)) {
				const clone = section.option(original.kind, original.option, original.title);
				for (const key of Object.keys(original))
					if (!['map', 'section', 'option', 'title', 'description'].includes(key))
						clone[key] = original[key];
			}
			this.addModalOptions(section, id);
			child.root = E('div', {}, [E('p', {}, section.description)]);
			for (const option of section.children) {
				// Dummy share-link rendering is independently covered by nodes-add.
				if (option.option.startsWith('_'))
					continue;
				const widget = option.renderWidget(id, 0, option.cfgvalue(id));
				child.root.appendChild(option.renderFrame(id, false, 0, widget));
			}
			child.checkDepends();
			h.modal = child;
			h.open = true;
			return child;
		}
		handleModalSave(...args) { return sdkSave.apply(this, args); }
		async handleModalCancel(map, ev, isSaving) {
			h.sequence.push(['close', isSaving]);
			h.open = false;
			delete this.map.addedSection;
		}
	}
	form.GridSection = Section;
	form.NamedSection = Section;
	form.Map = class {
		constructor(config) { this.config = config; this.data = h.uci; this.children = []; this.frames = {}; }
		section(kind, name) { const s = new kind(this, name); this.children.push(s); return s; }
		lookupOption(field) {
			return this.children.flatMap(s => s.children).filter(o => o.option === field
				&& this.frames[o.cbid(this.section)]?.parentNode);
		}
		findElement(attr, value) { assert.equal(attr, 'data-field'); return this.frames[value] ?? null; }
		checkDepends() {
			// SDK isActive reads the frame; dependency evaluation uses active live references.
			for (let pass = 0; pass < 3; pass++)
				for (const option of this.children[0].children) {
					const frame = this.frames[option.cbid(this.section)];
					if (frame)
						frame.classList[
							types.Value.prototype.isActive.call(option, this.section) ? 'remove' : 'add']('hidden');
				}
		}
		async save(callback, silent) {
			h.sequence.push(['save', callback, silent]);
			for (const option of this.children[0].children.filter(o => !o.option.startsWith('_')))
				await option.parse(this.section);
		}
		async load() { h.sequence.push(['load']); }
		async reset() { h.sequence.push(['reset']); }
		async render() { return E('form'); }
	};
	return form;
}

async function harness(page, saved = {}) {
	globalThis.E = E;
	const h = { calls: [], sequence: [], data: { main: {}, sub: {}, row: { ...saved } } };
	h.uci = {
		get: (config, id, field) => field == null ? h.data[id] : h.data[id]?.[field],
		sections: (config, type) => type === page ? [{ '.name': 'row', '.type': page, ...h.data.row }] : [],
		set: (config, id, field, value) => { h.calls.push(['set', field, value]); h.data[id][field] = value; },
		unset: (config, id, field) => { h.calls.push(['unset', field]); delete h.data[id][field]; },
		changes: async () => ({}), load: async () => {}
	};
	const form = formDouble(h);
	const modules = {
		baseclass: { extend: object => object }, view: { extend: object => object }, form, uci: h.uci,
		ui: { createHandlerFn: () => () => {},
			addNotification: () => assert.fail('modal error must stay inside modal') },
		dom: { content: (node, children) => contentChildren(node, children) },
		'aether-proxy.common': {}
	};
	const env = { window: { setTimeout() {} }, document: {} };
	for (const name of ['nodes', 'subscriptions'])
		modules['aether-proxy.model.' + name] = loadModule(
			path.join(RES, 'aether-proxy/model', name + '.js'), modules, env);
	const block = loadModule(path.join(RES, 'aether-proxy/subscriptions-block.js'), modules, env);
	modules['aether-proxy.subscriptions-block'] = block;
	if (page === 'node') {
		h.view = loadModule(path.join(RES, 'view/aether-proxy/nodes.js'), modules, env);
		h.view.rowMap = {};
		h.view.buildMap();
		h.grid = h.view.nodeGrid;
	}
	else {
		h.view = block;
		block.root = E('div');
		await block.redraw();
		h.grid = block.grid;
	}
	h.model = modules['aether-proxy.model.' + (page === 'node' ? 'nodes' : 'subscriptions')];
	h.openModal = async () => h.grid.renderMoreOptionsModal('row');
	await h.openModal();
	h.option = field => h.modal.lookupOption(field)[0];
	h.set = (field, value) => {
		const option = h.option(field);
		option.input.value = value;
		h.modal.frames[option.cbid('row')].emit('widget-change');
	};
	h.save = () => h.grid.handleModalSave(h.modal, {});
	return h;
}
module.exports = { harness, sdkSave, RES };
