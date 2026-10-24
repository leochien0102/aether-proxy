'use strict';
'require baseclass';

/* Change-aware UCI form saves (docs/10 "r16 修正：不改保存不写默认值").
 * Keep SDK validation and custom writers, but do not let Flag.parse's unconditional
 * writes or AbstractValue.parse's displayed defaults materialize absent options.
 * Display defaults come from the option; placeholder-only backend fallbacks are
 * passed separately, since a placeholder must never become the input value.
 */
function normalized(value) {
	if (Array.isArray(value))
		return value.map(String);
	return value == null ? '' : String(value);
}

function equal(left, right) {
	/* UCI permits a one-item list to be stored as a scalar. Compare as a list
	 * when the widget supplies one, without ignoring meaningful list ordering. */
	if (Array.isArray(left) || Array.isArray(right)) {
		left = left == null || left === '' ? [] : Array.isArray(left) ? left : [left];
		right = right == null || right === '' ? [] : Array.isArray(right) ? right : [right];
	}
	return JSON.stringify(normalized(left)) === JSON.stringify(normalized(right));
}

function default_value(option, fallback, section_id) {
	return fallback === undefined ? option.default :
		typeof fallback == 'function' ? fallback.call(option, section_id) : fallback;
}

function wrap(option, fallback, behavior) {
	const parse = option.parse;
	const write = option.write;
	const remove = option.remove;
	const normalize = value => value == null || !behavior?.normalize ? value : behavior.normalize(value);
	const same = (left, right) => equal(normalize(left), normalize(right));
	option.parse = function(section_id) {
		const saved = this.cfgvalue(section_id);
		/* Preserve inactive-layer values (docs/05), except dependency conflicts
		 * the page explicitly marks for SDK cleanup: direct + UDP, Vision + Mux.
		 * An absent or explicitly disabled flag still needs no cleanup write. */
		if (!this.isActive(section_id)) {
			if (behavior?.clear_inactive && saved != null && !same(saved, this.default))
				return parse.call(this, section_id);
			return Promise.resolve();
		}
		const value = this.formvalue(section_id);
		const displayed = saved ?? this.default;
		const unchanged = same(value, displayed) ||
			(saved == null && same(value, default_value(this, fallback, section_id)));
		const empty = value == null || value == '';
		/* Still delegate invalid inputs and required empty lists to SDK parse;
		 * an unchanged invalid configuration must not bypass validation. */
		if (this.isValid(section_id) && (!empty || this.rmempty || this.optional) && unchanged)
			return Promise.resolve();
		return parse.call(this, section_id);
	};
	option.write = function(section_id, value) {
		const defaultValue = default_value(this, fallback, section_id);
		if (defaultValue != null && same(value, defaultValue))
			return remove.call(this, section_id);
		return write.call(this, section_id, value);
	};
	option.remove = function(section_id) {
		// Optional empty inputs are parsed even if no option ever existed.
		if (this.cfgvalue(section_id) == null)
			return;
		return remove.call(this, section_id);
	};
	return option;
}

return baseclass.extend({
	equal: equal,
	/* Apply after declaring options so custom write/remove methods are retained.
	 * DummyValues are presentation only; subclasses such as TextValue,
	 * RichListValue and DeviceSelect use the same save contract as Value. */
	section: function(section, fallbacks, behaviors) {
		for (const option of section.children)
			if (!option.option.startsWith('_'))
				wrap(option, fallbacks?.[option.option], behaviors?.[option.option]);
	}
});
