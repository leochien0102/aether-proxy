'use strict';
/* Real offline SDK form.js/uci.js + current app, intercepted local-only RPC.
 * NODE_PATH=<playwright node_modules> node tests/luci/t16.117-optional-auth-preview.js <SDK root/www>
 * No screenshots, DOM dumps, credentials in output, devices or remote requests.
 * Save assertions concern session UCI only, not device apply or actual listeners.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');
const www = process.argv[2];
assert.ok(www, 'Supply offline SDK root/www');
const sdk = path.resolve(www, 'luci-static');
const app = path.resolve(__dirname, '../../luci-app-aether-proxy');
const assets = path.join(app, 'htdocs/luci-static');
const messages = parsePo(fs.readFileSync(path.join(app, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const tr = key => messages[key] || key;
const origin = 'http://luci.test';
const shared = { proxy_username: 'fictional-user', proxy_password: 'fictional-secret' };
const legacy = { socks_username: 'fictional-old-user', socks_password: 'fictional-old-secret',
	http_username: 'fictional-other-user', http_password: 'fictional-other-secret' };
const credentialKeys = ['proxy_username', 'proxy_password', ...Object.keys(legacy)];
const sameCredentials = (a, b) => credentialKeys.every(k => a[k] === b[k]);
function shell() {
	return `<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="/luci-static/bootstrap/cascade.css">
<script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script></head>
<body><div id="indicators"></div><main><div id="maincontent"><div id="view"></div></div></main>
<script>const messages=${JSON.stringify(messages).replace(/</g, '\\u003c')};window._=key=>messages[key]||key;
window.L=new LuCI({scriptname:'/cgi-bin/luci',resource:'/luci-static/resources',base_url:'/luci-static/resources',media:'/luci-static/bootstrap',ubuspath:'/ubus',sessionid:'00000000000000000000000000000000',nodespec:{satisfied:true,readonly:false}});
window.ready=L.require('view.aether-proxy.advanced');</script></body></html>`;
}
async function scenario(browser, name, initial, exercise) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 1000 }, serviceWorkers: 'block' });
	const values = Object.fromEntries([['main', 'global', { lan_ifaces: ['br-lan'], ...initial }],
		['dns', 'dns', {}], ['probe', 'probe', {}], ['stats', 'stats', {}]]
		.map(([id, type, opts], i) => [id, { '.name': id, '.type': type, '.index': i, ...opts }]));
	let writes = 0;
	const unexpected = [];
	const fixtures = {
		'session.access': () => ({ access: true }), 'luci.getFeatures': () => ({}), 'luci.getInitList': () => ({}),
		'uci.get': ({ config }) => ({ values: config === 'aetherproxy' ? values : {} }),
		'uci.changes': () => ({ changes: {} }),
		'uci.set': ({ section, values: incoming }) => { writes++; Object.assign(values[section], incoming); return {}; },
		'uci.delete': ({ section, options }) => { writes++; for (const k of options || []) delete values[section][k]; return {}; },
		'aetherproxy.status': () => ({ ok: true, explicit_lan: { interface: 'lan', addresses: ['192.0.2.1'] } }),
		'network.get_proto_handlers': () => ({}), 'network.interface.dump': () => ({ interface: [] }),
		'luci-rpc.getBoardJSON': () => ({}), 'luci-rpc.getHostHints': () => ({}),
		'luci-rpc.getNetworkDevices': () => ({ 'br-lan': { name: 'br-lan', devtype: 'bridge', up: true,
			ipaddrs: [{ address: '192.0.2.1', netmask: '255.255.255.0' }] } })
	};
	try {
		await context.route('**/*', async route => {
			const req = route.request(), url = new URL(req.url());
			if (url.origin !== origin) { unexpected.push('external request'); return route.abort(); }
			if (url.pathname === '/') return route.fulfill({ contentType: 'text/html', body: shell() });
			if (url.pathname === '/ubus') {
				const reply = call => {
					if (call.method === 'list') return { jsonrpc: '2.0', id: call.id, result: {} };
					const [, object, method, params] = call.params, key = object + '.' + method;
					if (!fixtures[key]) { unexpected.push(key); return { jsonrpc: '2.0', id: call.id, result: [3] }; }
					return { jsonrpc: '2.0', id: call.id, result: [0, fixtures[key](params || {})] };
				};
				const data = req.postDataJSON();
				return route.fulfill({ json: Array.isArray(data) ? data.map(reply) : reply(data) });
			}
			if (url.pathname.startsWith('/luci-static/')) {
				const name = url.pathname.slice('/luci-static/'.length);
				const file = [path.join(assets, name), path.join(sdk, name)].find(p => fs.statSync(p, { throwIfNoEntry: false })?.isFile());
				if (file) return route.fulfill({ path: file });
			}
			unexpected.push('missing local asset'); return route.fulfill({ status: 404 });
		});
		const page = await context.newPage();
		page.setDefaultTimeout(8000);
		// Expected native validation errors may be rethrown by the SDK. Never print their payloads.
		page.on('pageerror', error => {
			if (!/invalid input value|Authentication requires both|Legacy proxy credentials|Port conflicts|共享用户名和密码|旧.*凭据|端口.*冲突/.test(error.message))
				unexpected.push('unexpected SDK error');
		});
		const tab = () => page.locator('.cbi-tabmenu a').filter({ hasText: tr('LAN explicit proxy') }).click();
		const open = async () => { await page.goto(origin); await page.evaluate(() => window.ready.then(() => null)); await tab(); };
		const row = f => page.locator(`[data-name="${f}"]`);
		const input = f => row(f).locator('input').first();
		const fill = async (f, v) => { await input(f).fill(v); await input(f).blur(); };
		const flag = (f, v) => row(f).locator('input[type="checkbox"]').setChecked(v);
		const save = async () => {
			await page.locator('.cbi-page-actions .cbi-button-save').click();
			await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		};
		const badSave = async () => {
			const before = writes;
			await save();
			await page.locator('#modal_overlay').filter({ hasText: tr('Save error') }).waitFor();
			assert.ok(writes === before, 'invalid save made RPC writes');
			await page.getByRole('button', { name: tr('Dismiss'), exact: true }).click();
		};
		const reset = async () => { await page.locator('.cbi-page-actions .cbi-button-reset').click(); await tab(); };
		const clear = async () => {
			const before = writes;
			const authBefore = await row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked();
			const button = row('_proxy_clear_credentials').locator('button');
			assert.equal(await button.getAttribute('type'), 'button');
			await button.click();
			assert.equal(await input('proxy_username').inputValue(), '');
			assert.equal(await input('proxy_password').inputValue(), '');
			assert.equal(await row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), authBefore);
			assert.ok(writes === before, 'clear button must not save');
		};
		await open();
		assert.equal(await input('proxy_password').getAttribute('type'), 'password');
		assert.ok(await page.getByText(tr('Authentication is shared by both proxies. When disabled, any client that can reach the port can use the proxy. Clearing credentials does not disable authentication.'), { exact: false }).isVisible());
		await exercise({ page, values, open, tab, row, input, fill, flag, save, badSave, reset, clear });
		assert.ok(unexpected.length === 0, 'unexpected network or fixture call');
		console.log('PASS ' + name);
	} finally { await context.close(); }
}
(async () => {
	const browser = await chromium.launch();
	try {
		await scenario(browser, 'fresh off plus newly stored credentials remains explicitly off after reload', {}, async h => {
			await h.fill('proxy_username', shared.proxy_username); await h.fill('proxy_password', shared.proxy_password);
			await h.save(); await h.open();
			assert.equal(h.values.main.proxy_auth_enabled, '0');
			assert.ok(sameCredentials(h.values.main, shared));
			assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), false);
		});
		for (const source of ['socks', 'http']) {
			await scenario(browser, 'clear then select legacy ' + source + ' uses the last source', legacy, async h => {
				await h.clear();
				await h.row('_proxy_credential_source').locator('select').selectOption(source);
				await h.save(); await h.open();
				assert.equal(h.values.main.proxy_auth_enabled, '1');
				assert.ok(h.values.main.proxy_username === legacy[source + '_username']);
				assert.ok(h.values.main.proxy_password === legacy[source + '_password']);
				assert.ok(Object.keys(legacy).every(k => !(k in h.values.main)));
			});
		}
		await scenario(browser, 'default off -> auth required -> clear does not disable -> explicit off survives reopening', {}, async h => {
			assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), false);
			for (const p of ['socks', 'http']) await h.flag(p + '_enabled', true);
			await h.save();
			assert.ok(h.values.main.socks_enabled === '1' && h.values.main.http_enabled === '1');
			assert.ok(credentialKeys.every(k => !(k in h.values.main)));
			await h.tab(); await h.flag('proxy_auth_enabled', true);
			await h.badSave();
			await h.fill('proxy_username', shared.proxy_username);
			await h.badSave(); assert.ok(credentialKeys.every(k => !(k in h.values.main)));
			await h.fill('proxy_password', shared.proxy_password); await h.save();
			assert.ok(sameCredentials(h.values.main, shared));
			assert.equal(h.values.main.proxy_auth_enabled, '1');
			await h.tab(); await h.clear(); await h.badSave();
			assert.ok(sameCredentials(h.values.main, shared));
			assert.equal(h.values.main.proxy_auth_enabled, '1');
			await h.reset();
			assert.ok(await h.input('proxy_password').inputValue() === shared.proxy_password);
			assert.ok(sameCredentials(h.values.main, shared));
			await h.clear(); await h.flag('proxy_auth_enabled', false);
			await h.fill('socks_port', '53'); await h.badSave();
			assert.ok(sameCredentials(h.values.main, shared));
			await h.fill('socks_port', '1080'); await h.save();
			assert.equal(h.values.main.proxy_auth_enabled, '0');
			assert.ok(credentialKeys.every(k => !(k in h.values.main)));
			await h.tab(); for (const p of ['socks', 'http']) await h.flag(p + '_enabled', false);
			await h.save(); await h.open();
			for (const p of ['socks', 'http']) await h.flag(p + '_enabled', true);
			await h.save(); await h.open();
			assert.ok(credentialKeys.every(k => !(k in h.values.main)));
			assert.equal(await h.input('proxy_username').inputValue(), '');
			assert.equal(await h.input('proxy_password').inputValue(), '');
			assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), false);
			await h.flag('proxy_auth_enabled', true); await h.badSave();
			assert.equal(h.values.main.proxy_auth_enabled, '0');
		});
		for (const initial of [shared, { socks_username: shared.proxy_username, socks_password: shared.proxy_password }]) {
			await scenario(browser, 'existing credentials retained without editing; explicit clearing survives reload',
				{ ...initial, socks_enabled: '1' }, async h => {
					assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), true);
					await h.save(); assert.ok(sameCredentials(h.values.main, shared));
					assert.equal(h.values.main.proxy_auth_enabled, '1');
					await h.tab(); await h.flag('proxy_auth_enabled', false); await h.save(); await h.open();
					assert.equal(h.values.main.proxy_auth_enabled, '0');
					assert.ok(sameCredentials(h.values.main, shared), 'auth off may retain stored credentials');
					assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), false);
					await h.clear(); await h.save(); await h.open();
					assert.ok(credentialKeys.every(k => !(k in h.values.main)));
				});
		}
		await scenario(browser, 'legacy conflict defaults to auth even while listeners off; clear/reset/failure preserve originals', legacy, async h => {
			assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), true);
			await h.badSave(); assert.ok(sameCredentials(h.values.main, legacy));
			await h.clear(); await h.badSave();
			assert.ok(sameCredentials(h.values.main, legacy));
			await h.reset(); assert.ok(sameCredentials(h.values.main, legacy));
			assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), true);
			await h.badSave(); // Reset must also cancel clear intent, not only restore empty-looking inputs.
			assert.ok(sameCredentials(h.values.main, legacy));
			await h.flag('proxy_auth_enabled', false); await h.save(); await h.open();
			assert.equal(h.values.main.proxy_auth_enabled, '0');
			assert.ok(sameCredentials(h.values.main, legacy), 'explicit off must suppress retained legacy conflict');
			assert.equal(await h.row('proxy_auth_enabled').locator('input[type="checkbox"]').isChecked(), false);
			await h.clear(); await h.save(); await h.open();
			assert.ok(credentialKeys.every(k => !(k in h.values.main)));
			assert.equal(h.values.main.proxy_auth_enabled, '0');
			assert.equal(await h.row('_proxy_credential_source').count(), 0);
		});
	} finally { await browser.close(); }
})().catch(() => { console.error('FAIL T16.117 offline LuCI save regression (details withheld)'); process.exitCode = 1; });
