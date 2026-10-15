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

		let base = started_at;
		let previous = status[name];
		if (previous != null) {
			if (type(previous) != 'object') {
				// TODO(design): invalid per-subscription status has no defined fallback; skip this entry.
				continue;
			}
			if (previous.last_attempt != null) {
				if (!number(previous.last_attempt))
					continue;
				base = previous.last_attempt;
			}
		}

		// TODO(design): malformed last_attempt has no documented recovery; skip rather than retry early.
		let due_at = base + sub.interval_hours * C.SCHEDULE_HOUR_SECS * (1 + fraction);
		if (now >= due_at)
			return name;
	}
	return null;
};
