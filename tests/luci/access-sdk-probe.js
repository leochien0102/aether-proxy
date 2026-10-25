'use strict';

/* T10.63 diagnostic: run SDK Dropdown.render/createItems in memory, never
 * vendor SDK code. Binding, focus and selection are not browser-tested here.
 * Usage: node tests/luci/access-sdk-probe.js <SDK resources directory>
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { loadModule } = require('./loader');
const sdk = process.argv[2];
if (!sdk)
	throw new Error('SDK resources directory is required');
const source = fs.readFileSync(path.join(sdk, 'ui.js'), 'utf8');
const start = source.indexOf('const UIDropdown =');
assert.ok(start >= 0);
const code = source.slice(start, source.indexOf('\n});', start) + 4) + '\nreturn UIDropdown;';

function E(tag, attrs = {}, children = []) {
	const node = {
		tag, attrs, style: {}, children: [],
		get childNodes() { return this.children; },
		get lastElementChild() { return this.children.at(-1); },
		appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
		insertBefore(child, before) {
			assert.ok(this.children.includes(before));
			child.parentNode = this;
			this.children.splice(this.children.indexOf(before), 0, child);
			return child;
		},
		getAttribute(key) { return this.attrs[key]; },
		closest(selector) {
			if (selector == this.tag || selector == '.' + this.attrs.class)
				return this;
			return this.parentNode?.closest(selector) ?? null;
		},
		querySelector(selector) {
			for (const child of this.children) {
				if (selector == child.tag || selector == '.' + child.attrs.class)
					return child;
				const found = child.querySelector(selector);
				if (found) return found;
			}
			return null;
		}
	};
	for (const child of Array.isArray(children) ? children : [children])
		if (child && typeof child == 'object') node.appendChild(child);
	return node;
}
const Dropdown = new Function('UIElement', 'E', 'L', 'dom', '_', code)({
	extend(spec) {
		function Widget(...args) { spec.__init__.apply(this, args); }
		Object.assign(Widget.prototype, spec, {
			bind(node) { node.instance = this; return node; },
			createChoiceElement(sb, value) { return E('li', { 'data-value': value }); },
			toggleItem() {}, setFocus() {}
		});
		return Widget;
	}
}, E, { naturalCompare: (a, b) => a.localeCompare(b) }, { elem: () => false }, text => text);
const resources = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
const page = loadModule(path.join(resources, 'view/aether-proxy/access.js'), {
	view: { extend: value => value }, form: {}, dom: { findClassInstance: node => node.instance },
	'aether-proxy.form-defaults': {}, uci: {}, ui: {}, network: {}, 'aether-proxy.model.access': {}
}, {});
const widget = new Dropdown([], { 'aa:bb:cc:dd:ee:01': 'device' }, { create: true, multiple: true });
const option = { renderWidget: () => widget.render() };
page.deviceInputFirst(option);
const node = option.renderWidget();
const list = node.querySelector('ul');
const custom = node.querySelector('.create-item-input').closest('li');
assert.equal(list.lastElementChild, custom);
assert.equal(custom.style.order, '-1');
console.log('PASS SDK Dropdown.render: custom input is DOM-last with order:-1');
widget.createItems(node, '11:22:33:44:55:66');
assert.equal(list.lastElementChild, custom);
assert.equal(list.children.at(-2).attrs['data-value'], '11:22:33:44:55:66');
assert.equal(list.children[0].attrs['data-value'], 'aa:bb:cc:dd:ee:01');
assert.equal(custom.style.order, '-1');
console.log('PASS SDK Dropdown.createItems: new choice precedes the still-last custom input');
