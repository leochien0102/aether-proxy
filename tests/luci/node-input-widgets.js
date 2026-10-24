'use strict';

/* Minimal modal widgets for T10.33. Follow SDK form.js/ui.js contracts:
 * TextValue renders a frame containing a textarea, ListValue selects cfgvalue,
 * value() appends string key/caption pairs, and write() stages map.data.set().
 * No SDK code is loaded or copied; these doubles keep DOM and UCI inspectable. */
const { element: E } = require('./loader');

function inputOf(node) {
	if (['input', 'textarea', 'select'].includes(node.tag))
		return node;
	return node.children?.map(inputOf).find(Boolean);
}

function widgetTypes() {
	class Value {
		value(key, label) {
			(this.keylist ??= []).push(String(key));
			(this.vallist ??= []).push(String(label ?? key));
		}
		remove(id) { return this.map.data.unset(this.map.config, id, this.option); }
		write(id, value) {
			return this.map.data.set(this.map.config, id, this.option, value);
		}
	}
	class ListValue extends Value {
		renderWidget(id, index, cfgvalue) {
			const selected = cfgvalue ?? this.default;
			return E('select', {}, this.keylist.map((key, i) => E('option', {
				value: key, selected: key === selected ? true : null
			}, this.vallist[i])));
		}
	}
	class TextValue extends Value {
		renderWidget(id, index, cfgvalue) {
			const input = E('textarea', {
				value: cfgvalue ?? this.default ?? '', rows: this.rows, wrap: this.wrap ? 'soft' : 'off'
			});
			const frame = E('div', {}, [input]);
			frame.querySelector = selector => selector === 'textarea' ? input : null;
			return frame;
		}
	}
	return { Value, ListValue, TextValue,
		GridSection: class extends Value {}, DummyValue: class extends Value {},
		DynamicList: class extends Value {}, Flag: class extends Value {} };
}

module.exports = { widgetTypes, inputOf };
