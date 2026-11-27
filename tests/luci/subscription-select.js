'use strict';
/* Model ui.Select's selection contract from the read-only 24.10.8 SDK:
 * an empty choice enables optional selection; an array sort overrides key order.
 * Keep requested and actually selected values distinct, unlike the old double. */
function selectWidget(value, choices, options) {
	const values = Array.isArray(value) ? value : value != null && value !== '' ? [value] : [];
	const optional = Object.hasOwn(choices, '') || options.optional;
	let keys = Object.keys(choices);
	if (Array.isArray(options.sort))
		keys = options.sort;
	const ordered = (optional ? [''] : []).concat(keys.filter(key => key != null && key !== ''));
	const selected = ordered.find(key => values.includes(key));
	return {
		choices: ordered.map(key => [key, choices[key]]),
		value: selected ?? ordered[0] ?? '',
		placeholder: options.placeholder,
		setPlaceholder(text) { this.placeholder = text; }
	};
}
// T16.124 composite UA widgets: keep the text widget's actual value separate
// from its companion Select. These doubles do not replace the real SDK gate.
function textWidget(E, value, placeholder) {
	const input = E('input', { type: 'text', value: value ?? '', placeholder });
	const node = E('div', {}, [input]);
	Object.defineProperty(node, 'value', {
		get: () => input.value,
		set: value => { input.value = value; }
	});
	node.input = input;
	node.placeholder = placeholder;
	node.setPlaceholder = text => { node.placeholder = text; input.setAttribute('placeholder', text); };
	node.getValue = () => input.value;
	node.setValue = value => { input.value = value; };
	node.triggerValidation = () => false;
	node.querySelector = selector => selector.includes('input') ? input : null;
	return node;
}

function selectType(E) {
	return class Select {
		constructor(value, choices, options) {
			this.widget = selectWidget(value, choices, options);
			this.options = options;
		}
		render() {
			const options = this.widget.choices.map(([value, label]) => E('option', {
				value, selected: value === this.widget.value ? '' : null
			}, [label]));
			this.input = E('select', { id: 'widget.' + this.options.id }, options);
			const node = E('div', { id: this.options.id }, [this.input]);
			node.querySelector = selector => selector === 'option[value=""]'
				? options.find(option => option.value === '') : null;
			return node;
		}
		getValue() { return this.input.value; }
	};
}

module.exports = { selectWidget, selectType, textWidget };
