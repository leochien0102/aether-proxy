'use strict';

// T12.3 B25: the pure daily aggregation in usage.uc (docs/b25-heatmap.md §4).
// Fake clock: `now` values are built with timelocal, so the local dates are host-TZ
// deterministic and never sit near a DST transition. ucode's timelocal/localtime use
// 1-based month numbers (mon: 10 is October), matching local_date() in usage.uc.
// Fake nft: tx/rx are plain numbers, mirroring what aetherproxy.counters hands over
// from a real `nft -j list counters`.
//
// T12.4 adds the persistence half (docs/b25-heatmap.md §3/§5): load/collect/write are
// exercised against real files in a per-process scratch dir (state_read.uc's pattern),
// so permission and rename semantics are the host's own.

import * as fs from 'fs';
import * as usage from 'aetherproxy.usage';

const D1 = '2026-10-21';
const D2 = '2026-10-22';
const D3 = '2026-10-23';
const NOON1 = timelocal({ year: 2026, mon: 10, mday: 21, hour: 12, min: 0, sec: 0 });
const NOON2 = timelocal({ year: 2026, mon: 10, mday: 22, hour: 12, min: 0, sec: 0 });
const NOON3 = timelocal({ year: 2026, mon: 10, mday: 23, hour: 12, min: 0, sec: 0 });
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

// Scratch file helpers for the T12.4 persistence cases. Every case owns a file name
// and (re)creates it, so the cases stay order-independent despite the shared dir.
const SCRATCH = `/tmp/aether-proxy-test-usage.${fs.readlink('/proc/self')}`;

function scratch(name, content) {
	fs.mkdir(SCRATCH);
	let path = `${SCRATCH}/${name}`;
	if (content == null)
		fs.unlink(path);
	else
		fs.writefile(path, content);
	return path;
};

// A local date string built from timelocal's mday overflow (the T12.3 trim test's
// approach): noon timestamps, so the round-trip date label is DST-safe.
function date_of_mday(i) {
	let tm = localtime(timelocal({ year: 2026, mon: 10, mday: i, hour: 12, min: 0, sec: 0 }));
	return sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
};

const T124_CASES = [
	{
		name: 'T12.4 a missing file loads as an empty history without an error',
		run: 'load', file: 'load-missing.json', content: null,
		expect: { days: {}, error: false, op: 'read', updated_at: null }
	},
	{
		name: 'T12.4 a corrupt file loads as an empty history and is left untouched',
		run: 'load-kept', file: 'load-corrupt.json', content: '{not json',
		expect: { days: {}, error: true, op: 'parse', updated_at: null, kept: true }
	},
	{
		name: 'T12.4 a JSON value that is not an object loads as an empty history',
		run: 'load', file: 'load-array.json', content: '[1,2]',
		expect: { days: {}, error: true, op: 'parse', updated_at: null }
	},
	{
		name: 'T12.4 a days table that is not an object loads as an empty history',
		run: 'load', file: 'load-days-array.json', content: '{"schema":1,"days":[]}',
		expect: { days: {}, error: true, op: 'parse', updated_at: null }
	},
	{
		name: 'T12.4 kept entries preserve their unknown fields across a load',
		run: 'load', file: 'load-valid.json',
		content: '{"schema":1,"updated_at":1790000000,"days":{"2026-10-21":{"tx":1,"rx":2,"observed":10,"healthy":9,"note":"x"}}}',
		expect: { days: { '2026-10-21': { tx: 1, rx: 2, observed: 10, healthy: 9, note: 'x' } },
			error: false, op: 'parse', updated_at: 1790000000 }
	},
	{
		name: 'T12.5 a non-numeric updated_at loads as null, days still kept',
		run: 'load', file: 'load-updated-str.json',
		content: '{"schema":1,"updated_at":"1790000000","days":{"2026-10-21":{"tx":1,"rx":2,"observed":10,"healthy":9}}}',
		expect: { days: { '2026-10-21': { tx: 1, rx: 2, observed: 10, healthy: 9 } },
			error: false, op: 'parse', updated_at: null }
	},
	{
		name: 'T12.5 a negative updated_at loads as null',
		run: 'load', file: 'load-updated-negative.json',
		content: '{"updated_at":-1,"days":{"2026-10-21":{"tx":1,"rx":2,"observed":10,"healthy":9}}}',
		expect: { days: { '2026-10-21': { tx: 1, rx: 2, observed: 10, healthy: 9 } },
			error: false, op: 'parse', updated_at: null }
	},
	{
		name: 'T12.4 a healthy share above observed is clamped back on load',
		run: 'load', file: 'load-clamp.json',
		content: '{"days":{"2026-10-21":{"tx":1,"rx":2,"observed":10,"healthy":20}}}',
		expect: { days: { '2026-10-21': { tx: 1, rx: 2, observed: 10, healthy: 10 } },
			error: false, op: 'parse', updated_at: null }
	},
	{
		name: 'T12.4 malformed and non-date entries are ignored, valid neighbours kept',
		run: 'load', file: 'load-junk.json',
		content: '{"days":{"2026-10-21":{"tx":1,"rx":2,"observed":3,"healthy":2},' +
			'"2026-10-22":{"tx":-1,"rx":2,"observed":3,"healthy":2},' +
			'"2026-10-23":{"tx":1,"rx":2,"observed":3},' +
			'"2026-10-24":"junk",' +
			'"not-a-date":{"tx":1,"rx":2,"observed":3,"healthy":2}}}',
		expect: { days: { '2026-10-21': { tx: 1, rx: 2, observed: 3, healthy: 2 } },
			error: false, op: 'parse', updated_at: null }
	},
	{
		name: 'T12.4 a successful write leaves a 0600 document without temp residue',
		run: 'write', file: 'write-ok.json',
		days: { '2026-10-21': { tx: 1, rx: 2, observed: 3, healthy: 4 } }, now: 1790000000,
		expect: { ok: true, mode_0600: true, residue: 0,
			document: { schema: 1, updated_at: 1790000000,
				days: { '2026-10-21': { tx: 1, rx: 2, observed: 3, healthy: 4 } } } }
	},
	{
		name: 'T12.4 a failed write reports the reason and a retry succeeds',
		run: 'write-retry',
		expect: { first_error: true, second_ok: true }
	},
	{
		name: 'T12.4 collect merges completed days and the live day over the previous map',
		run: 'collect',
		previous: { '2026-10-20': { tx: 9, rx: 9, observed: 9, healthy: 9 },
			'2026-10-21': { tx: 1, rx: 1, observed: 1, healthy: 1 } },
		state: { day: '2026-10-22', tx: 5, rx: 6, observed: 7, healthy: 8,
			days: { '2026-10-21': { tx: 2, rx: 3, observed: 4, healthy: 4 } } },
		expect: { '2026-10-20': { tx: 9, rx: 9, observed: 9, healthy: 9 },
			'2026-10-21': { tx: 2, rx: 3, observed: 4, healthy: 4 },
			'2026-10-22': { tx: 5, rx: 6, observed: 7, healthy: 8 } }
	},
	{
		name: 'T12.4 collect rewrites the live day over a stale copy and drops future dates',
		run: 'collect',
		previous: { '2026-10-22': { tx: 1, rx: 1, observed: 1, healthy: 1 },
			'2026-10-24': { tx: 9, rx: 9, observed: 9, healthy: 9 } },
		state: { day: '2026-10-22', tx: 0, rx: 0, observed: 0, healthy: 0, days: {} },
		expect: { '2026-10-22': { tx: 0, rx: 0, observed: 0, healthy: 0 } }
	},
	{
		name: 'T12.4 collect reports nothing to persist while the sampler has no live day',
		run: 'collect',
		previous: { '2026-10-21': { tx: 1, rx: 2, observed: 3, healthy: 4 } },
		state: { day: null, tx: 0, rx: 0, observed: 0, healthy: 0, days: {} },
		expect: null
	},
	{
		name: 'T12.4 collect keeps the last 90 dates by local-date string order',
		run: 'trim-collect',
		expect: { kept: 90, first_kept: true, last_kept: true }
	}
];

