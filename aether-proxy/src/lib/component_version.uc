'use strict';

// Parse component banners without side effects (docs/04 "components" versions).
export function parse_version(text) {
	let first = trim(split(text ?? '', '\n')[0]);
	if (first == '')
		return null;
	let fields = split(first, /\s+/);
	return length(fields) >= 2 ? fields[1] : null;
};
