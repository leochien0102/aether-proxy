'use strict';
'require baseclass';

/* Shared display grades for Overview real latency and node TCP probes.
 * Callers handle failed probes separately: an absent/invalid time is unknown,
 * not a successful zero-millisecond result. */
function level(ms) {
	if (typeof ms != 'number' || !Number.isFinite(ms) || ms < 0)
		return 'neutral';
	return ms <= 200 ? 'ok' : ms <= 800 ? 'warn' : 'error';
}

return baseclass.extend({ level });
