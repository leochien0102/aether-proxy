'use strict';

// Feed normalized effective values into the unchanged scheduler (docs/05, docs/06, T9.17).
import * as config from 'aetherproxy.config';
import * as schedule from 'aetherproxy.schedule';

let result = config.normalize({
	sub: { interval_hours: '0' },
	subscriptions: {
		s_00000001: { url: 'https://sub.example/inherit' },
		s_00000002: { url: 'https://sub.example/override', interval_hours: '6' }
	}
});
if (!result.ok)
	die('cannot normalize schedule test configuration');
let subs = result.snapshot.subscriptions;
let status = { s_00000001: { last_attempt: 0 }, s_00000002: { last_attempt: 1000 } };
let jitter = { s_00000001: 0, s_00000002: 0 };
let cases = [
	{
		name: 'T9.17 common zero interval never schedules inheriting subscription',
		subs: { s_00000001: subs.s_00000001 }, now: 9999999, expect: null
	},
	{
		name: 'T9.17 explicit six hours is not due before boundary',
		subs, now: 1000 + 6 * 3600 - 1, expect: null
	},
	{
		name: 'T9.17 explicit six hours is due exactly at boundary',
		subs, now: 1000 + 6 * 3600, expect: 's_00000002'
	}
];
let failed = false;
for (let c in cases) {
	let actual = schedule.due(c.subs, status, jitter, c.now, 0);
	if (actual != c.expect) {
		warn(`FAIL  ${c.name}: got ${actual}, expected ${c.expect}\n`);
		failed = true;
	}
	else
		print(`PASS  ${c.name}\n`);
}
exit(failed ? 1 : 0);
