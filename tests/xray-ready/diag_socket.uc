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
