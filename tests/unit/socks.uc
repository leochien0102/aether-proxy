'use strict';

// T11.1: SOCKS schema, paired credentials and exact Xray server mapping (docs/05).
import { SCHEMA } from 'aetherproxy.schema';
import * as config from 'aetherproxy.config';
import * as outbound from 'aetherproxy.render.outbound';

export const cases = [
	{ name: 'SOCKS protocol enum', kind: 'enum', expect: true },
	{ name: 'SOCKS optional username field', kind: 'field', expect: true },
	{ name: 'SOCKS no auth valid', expect: [] },
	{ name: 'SOCKS auth valid', username: 'alice', password: 'test-secret', expect: [] },
	{ name: 'SOCKS missing username rejected without secret', password: 'test-secret', expect: ['node.username:required'] },
	{ name: 'SOCKS missing password rejected', username: 'alice', expect: ['node.password:required'] },
	{ name: 'SOCKS empty username rejected', username: '', password: 'test-secret', expect: ['node.username:required'] },
	{ name: 'SOCKS empty password rejected', username: 'alice', password: '', expect: ['node.password:required'] },
	{ name: 'SOCKS no auth exact outbound', kind: 'render', expect: { address: 'edge.example', port: 1080 } },
	{ name: 'SOCKS auth resolved address', kind: 'render', username: 'alice', password: 'test-secret',
		ip: '203.0.113.9', expect: { address: '203.0.113.9', port: 1080, users: [{ user: 'alice', pass: 'test-secret' }] } }
];

export function run(c) {
	if (c.kind == 'enum')
		return index(filter(SCHEMA.node, f => f.name == 'protocol')[0].enum, 'socks') >= 0;
	if (c.kind == 'field') {
		let fields = filter(SCHEMA.node, f => f.name == 'username');
		return length(fields) == 1 && index(fields[0].protocols, 'socks') >= 0 && !fields[0].required;
	}
	let node = { protocol: 'socks', address: 'edge.example', port: '1080' };
	if (c.username != null)
		node.username = c.username;
	if (c.password != null)
		node.password = c.password;
	if (c.kind == 'render') {
		node.port = 1080;
		let result = outbound.build_outbound(node, c.ip);
		return result.protocol == 'socks' ? result.settings.servers?.[0] : null;
	}
	let errors = config.validate_node(node);
	// Diagnostics must describe missing fields, never interpolate the provided password.
	if (index(sprintf('%.J', errors), 'test-secret') >= 0)
		return ['secret leaked'];
	return map(errors, e => e.field + ':' + e.code);
};
