'use strict';

/* DynamicList validation double, per docs/10 r14 / T10.47.
 * SDK ui.js DynamicList.render() / Dropdown.render() attach an optional
 * validator to the empty add box, and addValidator() runs it immediately.
 * validation.js still calls custom validation after accepting optional ''.
 * Check existing items too, so invalid persisted entries cannot hide behind a
 * valid add box. AbstractValue.parse() owns required-list and changed checks;
 * the add box is never a list item or a reason to write a backend default.
 */
const { isDeepStrictEqual } = require('node:util');
const { element: E } = require('./loader');

function items(value) {
	return Array.isArray(value) ? [...value] : value == null || value === '' ? [] : [value];
}

function renderList(option, section, value) {
	const node = E('list', { name: option.key ?? option.option ?? option.field, value: items(value) },
		option.label ?? option.title ?? '');
	node.validationCalls = [];
	node.triggerValidation = function() {
		this.validationCalls = [...items(this.value), ''];
		const results = this.validationCalls.map(value =>
			typeof option.validate == 'function' ? option.validate(section, value) : true);
		this.valid = results.every(result => result === true);
		this.validationError = results.find(result => result !== true) ?? '';
		return this.isValid();
	};
	node.isValid = function() { return this.valid; };
	node.getValidationError = function() { return this.validationError; };
	node.triggerValidation();
	return node;
}

function parseList(option, section, node, original, write, remove) {
	if (!node.isValid())
		throw new TypeError((option.key ?? option.option ?? option.field) + ': ' + node.getValidationError());
	const value = items(node.value);
	if (value.length === 0) {
		if (option.rmempty === false && !option.optional)
			throw new TypeError((option.key ?? option.option ?? option.field) + ': must not be empty');
		remove();
	}
	else if (option.forcewrite || !isDeepStrictEqual(items(original), value))
		write(value);
}

module.exports = { renderList, parseList };
