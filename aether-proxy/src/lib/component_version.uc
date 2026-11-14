'use strict';

// Pure component banner parsing and minimum-version comparison (docs/04 "components",
// docs/01 constants and docs/06 "Xray 配置渲染"). Version commands stay in cmd/* (docs/12).
// Only the dotted numeric core orders components; package release/build metadata does not.
// Validate the whole input before stripping metadata, so malformed versions remain unknown.
function version_parts(version) {
	if (type(version) != 'string')
		return null;
	let matched = match(version, /^v?([0-9]+(\.[0-9]+)+)(-r[0-9]+)?(\+[0-9A-Za-z._-]+)?$/);
	if (matched == null || matched[0] != version)
		return null;
	return map(split(matched[1], '.'), part => replace(part, /^0+/, '') || '0');
}

// Compare decimal segments without overflow, even for arbitrarily long numeric fields.
function segment_cmp(left, right) {
	if (length(left) != length(right))
		return length(left) < length(right) ? -1 : 1;
	for (let i = 0; i < length(left); i++) {
		let a = int(substr(left, i, 1), 10);
		let b = int(substr(right, i, 1), 10);
		if (a != b)
			return a < b ? -1 : 1;
	}
	return 0;
}

export function version_cmp(left, right) {
	let a = version_parts(left);
	let b = version_parts(right);
	if (a == null || b == null)
		return null;
	for (let i = 0; i < length(a) || i < length(b); i++) {
		let order = segment_cmp(a[i] ?? '0', b[i] ?? '0');
		if (order != 0)
			return order;
	}
	return 0;
};

export function parse_version(text) {
	let first = trim(split(text ?? '', '\n')[0]);
	if (first == '')
		return null;
	let fields = split(first, /\s+/);
	return length(fields) >= 2 ? fields[1] : null;
};

// M4-19: display the canonical "<core>-r<rev>". LEDE renders the package release as
// "<core>-<rev>", the SDK as "<core>-r<rev>"; both are the same revision.
export function normalize_release(version) {
	if (type(version) != 'string' || version == '')
		return null;
	let matched = match(version, /^(.+?)-r?([0-9]+)$/);
	return matched == null ? version : `${matched[1]}-r${matched[2]}`;
};

// The dotted core, without the packaging revision; used to compare banner and package.
export function release_core(version) {
	if (type(version) != 'string' || version == '')
		return null;
	return replace(version, /-r?[0-9]+$/, '');
};

// A mismatch means the installed package version and the binary banner disagree on the core.
// Missing data on either side is never a mismatch: it is "unknown", not "consistent".
export function version_mismatch(installed, banner) {
	let a = release_core(installed);
	let b = release_core(banner);
	return a != null && b != null && a != b;
};

