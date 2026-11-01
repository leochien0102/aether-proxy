'use strict';

// T12.3 B25: the pure daily aggregation in usage.uc (docs/b25-heatmap.md §4).
// Fake clock: `now` values are built with timelocal, so the local dates are host-TZ
// deterministic and never sit near a DST transition. Fake nft: tx/rx are plain numbers,
// mirroring what aetherproxy.counters hands over from a real `nft -j list counters`.

import * as usage from 'aetherproxy.usage';

const D1 = '2026-10-21';
const D2 = '2026-10-22';
const D3 = '2026-10-23';
const NOON1 = timelocal({ year: 2026, mon: 9, mday: 21, hour: 12, min: 0, sec: 0 });
const NOON2 = timelocal({ year: 2026, mon: 9, mday: 22, hour: 12, min: 0, sec: 0 });
const NOON3 = timelocal({ year: 2026, mon: 9, mday: 23, hour: 12, min: 0, sec: 0 });
const CAP = 60; // 30 s running cadence doubled (docs §4.3)

const RUNNING = 'running', DEGRADED = 'degraded', FAILSAFE = 'failsafe', STARTING = 'starting';

// A sample input on the first day, 30 s after the previous one.
function day1(tx, rx, extra) {
	return { tx, rx, now: NOON1 + 30, elapsed: 30, cap: CAP, state: RUNNING, proxy_ok: true, ...(extra ?? {}) };
}

function view(s) {
	return { day: s.day, tx: s.tx, rx: s.rx, observed: s.observed, healthy: s.healthy,
		last_tx: s.last_tx, last_rx: s.last_rx, days: s.days };
}

function one(input) {
	let s = usage.create();
	usage.sample(s, input);
	return view(s);
}

// A baseline followed by the case's samples on the same local day.
function series(c) {
	let s = usage.create();
	usage.sample(s, c.baseline);
	for (let input in c.samples)
		usage.sample(s, input);
	return view(s);
}

