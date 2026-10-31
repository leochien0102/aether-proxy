'use strict';

// Select one due subscription without reading runtime state or performing I/O.

import * as C from 'aetherproxy.const';

function number(value) {
	return type(value) == 'int' || type(value) == 'double';
}

export function last_slot(now, hour, minute, tm) {
	if (!number(now) || !number(hour) || hour < 0 || hour > 23 ||
	    (minute != null && (!number(minute) || minute < 0 || minute > 59)) || type(tm) != 'object')
		return null;
	minute ??= 30;
	// timelocal deliberately uses local wall time; subtracting a calendar day across DST is not modeled.
	let slot = timelocal({ ...tm, sec: 0, min: minute, hour });
	if (slot > now)
		slot = timelocal({ ...tm, sec: 0, min: minute, hour, mday: tm.mday - 1 });
	return slot;
};

export function update_due(cfg, record, slot, started_at) {
	if (type(cfg) != 'object' || !number(slot) || !number(started_at))
		return null;
	let due = name => {
		let base = started_at;
		let entry = type(record) == 'object' ? record[name] : null;
		if (type(entry) == 'object' && number(entry.last_attempt))
			base = entry.last_attempt;
		return base < slot;
	};
	if (cfg.data_auto != false && due('data'))
		return 'data';
	if (due('check'))
		return 'check';
	return null;
};

export function auto_install_due(cfg, updates, record) {
	if (type(cfg) != 'object' || cfg.xray_auto != 'auto' || type(updates) != 'object')
		return null;
	let item = updates.packages?.[C.XRAY_CORE_PACKAGE];
	if (type(item) != 'object' || item.newer != true || type(item.available) != 'string' ||
	    item.available == '' || type(item.asset) != 'string' || item.asset == '')
		return null;
	if (record?.auto_install?.version == item.available)
		return null;
	return item.available;
};

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
