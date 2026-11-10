'use strict';

// M4-02: metadata-only normalization must never alter discovery inputs.
import * as ids from 'aetherproxy.component_id';

export const cases = [];
for (let pair in [
	[ '/usr/bin/aether-dns', 'aether-dns' ], [ '/usr/bin/chinadns-ng', 'chinadns-ng' ],
	[ '/opt/foo', null ], [ null, null ], [ '', null ], [ 42, null ], [ {}, null ],
	[ 'aether-dns', 'aether-dns' ], [ '/opt/aether-dns/', null ]
])
	push(cases, { name: sprintf('engine %.J', pair[0]), path: pair[0], want: pair[1], expect: 'PASS' });
for (let value in [ null, 42, 'dns', [] ])
	push(cases, { name: sprintf('invalid table %.J', value), kind: 'invalid', value, expect: 'PASS' });
push(cases, { name: 'aliases preserve input and fields; dns wins conflict', kind: 'aliases', expect: 'PASS' });
push(cases, { name: 'missing path produces null engine', kind: 'missing', expect: 'PASS' });
push(cases, { name: 'undefined DNS metadata preserved conservatively', kind: 'malformed', expect: 'PASS' });

for (let pair in [ [ 'aether-dns', '1.0.0' ], [ 'chinadns-ng', '2025.08.09' ],
	[ null, null ], [ 'custom', null ] ])
	push(cases, { name: sprintf('M4-03a floor %.J', pair[0]), kind: 'floor',
		engine: pair[0], want: pair[1], expect: 'PASS' });

export function run(c) {
	if (c.kind == 'floor')
		return ids.min_version(c.engine) === c.want ? 'PASS' : 'FAIL: wrong engine floor';
	if (c.kind == 'invalid')
		return ids.with_aliases(c.value) === null ? 'PASS' : 'FAIL: invented table';
	if (c.kind == 'malformed') {
		let source = { xray: { path: '/xray' }, dns: null, 'chinadns-ng': { path: '/old' } };
		return sprintf('%.J', ids.with_aliases(source)) == sprintf('%.J', source)
			? 'PASS' : 'FAIL: recovered undefined metadata';
	}
	if (c.kind == 'missing') {
		let result = ids.with_aliases({ dns: { version: null } });
		return result.dns.engine === null && result['chinadns-ng'].engine === null
			&& index(keys(result.dns), 'path') < 0 ? 'PASS' : 'FAIL: missing path changed';
	}
	if (c.kind == 'aliases') {
		let source = { xray: { path: '/xray', version: '1' },
			dns: { found: true, path: '/usr/bin/aether-dns', version: '2', extra: [ 'keep' ] },
			'chinadns-ng': { path: '/old', version: 'stale' } };
		let before = sprintf('%.J', source);
		let result = ids.with_aliases(source);
		let want = { ...source.dns, engine: 'aether-dns' };
		if (sprintf('%.J', result.dns) != sprintf('%.J', want)
			|| sprintf('%.J', result.dns) != sprintf('%.J', result['chinadns-ng'])
			|| sprintf('%.J', result.xray) != sprintf('%.J', source.xray))
			return 'FAIL: alias content or authority';
		result.dns.version = 'changed';
		result.new_field = true;
		return sprintf('%.J', source) == before ? 'PASS' : 'FAIL: input mutated';
	}
	return ids.engine(c.path) === c.want ? 'PASS' : 'FAIL: wrong engine';
};
