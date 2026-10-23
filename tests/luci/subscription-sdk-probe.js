'use strict';
/* T10.40 diagnostic, not a CI dependency: evaluate the installed SDK's Select,
 * ListValue and cloneOptions directly in memory (no vendored third-party code).
 * Usage: node tests/luci/subscription-sdk-probe.js <SDK resources dir> [git revision]
 * The small DOM records selected attributes; widget binding/validation is omitted.
 */
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const { loadModule } = require('./loader');
const sdk = process.argv[2];
if (!sdk)
	throw new Error('SDK resources directory is required');
const uiSource = fs.readFileSync(path.join(sdk, 'ui.js'), 'utf8');
const formSource = fs.readFileSync(path.join(sdk, 'form.js'), 'utf8');
const resources = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
function classSource(source, name) {
	const start = source.indexOf('const ' + name + ' =');
	assert.ok(start >= 0, name + ' exists');
	return source.slice(start, source.indexOf('\n});', start) + 4) + '\nreturn ' + name + ';';
}
function E(tag, attrs = {}, children = []) {
	return {
		tag, attrs, children: Array.isArray(children) ? children : [children],
		appendChild(child) { this.children.push(child); return child; },
		get lastChild() { return this.children.at(-1); }
	};
}
const Select = new Function('UIElement', 'L', 'E', classSource(uiSource, 'UISelect'))({
	extend(spec) {
		function Widget(...args) { spec.__init__.apply(this, args); }
		Object.assign(Widget.prototype, spec, { bind(frame) { return frame; } });
		return Widget;
	}
}, { isObject: value => value && typeof value === 'object' }, E);
const list = new Function('CBIValue', 'ui', classSource(formSource, 'CBIListValue'))(
	{ extend: spec => spec }, { Select });
const cloneStart = formSource.indexOf('\tcloneOptions(src_section, dest_section)');
assert.ok(cloneStart >= 0, 'cloneOptions exists');
const cloneEnd = formSource.indexOf('\n\t/** @private */', cloneStart);
const cloneOptions = new Function('return ({' + formSource.slice(cloneStart, cloneEnd) + '}).cloneOptions;')();
global._ = text => text;
const model = loadModule(path.join(resources, 'aether-proxy/model/subscriptions.js'),
	{ baseclass: { extend: o => o } }, {});
const blockPath = 'luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/subscriptions-block.js';
const blockSource = process.argv[3]
	? execFileSync('git', ['show', process.argv[3] + ':' + blockPath], { encoding: 'utf8' })
	: fs.readFileSync(blockPath, 'utf8');
const block = new Function('baseclass', 'form', 'uci', 'ui', 'dom', 'ap', 'model', blockSource)(
	{ extend: o => o }, { ListValue: 'ListValue', Value: 'Value' }, {}, {}, {}, {}, model);
block.general_values = () => ({ interval_hours: '24', fetch_via: 'auto' });
const proto = {
	renderWidget: list.renderWidget,
	value(key, label) {
		(this.keylist ??= []).push(String(key));
		(this.vallist ??= []).push(label);
	},
	transformChoices() { return Object.fromEntries(this.keylist.map((key, i) => [key, this.vallist[i]])); },
	cbid() { return 'probe'; },
	getValidator() {}
};
function section() {
	return {
		children: [],
		option(kind, name, title) {
			const option = Object.assign(Object.create(proto), {
				constructor: kind, option: name, title, map: {}
			});
			this.children.push(option);
			return option;
		}
	};
}
let count = 0;
for (const [field, values] of [
	['interval_hours', ['0', '12', '24', '72', '168', '6']],
	['fetch_via', ['auto', 'direct', 'proxy']]
]) {
	const source = section();
	block.setting_option(source, field, field, true);
	// Reopen from the same grid option, just like renderMoreOptionsModal.
	for (const value of [...values, undefined, ...values]) {
		const modal = section();
		cloneOptions.call(source, source, modal);
		const frame = modal.children[0].renderWidget('s_probe', 0, value);
		const options = frame.lastChild.children;
		const actual = (options.find(o => o.attrs.selected != null) ?? options[0]).attrs.value;
		assert.equal(actual, value ?? '');
		console.log(`PASS SDK Select + ListValue + cloneOptions: ${field}=${value ?? '(inherit)'} -> `
			+ (actual || '(inherit)'));
		count++;
	}
}
console.log(`${count} passed, 0 failed; 24 -> 0 not reproduced`);
