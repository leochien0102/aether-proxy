'use strict';

// B25 usage heatmap (docs/b25-heatmap.md): per-day accounting (§4, T12.3) plus its file
// persistence (§3/§5, T12.4). The aggregation half stays pure — no clock access: the
// monitor passes counters, wall time and the monotonic elapsed; a completed day moves
// into `days` in memory. The persistence half owns the usage.json format, validation
// and the atomic 0600 rewrite; the monitor decides when to call it (a crossed local
// date, a clean daemon stop) and how failures are logged.

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';

// A day counts toward `observed` only while the service is supposed to intercept traffic
// and the round could read the proxy counters (docs/b25-heatmap.md §4.6).
const OBSERVED_STATES = [ 'running', 'degraded', 'failsafe' ];

// ucode's localtime() deviates from the C struct tm: `mon`, `wday` and `yday` are
// already 1-based, so `mon` is the calendar month number as-is. Adding 1 shifted every
// label a month ahead (found in T12.4, 2026-11-01: the host build returns mon: 11 for
// November), hidden so long as producers and consumers shifted consistently.
function local_date(now) {
	let tm = localtime(now);
	return type(tm) != 'object' ? null
		: sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
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

// ---- Persistence (docs/b25-heatmap.md §3/§5, T12.4) ----

const DATE_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

function numeric(value) {
	return (type(value) == 'int' || type(value) == 'double') && value >= 0;
};

function valid_entry(entry) {
	return type(entry) == 'object' && numeric(entry.tx) && numeric(entry.rx) &&
		numeric(entry.observed) && numeric(entry.healthy);
};

// load(path) -> { days, error, op }. A missing file is an empty history without an
// error. A corrupt or unreadable file is an empty history plus the failure detail —
// the caller warns once and leaves the file in place for the next successful write to
// overwrite it (docs §5). Entries without four non-negative numbers, or under a
// non-date key, are ignored; unknown fields of a kept entry are preserved, and a
// healthy share above observed is clamped back into range.
export function load(path) {
	let text = fs.readfile(path);
	if (text == null) {
		let detail = fs.error() ?? 'unknown error';
		return detail == 'No such file or directory'
			? { days: {}, error: null, op: 'read' }
			: { days: {}, error: `read ${path}: ${detail}`, op: 'read' };
	}
	let data = null;
	try {
		data = json(text);	// throws on bad input
	}
	catch (e) {
		data = null;
	}
	if (type(data) != 'object' || type(data.days) != 'object')
		return { days: {}, error: `parse ${path}: expected a JSON object with a days table`, op: 'parse' };
	let days = {};
	for (let date, entry in data.days)
		if (match(date, DATE_PATTERN) && valid_entry(entry))
			days[date] = { ...entry, healthy: min(entry.healthy, entry.observed) };
	return { days, error: null, op: 'parse' };
};

// collect(state, previous) -> the day map to persist, or null while the sampler never
// held a live day (this run has nothing to add, so the file is left alone). This run's
// completed days and the live day — written even when empty (docs §3) — override the
// previous map for their date. Dates after the live day (a clock that jumped forward
// and back) are dropped rather than rewritten, and the map keeps the last
// USAGE_DAYS_KEEP dates by plain local-date string order (docs §5).
export function collect(state, previous) {
	if (state?.day == null)
		return null;
	let days = { ...(previous ?? {}) };
	for (let date, entry in state.days)
		if (valid_entry(entry))
			days[date] = { ...entry };
	for (let date in days)
		if (date > state.day)
			delete days[date];
	days[state.day] = { tx: state.tx, rx: state.rx, observed: state.observed, healthy: state.healthy };
	let dates = sort(keys(days));
	while (length(dates) > C.USAGE_DAYS_KEEP)
		delete days[shift(dates)];
	return days;
};

// write(path, days, now) -> { ok, error }. One JSON document renamed atomically into
// place with mode 0600 (sys.write_atomic), so a reader or a crash never sees a partial
// file (docs §3). The success return is the write verification; on failure any previous
// file is left untouched and the reason is reported to the caller.
export function write(path, days, now) {
	let parent = substr(path, 0, rindex(path, '/'));
	if (parent != '' && !sys.mkdir_p(parent))
		return { ok: false, error: `mkdir ${parent}: ${sys.error() ?? 'unknown error'}` };
	if (!sys.write_atomic(path, sprintf('%.J', { schema: 1, updated_at: now, days }) + '\n'))
		return { ok: false, error: sys.error() ?? 'unknown error' };
	return { ok: true, error: null };
};
