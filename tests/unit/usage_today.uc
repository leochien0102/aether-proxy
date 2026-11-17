'use strict';

// T16.8 design §2.1: optional live snapshots survive state round trips; junk is unavailable.
import * as state from 'aetherproxy.state';
import * as fs from 'fs';

const DIR = `${getenv('TMPDIR') ?? '/tmp'}/aether-live-state.${fs.readlink('/proc/self')}`;
const LIVE = { date: '2026-11-17', tx: 123, rx: 456, observed: 60.5, healthy: 55, at: 1794900000 };

export const cases = [
	{ name: 'T16.8 state live-day round trip', live: LIVE, expect: LIVE },
	{ name: 'T16.8 state accepts age exactly 600 seconds', live: LIVE, now: LIVE.at + 600, expect: LIVE },
	{ name: 'T16.8 state rejects age 601 seconds', live: LIVE, now: LIVE.at + 601, expect: null },
	{ name: 'T16.8 state accepts timestamp distance exactly 600 seconds',
		live: LIVE, now: LIVE.at - 600, expect: LIVE },
	{ name: 'T16.8 state rejects timestamp distance 601 seconds', live: LIVE, now: LIVE.at - 601, expect: null },
	{ name: 'T16.8 state old snapshot without live day', absent: true, expect: null },
	{ name: 'T16.8 state malformed scalar live day', live: 7, expect: null },
	{ name: 'T16.8 state malformed array live day', live: [], expect: null },
	{ name: 'T16.8 state missing numeric field', live: { ...LIVE, rx: null }, expect: null },
	{ name: 'T16.8 state numeric string is not a counter', live: { ...LIVE, tx: '123' }, expect: null },
	{ name: 'T16.8 state negative counter', live: { ...LIVE, tx: -1 }, expect: null },
	{ name: 'T16.8 state invalid timestamp', live: { ...LIVE, at: 'now' }, expect: null },
	{ name: 'T16.8 state missing date', live: { ...LIVE, date: null }, expect: null },
	{ name: 'T16.8 state malformed date', live: { ...LIVE, date: 'yesterday' }, expect: null },
	{ name: 'T16.8 state healthy exceeds observed', live: { ...LIVE, healthy: 61 }, expect: null }
];

export function run(c) {
	fs.mkdir(DIR);
	let obj = { state: 'running' };
	if (!c.absent)
		obj.usage_today = c.live;
	let written = state.write(DIR, obj);
	let got = state.read(DIR);
	let error = state.error();
	fs.unlink(`${DIR}/state.json`);
	fs.rmdir(DIR);
	if (!written || error != null || sprintf('%.J', got) != sprintf('%.J', obj))
		return 'state round trip failed';
	return state.usage_today_of(got, c.now ?? LIVE.at);
};
