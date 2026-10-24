'use strict';

/* Layout contract modeled from SDK 24.10.8 form.js Value.renderFrame and
 * ui.js Checkbox.render (docs/10 r16 card flags). Preserve the two native divs,
 * dependency marker, label and input; a span-only widget double missed T10.49.
 * This is a behavioral double, not copied LuCI source or a CSS layout engine.
 */
const { element: E } = require('./loader');

function node(tag, attrs, children) {
	const el = E(tag, attrs, children);
	el.style = {};
	el.matches = selector => selector === tag;
	el.classList = {
		contains: name => (el.attrs.class ?? '').split(/\s+/).includes(name),
		add: name => { if (!el.classList.contains(name)) el.attrs.class = `${el.attrs.class ?? ''} ${name}`.trim(); },
		remove: name => { el.attrs.class = (el.attrs.class ?? '').split(/\s+/).filter(c => c !== name).join(' '); }
	};
	el.querySelector = selector => {
		for (const child of el.children) {
			if (typeof child !== 'object' || child == null)
				continue;
			const match = selector === '[data-field]' ? child.attrs['data-field'] != null
				: selector === '.cbi-checkbox' && child.classList?.contains('cbi-checkbox');
			if (match)
				return child;
			const nested = child.querySelector?.(selector);
			if (nested)
				return nested;
		}
		return null;
	};
	for (const child of el.children)
		if (child && typeof child === 'object')
			child.parentNode = el;
	return el;
}

function checkboxWidget(checked) {
	return node('div', { class: 'cbi-checkbox' }, [
		node('input', { type: 'checkbox', checked: checked || null }, []),
		node('label', { for: 'native-checkbox' }, [])
	]);
}

function renderFrame(id, in_table, index, widget) {
	const field = node('div', { 'data-field': `cbid.aetherproxy.${id}.${this.option}`,
		'data-index': index, class: this.initiallyHidden ? 'hidden' : '' }, [widget]);
	const frame = in_table
		? node('td', { class: 'td cbi-value-field', 'data-name': this.option,
			'data-widget': 'CBI.FlagValue', 'data-title': this.title }, [field])
		: node('div', { class: 'cbi-value' }, [node('label', {}, [this.title]), field]);
	this.baseFrame = frame;
	return frame;
}

module.exports = { renderFrame, checkboxWidget };
