'use strict';

/* T10.57: exercise the real view hooks against SDK-shaped editable cells.
 * These tests prove DOM/style contracts, not browser geometry; the report has
 * a computed-display console probe for proton2025/bootstrap on the device.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, element: E } = require('./loader');
const { renderFrame, checkboxWidget } = require('./flag-frame');
const RES = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
globalThis.E = E;
globalThis._ = text => text;

function flags(page) {
	const options = [];
	class Option {
		constructor(key, title) { this.option = key; this.title = title; this.map = map; }
		value() {}
		depends() {}
		cbid(id) { return `cbid.aetherproxy.${id}.${this.option}`; }
		setActive(id, active) {
			const field = this.map.findElement('data-field', this.cbid(id));
			if (!field || field.classList.contains('hidden') !== active)
				return false;
			field.classList[active ? 'remove' : 'add']('hidden');
			return true;
		}
	}
	Option.prototype.renderFrame = renderFrame;
	const section = { option(kind, key, title) {
		const option = new Option(key, title);
		option.kind = kind;
		options.push(option);
		return option;
	} };
	const fields = new Map();
	const map = { section: () => section, findElement: (attr, id) => fields.get(id) };
	const form = { Flag: 'Flag', GridSection: { extend: methods => methods } };
	const modules = { baseclass: { extend: value => value }, view: { extend: value => value },
		form, uci: {}, ui: {}, dom: {}, network: {}, 'aether-proxy.common': {},
		'aether-proxy.model.access': { policy_text: text => text }, 'aether-proxy.model.subscriptions': {} };
	const file = page === 'subscriptions' ? 'aether-proxy/subscriptions-block.js' : 'view/aether-proxy/access.js';
	const view = loadModule(path.join(RES, file), modules, {});
	if (page === 'subscriptions')
		view.table_columns(section);
	else {
		view.candidates = [];
		view.addHostOptions(map);
	}
	return { options: options.filter(o => o.kind === 'Flag'), fields };
}

for (const page of ['subscriptions', 'access']) {
	for (const checked of [false, true]) {
		test(`T10.57 scenario 1: ${page} editable flags style both SDK divs (checked=${checked})`, () => {
			const { options } = flags(page);
			assert.deepEqual(options.map(o => o.option), page === 'subscriptions' ? ['enabled'] : ['enabled', 'udp']);
			for (const option of options) {
				assert.equal(option.editable, true);
				const widget = checkboxWidget(checked);
				const input = widget.children[0];
				const frame = option.renderFrame('row', true, 3, widget);
				assert.equal(frame, option.baseFrame, 'delegate rendering, retain native frame/bindings');
				const field = frame.querySelector('[data-field]');
				assert.equal(field.style.display, 'inline', `${option.option}: outer field must not start a new line`);
				assert.equal(field.attrs['data-index'], 3, 'forward renderFrame arguments');
				assert.equal(field.children[0], widget, 'retain the bound Checkbox, no extra widget-only wrapper');
				assert.deepEqual(widget.style, { display: 'inline-flex', alignItems: 'center' });
				assert.equal(widget.children[0], input);
				assert.equal(input.checked, checked);
				assert.equal(widget.children[1].tag, 'label', 'retain the native checkbox label');
			}
		});
	}

	test(`T10.57 scenario 2: ${page} preserves table/theme classes and leaves modal layout untouched`, () => {
		for (const option of flags(page).options) {
			const widget = checkboxWidget(true);
			const frame = option.renderFrame('row', true, 0, widget);
			assert.deepEqual(frame.style, {}, 'do not style td or change desktop table display');
			assert.equal(frame.attrs.class, 'td cbi-value-field');
			assert.equal(frame.attrs['data-title'], option.title, 'bootstrap block label stays theme-controlled');
			assert.equal(widget.attrs.class, 'cbi-checkbox');
			assert.deepEqual(frame.querySelector('[data-field]').style, { display: 'inline' });
			const modalWidget = checkboxWidget(false);
			const modal = option.renderFrame('row', false, 0, modalWidget);
			assert.equal(modal.attrs.class, 'cbi-value');
			assert.deepEqual(modal.querySelector('[data-field]').style, {});
			assert.deepEqual(modalWidget.style, {}, 'keep modal grid/checkbox styling');
		}
	});
}

test('T10.57 scenario 2: Game mode dependency hiding survives inline display and reactivation', () => {
	const { options, fields } = flags('access');
	const option = options.find(o => o.option === 'udp');
	for (const initiallyHidden of [false, true]) {
		option.initiallyHidden = initiallyHidden;
		const frame = option.renderFrame('host', true, 0, checkboxWidget(true));
		const field = frame.querySelector('[data-field]');
		fields.set(option.cbid('host'), field);
		assert.equal(field.style.display, initiallyHidden ? 'none' : 'inline');
		assert.equal(option.setActive('host', false), !initiallyHidden, 'preserve SDK changed return');
		assert.equal(field.classList.contains('hidden'), true);
		assert.equal(field.style.display, 'none', 'inline style must not override bootstrap .hidden');
		assert.equal(option.setActive('host', false), false, 'repeated dependency check stays unchanged');
		assert.equal(option.setActive('host', true), true);
		assert.equal(field.classList.contains('hidden'), false);
		assert.equal(field.style.display, 'inline');
	}
	const modal = option.renderFrame('host', false, 0, checkboxWidget(true));
	const modalField = modal.querySelector('[data-field]');
	fields.set(option.cbid('host'), modalField);
	option.setActive('host', false);
	assert.equal(modalField.classList.contains('hidden'), true);
	assert.deepEqual(modalField.style, {}, 'modal dependencies keep theme-driven display');
	option.setActive('host', true);
	assert.deepEqual(modalField.style, {});
	fields.clear();
	assert.equal(option.setActive('missing', false), false, 'no detached field is not an error');
});

test('T10.57 scenario 2: fixes add no media queries, stylesheets or theme-specific classes', () => {
	for (const file of ['aether-proxy/subscriptions-block.js', 'view/aether-proxy/access.js']) {
		const source = fs.readFileSync(path.join(RES, file), 'utf8');
		assert.doesNotMatch(source, /@media|E\(['"]style['"]|E\(['"]link['"]|class:\s*['"][^'"]*proton/);
	}
});
