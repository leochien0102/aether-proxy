'use strict';

import { connect_poll_ready, node_reachable } from 'aetherproxy.monitor';

export const cases = [
	{ name: 'poll writable with no socket error', revents: 4, so_error: 0, expect: true },
	{ name: 'poll error with refused connect', revents: 28, so_error: 111, expect: false },
	{ name: 'poll timeout even with no socket error', revents: 0, so_error: 0, expect: false },
	{ name: 'null poll result is unreachable', revents: null, expect: false },
	{ name: 'immediate connect succeeds without polling', immediate: true, expect: true }
];

export function run(c) {
	let reads = 0, closes = 0;
	let sock = {
		connect: () => true,
		getopt: () => { reads++; return c.so_error; },
		close: () => { closes++; }
	};
	if (c.immediate) {
		let unexpected = () => die('immediate connect must not poll or read socket.error()');
		return node_reachable('127.0.0.1', 9, { create: () => sock, error: unexpected, poll: unexpected }) &&
			reads == 0 && closes == 1;
	}

	let polled = c.revents == null ? null : [[ sock, c.revents, 1 ]];
	let connected = connect_poll_ready(polled, sock);
	if (reads != (c.revents ? 1 : 0))
		die('SO_ERROR must be read exactly once, and only when poll reports an event');
	return connected;
};
