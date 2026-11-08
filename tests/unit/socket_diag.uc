'use strict';
// Synthetic UAPI wire fixtures, explicitly both endian orders (not a BE device).
import * as diag from 'aetherproxy.socket_diag';

export const cases = [
	{ name: 'P3 P6 diag LE BE multipart clean completion and unknown attributes', kind: 'valid', expect: 'PASS' },
	{ name: 'P3 diag strict alignment sequence completion and attribute flags', kind: 'invalid', expect: 'PASS' },
	{ name: 'P4 handler ENOENT LE BE restricted to clean correlated TCPv6 dump', kind: 'handler', expect: 'PASS' }
];

function number(n, size, little) {
	let out = '';
	for (let i = 0; i < size; i++) {
		out = little ? out + chr(n % 256) : chr(n % 256) + out;
		n = int(n / 256);
	}
	return out;
};

function zeros(n) {
	let out = '';
	for (let i = 0; i < n; i++) out += chr(0);
	return out;
};

function message(kind, payload, little, flags) {
	return number(16 + length(payload), 4, little) + number(kind, 2, little) +
		number(flags ?? 2, 2, little) + number(42, 4, little) + number(12345, 4, little) + payload;
};

function attribute(kind, little) {
	return number(5, 2, little) + number(kind, 2, little) + zeros(4);
};

function handler_case(row, little, body) {
	let req = diag.request(row, 42, little);
	let negative = number(0xfffffffe, 4, little);
	let error = message(2, negative + req, little);
	let done = message(3, negative, little);
	for (let response in [ error, done, message(2, negative + substr(req, 0, 16), little, 258) ]) {
		let state = {};
		if (!diag.consume(state, response, row, 42, little).ok || !state.done || !state.fallback)
			return 'clean correlated missing handler not classified';
		for (let v6only in [ null, 0, 1 ]) {
			let attr = v6only == null ? '' : number(5, 2, little) + number(11, 2, little) + chr(v6only) + zeros(3);
			state = {};
			if (!diag.consume(state, message(20, body + attr, little), row, 42, little).ok)
				return 'partial evidence precondition failed';
			if (diag.consume(state, response, row, 42, little).ok)
				return 'handler error after partial evidence accepted';
		}
	}
	let wrong_seq = diag.request(row, 43, little);
	let wrong_dump = substr(req, 0, 6) + number(1, 2, little) + substr(req, 8);
	for (let bad in [ message(2, negative + wrong_seq, little), message(2, negative + wrong_dump, little),
		message(2, negative + substr(req, 0, 71), little), message(2, negative + req + zeros(4), little),
		message(3, negative, little, 0), message(3, negative, little, 18),
		message(3, negative + zeros(4), little), message(3, number(2, 4, little), little),
		message(3, number(0xfffffffb, 4, little), little), message(3, zeros(4), little) ])
		if (diag.consume({}, bad, row, 42, little).ok)
			return 'invalid missing-handler context accepted';
	if (diag.consume({}, error, row, 43, little).ok || diag.consume({}, done, row, 43, little).ok)
		return 'uncorrelated missing-handler status accepted';
	return 'PASS';
};

export function run(c) {
	let row = { address: '00000000000000000000000000000000', port: 45678, inode: '123456' };
	for (let little in [ true, false ]) {
		let body = chr(10) + chr(10) + zeros(2) + number(row.port, 2, false) + zeros(62) +
			number(123456, 4, little);
		let record = message(20, body + attribute(11, little) + attribute(123, little), little);
		let done = message(3, zeros(4), little);
		let state = {};
		if (c.kind == 'handler') {
			let result = handler_case(row, little, body);
			if (result != 'PASS')
				return result;
		}
		else if (c.kind == 'valid') {
			let req = diag.request(row, 42, little);
			if (length(req) != 72 || substr(req, 24, 2) != number(row.port, 2, false))
				return 'incorrect request framing';
			if (!diag.consume(state, record, row, 42, little).ok || state.done || state.v6only != 0)
				return 'matching record not parsed';
			if (!diag.consume(state, done, row, 42, little).ok || !state.done)
				return 'multipart completion not associated';
			state = {};
			if (!diag.consume(state, record + done, row, 42, little).ok || !state.done)
				return 'same datagram multipart rejected';
		}
		else {
			for (let bad in [ record + chr(0), substr(record, 0, length(record) - 1),
				message(20, body + attribute(0x800b, little), little),
				message(20, body + attribute(11, little) + attribute(11, little), little),
				message(3, '', little), done, record + done + done ])
				if (diag.consume({}, bad, row, 42, little).ok)
					return 'bad wire accepted';
			if (diag.consume({}, record, row, 43, little).ok || diag.consume({}, record, row, 42).ok)
				return 'missing byte order or wrong seq accepted';
		}
	}
	return 'PASS';
};
