'use strict';

import * as config from 'aetherproxy.config';
import * as pipeline from 'aetherproxy.pipeline';
import * as xray from 'aetherproxy.render.xray';

const AUTH = { socks_enabled: '1', socks_port: '41080', http_enabled: '1', http_port: '41081',
	proxy_username: 'local-user', proxy_password: 'local-secret' };
const OLD = { socks_username: 'local-user', socks_password: 'local-secret', http_username: 'local-user', http_password: 'local-secret' };

export const cases = [
	{ name: 'legacy disabled snapshot has defaults but no extra listeners', legacy: true, expect: true },
	{ name: 'shared authenticated TCP LAN inbounds route proxy', render: true, expect: true },
	{ name: 'explicit off retains credentials but emits no accounts', render: true, change: { proxy_auth_enabled: '0' }, expect: true },
	{ name: 'explicit on with credentials', render: true, change: { proxy_auth_enabled: '1' }, expect: true },
	{ name: 'auth on requires both fields even with listeners off', change: { proxy_auth_enabled: '1', socks_enabled: '0', http_enabled: '0', proxy_username: '', proxy_password: '' }, expect: ['main.proxy_username:required', 'main.proxy_password:required'] },
	{ name: 'auth on cannot become noauth by emptying credentials', change: { proxy_auth_enabled: '1', proxy_username: '', proxy_password: '' }, expect: ['main.proxy_username:required', 'main.proxy_password:required'] },
	{ name: 'empty auth flag cannot suppress legacy inference', change: { proxy_auth_enabled: '' }, invalid_auth: true, expect: true },
	{ name: 'invalid auth flag cannot suppress legacy inference', change: { proxy_auth_enabled: 'false' }, invalid_auth: true, expect: true },
	{ name: 'explicit off with unresolved conflict renders noauth', old: { ...OLD, http_password: 'other-secret' }, change: { proxy_auth_enabled: '0' }, render: true, expect: true },
	{ name: 'enabled without credentials is noauth for both protocols', render: true, change: { proxy_username: '', proxy_password: '' }, expect: true },
	{ name: 'absent credentials are noauth', render: true, change: { proxy_username: null, proxy_password: null }, expect: true },
	{ name: 'disabled partial credentials still fail', change: { socks_enabled: '0', http_enabled: '0', proxy_password: '' }, expect: ['main.proxy_password:required'] },
	{ name: 'disabled incomplete legacy credentials still fail', old: { socks_password: 'local-secret' }, change: { socks_enabled: '0', http_enabled: '0' }, expect: ['main.proxy_username:required'] },
	{ name: 'only SOCKS enabled', render: true, change: { http_enabled: '0' }, expect: true },
	{ name: 'only HTTP enabled', render: true, change: { socks_enabled: '0' }, expect: true },
	{ name: 'both disabled need neither addresses nor credentials', render: true, change: { socks_enabled: '0', http_enabled: '0', proxy_username: '', proxy_password: '' }, expect: true },
	{ name: 'missing shared username', change: { proxy_username: '' }, expect: ['main.proxy_username:required'] },
	{ name: 'missing shared password', change: { proxy_password: '' }, expect: ['main.proxy_password:required'] },
	{ name: 'missing SOCKS port defaults to 1080', change: { socks_port: '' }, defaults: true, expect: true },
	{ name: 'missing HTTP port defaults to 8080', change: { http_port: '' }, defaults: true, expect: true },
	{ name: 'enabled ports collide', change: { http_port: '41080' }, expect: ['main.http_port:port_conflict'] },
	{ name: 'disabled port need not be unique', change: { http_enabled: '0', http_port: '41080' }, expect: [] },
	{ name: 'invalid port zero', change: { socks_port: '0' }, expect: ['main.socks_port:out_of_range'] },
	{ name: 'invalid port overflow', change: { http_port: '65536' }, expect: ['main.http_port:out_of_range'] },
	{ name: 'invalid boolean', change: { socks_enabled: 'yes' }, expect: ['main.socks_enabled:invalid_bool'] },
	{ name: 'control in secret never echoed', change: { proxy_password: 'local-secret\n' }, invalid: true, expect: true },
	{ name: 'list secret never echoed', change: { proxy_password: ['local-secret'] }, invalid: true, expect: true },
	{ name: 'shared username colon rejected for SOCKS too', change: { http_enabled: '0', proxy_username: 'local-secret:bad' }, invalid: true, expect: true },
	{ name: 'overlong shared secret rejected', change: { proxy_password: sprintf('%0256d', 0) }, invalid: true, expect: true },
	{ name: 'enabled service missing node still rejected', change: { enabled: '1' }, expect: ['main.node:required'] },
	{ name: 'identical old pairs inherited without writeback', old: OLD, migration: true, expect: true },
	{ name: 'single old SOCKS pair inherited', old: { socks_username: 'local-user', socks_password: 'local-secret' }, migration: true, expect: true },
	{ name: 'single old HTTP pair inherited', old: { http_username: 'local-user', http_password: 'local-secret' }, migration: true, expect: true },
	{ name: 'different old passwords require explicit resolution', old: { ...OLD, http_password: 'other-secret' }, expect: ['main.proxy_credentials:migration_conflict'] },
	{ name: 'partial old conflict requires explicit resolution', old: { ...OLD, http_password: '' }, expect: ['main.proxy_credentials:migration_conflict'] },
	{ name: 'complementary old partial groups never silently merge', old: { socks_username: 'local-user', http_password: 'local-secret' }, expect: ['main.proxy_credentials:migration_conflict'] },
	{ name: 'single incomplete old pair remains incomplete', old: { socks_username: 'local-user' }, expect: ['main.proxy_password:required'] },
	{ name: 'legacy colon rejected by shared username policy', old: { socks_username: 'local-secret:bad', socks_password: 'local-secret' }, invalid: true, expect: true },
	{ name: 'new complete pair resolves old conflict even malformed old secret', old: { ...OLD, http_password: ['other-secret'] }, change: AUTH, render: true, expect: true },
	{ name: 'partial new pair cannot resolve old conflict', old: { ...OLD, http_password: 'other-secret' }, change: { proxy_username: 'new-user' }, expect: ['main.proxy_credentials:migration_conflict'] },
	{ name: 'password-only new pair cannot resolve old conflict', old: { ...OLD, http_password: 'other-secret' }, change: { proxy_password: 'new-secret' }, expect: ['main.proxy_credentials:migration_conflict'] },
	{ name: 'partial new pair never combines with old compatible pair', old: OLD, change: { proxy_username: 'new-user' }, expect: ['main.proxy_password:required'] },
	{ name: 'legacy conflict requires resolution even with both listeners disabled', old: { ...OLD, http_password: 'other-secret' }, change: { socks_enabled: '0', http_enabled: '0' }, expect: ['main.proxy_credentials:migration_conflict'] },
	{ name: 'unresolved renderer fails closed rather than default wildcard', unresolved: true, expect: true }
];
for (let proto in ['socks', 'http']) {
	for (let listen in [ '', '0.0.0.0', '0.1.2.3', '127.0.0.1', '127.1.2.3', '224.0.0.1', '239.1.2.3',
		'255.255.255.255', '::1', '::', 'localhost', '192.0.2.1/24', '192.0.2.256', '192.00.2.1' ]) {
		let change = {}; change[proto + '_listen'] = listen;
		push(cases, { name: proto + ' ignores legacy listen ' + listen, change, render: true, expect: true });
	}
}
for (let port in [53, 31053, 31080, 31081, 31082, 31083])
	for (let proto in ['socks', 'http']) {
		let change = {}; change[proto + '_port'] = '' + port;
		push(cases, { name: proto + ' rejects internal port ' + port, change, expect: ['main.' + proto + '_port:port_conflict'] });
	}

