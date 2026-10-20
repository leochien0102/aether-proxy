'use strict';

// Parse component banners without side effects (docs/04 "components" versions). Running the
// version commands lives in cmd/components.uc: docs/12 rule 1 keeps command execution in cmd/*.
export function parse_version(text) {
	let first = trim(split(text ?? '', '\n')[0]);
	if (first == '')
		return null;
	let fields = split(first, /\s+/);
	return length(fields) >= 2 ? fields[1] : null;
};

