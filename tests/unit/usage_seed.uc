'use strict';

import * as usage from 'aetherproxy.usage';

const NOW = timelocal({ year: 2026, mon: 11, mday: 21, hour: 12, min: 0, sec: 0 });
const TOMORROW = timelocal({ year: 2026, mon: 11, mday: 22, hour: 12, min: 0, sec: 0 });
const DAY = '2026-11-21', NEXT = '2026-11-22';
const ENTRY = { tx: 200000000, rx: 1800000000, observed: 1800, healthy: 1500 };

export const cases = [
	{ name: 'T16.45 valid today seeds all totals but neither nft baseline', expect: {
		day: DAY, ...ENTRY, last_tx: null, last_rx: null, input_unchanged: true } },
	{ name: 'T16.45 wrong date does not seed', day: NEXT, expect: null },
	{ name: 'T16.45 valid_entry rejects negative counters', entry: { ...ENTRY, tx: -1 }, expect: null },
	{ name: 'T16.45 valid_entry rejects a missing timing field',
		entry: { tx: ENTRY.tx, rx: ENTRY.rx, observed: ENTRY.observed }, expect: null },
	{ name: 'T16.45 no entry does not seed', entry: null, expect: null },
	{ name: 'T16.47 seed uses all larger runtime totals',
		live: { date: DAY, tx: ENTRY.tx + 11, rx: ENTRY.rx + 22, observed: 1900, healthy: 1600 },
		expect: { day: DAY, tx: ENTRY.tx + 11, rx: ENTRY.rx + 22, observed: 1900, healthy: 1600,
			last_tx: null, last_rx: null, input_unchanged: true } },
	{ name: 'T16.47 seed uses all larger disk totals',
		live: { date: DAY, tx: 10, rx: 20, observed: 30, healthy: 25 },
		expect: { day: DAY, ...ENTRY, last_tx: null, last_rx: null, input_unchanged: true } },
	{ name: 'T16.47 seed combines mixed totals without summing',
		live: { date: DAY, tx: 10, rx: ENTRY.rx + 22, observed: 1790, healthy: 1550 },
		expect: { day: DAY, ...ENTRY, rx: ENTRY.rx + 22, healthy: 1550,
			last_tx: null, last_rx: null, input_unchanged: true } },
	{ name: 'T16.47 seed uses validated runtime alone without valid disk',
		entry: { tx: ENTRY.tx + 11, rx: -1 }, live: { date: DAY, ...ENTRY },
		expect: { day: DAY, ...ENTRY, last_tx: null, last_rx: null, input_unchanged: true } },
	{ name: 'T16.47 seed ignores a runtime entry from another day',
		entry: null, live: { date: NEXT, ...ENTRY }, expect: null },
	{ name: 'T16.45 first readable sample after a failed read only records the baseline',
		reads: [[ null, null ], [ 5000, 8000 ]], expect: {
			day: DAY, ...ENTRY, last_tx: 5000, last_rx: 8000, input_unchanged: true } },
	{ name: 'T16.45 subsequent samples add only the nft deltas and new observation time',
		reads: [[ 5000, 8000 ], [ 5050, 8200 ]], expect: {
			day: DAY, tx: ENTRY.tx + 50, rx: ENTRY.rx + 200,
			observed: ENTRY.observed + 30, healthy: ENTRY.healthy + 30,
			last_tx: 5050, last_rx: 8200, input_unchanged: true } },
	{ name: 'T16.45 crossing before the first readable sample preserves the old day',
		reads: [[ 5000, 8000, TOMORROW ]], completed: true, expect: {
			day: NEXT, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 5000, last_rx: 8000,
			input_unchanged: true, completed: ENTRY } }
];

export function run(c) {
	let initial = usage.create();
	let seeded = usage.seed(initial, 'entry' in c ? c.entry : ENTRY, c.day ?? DAY, NOW, c.live);
	if (seeded == null)
		return null;
	let input_unchanged = sprintf('%.J', initial) == sprintf('%.J', usage.create());
	for (let reading in c.reads ?? [])
		usage.sample(seeded, { tx: reading[0], rx: reading[1], now: reading[2] ?? NOW,
			elapsed: 30, cap: 60, state: 'running', proxy_ok: true });
	let result = { day: seeded.day, tx: seeded.tx, rx: seeded.rx, observed: seeded.observed,
		healthy: seeded.healthy, last_tx: seeded.last_tx, last_rx: seeded.last_rx, input_unchanged };
	if (c.completed)
		result.completed = seeded.days[DAY];
	return result;
};
