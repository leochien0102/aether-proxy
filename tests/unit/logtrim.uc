'use strict';
// T16.9: injected local clock exercises month/year inference without host date dependence.
import * as trimlog from 'aetherproxy.logtrim';

const JAN = timelocal({ year: 2027, mon: 1, mday: 1, hour: 12, min: 0, sec: 0 });
const NOV = timelocal({ year: 2026, mon: 11, mday: 1, hour: 12, min: 0, sec: 0 });
const DEC = timelocal({ year: 2026, mon: 12, mday: 31, hour: 23, min: 59, sec: 59 });
const OCT = timelocal({ year: 2026, mon: 10, mday: 31, hour: 23, min: 59, sec: 59 });

export const cases = [
	{ name: 'events equality retained, earlier and invalid JSON/timestamps dropped', kind: 'events',
	  text: '{"ts":9}\n{"ts":10}\nbad\n{}\n{"ts":"20"}\n{"ts":null}\n{"ts":11}\n', since: 10,
	  expect: { text: '{"ts":10}\n{"ts":11}\n', kept: 2, dropped: 5 } },
	{ name: 'raw cross-year Dec 31 inferred as previous year', stamp: 'Dec 31 23:59:59 host tag[1]: old',
	  now: JAN, expect: DEC },
	{ name: 'raw cross-month Oct 31 stays in current year', stamp: 'Oct 31 23:59:59 host tag[1]: old',
	  now: NOV, expect: OCT },
	{ name: 'raw real logread weekday/year envelope uses inferred year',
	  stamp: 'Thu Dec 31 23:59:59 2026 daemon.notice aether-proxy[1]: msg', now: JAN, expect: DEC },
	{ name: 'raw bad month rejected', stamp: 'Foo 01 12:00:00 host msg', now: JAN, expect: null },
	{ name: 'raw impossible date rejected', stamp: 'Feb 30 12:00:00 host msg', now: JAN, expect: null },
	{ name: 'raw invalid clock rejected', stamp: 'Jan 01 24:00:00 host msg', now: JAN, expect: null },
	{ name: 'raw malformed line rejected', stamp: 'bad line', now: JAN, expect: null },
	{ name: 'raw whole expired file becomes empty', kind: 'raw',
	  text: 'Dec 31 23:59:59 host msg\nbad\n', since: JAN, now: JAN,
	  expect: { text: '', kept: 0, dropped: 2 } },
	{ name: 'raw equality retained and counts separate from raw1', kind: 'raw',
	  text: 'Jan  1 12:00:00 host msg\nbad\n', since: JAN, now: JAN,
	  expect: { text: 'Jan  1 12:00:00 host msg\n', kept: 1, dropped: 1 } },
	{ name: 'raw1 independently filters its own records', kind: 'raw1',
	  text: 'Dec 31 23:59:59 host msg\nJan  1 12:00:00 host msg\n', since: JAN, now: JAN,
	  expect: { text: 'Jan  1 12:00:00 host msg\n', kept: 1, dropped: 1 } },
	{ name: 'empty file has zero records', kind: 'events', text: '', since: 0,
	  expect: { text: '', kept: 0, dropped: 0 } }
];

export function run(c) {
	return c.stamp != null ? trimlog.raw_time(c.stamp, c.now)
		: trimlog.filter_text(c.text, c.kind, c.since, c.now ?? JAN);
};
