'use strict';
// Test-only fault boundary around real fs handles. All opened descriptors really
// close, even when simulating the API's close-error return; counters prove cleanup.
import * as native from 'fs';
import * as uloop from 'uloop';
// Separate loadstring programs may instantiate this module more than once. Keep
// counters in the test VM, so the driver and final observation share real I/O counts.
export const stats = global.XRAY_READY_FS_STATS ?? { opened: 0, closed: 0, read: 0 };
global.XRAY_READY_FS_STATS = stats;
export function open(path, mode) {
	let fault = getenv('XRAY_READY_FS_FAULT');
	if (fault == 'open')
		return null;
	let file = native.open(path, mode);
	if (file == null)
		return null;
	stats.opened++;
	return {
		read: count => {
			stats.read++;
			if (fault == 'read' || fault == 'read-close')
				return null;
			if (fault == 'signal') {
				warn('ELF_OPEN\n');
				uloop.run(250);
			}
			if (fault == 'budget')
				uloop.run(5100);
			return file.read(count);
		},
		close: () => {
			stats.closed++;
			let result = file.close();
			return fault == 'close' || fault == 'read-close' ? null : result;
		}
	};
};
export function error() { return native.error() ?? 'injected fs failure'; };
export function readfile(path) { return native.readfile(path); };
export function readlink(path) { return native.readlink(path); };
export function lsdir(path) { return native.lsdir(path); };