export function run(c) {
	let main = c.legacy ? {} : { ...AUTH, ...(c.old ? { proxy_username: null, proxy_password: null, ...c.old } : {}), ...(c.change ?? {}) };
	let raw = { main }, before = sprintf('%.J', raw);
	let result = config.normalize(raw);
	if (sprintf('%.J', raw) != before) return false;
	if (c.invalid_auth)
		return !result.ok && length(filter(result.errors, e => e.field == 'main.proxy_auth_enabled')) > 0;
	if (c.invalid)
		return !result.ok && index(sprintf('%.J', result), 'local-secret') < 0 && index(sprintf('%.J', result), 'other-secret') < 0;
	if (c.legacy)
		return result.ok && !('socks_enabled' in result.snapshot.main) && !('http_enabled' in result.snapshot.main)
			&& !('proxy_listen' in result.snapshot.main) && result.snapshot.main.socks_port == 1080
			&& result.snapshot.main.http_port == 8080 && length(xray.build(result.snapshot, {}).inbounds) == 4;
	if (c.defaults)
		return result.ok && result.snapshot.main[c.change.socks_port != null ? 'socks_port' : 'http_port'] == (c.change.socks_port != null ? 1080 : 8080);
	if (c.migration)
		return result.ok && result.snapshot.main.proxy_username == 'local-user' && result.snapshot.main.proxy_password == 'local-secret';
	if (c.unresolved) {
		try { xray.build(result.snapshot, {}); } catch (e) { return true; }
		return false;
	}
	if (!c.render)
		return map(result.errors ?? [], e => e.field + ':' + e.code);
	if (!result.ok) return false;
	pipeline.resolve_proxy_listen(result.snapshot.main, { addresses: ['192.0.2.1'] });
	let built = xray.build(result.snapshot, {});
	let explicit = filter(built.inbounds, i => index(i.tag, 'explicit-') == 0);
	let count = 0;
	for (let proto in ['socks', 'http']) {
		let main = result.snapshot.main;
		if (!main[proto + '_enabled']) continue;
		count++;
		let i = filter(explicit, i => i.tag == 'explicit-' + proto)[0];
		if (i?.listen != '192.0.2.1' || i.port != main[proto + '_port'] || i.protocol != proto) return false;
		let auth = main.proxy_auth_enabled == true;
		if (auth) {
			if (i.settings.accounts?.[0].user != main.proxy_username || i.settings.accounts?.[0].pass != main.proxy_password) return false;
		}
		else if ('accounts' in i.settings) return false;
		if (proto == 'socks' && (i.settings.auth != (auth ? 'password' : 'noauth') || i.settings.udp != false)) return false;
		if (length(filter(built.routing.rules, r => r.outboundTag == 'proxy' && index(r.inboundTag, i.tag) >= 0)) != 1) return false;
	}
	return length(explicit) == count && length(built.inbounds) == 4 + count;
};
