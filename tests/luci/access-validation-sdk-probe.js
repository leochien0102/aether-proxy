'use strict';

/* T10.66 diagnostic: evaluate SDK validation.js Validator and ui.js tooltip
 * methods in memory. No third-party code is copied into the repository.
 * Usage: node tests/luci/access-validation-sdk-probe.js <SDK resources directory>
 * Geometry, datatype parsing and tooltip timers are not browser-tested here.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { loadModule, element: E } = require('./loader');
const { renderAccessList, textInput } = require('./access-input');
const sdk = process.argv[2];
if (!sdk)
	throw new Error('SDK resources directory is required');
const validationSource = fs.readFileSync(path.join(sdk, 'validation.js'), 'utf8');
const uiSource = fs.readFileSync(path.join(sdk, 'ui.js'), 'utf8');
function snippet(source, start, end) {
	const from = source.indexOf(start);
	const to = source.indexOf(end, from);
	assert.ok(from >= 0 && to > from);
	return source.slice(from, to);
}
class CustomEvent {
	constructor(type, options = {}) { Object.assign(this, { type }, options); }
}
const Validator = new Function('baseclass', 'findParent', 'CustomEvent',
	snippet(validationSource, 'const Validator =', '\nconst ValidatorFactory =') + '\nreturn Validator;')({
	extend(spec) {
		function Widget(...args) { spec.__init__.apply(this, args); }
		Object.assign(Widget.prototype, spec);
		return Widget;
	}
}, field => field, CustomEvent);
const tooltip = {
	style: {}, classList: { add() {} }, firstChild: { data: '' }, offsetHeight: 20,
	contains: () => false, dispatchEvent() {}, removeAttribute() {},
	set innerHTML(value) { this.firstChild.data = value; }
};
const ui = new Function('tooltipDiv', 'findParent', 'window', 'CustomEvent',
	'let tooltipTimeout = null; return ({' + snippet(uiSource, '\tshowTooltip(ev)',
	'\n\t/**\n\t * Add a notification banner') + '});')(
	tooltip, (field, selector) => selector == '[data-tooltip]' && Object.hasOwn(field.attrs, 'data-tooltip')
		? field : null,
	{ pageXOffset: 0, pageYOffset: 0, innerHeight: 1000, clearTimeout() {}, setTimeout: () => 1 }, CustomEvent);
const resources = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
globalThis.E = E;
const page = loadModule(path.join(resources, 'view/aether-proxy/access.js'), {
	view: { extend: value => value }, form: {}, dom: {}, 'aether-proxy.form-defaults': {},
	uci: {}, ui, network: {}, 'aether-proxy.model.access': {}
}, {});
function validator(input, validate) {
	input.classList = { add() {}, remove() {} };
	input.getBoundingClientRect = () => ({ left: 0, top: 0, height: 20 });
	input.getAttribute = key => input.attrs[key];
	input.hasAttribute = key => Object.hasOwn(input.attrs, key);
	input.querySelector = () => null;
	input.offsetHeight = 20;
	const factory = { compile: () => [ function() { return this.assert(true); }, [] ] };
	return new Validator(input, 'string', true, validate, factory);
}
for (const field of [ 'ip', 'mac' ]) {
	for (const dropdown of [ false, true ]) {
		const validate = value => value == 'bad' ? field + ' SDK reason' : true;
		const option = { choices: dropdown ? [ { key: 'device' } ] : [],
			renderWidget() { return renderAccessList(this, 'x', []); } };
		page.listFeedback(option, validate);
		const node = option.renderWidget();
		const input = node.input;
		const check = validator(input, validate);
		input.value = 'bad';
		// A tooltip left visible from an earlier focus must not survive revalidation.
		tooltip.style.opacity = 1;
		assert.equal(check.validate(), false);
		assert.equal(input.attrs['data-tooltip'], undefined);
		assert.equal(input.attrs['data-tooltip-style'], undefined);
		assert.equal(input.accessFeedback.textContent, field + ' SDK reason');
		assert.equal(input.animations.length, 0);
		assert.equal(tooltip.style.opacity, 0);
		for (const type of [ 'focus', 'mouseover' ]) {
			ui.showTooltip({ type, target: input });
			assert.equal(tooltip.style.opacity, 0);
		}
		input.value = 'valid';
		assert.equal(check.validate(), true);
		assert.equal(input.accessFeedback.textContent, '');
		assert.equal(input.style.borderColor, 'original');
		console.log(`PASS SDK Validator + tooltip: ${field} ${dropdown ? 'dropdown' : 'plain'} stays inline`);
	}
}
const other = textInput('bad');
assert.equal(validator(other, () => 'other field reason').validate(), false);
assert.equal(other.attrs['data-tooltip'], 'other field reason');
for (const type of [ 'focus', 'mouseover' ]) {
	ui.showTooltip({ type, target: other });
	assert.equal(tooltip.style.opacity, 1);
	assert.equal(tooltip.firstChild.data, '▲ other field reason');
}
console.log('PASS SDK Validator + tooltip: undecorated fields still show ▲ on focus and mouseover');