export const cases = [
	{
		name: 'T12.3 first sample records the baseline only, whatever the elapsed',
		run: 'one',
		input: { tx: 1000, rx: 2000, now: NOON1, elapsed: 500, cap: CAP, state: RUNNING, proxy_ok: true },
		expect: { day: D1, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 1000, last_rx: 2000, days: {} }
	},
	{
		name: 'T12.3 a fresh running sample with readable counters still counts nothing',
		run: 'one',
		input: day1(1500, 2600),
		expect: { day: D1, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 1500, last_rx: 2600, days: {} }
	},
	{
		name: 'T12.3 a same-day increment accumulates deltas, observed and healthy',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(1500, 2600) ],
		expect: { day: D1, tx: 500, rx: 600, observed: 30, healthy: 30, last_tx: 1500, last_rx: 2600, days: {} }
	},
	{
		name: 'T12.3 a counter reset counts the post-reset value, not a negative delta',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(300, 2600) ],
		expect: { day: D1, tx: 300, rx: 600, observed: 30, healthy: 30, last_tx: 300, last_rx: 2600, days: {} }
	},
	{
		name: 'T12.3 tx and rx resets are decided independently',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(2600, 400) ],
		expect: { day: D1, tx: 1600, rx: 400, observed: 30, healthy: 30, last_tx: 2600, last_rx: 400, days: {} }
	},
	{
		name: 'T12.3 unreadable counters skip the bytes and the seconds, keeping the baseline',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(null, null) ],
		expect: { day: D1, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 1000, last_rx: 2000, days: {} }
	},
	{
		name: 'T12.3 the next good read resumes the series across a failed round',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(null, null), day1(1200, 2100) ],
		expect: { day: D1, tx: 200, rx: 100, observed: 30, healthy: 30, last_tx: 1200, last_rx: 2100, days: {} }
	},
	{
		name: 'T12.3 counters that were never readable start the series at the first reading',
		run: 'series',
		baseline: { tx: null, rx: null, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(700, 800) ],
		expect: { day: D1, tx: 700, rx: 800, observed: 30, healthy: 30, last_tx: 700, last_rx: 800, days: {} }
	},
	{
		name: 'T12.3 elapsed is capped at the sample cap',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(1500, 2600, { elapsed: 1000 }) ],
		expect: { day: D1, tx: 500, rx: 600, observed: 60, healthy: 60, last_tx: 1500, last_rx: 2600, days: {} }
	},
	{
		name: 'T12.3 a negative elapsed writes zero seconds',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(1500, 2600, { elapsed: -50 }) ],
		expect: { day: D1, tx: 500, rx: 600, observed: 0, healthy: 0, last_tx: 1500, last_rx: 2600, days: {} }
	},
	{
		name: 'T12.3 observed needs the service to be in an observed state',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(1500, 2600, { state: STARTING, proxy_ok: null }) ],
		expect: { day: D1, tx: 500, rx: 600, observed: 0, healthy: 0, last_tx: 1500, last_rx: 2600, days: {} }
	},
	{
		name: 'T12.3 degraded and failsafe days observe but stay unhealthy',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [
			day1(1500, 2600, { state: DEGRADED }),
			day1(1800, 2900, { state: FAILSAFE })
		],
		expect: { day: D1, tx: 800, rx: 900, observed: 60, healthy: 0, last_tx: 1800, last_rx: 2900, days: {} }
	},
	{
		name: 'T12.3 healthy needs the probe verdict, not just the running state',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [
			day1(1500, 2600, { proxy_ok: false }),
			day1(1800, 2900, { proxy_ok: null })
		],
		expect: { day: D1, tx: 800, rx: 900, observed: 60, healthy: 0, last_tx: 1800, last_rx: 2900, days: {} }
	},
	{
		name: 'T12.3 healthy cannot outrun observed when counters fail in a later round',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ day1(null, null, { proxy_ok: true }) ],
		expect: { day: D1, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 1000, last_rx: 2000, days: {} }
	},
	{
		name: 'T12.3 crossing the local date finalizes the old day with its pending delta',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [
			day1(1500, 2600),
			{ tx: 2600, rx: 3000, now: NOON2, elapsed: 30, cap: CAP, state: RUNNING, proxy_ok: true }
		],
		expect: { day: D2, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 2600, last_rx: 3000,
			days: { [D1]: { tx: 1600, rx: 1000, observed: 60, healthy: 60 } } }
	},
	{
		name: 'T12.3 crossing with unreadable counters still finalizes the old day',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [
			day1(1500, 2600),
			{ tx: null, rx: null, now: NOON2, elapsed: 30, cap: CAP, state: RUNNING, proxy_ok: true }
		],
		expect: { day: D2, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 1500, last_rx: 2600,
			days: { [D1]: { tx: 500, rx: 600, observed: 30, healthy: 30 } } }
	},
	{
		name: 'T12.3 a multi-day forward jump starts the new day without backfilling',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ { tx: 2600, rx: 3000, now: NOON3, elapsed: 1000, cap: CAP, state: RUNNING, proxy_ok: true } ],
		expect: { day: D3, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 2600, last_rx: 3000,
			days: { [D1]: { tx: 1600, rx: 1000, observed: 60, healthy: 60 } } }
	},
	{
		name: 'T12.3 a rolled-back clock keeps the live day and writes no negative seconds',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [
			day1(1500, 2600),
			{ tx: 2600, rx: 3000, now: NOON2, elapsed: 30, cap: CAP, state: RUNNING, proxy_ok: true },
			{ tx: 3000, rx: 3400, now: NOON1 + 60, elapsed: -50, cap: CAP, state: RUNNING, proxy_ok: true }
		],
		expect: { day: D2, tx: 400, rx: 400, observed: 0, healthy: 0, last_tx: 3000, last_rx: 3400,
			days: { [D1]: { tx: 1600, rx: 1000, observed: 60, healthy: 60 } } }
	},
	{
		name: 'T12.3 an invalid wall clock sample is ignored entirely',
		run: 'series',
		baseline: { tx: 1000, rx: 2000, now: NOON1, elapsed: 0, cap: CAP, state: RUNNING, proxy_ok: true },
		samples: [ { tx: 1500, rx: 2600, now: null, elapsed: 30, cap: CAP, state: RUNNING, proxy_ok: true } ],
		expect: { day: D1, tx: 0, rx: 0, observed: 0, healthy: 0, last_tx: 1000, last_rx: 2000, days: {} }
	},
	{
		name: 'T12.3 the in-memory window keeps only the last 89 completed dates',
		run: 'trim',
		expect: { completed: 89, today: 95, first_kept: 6 }
	}
];

export function run(c) {
	if (c.run == 'one')
		return one(c.input);
	if (c.run == 'series')
		return series(c);
	if (c.run == 'trim') {
		let s = usage.create();
		let dates = [];
		for (let i = 1; i <= c.expect.today; i++) {
			let now = timelocal({ year: 2026, mon: 9, mday: i, hour: 12, min: 0, sec: 0 });
			let tm = localtime(now);
			push(dates, sprintf('%04d-%02d-%02d', tm.year, tm.mon + 1, tm.mday));
			usage.sample(s, { tx: i * 100, rx: i * 100, now, elapsed: 0, cap: CAP,
				state: 'stopped', proxy_ok: null });
		}
		let kept = sort(keys(s.days));
		return {
			completed: length(kept),
			today: s.day == dates[c.expect.today - 1] ? c.expect.today : -1,
			first_kept: s.days[dates[c.expect.today - 2]] != null && s.days[dates[0]] == null
				? index(dates, kept[0]) + 1 : -1
		};
	}
	die('unknown usage test kind');
};
