'use strict';

// T11.2: HTTP schema, paired credentials and exact Xray server mapping (docs/05).
import { SCHEMA } from 'aetherproxy.schema';
import * as config from 'aetherproxy.config';
import * as outbound from 'aetherproxy.render.outbound';

export const cases = [
	{ name: 'HTTP protocol enum', kind: 'enum', expect: true },
	{ name: 'HTTP optional username field', kind: 'field', expect: true },
	{ name: 'HTTP optional password field', kind: 'password_field', expect: true },
	{ name: 'HTTP both empty valid', username: '', password: '', expect: [] },
	{ name: 'HTTP no auth valid', expect: [] },
	{ name: 'HTTP auth valid', username: 'alice', password: 'test-secret', expect: [] },
	{ name: 'HTTP missing username rejected without secret', password: 'test-secret', expect: ['node.username:required'] },
	{ name: 'HTTP missing password rejected', username: 'alice', expect: ['node.password:required'] },
	{ name: 'HTTP empty username rejected', username: '', password: 'test-secret', expect: ['node.username:required'] },
	{ name: 'HTTP empty password rejected', username: 'alice', password: '', expect: ['node.password:required'] },
	{ name: 'HTTP no auth exact outbound', kind: 'render', expect: { address: 'edge.example', port: 8080 } },
	{ name: 'HTTP auth resolved address', kind: 'render', username: 'alice', password: 'test-secret',
		ip: '203.0.113.9', expect: { address: '203.0.113.9', port: 8080, users: [{ user: 'alice', pass: 'test-secret' }] } }
];

export function run(c) {
	if (c.kind == 'enum')
		return index(filter(SCHEMA.node, f => f.name == 'protocol')[0].enum, 'http') >= 0;
	if (c.kind == 'field') {
		let fields = filter(SCHEMA.node, f => f.name == 'username');
		return length(fields) == 1 && index(fields[0].protocols, 'http') >= 0 && !fields[0].required;
	}
	if (c.kind == 'password_field') {
		let field = filter(SCHEMA.node, f => f.name == 'password')[0];
		return index(field.protocols, 'http') >= 0 && index(field.required, 'http') < 0;
	}
	let node = { protocol: 'http', address: 'edge.example', port: '8080' };
	if (c.username != null)
		node.username = c.username;
	if (c.password != null)
		node.password = c.password;
	if (c.kind == 'render') {
		node.port = 8080;
		let result = outbound.build_outbound(node, c.ip);
		return result.protocol == 'http' ? result.settings.servers?.[0] : null;
	}
	let errors = config.validate_node(node);
	// Diagnostics must describe missing fields, never interpolate the provided password.
	if (index(sprintf('%.J', errors), 'test-secret') >= 0)
		return ['secret leaked'];
	return map(errors, e => e.field + ':' + e.code);
};
