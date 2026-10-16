'use strict';

import * as schedule from 'aetherproxy.schedule';

function local_epoch(mday, mon, year, hour, minute) {
	return timelocal({ sec: 0, min: minute, hour, mday, mon, year });
};

let day = local_epoch(16, 9, 2025, 0, 0);
let tm = localtime(day + 12 * 3600);
let due_cfg = { data_auto: true };
let updates = { packages: { 'xray-core': { newer: true, available: '2', asset: 'xray.ipk' } } };
let cases = [
	{ name: 'last slot today passed', actual: schedule.last_slot(day + 13 * 3600, 12, 0, tm), expected: day + 12 * 3600 },
	{ name: 'last slot not yet reached', actual: schedule.last_slot(day + 11 * 3600, 12, 0, tm), expected: day - 12 * 3600 },
	{ name: 'last slot exact', actual: schedule.last_slot(day + 12 * 3600, 12, 0, tm), expected: day + 12 * 3600 },
	{ name: 'last slot null minute defaults to 30', actual: schedule.last_slot(day + 13 * 3600, 12, null, tm), expected: day + 12 * 3600 + 1800 },
	{ name: 'last slot crosses month', actual: schedule.last_slot(local_epoch(1, 10, 2025, 1, 0), 23, 0, localtime(local_epoch(1, 10, 2025, 1, 0))), expected: local_epoch(30, 9, 2025, 23, 0) },
	{ name: 'missing record uses start time', actual: schedule.update_due(due_cfg, {}, day, day + 1), expected: null },
	{ name: 'data prioritized when both due', actual: schedule.update_due(due_cfg, { data: { last_attempt: 0 }, check: { last_attempt: 0 } }, day, day + 1), expected: 'data' },
	{ name: 'data after slot checks check using daemon start', actual: schedule.update_due(due_cfg, { data: { last_attempt: day + 1 } }, day, 0), expected: 'check' },
	{ name: 'data disabled selects check', actual: schedule.update_due({ data_auto: false }, { data: { last_attempt: 0 }, check: { last_attempt: 0 } }, day, day + 1), expected: 'check' },
	{ name: 'malformed record uses daemon start', actual: schedule.update_due(due_cfg, { data: { last_attempt: 'bad' }, check: { last_attempt: 'bad' } }, day, day + 1), expected: null },
	{ name: 'auto installs newer xray', actual: schedule.auto_install_due({ xray_auto: 'auto' }, updates, {}), expected: '2' },
	{ name: 'off does not install', actual: schedule.auto_install_due({ xray_auto: 'off' }, updates, {}), expected: null },
	{ name: 'notify does not install', actual: schedule.auto_install_due({ xray_auto: 'notify' }, updates, {}), expected: null },
	{ name: 'not newer does not install', actual: schedule.auto_install_due({ xray_auto: 'auto' }, { packages: { 'xray-core': { newer: false, available: '2', asset: 'xray.ipk' } } }, {}), expected: null },
	{ name: 'null asset does not install', actual: schedule.auto_install_due({ xray_auto: 'auto' }, { packages: { 'xray-core': { newer: true, available: '2', asset: null } } }, {}), expected: null },
	{ name: 'same version installs once', actual: schedule.auto_install_due({ xray_auto: 'auto' }, updates, { auto_install: { version: '2' } }), expected: null },
	{ name: 'new version is eligible', actual: schedule.auto_install_due({ xray_auto: 'auto' }, { packages: { 'xray-core': { newer: true, available: '3', asset: 'xray.ipk' } } }, { auto_install: { version: '2' } }), expected: '3' }
];
let failed = 0;
for (let c in cases) {
	if (c.actual != c.expected) {
		warn(`FAIL ${c.name}: expected ${c.expected}, got ${c.actual}\n`);
		failed++;
	}
	else
		warn(`PASS ${c.name}\n`);
}
if (failed) die(`${failed} update schedule unit case(s) failed`);
