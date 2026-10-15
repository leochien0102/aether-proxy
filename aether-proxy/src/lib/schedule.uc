'use strict';

// Select one due subscription without reading runtime state or performing I/O.

import * as C from 'aetherproxy.const';

function number(value) {
	return type(value) == 'int' || type(value) == 'double';
}

export function due(subs, status, jitter, now, started_at) {
	if (type(subs) != 'object' || type(status) != 'object' || type(jitter) != 'object' ||
	    !number(now) || !number(started_at))
		return null;

	for (let name in sort(keys(subs))) {
		let sub = subs[name];
		if (sub?.enabled != true || !number(sub.interval_hours) || sub.interval_hours <= 0)
			continue;

		let fraction = jitter[name];
		if (!number(fraction) || fraction < 0 || fraction >= C.SCHEDULE_MAX_JITTER)
			continue;

		// A missing or malformed record counts as "never attempted": time it from daemon start
		// rather than leaving the subscription unscheduled forever.
		let base = started_at;
		let previous = status[name];
		if (type(previous) == 'object' && number(previous.last_attempt))
			base = previous.last_attempt;

		let due_at = base + sub.interval_hours * C.SCHEDULE_HOUR_SECS * (1 + fraction);
		if (now >= due_at)
			return name;
	}
	return null;
};
