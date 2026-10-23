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
module.exports = { selectWidget };
