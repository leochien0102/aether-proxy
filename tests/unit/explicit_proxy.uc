'use strict';

import * as config from 'aetherproxy.config';
import * as xray from 'aetherproxy.render.xray';

const AUTH = { socks_enabled: '1', socks_listen: '192.0.2.1', socks_port: '41080', socks_username: 'local-user', socks_password: 'local-secret',
	http_enabled: '1', http_listen: '198.51.100.1', http_port: '41081', http_username: 'http-user', http_password: 'http-secret' };

export const cases = [
	{ name: 'legacy snapshot and listeners unchanged', legacy: true, expect: true },
	{ name: 'independent authenticated TCP LAN inbounds route proxy', render: true, expect: true },
	{ name: 'only SOCKS enabled', render: true, change: { http_enabled: '0' }, expect: true },
	{ name: 'only HTTP enabled', render: true, change: { socks_enabled: '0' }, expect: true },
	{ name: 'both explicitly disabled', render: true, change: { socks_enabled: '0', http_enabled: '0' }, expect: true },
	{ name: 'missing SOCKS username', change: { socks_username: '' }, expect: ['main.socks_username:required'] },
	{ name: 'missing SOCKS password', change: { socks_password: '' }, expect: ['main.socks_password:required'] },
	{ name: 'missing HTTP username', change: { http_username: '' }, expect: ['main.http_username:required'] },
	{ name: 'missing HTTP password', change: { http_password: '' }, expect: ['main.http_password:required'] },
	{ name: 'missing SOCKS port', change: { socks_port: '' }, expect: ['main.socks_port:required'] },
	{ name: 'missing HTTP port', change: { http_port: '' }, expect: ['main.http_port:required'] },
	{ name: 'enabled ports collide', change: { http_port: '41080' }, expect: ['main.http_port:port_conflict'] },
	{ name: 'disabled port need not be unique', change: { http_enabled: '0', http_port: '41080' }, expect: [] },
	{ name: 'invalid port zero', change: { socks_port: '0' }, expect: ['main.socks_port:out_of_range'] },
	{ name: 'invalid port overflow', change: { http_port: '65536' }, expect: ['main.http_port:out_of_range'] },
	{ name: 'invalid boolean', change: { socks_enabled: 'yes' }, expect: ['main.socks_enabled:invalid_bool'] },
	{ name: 'control in secret never echoed', change: { socks_password: 'local-secret\n' }, invalid: true, expect: true },
	{ name: 'list secret never echoed', change: { http_password: ['http-secret'] }, invalid: true, expect: true },
	{ name: 'HTTP username colon rejected', change: { http_username: 'local-secret:bad' }, invalid: true, expect: true },
	{ name: 'overlong SOCKS secret rejected', change: { socks_password: sprintf('%0256d', 0) }, invalid: true, expect: true },
	{ name: 'enabled service missing node still rejected', change: { enabled: '1' }, expect: ['main.node:required'] }
];
for (let proto in ['socks', 'http']) {
	for (let listen in [ '', '0.0.0.0', '0.1.2.3', '127.0.0.1', '127.1.2.3', '224.0.0.1', '239.1.2.3',
		'255.255.255.255', '::1', '::', 'localhost', '192.0.2.1/24', '192.0.2.256', '192.00.2.1' ]) {
		let change = {}; change[proto + '_listen'] = listen;
		push(cases, { name: proto + ' rejects listen ' + listen, change,
			expect: ['main.' + proto + '_listen:' + (listen == '' ? 'required' : 'invalid_ipv4')] });
	}
	let change = {}; change[proto + '_enabled'] = '0'; change[proto + '_listen'] = 'not-an-address';
	push(cases, { name: proto + ' disabled listen not used', change, render: true, expect: true });
}
for (let port in [53, 31053, 31080, 31081, 31082, 31083])
	for (let proto in ['socks', 'http']) {
		let change = {}; change[proto + '_port'] = '' + port;
		push(cases, { name: proto + ' rejects internal port ' + port, change, expect: ['main.' + proto + '_port:port_conflict'] });
	}

export function run(c) {
	let result = config.normalize({ main: c.legacy ? {} : { ...AUTH, ...(c.change ?? {}) } });
	if (c.invalid)
		return !result.ok && index(sprintf('%.J', result), 'local-secret') < 0 && index(sprintf('%.J', result), 'http-secret') < 0;
	if (c.legacy)
		return result.ok && !('socks_enabled' in result.snapshot.main) && !('http_enabled' in result.snapshot.main)
			&& !('socks_listen' in result.snapshot.main) && !('http_listen' in result.snapshot.main)
			&& length(xray.build(result.snapshot, {}).inbounds) == 4;
	if (!c.render)
		return map(result.errors ?? [], e => e.field + ':' + e.code);
	if (!result.ok)
		return false;
	let built = xray.build(result.snapshot, {});
	let explicit = filter(built.inbounds, i => index(i.tag, 'explicit-') == 0);
	let count = 0;
	for (let proto in ['socks', 'http']) {
		let main = result.snapshot.main;
		if (!main[proto + '_enabled']) continue;
		count++;
		let i = filter(explicit, i => i.tag == 'explicit-' + proto)[0];
		if (i?.listen != main[proto + '_listen'] || i.port != main[proto + '_port'] || i.protocol != proto
			|| i.settings.accounts[0].user != main[proto + '_username'] || i.settings.accounts[0].pass != main[proto + '_password']) return false;
		if (proto == 'socks' && (i.settings.auth != 'password' || i.settings.udp != false)) return false;
		if (length(filter(built.routing.rules, r => r.outboundTag == 'proxy' && index(r.inboundTag, i.tag) >= 0)) != 1) return false;
	}
	return length(explicit) == count && length(built.inbounds) == 4 + count;
};
