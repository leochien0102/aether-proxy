'use strict';

/* Access-only DOM/SDK doubles (docs/10 r17). ui.js DynamicList.handleClick,
 * handleKeydown and addItem reject invalid add boxes and exact duplicates.
 * getValue includes plain pending text, never Dropdown.create-item-input.
 * Dropdown.handleCreateKeydown creates custom items on Enter. Capture handlers
 * run before these SDK handlers, not after successful insertion/clearing.
 */
const { element: E } = require('./loader');
const { renderList } = require('./dynamic-list');

function textInput(value = '') {
	const listeners = {};
	const input = E('input', { type: 'text', value });
	input.style = { borderColor: 'original' };
	input.animations = [];
	input.animate = (frames, options) => input.animations.push({ frames, options });
	input.addEventListener = (type, fn) => { (listeners[type] ??= []).push(fn); };
	input.edit = value => {
		input.value = value;
		for (const fn of listeners.input ?? []) fn({ target: input });
	};
	const parent = E('div', {}, [ input ]);
	parent.style = {};
	parent.insertBefore = (node, before) => {
		const index = parent.children.indexOf(before);
		parent.children.splice(index < 0 ? parent.children.length : index, 0, node);
	};
	input.parentNode = parent;
	return input;
}

function renderAccessList(option, sid, value) {
	const node = renderList(option, sid, value);
	const input = node.input = textInput();
	const dropdown = option.choices.length > 0;
	const captures = {};
	const plus = { closest: selector => selector == '.cbi-button-add' ? plus : null,
		get previousElementSibling() {
			return input.parentNode.children[input.parentNode.children.indexOf(plus) - 1];
		} };
	if (!dropdown) input.parentNode.children.push(plus);
	node.addEventListener = (type, fn, capture) => {
		if (!capture) throw new Error('test expects pre-SDK capture handler');
		captures[type] = fn;
	};
	node.querySelector = selector => {
		if (selector.includes('.create-item-input')) return input;
		if (selector == '.add-item > input[type="text"]') return dropdown ? null : input;
		return null;
	};
	input.closest = () => null;
	node.getValue = () => {
		const values = [...node.value];
		if (!dropdown && input.value.trim() && option.validate(sid, input.value) === true
			&& !values.includes(input.value)) values.push(input.value);
		return values;
	};
	const validateItems = node.triggerValidation;
	node.triggerValidation = () => {
		validateItems.call(node);
		const error = option.validate(sid, input.value);
		if (error !== true) {
			node.valid = false;
			node.validationError = error;
		}
		return node.valid;
	};
	node.attempt = type => {
		const ev = { type: type == 'enter' ? 'keydown' : 'click', keyCode: 13,
			target: type == 'enter' ? input : plus, stopped: false,
			preventDefault() {}, stopPropagation() { this.stopped = true; } };
		captures[ev.type]?.(ev);
		const target = type == 'plus' && !dropdown ? plus.previousElementSibling : input;
		if (!ev.stopped && target.value && option.validate(sid, target.value) === true) {
			if (!node.value.includes(target.value)) node.value.push(target.value);
			target.value = '';
		}
		node.triggerValidation();
	};
	return node;
}

module.exports = { textInput, renderAccessList };