export const cases = [ ...T124_CASES,
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
			let now = timelocal({ year: 2026, mon: 10, mday: i, hour: 12, min: 0, sec: 0 });
			let tm = localtime(now);
			push(dates, sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday));
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
	if (c.run == 'load' || c.run == 'load-kept') {
		let path = scratch(c.file, c.content);
		let got = usage.load(path);
		let out = { days: got.days, error: got.error != null, op: got.op, updated_at: got.updated_at };
		if (c.run == 'load-kept')
			out.kept = fs.readfile(path) == c.content;
		return out;
	}
	if (c.run == 'write') {
		let path = scratch(c.file, null);
		let got = usage.write(path, c.days, c.now);
		let st = fs.stat(path);
		return {
			ok: got.ok == true && got.error == null,
			mode_0600: st != null && (st.mode & 511) == 384,
			residue: length(fs.glob(`${SCRATCH}/${c.file}.tmp.*`) ?? []),
			document: st == null ? null : json(fs.readfile(path))
		};
	}
	if (c.run == 'write-retry') {
		let blocked = `${SCRATCH}/blocked`;
		fs.mkdir(SCRATCH);
		fs.unlink(blocked);
		fs.writefile(blocked, 'not a directory');
		let first = usage.write(`${blocked}/usage.json`, {}, 1790000000);
		fs.unlink(blocked);
		let second = usage.write(`${blocked}/usage.json`, {}, 1790000000);
		fs.unlink(`${blocked}/usage.json`);
		fs.rmdir(blocked);
		return { first_error: first.ok == false && first.error != null, second_ok: second.ok == true };
	}
	if (c.run == 'collect')
		return usage.collect(c.state, c.previous);
	if (c.run == 'trim-collect') {
		let previous = {};
		for (let i = 1; i <= 95; i++)
			previous[date_of_mday(i)] = { tx: i, rx: i, observed: 1, healthy: 1 };
		let collected = usage.collect(
			{ day: date_of_mday(96), tx: 0, rx: 0, observed: 0, healthy: 0, days: {} }, previous);
		let kept = sort(keys(collected));
		return { kept: length(kept), first_kept: kept[0] == date_of_mday(7),
			last_kept: kept[89] == date_of_mday(96) };
	}
	die('unknown usage test kind');
};
