'use strict';

/* Access-only DOM/SDK doubles (docs/10 r17). ui.js DynamicList.handleClick,
 * handleKeydown and addItem reject invalid add boxes and exact duplicates.
 * getValue includes plain pending text, never Dropdown.create-item-input.
 * Dropdown.handleCreateKeydown creates custom items on Enter. Capture handlers
 * run before these SDK handlers, not after successful insertion/clearing.
 * The dropdown layout double follows SDK render/createItems: the custom li
 * stays last, new choices are inserted before it, and open clones a preview.
 * T10.66 also models validation.js attributes/events and the optional selected
 * placeholder. finishOpen runs the SDK scroll calculation after layout (rAF).
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
	input.dispatchEvent = event => {
		event.target ??= input;
		for (const fn of listeners[event.type] ?? []) fn(event);
		if (event.bubbles) input.eventParent?.dispatchEvent(event);
	};
	input.edit = value => {
		input.value = value;
		input.dispatchEvent({ type: 'input' });
	};
	// validation.js sets attributes before the bubbling CustomEvent, even on Save.
	input.validationResult = result => {
		if (result === true) {
			input.removeAttribute('data-tooltip');
			input.removeAttribute('data-tooltip-style');
			input.dispatchEvent({ type: 'validation-success', bubbles: true });
		}
		else {
			input.setAttribute('data-tooltip', result);
			input.setAttribute('data-tooltip-style', 'error');
			input.dispatchEvent({ type: 'validation-failure', bubbles: true, detail: { message: result } });
		}
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

function dropdownLayout(node, input, choices) {
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
	const placeholder = node.placeholder = E('li', { placeholder: '', selected: '' });
	placeholder.style = {};
	list.children = [ placeholder, ...choices.map(c => E('li', { 'data-value': c.key })), item ];
	list.querySelector = selector => selector.split(', ').some(part =>
		(part == 'li[placeholder]' && Object.hasOwn(placeholder.attrs, 'placeholder'))
		|| (part == 'li[data-value=""]' && placeholder.attrs['data-value'] === '')) ? placeholder : null;
	node.finishOpen = () => {
		const visual = [...list.children];
		if (list.style.display == 'flex')
			visual.sort((a, b) => Number(a.style?.order ?? 0) - Number(b.style?.order ?? 0));
		const selected = list.children.find(li => Object.hasOwn(li.attrs, 'selected'));
		let offset = 0;
		for (const li of visual) {
			li.offsetHeight = li == item ? 40 : 20;
			li.offsetTop = offset;
			offset += li.offsetHeight;
		}
		list.scrollTop = node.scrollTop = selected ? Math.max(selected.offsetTop - selected.offsetHeight, 0) : 0;
	};
	const box = node.dropdown = {
		openDropdown() {
			node.previewStyle = { ...list.style };
			node.open = true;
		},
		closeDropdown() { node.open = false; }
	};
	input.closest = selector => selector == 'li' ? item : selector == '.cbi-dropdown' ? box : null;
}

function renderAccessList(option, sid, value) {
	const node = renderList(option, sid, value);
	const input = node.input = textInput();
	const dropdown = option.choices.length > 0;
	const captures = {};
	const listeners = {};
	input.eventParent = node;
	node.dispatchEvent = event => {
		for (const fn of listeners[event.type] ?? []) fn(event);
	};
	const plus = { closest: selector => selector == '.cbi-button-add' ? plus : null,
		get previousElementSibling() {
			return input.parentNode.children[input.parentNode.children.indexOf(plus) - 1];
		} };
	if (!dropdown) input.parentNode.children.push(plus);
	node.addEventListener = (type, fn, capture) => {
		if (capture) captures[type] = fn;
		else (listeners[type] ??= []).push(fn);
	};
	node.querySelector = selector => {
		if (selector.includes('.create-item-input'))
			return dropdown || selector.includes('.add-item') ? input : null;
		if (selector == '.add-item > input[type="text"]') return dropdown ? null : input;
		return null;
	};
	input.closest = () => null;
	if (dropdown)
		dropdownLayout(node, input, option.choices);
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
		input.validationResult(error);
		if (error !== true) {
			node.valid = false;
			node.validationError = error;
		}
		return node.valid;
	};
	for (const event of [ 'keyup', 'blur' ])
		input.addEventListener(event, () => node.triggerValidation());
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
