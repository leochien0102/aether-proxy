'use strict';

/* Save-path double from SDK 24.10.8 form.js: AbstractValue and FlagValue.
 * In particular a Flag reads the displayed checkbox state, and its parse does
 * NOT compare cfgvalue. Keep this distinct from a change-aware application option.
 * No third-party source is copied; only the observable save contract is modeled.
 */
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
class Value {
	constructor(section, field) {
		this.section = section;
		this.map = section.map;
		this.option = field;
		this.rmempty = true;
		this.keylist = [];
		this.vallist = [];
		this.inputs = {};
		this.deplist = [];
	}
	value(key, label) { this.keylist.push(key); this.vallist.push(label); return this; }
	depends(field, value) { this.deplist.push(typeof field == 'string' ? { [field]: value } : field); }
	cfgvalue(id) {
		return this.loaded && Object.hasOwn(this.loaded, id) ? this.loaded[id]
			: this.map.data.get(this.map.config, this.ucisection ?? id, this.option);
	}
	formvalue(id) { return this.inputs[id] ?? this.cfgvalue(id) ?? this.default ?? ''; }
	getUIElement() { return null; }
	isActive(id) {
		if (this.active != null)
			return this.active;
		return !this.deplist.length || this.deplist.some(dep => {
			const matches = Object.entries(dep).filter(([field]) => field != '!reverse').every(([field, expected]) => {
				const value = this.map.lookupOption(field)?.[0].formvalue(id);
				return expected instanceof RegExp ? expected.test(value ?? '') : value === expected;
			});
			return dep['!reverse'] ? !matches : matches;
		});
	}
	isValid(id) { return !this.validate || this.validate(id, this.formvalue(id)) === true; }
	parse(id) {
		if (!this.isActive(id))
			return Promise.resolve(this.retain ? undefined : this.remove(id));
		if (!this.isValid(id))
			return Promise.reject(new TypeError('invalid input value'));
		const value = this.formvalue(id);
		if (value == null || value == '') {
			if (this.rmempty || this.optional)
				return Promise.resolve(this.remove(id));
			return Promise.reject(new TypeError('must not be empty'));
		}
		return Promise.resolve(this.forcewrite || !equal(this.cfgvalue(id), value) ? this.write(id, value) : undefined);
	}
	write(id, value) { return this.map.data.set(this.map.config, this.ucisection ?? id, this.option, value); }
	remove(id) { return this.map.data.unset(this.map.config, this.ucisection ?? id, this.option); }
}
class Flag extends Value {
	constructor(...args) { super(...args); this.default = '0'; this.enabled = '1'; this.disabled = '0'; }
	formvalue(id) { return super.formvalue(id) === this.enabled ? this.enabled : this.disabled; }
	parse(id) {
		if (!this.isActive(id))
			return Promise.resolve(this.retain ? undefined : this.remove(id));
		if (!this.isValid(id))
			return Promise.reject(new TypeError('invalid input value'));
		const value = this.formvalue(id);
		return Promise.resolve(value == this.default && (this.optional || this.rmempty)
			? this.remove(id) : this.write(id, value));
	}
}
class DynamicList extends Value {
	formvalue(id) { const v = super.formvalue(id); return Array.isArray(v) ? v : v === '' ? [] : [v]; }
	isValid(id) {
		return !this.validate || [...this.formvalue(id), ''].every(value => this.validate(id, value) === true);
	}
}
module.exports = { Value, Flag, DynamicList, ListValue: class extends Value {},
	RichListValue: class extends Value {}, TextValue: class extends Value {}, DummyValue: class extends Value {} };
