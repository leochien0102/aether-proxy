'use strict';

// T16.86: raw NUL and leading-space parse_line() cases that cannot be passed
// through POSIX argv in tests/node/parse.py, plus byte-level control-byte checks.

import * as uri from 'aetherproxy.uri';

const UUID = '11111111-2222-4333-8444-555555555555';
const VMESS_BASE = `{"ps":"ok","add":"vm.example.com","port":"443","id":"${UUID}","aid":0,"scy":"auto","net":"tcp","tls":"tls"}`;
const GOOD_URI = `vless://${UUID}@good.example:443?security=tls#%E4%B8%AD%E6%96%87%20%E8%8A%82%E7%82%B9`;

export const cases = [
	{
		name: 'raw NUL in label rejected without truncation',
		fn: () => uri.parse_line(`vless://${UUID}@edge.example:443?security=tls#raw\x00nul`),
		expect: { skip: 'malformed' }
	},
	{
		name: 'raw NUL in scheme rejected without lc truncation',
		fn: () => uri.parse_line(`vless\x00evil://${UUID}@edge.example:443?security=tls#ok`),
		expect: { skip: 'malformed' }
	},
	{
		name: 'raw NUL after VMess base64 payload rejected without replace truncation',
		fn: () => uri.parse_line('vmess://' + b64enc(VMESS_BASE) + '\x00GARBAGE'),
		expect: { skip: 'malformed' }
	},
	{
		name: 'leading and trailing ordinary spaces trimmed while preserving Chinese+space label',
		fn: () => uri.parse_line('  ' + GOOD_URI + '  '),
		expect: { node: {
			protocol: 'vless', address: 'good.example', port: 443, uuid: UUID,
			label: '中文 节点', transport: 'raw', security: 'tls', encryption: 'none'
		} }
	}
];

export function run(c) {
	return c.fn();
};
