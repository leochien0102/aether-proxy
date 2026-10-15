'use strict';

import * as schedule from 'aetherproxy.schedule';

const STARTED = 1000;
const SUBS = { s_00000001: { enabled: true, interval_hours: 1 } };

export const cases = [
	{
		name: 'not due before the interval boundary',
		subs: SUBS, status: { s_00000001: { last_attempt: STARTED } }, jitter: { s_00000001: 0 },
		now: STARTED + 3599, started_at: 0,
		expect: null
	},
	{
		name: 'exactly due at the interval boundary',
		subs: SUBS, status: { s_00000001: { last_attempt: STARTED } }, jitter: { s_00000001: 0 },
		now: STARTED + 3600, started_at: 0,
		expect: 's_00000001'
	},
	{
		name: 'zero interval is disabled for automatic scheduling',
		subs: { s_00000001: { enabled: true, interval_hours: 0 } }, status: {},
		jitter: { s_00000001: 0 }, now: STARTED + 999999, started_at: 0,
		expect: null
	},
	{
		name: 'disabled subscription is never due',
		subs: { s_00000001: { enabled: false, interval_hours: 1 } }, status: {},
		jitter: { s_00000001: 0 }, now: STARTED + 999999, started_at: 0,
		expect: null
	},
	{
		name: 'never-updated subscription uses daemon start time',
		subs: SUBS, status: {}, jitter: { s_00000001: 0 },
		now: STARTED + 3599, started_at: STARTED,
		expect: null
	},
	{
		name: 'never-updated subscription becomes due from daemon start time',
		subs: SUBS, status: {}, jitter: { s_00000001: 0 },
		now: STARTED + 3600, started_at: STARTED,
		expect: 's_00000001'
	},
	{
		name: 'simultaneous due subscriptions choose the lexically first name',
		subs: {
			s_00000002: { enabled: true, interval_hours: 1 },
			s_00000001: { enabled: true, interval_hours: 1 }
		},
		status: { s_00000001: { last_attempt: STARTED }, s_00000002: { last_attempt: STARTED } },
		jitter: { s_00000001: 0, s_00000002: 0 }, now: STARTED + 3600, started_at: 0,
		expect: 's_00000001'
	},
	{
		name: 'jitter delays the due boundary',
		subs: SUBS, status: { s_00000001: { last_attempt: STARTED } }, jitter: { s_00000001: 0.05 },
		now: STARTED + 3779, started_at: 0,
		expect: null
	},
	{
		name: 'jitter-adjusted boundary is inclusive',
		subs: SUBS, status: { s_00000001: { last_attempt: STARTED } }, jitter: { s_00000001: 0.05 },
		now: STARTED + 3780, started_at: 0,
		expect: 's_00000001'
	},
	{
		name: 'malformed status entry is timed from daemon start, not skipped forever',
		subs: SUBS, status: { s_00000001: 'garbage' }, jitter: { s_00000001: 0 },
		now: STARTED + 3600, started_at: STARTED,
		expect: 's_00000001'
	},
	{
		name: 'malformed last_attempt is timed from daemon start',
		subs: SUBS, status: { s_00000001: { last_attempt: 'yesterday' } }, jitter: { s_00000001: 0 },
		now: STARTED + 3600, started_at: STARTED,
		expect: 's_00000001'
	}
];

export function run(c) {
	return schedule.due(c.subs, c.status, c.jitter, c.now, c.started_at);
};
