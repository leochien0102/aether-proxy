'use strict';
// Synthetic UAPI wire fixtures, explicitly both endian orders (not a BE device).
import * as diag from 'aetherproxy.socket_diag';

export const cases = [
	{ name: 'P3 P6 diag LE BE multipart clean completion and unknown attributes', kind: 'valid', expect: 'PASS' },
	{ name: 'P3 diag strict alignment sequence completion and attribute flags', kind: 'invalid', expect: 'PASS' }
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

function message(kind, payload, little) {
	return number(16 + length(payload), 4, little) + number(kind, 2, little) +
		number(2, 2, little) + number(42, 4, little) + number(12345, 4, little) + payload;
};

function attribute(kind, little) {
	return number(5, 2, little) + number(kind, 2, little) + zeros(4);
};

export function run(c) {
	let row = { address: '00000000000000000000000000000000', port: 45678, inode: '123456' };
	for (let little in [ true, false ]) {
		let body = chr(10) + chr(10) + zeros(2) + number(row.port, 2, false) + zeros(62) +
			number(123456, 4, little);
		let record = message(20, body + attribute(11, little) + attribute(123, little), little);
		let done = message(3, zeros(4), little);
		let state = {};
		if (c.kind == 'valid') {
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
