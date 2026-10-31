'use strict';

// B24 client ownership must never include the feeds/legacy package (docs/tasks T10.73).
import * as C from 'aetherproxy.const';
import * as schedule from 'aetherproxy.schedule';

export const cases = [ {
	name: 'T10.73 manages aether-xray only and preserves minimum version', expect: 'PASS'
} ];
const owned = { newer: true, available: '26.10.21-r1', asset: 'aether-xray.ipk' };
const legacy = { newer: true, available: '99.1-r9', asset: 'xray-core.ipk' };
for (let policy in [ 'off', 'notify', 'auto' ])
	for (let mode in [ 'owned', 'legacy', 'both', 'attempted' ])
		push(cases, {
			name: `T10.73 xray_auto ${policy} ${mode} uses owned package only`, expect: 'PASS',
			policy, mode
		});

export function run(test) {
	if (test.policy != null) {
		let packages = {};
		if (test.mode != 'legacy')
			packages['aether-xray'] = owned;
		if (test.mode == 'legacy' || test.mode == 'both')
			packages['xray-core'] = legacy;
		let record = test.mode == 'attempted' ? { auto_install: { version: owned.available } } : {};
		let got = schedule.auto_install_due({ xray_auto: test.policy }, { packages }, record);
		let want = test.policy == 'auto' && test.mode != 'legacy' && test.mode != 'attempted'
			? owned.available : null;
		return got == want ? 'PASS' : sprintf('FAIL: got %.J, expected %.J', got, want);
	}
	return C.XRAY_CORE_PACKAGE == 'aether-xray'
		&& index(C.UPDATE_PACKAGES, 'aether-xray') >= 0
		&& index(C.UPDATE_PACKAGES, 'xray-core') < 0
		&& C.XRAY_MIN_VERSION == '26.3.27' ? 'PASS' : 'FAIL: wrong managed package or minimum version';
};
