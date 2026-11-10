'use strict';

// Pure logical-component normalization (docs/04 components, M4-02).
// Discovery and event identities remain legacy ids; only public metadata gets aliases.
import * as C from 'aetherproxy.const';

export function engine(path) {
	if (type(path) != 'string' || path == '')
		return null;
	let basename = replace(path, /^.*\//, '');
	return basename == 'aether-dns' || basename == 'chinadns-ng' ? basename : null;
};

// M4-03a: custom binaries have no defined engine floor and remain informational.
export function min_version(engine) {
	if (engine == 'aether-dns')
		return C.AETHER_DNS_MIN_VERSION;
	if (engine == 'chinadns-ng')
		return C.CHINADNS_MIN_VERSION;
	return null;
};

export function with_aliases(components) {
	if (type(components) != 'object')
		return null;
	let result = { ...components };
	// Presence, not truthiness, determines authority when both ids are supplied.
	let source = index(keys(components), C.DNS_COMPONENT) >= 0
		? components[C.DNS_COMPONENT] : components[C.CHINADNS_COMPONENT];
	if (type(source) != 'object') {
		// TODO(design): malformed/missing DNS entries have no defined recovery contract.
		// Preserve them rather than inventing a usable component or falling back to stale data.
		return result;
	}
	let dns = { ...source, engine: engine(source.path) };
	result[C.DNS_COMPONENT] = dns;
	result[C.CHINADNS_COMPONENT] = { ...dns };
	return result;
};
