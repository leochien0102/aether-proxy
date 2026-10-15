'use strict';

import { trim_event_history } from 'aetherproxy.log';
import { filter_events } from 'aetherproxy.cmd.events';

function make_history(count) {
	let lines = [];
	for (let i = 0; i < count; i++)
		push(lines, sprintf('%J', { ts: i, level: 'notice', code: 'SERVICE_STARTED', args: {} }));
	return join('\n', lines) + '\n';
}

function history_summary(text) {
	let lines = split(trim_event_history(text), '\n');
	if (lines[length(lines) - 1] == '')
		pop(lines);

	return {
		count: length(lines),
		first: length(lines) ? +json(lines[0]).ts : null,
		last: length(lines) ? +json(lines[length(lines) - 1]).ts : null
	};
}

const EVENT_ROWS = [
	{ ts: 100, level: 'notice', code: 'SERVICE_STARTED', args: {} },
	{ ts: 200, level: 'warn', code: 'DNS_TIER_CHANGED', args: {} },
	{ ts: 300, level: 'error', code: 'XRAY_DOWN', args: {} },
	{ ts: 400, level: 'warn', code: 'NODE_STALE', args: {} }
];

export const cases = [
	{ name: 'event history below limit is unchanged', kind: 'trim', input: 2,
		expect: { count: 2, first: 0, last: 1 } },
	{ name: '500 events are not truncated', kind: 'trim', input: 500,
		expect: { count: 500, first: 0, last: 499 } },
	{ name: '501 events drop the older half', kind: 'trim', input: 501,
		expect: { count: 251, first: 250, last: 500 } },
	{ name: 'since includes its boundary', kind: 'filter', since: 200,
		expect: [ 'DNS_TIER_CHANGED', 'XRAY_DOWN', 'NODE_STALE' ] },
	{ name: 'warn includes more severe error events', kind: 'filter', level: 'warn',
		expect: [ 'DNS_TIER_CHANGED', 'XRAY_DOWN', 'NODE_STALE' ] },
	{ name: 'no filter preserves input order', kind: 'filter',
		expect: [ 'SERVICE_STARTED', 'DNS_TIER_CHANGED', 'XRAY_DOWN', 'NODE_STALE' ] }
];

export function run(c) {
	if (c.kind == 'trim')
		return history_summary(make_history(c.input));

	return map(filter_events(EVENT_ROWS, c.since, c.level), event => event.code);
};
