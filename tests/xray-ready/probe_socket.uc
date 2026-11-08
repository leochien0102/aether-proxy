'use strict';
// Observation-only boundary in a copied readiness module: every operation uses
// the real socket. Count connect entry independently of scheduling TCP accept.
import * as native from 'socket';
import { stats } from 'diag_socket';
stats.connect_calls ??= 0;
export const AF_INET = native.AF_INET;
export const SOCK_STREAM = native.SOCK_STREAM;
export const SOCK_NONBLOCK = native.SOCK_NONBLOCK;
export const POLLOUT = native.POLLOUT;
export const POLLERR = native.POLLERR;
export const SOL_SOCKET = native.SOL_SOCKET;
export const SO_ERROR = native.SO_ERROR;
export function create(family, kind) {
	let sock = native.create(family, kind);
	if (sock == null)
		return null;
	return {
		native_socket: sock,
		connect: (address, port) => {
			stats.connect_calls = (stats.connect_calls ?? 0) + 1;
			return sock.connect(address, port);
		},
		getopt: (level, option) => sock.getopt(level, option),
		close: () => sock.close()
	};
};
export function poll(ms, entries) {
	// Unwrap for the native poll without substituting its result or budget.
	return native.poll(ms, [ entries[0].native_socket, entries[1] ]);
};
