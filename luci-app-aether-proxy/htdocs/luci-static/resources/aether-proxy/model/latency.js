'use strict';
'require baseclass';

/* Overview real-latency display grades.
 * Callers handle failed probes separately: an absent/invalid time is unknown,
 * not a successful zero-millisecond result. */
function level(ms) {
	if (typeof ms != 'number' || !Number.isFinite(ms) || ms < 0)
		return 'neutral';
	return ms <= 200 ? 'ok' : ms <= 800 ? 'warn' : 'error';
}

/* Node TCP probes use stricter boundaries than Overview real latency. */
function tcp_level(ms) {
	if (typeof ms != 'number' || !Number.isFinite(ms) || ms < 0)
		return 'neutral';
	return ms < 100 ? 'ok' : ms < 200 ? 'warn' : 'error';
}

return baseclass.extend({ level, tcp_level });
