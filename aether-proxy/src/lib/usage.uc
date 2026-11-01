'use strict';

// B25 usage heatmap aggregation (docs/b25-heatmap.md §4, T12.3): pure per-day accounting.
// No I/O and no clock access: the monitor passes counters, wall time and the monotonic
// elapsed; this module only decides how they accumulate. A completed day moves into
// `days` in memory; persistence is T12.4, so nothing here touches the filesystem.

import * as C from 'aetherproxy.const';

// A day counts toward `observed` only while the service is supposed to intercept traffic
// and the round could read the proxy counters (docs/b25-heatmap.md §4.6).
const OBSERVED_STATES = [ 'running', 'degraded', 'failsafe' ];

function local_date(now) {
	let tm = localtime(now);
	return type(tm) != 'object' ? null
		: sprintf('%04d-%02d-%02d', tm.year, tm.mon + 1, tm.mday);
}

// The heatmap credits at most the current monitor cadence doubled (docs §4.3): a sleep,
// a skipped round or a restart gap must not pour minutes of unobserved time into one day.
// A negative elapsed cannot happen from the monotonic source but is clamped all the same.
function clamped_elapsed(elapsed, cap) {
	let value = (type(elapsed) == 'int' || type(elapsed) == 'double') ? max(elapsed, 0) : 0;
	return (type(cap) == 'int' || type(cap) == 'double') ? min(value, cap) : value;
}

function delta(current, previous) {
	// A counter below its previous value means the table was rebuilt (docs §4.4): count
	// the post-reset value instead of a negative delta. `previous == null` means the
	// baseline never held a readable reading, so the current value is the whole series.
	return previous == null ? current : (current >= previous ? current - previous : current);
}

function trim_days(days) {
	// Keep the same 90-date window the persisted history will use (docs §3): the live day
	// lives outside `days`, so only the last 89 completed dates stay in memory.
	let keep = C.USAGE_DAYS_KEEP - 1;
	let dates = sort(keys(days));
	while (length(dates) > keep)
		delete days[shift(dates)];
};

// create() -> state. `day` is the local date of the live accumulators; the previous
// sample's counter readings (`last_tx`/`last_rx`) are the baseline the next sample
// computes its deltas against.
export function create() {
	return { day: null, tx: 0, rx: 0, observed: 0, healthy: 0,
		last_tx: null, last_rx: null, days: {} };
};

// sample(state, s) mutates and returns state. `s`:
//   tx/rx      current proxy counter bytes, or null when this round could not read them;
//   now        wall clock seconds of this sample;
//   elapsed    seconds since the previous sample (monotonic; may be fractional);
//   cap        maximum elapsed seconds credited to one sample;
//   state      service state string ('running'/'degraded'/...);
//   proxy_ok   this round's HTTP probe verdict (true/false/null).
//
// The first sample only records the baseline (docs §4.4). Unreadable counters skip the
// round's bytes but keep the baseline, so the next good read resumes the series; the day
// and its time accounting still advance.
export function sample(state, s) {
	if ((type(s.now) != 'int' && type(s.now) != 'double') || s.now < 0)
		return state;
	let date = local_date(s.now);

	// The clock cannot create negative accounting: elapsed arrives from the monotonic
	// source, and a rolled-back wall clock (date below the live day) keeps the current
	// day instead of reopening or rewinding an existing entry (docs §8).
	let rolled_back = state.day != null && date < state.day;
	let crossed_day = !rolled_back && state.day != null && date != state.day;
	let readable = s.tx != null && s.rx != null;
	let elapsed = clamped_elapsed(s.elapsed, s.cap);
	let counted = index(OBSERVED_STATES, s.state) >= 0 && readable;
	let observed = counted ? elapsed : 0;
	let healthy = counted && s.state == 'running' && s.proxy_ok === true ? elapsed : 0;

	if (state.day == null) {
		// Baseline only: no bytes and no seconds are attributed to a sample window
		// that started before the sampler existed (docs §4.4).
		if (readable) {
			state.last_tx = s.tx;
			state.last_rx = s.rx;
		}
	}
	else if (crossed_day) {
		// Finalize the old day first, including the bytes since its last sample
		// (docs §4.5); the new day starts from the current counters.
		state.days[state.day] = {
			tx: state.tx + (readable ? delta(s.tx, state.last_tx) : 0),
			rx: state.rx + (readable ? delta(s.rx, state.last_rx) : 0),
			observed: state.observed + observed,
			healthy: min(state.healthy + healthy, state.observed + observed)
		};
		trim_days(state.days);
		state.tx = 0; state.rx = 0; state.observed = 0; state.healthy = 0;
		if (readable) {
			state.last_tx = s.tx;
			state.last_rx = s.rx;
		}
	}
	else {
		if (readable) {
			state.tx += delta(s.tx, state.last_tx);
			state.rx += delta(s.rx, state.last_rx);
			state.last_tx = s.tx;
			state.last_rx = s.rx;
		}
		state.observed += observed;
		state.healthy += healthy;
		state.healthy = min(state.healthy, state.observed);
	}

	if (state.day == null || crossed_day)
		state.day = date;
	return state;
};
