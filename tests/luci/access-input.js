'use strict';

/* Access-only DOM/SDK doubles (docs/10 r17). ui.js DynamicList.handleClick,
 * handleKeydown and addItem reject invalid add boxes and exact duplicates.
 * getValue includes plain pending text, never Dropdown.create-item-input.
 * Dropdown.handleCreateKeydown creates custom items on Enter. Capture handlers
 * run before these SDK handlers, not after successful insertion/clearing.
 * The dropdown layout double follows SDK render/createItems: the custom li
 * stays last, new choices are inserted before it, and open clones a preview.
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
		if (selector.includes('.create-item-input'))
			return dropdown || selector.includes('.add-item') ? input : null;
		if (selector == '.add-item > input[type="text"]') return dropdown ? null : input;
		return null;
	};
	input.closest = () => null;
	if (dropdown) {
		const list = node.list = E('ul');
		list.style = { display: '', flexDirection: '', alignItems: '' };
		const item = node.customItem = E('li', { 'data-value': '-' }, input);
		item.style = {};
		item.parentNode = list;
		input.parentNode = item;
		item.insertBefore = (child, before) => {
			const index = item.children.indexOf(before);
			item.children.splice(index < 0 ? item.children.length : index, 0, child);
		};
		list.children = option.choices.map(c => E('li', { 'data-value': c.key })).concat(item);
		const box = node.dropdown = {
			openDropdown() {
				node.previewStyle = { ...list.style };
				node.scrollTop = 0; // optional combobox starts unselected
				node.open = true;
			},
			closeDropdown() { node.open = false; }
		};
		input.closest = selector => selector == 'li' ? item : selector == '.cbi-dropdown' ? box : null;
	}
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
			if (dropdown && !node.list.children.some(li => li.attrs['data-value'] == target.value)) {
				const entry = E('li', { 'data-value': target.value });
				const children = node.list.children;
				children.splice(children.length - 1, 0, entry);
			}
			target.value = '';
		}
		node.triggerValidation();
	};
	return node;
}

module.exports = { textInput, renderAccessList };
