'use strict';
// Transport-only fault boundary in copied socket_diag; real FD allocation/close,
// production wire parser, readiness, ownership, cancellation and fallback remain.
import * as native from 'socket';
import * as fs from 'fs';
import * as uloop from 'uloop';
let spec = getenv('DIAG_WIRE') == null ? {} : json(fs.readfile(getenv('DIAG_WIRE')));
export const AF_INET6 = native.AF_INET6;
export const SOCK_RAW = native.SOCK_RAW;
export const SOCK_NONBLOCK = native.SOCK_NONBLOCK;
export const SOCK_CLOEXEC = native.SOCK_CLOEXEC;
export const POLLIN = native.POLLIN;
export const MSG_TRUNC = native.MSG_TRUNC;
export const MSG_CTRUNC = native.MSG_CTRUNC;
export function strerror(n) { return native.strerror(n); };
export function error(numeric) { return spec.errno; };
export const stats = global.DIAG_TRANSPORT_STATS ?? { created: 0, closed: 0 };
global.DIAG_TRANSPORT_STATS = stats;
let received = 0;
function now_ms() {
	let t = clock(true);
	return t[0] * 1000 + t[1] / 1000000;
};

function late_completion() {
	let deadline = global.PROBE_ORIGINAL_DEADLINE;
	if (deadline == null)
		die('budget test is missing the original deadline observation');
	// Hold only the final legal receive result, not poll or the production clock.
	// A loop handles early uloop wakeups; the original deadline is never changed.
	while (now_ms() < deadline + 1)
		uloop.run(min(100, max(1, int(deadline + 1 - now_ms()) + 1)));
	stats.original_deadline_ms = deadline;
	stats.completion_return_ms = now_ms();
};

export function create(family, kind, protocol) {
	received = 0;
	if (spec.create_error)
		return null;
	let sock = native.create(family, kind, protocol);
	stats.created++;
	let at = 0;
	return {
		send: wire => spec.send_error ? null : length(wire),
		recvmsg: () => {
			received++;
			if (spec.receive_error)
				return null;
			let text = '';
			for (let b in spec.messages[at++])
				text += chr(b);
			if (spec.late_completion && at == length(spec.messages))
				late_completion();
			return { data: text, length: length(text), flags: spec.flags ?? 0 };
		},
		close: () => {
			let closed = sock.close();
			stats.closed++;
			return spec.close_error ? null : closed;
		}
	};
};
export function poll(ms, entry) {
	let timeout = spec.timeout || (spec.timeout_after != null && received >= spec.timeout_after);
	uloop.run(timeout ? ms : min(ms, spec.delay ?? 1));
	if (spec.poll_error)
		return null;
	return [ [ entry[0][0], timeout ? 0 : POLLIN ] ];
};
