'use strict';

import * as net from 'aetherproxy.net';

const TCP = 'sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' +
	'   0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1\n' +
	'   1: 0100007F:7968 0100007F:9C40 01 00000000:00000000 00:00000000 00000000     0        0 2 1\n';
// Xray on 0.0.0.0:31080 as seen on the device: one dual-stack IPv6 socket.
const TCP6 = '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' +
	'   0: 00000000000000000000000000000000:7968 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 3 1\n';

export const cases = [
	{ expect: 'PASS', name: 'IPv4 listener found', text: TCP, port: 31053, want: true },
	{ expect: 'PASS', name: 'established socket on the port is not a listener', text: TCP, port: 31080, want: false },
	{ expect: 'PASS', name: 'dual-stack listener found in tcp6', text: TCP6, port: 31080, want: true },
	{ expect: 'PASS', name: 'other port not found', text: TCP6, port: 31053, want: false },
	{ expect: 'PASS', name: 'missing file is not listening', text: null, port: 31080, want: false }
];

export function run(c) {
	let got = net.tcp_listening(c.text, c.port);
	return got == c.want ? 'PASS' : `FAIL: got ${got}`;
};
