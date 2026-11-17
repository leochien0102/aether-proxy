'use strict';

// Pure time filtering for T16.9 (docs/tasks/m16.md, docs/09 logging).
// The caller supplies the clock so year rollover is deterministic in tests.
const MONTHS = [ 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' ];

export function valid_epoch(value) {
	return (type(value) == 'int' || type(value) == 'double') && value >= 0 && value < 9007199254740992;
};

function event_time(line) {
	let event;
	try { event = json(line); }
	catch (e) { return null; } // Malformed records are explicitly discarded by the contract.
	return type(event) == 'object' && valid_epoch(event.ts) ? event.ts : null;
}

export function raw_time(line, now) {
	// Accept both the contract's short envelope and logread's weekday/year envelope.
	let envelope = replace(line, /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) /, '');
	let m = match(envelope,
		/^([A-Z][a-z]{2}) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) /);
	if (m == null)
		return null;
	let month = index(MONTHS, m[1]) + 1;
	if (!month || +m[2] < 1 || +m[2] > 31 || +m[3] > 23 || +m[4] > 59 || +m[5] > 59)
		return null;
	let year = localtime(now).year;
	let fields = { year, mon: month, mday: +m[2], hour: +m[3], min: +m[4], sec: +m[5], isdst: -1 };
	let stamp = timelocal(fields);
	if (stamp > now + 86400) {
		fields.year--;
		stamp = timelocal(fields);
	}
	// timelocal normalizes impossible dates; do not keep those as valid log records.
	let tm = localtime(stamp);
	return tm.mon == month && tm.mday == +m[2] && tm.hour == +m[3]
		&& tm.min == +m[4] && tm.sec == +m[5] ? stamp : null;
};

export function filter_text(text, kind, since, now) {
	let lines = split(text, '\n');
	// A final newline terminates the last record, not an extra malformed record.
	if (lines[-1] == '')
		pop(lines);
	let result = { text: '', kept: 0, dropped: 0 };
	for (let line in lines) {
		let ts = kind == 'events' ? event_time(line) : raw_time(line, now);
		if (ts != null && ts >= since) {
			result.text += line + '\n';
			result.kept++;
		}
		else {
			result.dropped++;
		}
	}
	return result;
};
