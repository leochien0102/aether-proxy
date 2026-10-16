'use strict';
// log line classification and tail selection (docs/10 "`log`、`node import`、`custom`",
// docs/09 "子进程日志"). Pure functions of aetherproxy.cmd.log, table-driven.

import { classify, select_lines } from 'aetherproxy.cmd.log';

const LOGD = [
	'Thu Oct 16 12:00:00 2026 daemon.notice aether-proxy[1234]: SERVICE_STARTED proxy started',
	'Thu Oct 16 12:00:01 2026 daemon.warn aether-proxy[1234]: 2026/10/16 12:00:01.123456 [Warning] dial failed',
	'Thu Oct 16 12:00:02 2026 daemon.notice aether-proxy[1234]: 2026/10/16 12:00:02.000000 [Error] transport down',
	'Thu Oct 16 12:00:03 2026 daemon.notice aether-proxy[1234]: [main.zig:123] upstream switched',
	'Thu Oct 16 12:00:04 2026 daemon.notice dnsmasq[999]: reading /tmp/resolv.conf',
	'Thu Oct 16 12:00:05 2026 daemon.info aether-proxy[9999]: [resolver.zig:44] cached 10 entries',
	'Thu Oct 16 12:00:06 2026 user.notice logger: aether-proxy[1]: not a real tagged line'
];

export const cases = [
	// --- classify: the two child formats and the fallback -----------------------
	{ name: 'classify xray warning', kind: 'classify',
	  message: '2026/10/16 12:00:01.123456 [Warning] transport: dial failed', expect: 'xray' },
	{ name: 'classify xray info', kind: 'classify',
	  message: '2026/10/16 12:00:02.000000 [Info] app: listener ready', expect: 'xray' },
	{ name: 'classify xray error', kind: 'classify',
	  message: '2026/10/16 12:00:03.000000 [Error] transport down', expect: 'xray' },
	{ name: 'classify xray debug', kind: 'classify',
	  message: '2026/10/16 12:00:04.999999 [Debug] inbound: accepted', expect: 'xray' },
	{ name: 'classify xray lowercase tag is not xray', kind: 'classify',
	  message: '2026/10/16 12:00:00 [warning] nope', expect: 'aether-proxy' },
	{ name: 'classify dns main.zig', kind: 'classify',
	  message: '[main.zig:123] upstream switched', expect: 'dns' },
	{ name: 'classify dns nested module', kind: 'classify',
	  message: '[resolver.zig:44] cached 10 entries', expect: 'dns' },
	{ name: 'classify dns requires digits', kind: 'classify',
	  message: '[main.zig:x] no line number', expect: 'aether-proxy' },
	{ name: 'classify event line', kind: 'classify',
	  message: 'SERVICE_STARTED proxy started [mode=gfw]', expect: 'aether-proxy' },
	{ name: 'classify empty', kind: 'classify', message: '', expect: 'aether-proxy' },

	// --- select_lines: tag filter, source filter, tail, order -------------------
	{ name: 'select all keeps the tagged lines in order', kind: 'select',
	  text: join('\n', LOGD), source: 'all', n: 200,
	  expect: [
		{ source: 'aether-proxy', text: LOGD[0] },
		{ source: 'xray', text: LOGD[1] },
		{ source: 'xray', text: LOGD[2] },
		{ source: 'dns', text: LOGD[3] },
		{ source: 'dns', text: LOGD[5] }
	  ] },
	{ name: 'select never returns other programs', kind: 'select',
	  text: join('\n', LOGD), source: 'all', n: 200,
	  expect_filter: 'dnsmasq', expect: 'filtered' },
	{ name: 'select xray keeps only xray lines', kind: 'select',
	  text: join('\n', LOGD), source: 'xray', n: 200,
	  expect: [
		{ source: 'xray', text: LOGD[1] },
		{ source: 'xray', text: LOGD[2] }
	  ] },
	{ name: 'select dns keeps only dns lines', kind: 'select',
	  text: join('\n', LOGD), source: 'dns', n: 200,
	  expect: [
		{ source: 'dns', text: LOGD[3] },
		{ source: 'dns', text: LOGD[5] }
	  ] },
	{ name: 'select aether-proxy keeps only unclassified lines', kind: 'select',
	  text: join('\n', LOGD), source: 'aether-proxy', n: 200,
	  expect: [ { source: 'aether-proxy', text: LOGD[0] } ] },
	{ name: 'select takes the tail of the filtered lines', kind: 'select',
	  text: join('\n', LOGD), source: 'all', n: 2,
	  expect: [
		{ source: 'dns', text: LOGD[3] },
		{ source: 'dns', text: LOGD[5] }
	  ] },
	{ name: 'select tail order preserved', kind: 'select',
	  text: join('\n', LOGD), source: 'xray', n: 1,
	  expect: [ { source: 'xray', text: LOGD[2] } ] },
	{ name: 'select empty input', kind: 'select', text: '', source: 'all', n: 200, expect: [] },
	{ name: 'select a quoted tag in a message is not a tagged line', kind: 'select',
	  text: LOGD[6], source: 'all', n: 200, expect: [] },
	{ name: 'select untagged lines are dropped', kind: 'select',
	  text: 'random output\nno tag here', source: 'all', n: 200, expect: [] }
];

// NOTE: with the pinned ucode, `export function f() {...}` must be terminated by `;`.
export function run(c) {
	if (c.kind == 'classify')
		return classify(c.message);

	let out = select_lines(c.text, c.source, c.n);
	if (c.expect_filter != null)
		return index(out, c.expect_filter) < 0 ? 'filtered' : `LEAKED: ${c.expect_filter}`;
	return out;
};
