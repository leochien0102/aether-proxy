'use strict';

// B25 usage heatmap (docs/b25-heatmap.md): per-day accounting (§4, T12.3) plus its file
// persistence (§3/§5, T12.4) and quota (docs/design/b25-quota-heatmap-20261116.md §2–§3).
// The aggregation half stays pure — no clock access: the
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
export function local_date(now) {
	let tm = localtime(now);
	return type(tm) != 'object' ? null
		: sprintf('%04d-%02d-%02d', tm.year, tm.mon, tm.mday);
};

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
	// A seeded day already exists, but its first readable nft sample is still baseline-only.
	let accumulate = readable && state.seed_pending !== true;
	let counted = index(OBSERVED_STATES, s.state) >= 0 && accumulate;
	let observed = counted ? elapsed : 0;
	let healthy = counted && s.state == 'running' && s.proxy_ok === true ? elapsed : 0;

	if (crossed_day) {
		// Finalize the old day first, including the bytes since its last sample
		// (docs §4.5); the new day starts from the current counters.
		state.days[state.day] = {
			tx: state.tx + (accumulate ? delta(s.tx, state.last_tx) : 0),
			rx: state.rx + (accumulate ? delta(s.rx, state.last_rx) : 0),
			observed: state.observed + observed,
			healthy: min(state.healthy + healthy, state.observed + observed)
		};
		trim_days(state.days);
		state.tx = 0; state.rx = 0; state.observed = 0; state.healthy = 0;
	}
	else if (state.day != null) {
		if (accumulate) {
			state.tx += delta(s.tx, state.last_tx);
			state.rx += delta(s.rx, state.last_rx);
		}
		state.observed += observed;
		state.healthy = min(state.healthy + healthy, state.observed);
	}

	if (readable) {
		state.last_tx = s.tx;
		state.last_rx = s.rx;
		if (state.seed_pending === true)
			delete state.seed_pending;
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

// Merge already validated totals; neither source is an increment to the other.
export function max_day(a, b) {
	return {
		tx: max(a?.tx ?? 0, b?.tx ?? 0),
		rx: max(a?.rx ?? 0, b?.rx ?? 0),
		observed: max(a?.observed ?? 0, b?.observed ?? 0),
		healthy: max(a?.healthy ?? 0, b?.healthy ?? 0)
	};
};

// Restore today's totals without changing the input or the nft baselines.
// The optional live entry must have passed state.usage_today_of().
export function seed(state, entry, day, now, live) {
	if (day == null || day !== local_date(now))
		return null;
	let disk = valid_entry(entry) ? entry : null;
	live = live?.date === day && valid_entry(live) ? live : null;
	if (disk == null && live == null)
		return null;
	return { ...state, ...max_day(disk, live), day, seed_pending: true };
};

// T16.2: normalize absent or unusable quota without rejecting an older history file.
export function quota_of(data) {
	let quota = data?.quota;
	if (type(quota) != 'object' || type(quota.bytes) != 'int' ||
		quota.bytes < C.QUOTA_MIN_BYTES || quota.bytes > C.QUOTA_MAX_BYTES)
		return { bytes: null, set_at: null };
	return { bytes: quota.bytes, set_at: type(quota.set_at) == 'int' && quota.set_at >= 0 ? quota.set_at : null };
};

// Decimal units only; bound the digits before conversion to prevent integer overflow.
export function parse_quota(raw) {
	let parts = type(raw) == 'string' ? match(raw, /^([0-9]+)(G|GB|T|TB)?$/) : null;
	if (parts == null)
		return null;
	let digits = replace(parts[1], /^0+/, '');
	if (length(digits) > length(`${C.QUOTA_MAX_BYTES}`))
		return null;
	let value = +digits;
	let scale = parts[2] == 'G' || parts[2] == 'GB' ? C.QUOTA_GB
		: parts[2] == 'T' || parts[2] == 'TB' ? C.QUOTA_TB : 1;
	if (value < C.QUOTA_MIN_BYTES / scale || value > C.QUOTA_MAX_BYTES / scale)
		return null;
	return value * scale;
};

// load(path) -> { days, error, op, updated_at, document? }. The raw valid document
// is retained for quota/unknown-field-preserving writes (T16.2). A missing file is an empty history
// without an error. A corrupt or unreadable file is an empty history plus the failure
// detail — writers leave it in place until the read failure is resolved. Entries
// without four non-negative numbers, or under a
// non-date key, are ignored; unknown fields of a kept entry are preserved, and a
// healthy share above observed is clamped back into range. `updated_at` (T12.5, read
// only) is the document's wall-clock write time as a non-negative number, and null
// whenever no valid document was read — a missing, corrupt or malformed file has no
// history snapshot time to report.
export function load(path) {
	let text = fs.readfile(path);
	if (text == null) {
		let detail = fs.error() ?? 'unknown error';
		return detail == 'No such file or directory'
			? { days: {}, error: null, op: 'read', updated_at: null }
			: { days: {}, error: `read ${path}: ${detail}`, op: 'read', updated_at: null };
	}
	let data = null;
	try {
		data = json(text);	// throws on bad input
	}
	catch (e) {
		data = null;
	}
	if (type(data) != 'object' || type(data.days) != 'object')
		return { days: {}, error: `parse ${path}: expected a JSON object with a days table`,
			op: 'parse', updated_at: null };
	let days = {};
	for (let date, entry in data.days)
		if (match(date, DATE_PATTERN) && valid_entry(entry))
			days[date] = { ...entry, healthy: min(entry.healthy, entry.observed) };
	return { document: data, days, error: null, op: 'parse',
		updated_at: numeric(data.updated_at) ? data.updated_at : null };
};

// collect(state, previous) -> the day map to persist, or null while the sampler never
// held a live day (this run has nothing to add, so the file is left alone). This run's
// completed days merge monotonically with the previous map for their date.
// The live day is written
// even when empty (docs §3), but cannot shrink an already persisted total.
// Dates after the live day (a clock that jumped forward
// and back) are dropped rather than rewritten, and the map keeps the last
// USAGE_DAYS_KEEP dates by plain local-date string order (docs §5).
export function collect(state, previous) {
	if (state?.day == null)
		return null;
	let days = { ...(previous ?? {}) };
	for (let date, entry in state.days)
		if (valid_entry(entry))
			days[date] = { ...entry, ...max_day(entry, valid_entry(previous?.[date]) ? previous[date] : null) };
	for (let date in days)
		if (date > state.day)
			delete days[date];
	let prior = previous?.[state.day];
	days[state.day] = max_day(state, valid_entry(prior) ? prior : null);
	let dates = sort(keys(days));
	while (length(dates) > C.USAGE_DAYS_KEEP)
		delete days[shift(dates)];
	return days;
};

// One JSON document renamed atomically into
// place with mode 0600 (sys.write_atomic), so a reader or a crash never sees a partial
// file (docs §3). The success return is the write verification; on failure any previous
// file is left untouched and the reason is reported to the caller.
function write_document(path, document) {
	let parent = substr(path, 0, rindex(path, '/'));
	if (parent != '' && !sys.mkdir_p(parent))
		return { ok: false, error: `mkdir ${parent}: ${sys.error() ?? 'unknown error'}` };
	if (!sys.write_atomic(path, sprintf('%.J', document) + '\n'))
		return { ok: false, error: sys.error() ?? 'unknown error' };
	return { ok: true, error: null };
};

// All writers share a stable sidecar, never the inode replaced by rename. Lock
// acquisition is non-blocking (bounded wait of zero); callers retain pending data
// and retry on the next flush/command. Never unlink this lock file.
function transaction(path, merge) {
	let held = sys.lock(`${path}.lock`);
	if (held == null)
		return { ok: false, error: sys.error() ?? 'usage lock failed', op: 'lock',
			retryable: sys.lock_contended() };
	let result;
	try {
		let loaded = load(path);
		if (loaded.error != null)
			result = { ok: false, error: loaded.error, op: loaded.op, loaded };
		else {
			let document = merge(loaded);
			result = document == null ? { ok: true, error: null }
				: { ...write_document(path, document), days: document.days };
			result.loaded = loaded;
		}
	}
	catch (e) {
		result = { ok: false, error: `${e}`, op: 'write' };
	}
	held.close();
	return result;
};

// Low-level day-map writer: even legacy callers cannot supply a stale quota
// document. The optional fourth argument is intentionally no longer trusted.
export function write(path, days, now, document) {
	return transaction(path, loaded => ({ schema: 1, ...(loaded.document ?? {}),
		updated_at: now, days }));
};

// The monitor's entire read/merge/replace transaction lives here, not in its
// caller. Both persisted and cached totals are floors, independently per field.
export function flush(path, state, previous, now) {
	if (state?.day == null)
		return { ok: true, error: null };
	return transaction(path, loaded => {
		let floors = { ...loaded.days };
		for (let date, entry in (previous ?? {}))
			if (valid_entry(entry))
				floors[date] = { ...entry, ...max_day(entry, floors[date]) };
		let days = collect(state, floors);
		return { schema: 1, ...(loaded.document ?? {}), updated_at: now, days };
	});
};

// Quota changes do not touch history or its update timestamp and never reload UCI.
export function set_quota(path, bytes, now) {
	let quota = { bytes, set_at: bytes == null ? null : now };
	let result = transaction(path, loaded => ({ schema: 1, days: {},
		...(loaded.document ?? {}), quota }));
	return { ...result, quota };
};
