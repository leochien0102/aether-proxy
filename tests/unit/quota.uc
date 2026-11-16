'use strict';

// T16.2 quota contract (docs/design/b25-quota-heatmap-20261116.md §2–§3).
// Pure parsing/normalization plus read-modify-write against an isolated file.
import * as fs from 'fs';
import * as usage from 'aetherproxy.usage';

const UNSET = { bytes: null, set_at: null };
const PARSE_CASES = map([
	{ raw: '100G', expect: 100000000000 },
	{ raw: '100GB', expect: 100000000000 },
	{ raw: '1T', expect: 1000000000000 },
	{ raw: '1TB', expect: 1000000000000 },
	{ raw: '0001G', expect: 1000000000 },
	{ raw: '1000000001', expect: 1000000001 },
	{ raw: '100000G', expect: 100000000000000 },
	{ raw: '1.5G', expect: null },
	{ raw: '0', expect: null },
	{ raw: '100001G', expect: null },
	{ raw: 'not-a-number', expect: null },
	{ raw: '99999999999999999999999999999999999G', expect: null }
], c => ({ ...c, parse: true, name: `T16.2 pure decimal quota parser: ${c.raw}` }));
export const cases = [ ...PARSE_CASES,
	{ name: 'T16.2 quota normalizes missing field', data: {}, expect: UNSET },
	{ name: 'T16.2 quota normalizes null field', data: { quota: null }, expect: UNSET },
	{ name: 'T16.2 quota normalizes null bytes', data: { quota: { bytes: null, set_at: 17 } }, expect: UNSET },
	{ name: 'T16.2 quota accepts integer bytes and timestamp',
		data: { quota: { bytes: 100000000000, set_at: 17 } }, expect: { bytes: 100000000000, set_at: 17 } },
	{ name: 'T16.2 quota rejects fractional persisted bytes',
		data: { quota: { bytes: 1000000000.5, set_at: 17 } }, expect: UNSET },
	{ name: 'T16.2 quota set clear and day writes preserve each other', roundtrip: true,
		expect: { set: true, clear: true, days: true, unknown: true, flush: true, mode: true } }
];

export function run(c) {
	if (c.parse)
		return usage.parse_quota(c.raw);
	if (!c.roundtrip)
		return usage.quota_of(c.data);
	let path = `tests/unit/.quota-${fs.readlink('/proc/self')}.json`;
	let day = { tx: 1, rx: 2, observed: 30, healthy: 20 };
	fs.writefile(path, sprintf('%.J', { schema: 1, days: { '2026-11-15': day }, future: 'keep' }));
	let set = usage.set_quota(path, 100000000000, 17);
	let first = json(fs.readfile(path));
	let days = { ...first.days, '2026-11-16': day };
	let flushed = usage.write(path, days, 18);
	let second = json(fs.readfile(path));
	let clear = usage.set_quota(path, null, 19);
	let last = json(fs.readfile(path));
	let out = {
		set: set.ok && first.quota.bytes == 100000000000 && first.quota.set_at == 17,
		clear: clear.ok && last.quota.bytes == null && last.quota.set_at == null,
		days: first.days['2026-11-15'].tx == 1 && length(keys(last.days)) == 2,
		unknown: last.future == 'keep',
		flush: flushed.ok && second.quota.bytes == 100000000000 && second.quota.set_at == 17,
		mode: (fs.stat(path).mode & 511) == 384
	};
	fs.unlink(path);
	return out;
};
