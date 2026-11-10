'use strict';

// Pure prerequisites keep unknown runtime engines separate from package capability.
import * as update from 'aetherproxy.update';
let provider = { ok: true, version: '1.0.0-r1', provides: [ 'dns-engine' ] };
let absent = { ok: true, version: null, provides: [] };
let cases = [
	[ 'provider without runtime', null, [ provider ], false ],
	[ 'runtime without provider', { path: '/usr/bin/chinadns-ng', version: '2025.08.09' }, [ absent ], false ],
	[ 'known engine below floor', { path: '/usr/bin/aether-dns', version: '0.9.9' }, [ provider ], false ],
	[ 'known engine malformed banner', { path: '/usr/bin/aether-dns', version: 'garbage' }, [ provider ], false ],
	[ 'known engine at floor', { path: '/usr/bin/aether-dns', version: '1.0.0' }, [ provider ], true ],
	[ 'custom runtime still needs provider', { path: '/custom/dns', version: null }, [ absent ], false ],
	[ 'custom runtime has no floor', { path: '/custom/dns', version: null }, [ provider ], true ],
	[ 'unreadable provider metadata', { path: '/custom/dns' }, [ { ok: false, provides: [ 'dns-engine' ] } ], false ]
];
let failed = 0;
for (let c in cases) {
	let actual = update.prerequisite_satisfied(c[1], c[2]);
	printf('%s  M4-03b pure %s\n', actual == c[3] ? 'PASS' : 'FAIL', c[0]);
	if (actual != c[3])
		failed++;
}
exit(failed ? 1 : 0);
