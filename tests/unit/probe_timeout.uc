'use strict';

// T9.50 / docs/05 config probe: schema and normalized error contract, no UCI mutation.
import { SCHEMA } from 'aetherproxy.schema';
import { normalize } from 'aetherproxy.config';

export const cases = [
	{ name: 'probe timeout schema bounds and default', schema: true, expect: [ 1, 30, 5 ] },
	{ name: 'probe timeout absent defaults to 5', expect: [ true, 5, [] ] },
	{ name: 'probe timeout 0 invalid_range', value: '0', expect: [ false, null, [ 'probe.timeout:invalid_range' ] ] },
	{ name: 'probe timeout 1 accepted', value: '1', expect: [ true, 1, [] ] },
	{ name: 'probe timeout 5 accepted', value: '5', expect: [ true, 5, [] ] },
	{ name: 'probe timeout 30 accepted', value: '30', expect: [ true, 30, [] ] },
	{ name: 'probe timeout 31 invalid_range', value: '31', expect: [ false, null, [ 'probe.timeout:invalid_range' ] ] },
	{ name: 'probe timeout -1 invalid_range', value: '-1', expect: [ false, null, [ 'probe.timeout:invalid_range' ] ] },
	{ name: 'probe timeout nonnumeric invalid_int', value: 'abc', expect: [ false, null, [ 'probe.timeout:invalid_int' ] ] }
];

export function run(c) {
	if (c.schema) {
		let f = filter(SCHEMA.probe, f => f.name == 'timeout')[0];
		return [ f.min, f.max, f.default ];
	}
	let raw = { probe: c.value == null ? {} : { timeout: c.value } };
	let result = normalize(raw);
	return [ result.ok, result.snapshot?.probe.timeout ?? null,
		map(result.errors ?? [], e => e.field + ':' + e.code) ];
};
