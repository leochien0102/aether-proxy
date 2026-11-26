'use strict';
/* Offline LuCI SDK + current application assets. No server, device or live RPC.
 * NODE_PATH=/tmp/t16.23-evidence/node_modules node tests/luci/t16.111-explicit-preview.js <SDK root/www> [output dir]
 * Shell and route approach: t16.24-theme-preview.js; deliberately advanced-only.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');
const [www, out = path.join(__dirname, 'evidence/t16.111')] = process.argv.slice(2);
assert.ok(www, 'Supply the offline SDK root/www');
const sdk = path.resolve(www, 'luci-static');
const app = path.resolve(__dirname, '../../luci-app-aether-proxy');
const assets = path.join(app, 'htdocs/luci-static');
const messages = parsePo(fs.readFileSync(path.join(app, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const tr = key => messages[key] || key;
const origin = 'http://luci.test';
const report = { boundary: 'Offline UI only; fixture UCI writes are not backend/schema/firewall/listener verification. Save & Apply is present but not executed.', checks: [], writes: [], rpc: [], assets: [], screenshots: [] };
const check = name => { report.checks.push(name); console.log('PASS ' + name); };
const themes = { 'bootstrap-dark': 'bootstrap/cascade.css', 'argon-light': 'argon-plus/css/cascade.css' };
function shell(stylesheet, dark) {
	return `<!doctype html><html lang="zh-Hans" data-darkmode="${dark}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="/luci-static/${stylesheet}">
${dark ? '<link rel="stylesheet" href="/luci-static/bootstrap/mobile.css">' : ''}
<script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script></head>
<body class="lang_zh-cn" data-page="admin-services-aether-proxy-advanced"><div id="indicators"></div><main class="main"><div class="main-right"><div id="maincontent" class="container"><div id="view" class="container"></div></div></div></main>
<script>const messages=${JSON.stringify(messages).replace(/</g, '\\u003c')};window._=key=>Object.hasOwn(messages,key)?messages[key]:key;
window.L=new LuCI({scriptname:'/cgi-bin/luci',resource:'/luci-static/resources',base_url:'/luci-static/resources',media:'/luci-static/${stylesheet.split('/')[0]}',ubuspath:'/ubus',sessionid:'00000000000000000000000000000000',nodespec:{satisfied:true,readonly:false}});
window.ready=L.require('view.aether-proxy.advanced');</script></body></html>`;
}
async function run(browser, theme, stylesheet) {
	const dark = theme === 'bootstrap-dark';
	const context = await browser.newContext({ viewport: { width: 1320, height: 1200 }, locale: 'zh-CN', colorScheme: dark ? 'dark' : 'light', reducedMotion: 'reduce', serviceWorkers: 'block' });
	const errors = [], calls = new Set(), loaded = new Set();
	let rejectWrite = false;
	const values = Object.fromEntries([['main', 'global', { lan_ifaces: ['br-lan'], port_scope: 'all' }], ['dns', 'dns', {}], ['probe', 'probe', {}], ['stats', 'stats', {}]]
		.map(([id, type, opts], i) => [id, { '.name': id, '.type': type, '.index': i, ...opts }]));
	const writes = [], pendingChanges = [];
	const fixtures = {
		'session.access': () => ({ access: true }), 'luci.getFeatures': () => ({}), 'luci.getInitList': () => ({}),
		'uci.get': ({ config }) => ({ values: config === 'aetherproxy' ? values : {} }),
		'uci.changes': () => ({ changes: pendingChanges.length ? { aetherproxy: pendingChanges } : {} }),
		'uci.set': ({ config, section, values: incoming }) => {
			assert.equal(config, 'aetherproxy');
			writes.push({ section, fields: Object.keys(incoming).sort(), result: rejectWrite ? 'rejected' : 'accepted' });
			if (!rejectWrite) {
				Object.assign(values[section], incoming);
				for (const [field, value] of Object.entries(incoming)) pendingChanges.push(['set', section, field, value]);
			}
			return {};
		},
		'uci.delete': ({ section, options }) => { for (const key of options || []) delete values[section][key]; return {}; },
		'network.get_proto_handlers': () => ({}), 'network.interface.dump': () => ({ interface: [] }),
		'luci-rpc.getBoardJSON': () => ({}), 'luci-rpc.getHostHints': () => ({}),
		'luci-rpc.getNetworkDevices': () => ({ 'br-lan': { name: 'br-lan', devtype: 'bridge', up: true, ipaddrs: [{ address: '192.0.2.1', netmask: '255.255.255.0' }] } })
	};
	try {
		await context.route('**/*', async route => {
			const req = route.request(), url = new URL(req.url());
			if (url.origin !== origin) { errors.push('Blocked external request'); return route.abort(); }
			if (url.pathname === '/') return route.fulfill({ contentType: 'text/html', body: shell(stylesheet, dark) });
			if (url.pathname === '/ubus') {
				const reply = call => {
					if (call.method === 'list') return { jsonrpc: '2.0', id: call.id, result: {} };
					const [, object, method, params] = call.params, key = `${object}.${method}`;
					calls.add(key);
					if (!fixtures[key]) { errors.push('Missing fixture: ' + key); return { jsonrpc: '2.0', id: call.id, result: [3] }; }
					const result = fixtures[key](params || {});
					return { jsonrpc: '2.0', id: call.id, result: key === 'uci.set' && rejectWrite ? [9] : [0, result] };
				};
				const data = req.postDataJSON();
				return route.fulfill({ json: Array.isArray(data) ? data.map(reply) : reply(data) });
			}
			if (url.pathname.startsWith('/luci-static/')) {
				const name = url.pathname.slice('/luci-static/'.length);
				const file = [path.join(assets, name), path.join(sdk, name)].find(p => fs.statSync(p, { throwIfNoEntry: false })?.isFile());
				if (file) { if (file.startsWith(assets + path.sep)) loaded.add(name); return route.fulfill({ path: file }); }
			}
			errors.push('Unexpected local path: ' + url.pathname);
			return route.fulfill({ status: 404 });
		});
		const page = await context.newPage();
		page.setDefaultTimeout(6000);
		page.on('pageerror', error => errors.push(error.message.replace(/fictional[^\s'"<>]*/g, '[REDACTED]')));
		await page.goto(origin);
		await page.evaluate(() => window.ready.then(() => null));
		const tab = () => page.locator('.cbi-tabmenu a').filter({ hasText: tr('LAN explicit proxy') }).click();
		const row = field => page.locator(`[data-name="${field}"]`);
		const input = field => row(field).locator('input').first();
		const flag = field => row(field).locator('input[type="checkbox"]');
		const save = () => page.locator('.cbi-page-actions .cbi-button-save').click();
		const reset = () => page.locator('.cbi-page-actions .cbi-button-reset').click();
		async function shot(name) {
			await page.evaluate(() => document.fonts.ready.then(() => null));
			for (const protocol of ['socks', 'http']) assert.equal(await input(protocol + '_password').getAttribute('type'), 'password');
			const file = `${theme}-${name}.png`;
			// Substitute DOM values only (no events), preserving native controls and password bullets.
			// Originals stay inside the page and are restored even when screenshot fails.
			await page.evaluate(() => {
				window.previewCaptureInputs = [...document.querySelectorAll('[data-name$="_username"] input,[data-name$="_password"] input')].map(el => [el, el.value]);
				for (const [el] of window.previewCaptureInputs) el.value = el.type === 'password' ? 'redacted' : '[REDACTED]';
			});
			try {
				await page.screenshot({ path: path.join(out, file), fullPage: true, animations: 'disabled' });
			} finally {
				await page.evaluate(() => {
					for (const [el, value] of window.previewCaptureInputs) el.value = value;
					delete window.previewCaptureInputs;
				});
			}
			report.screenshots.push(file);
		}
		await tab();
		for (const p of ['socks', 'http']) {
			assert.equal(await flag(p + '_enabled').isChecked(), false);
			for (const f of ['listen', 'port', 'username', 'password']) assert.equal(await row(`${p}_${f}`).isVisible(), false);
		}
		assert.equal(await page.locator('.cbi-page-actions .cbi-button-apply').count(), 1);
		check(theme + ': defaults both off, dependent fields hidden, standard footer');
		await shot('default-off');
		await save();
		await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		assert.ok(!writes.some(w => w.fields.some(f => /^(socks|http)_/.test(f))));
		check(theme + ': untouched save does not backfill explicit defaults');
		await tab();
		await flag('socks_enabled').check();
		assert.equal(await row('socks_listen').isVisible(), true);
		assert.equal(await row('http_listen').isVisible(), false);
		await flag('http_enabled').check();
		const demo = { socks_listen: '192.0.2.1', socks_port: '1080', socks_username: 'fictional-socks-user', socks_password: 'fictional-socks-secret', http_listen: '192.0.2.1', http_port: '8080', http_username: 'fictional-http-user', http_password: 'fictional-http-secret' };
		for (const [f, v] of Object.entries(demo)) { await input(f).fill(v); await input(f).blur(); }
		assert.equal(await page.locator('.cbi-input-invalid:visible').count(), 0);
		await page.locator('#view h2').click();
		await shot('both-enabled');
		const invalid = [ ['socks_listen', '0.0.0.0'], ['socks_listen', '127.0.0.1'], ['socks_listen', '::1'], ['socks_port', '0'], ['socks_port', '65536'], ['socks_port', '53'], ['http_port', '1080'], ['http_username', 'fictional:invalid'], ['socks_password', 'x'.repeat(256)], ['http_password', ''], ['socks_username', ''] ];
		for (const [f, v] of invalid) {
			await input(f).fill(v);
			await input(f).blur();
			await row(f).locator('.cbi-input-invalid').waitFor();
			check(theme + ': rejected ' + f + ' case ' + (invalid.findIndex(item => item[0] === f && item[1] === v) + 1));
			if (f === 'http_port') await shot('port-conflict');
			if (f === 'http_username') {
				const invalidInput = row(f).locator('.cbi-input-invalid');
				const tooltip = await invalidInput.getAttribute('data-tooltip');
				assert.ok(tooltip && !tooltip.includes('fictional'), 'Credential validation must not echo input');
				await shot('credential-validation');
			}
			await input(f).fill(demo[f]);
			await input(f).blur();
		}
		const before = writes.length;
		await input('socks_port').fill('53');
		await save();
		await page.locator('#modal_overlay').filter({ hasText: tr('Save error') }).waitFor();
		assert.equal(writes.length, before);
		assert.ok(!(await page.locator('#modal_overlay').innerText()).includes('fictional'));
		await shot('validation-save-error');
		await page.getByRole('button', { name: tr('Dismiss'), exact: true }).click();
		await input('socks_port').fill(demo.socks_port);
		await save();
		await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		for (const [f, v] of Object.entries(demo)) assert.ok(values.main[f] === v, f + ' persisted independently');
		assert.equal(values.main.socks_enabled, '1'); assert.equal(values.main.http_enabled, '1');
		check(theme + ': valid Save persisted independent 10 main fields; invalid Save made no RPC writes');
		// Exercise the real SDK Changes indicator after the real form Save.
		await page.evaluate(async () => {
			const ui = await L.require('ui');
			await ui.changes.init();
			window.originalPreviewChanges = ui.changes.changes;
			window.originalPreviewChangesJSON = JSON.stringify(ui.changes.changes);
		});
		await page.locator('[data-indicator="uci-changes"]').click();
		await page.locator('.uci-change-list').waitFor();
		assert.ok(!(await page.locator('#modal_overlay').innerText()).includes('fictional'));
		assert.ok((await page.locator('.uci-change-list').innerText()).includes('********'));
		assert.ok(await page.evaluate(async () => {
			const ui = await L.require('ui');
			return ui.changes.changes === window.originalPreviewChanges &&
				JSON.stringify(ui.changes.changes) === window.originalPreviewChangesJSON &&
				ui.changes.changes.aetherproxy.filter(c => /^(socks|http)_(username|password)$/.test(c[2])).length === 4;
		}));
		await shot('changes-redacted');
		await page.getByRole('button', { name: tr('Close'), exact: true }).click();
		check(theme + ': Changes modal redacts all four credentials; original changes identity and values preserved');
		await tab();
		await input('socks_port').fill('1081');
		await flag('http_enabled').uncheck();
		await reset(); await tab();
		assert.equal(await input('socks_port').inputValue(), '1080');
		assert.equal(await flag('http_enabled').isChecked(), true);
		check(theme + ': Reset restores saved fields and flags');
		for (const only of ['socks', 'http']) {
			for (const p of ['socks', 'http']) await flag(p + '_enabled').setChecked(p === only);
			for (const [f, v] of Object.entries(demo).filter(([f]) => f.startsWith(only + '_'))) await input(f).fill(v);
			await save();
			await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
			assert.equal(values.main.socks_enabled, only === 'socks' ? '1' : '0');
			assert.equal(values.main.http_enabled, only === 'http' ? '1' : '0');
			await tab();
			assert.equal(await row((only === 'socks' ? 'http' : 'socks') + '_listen').isVisible(), false);
			await shot(only + '-only-saved');
			check(theme + ': ' + only + '-only Save persists flags and hides the other protocol');
		}
		await flag('socks_enabled').check();
		for (const [f, v] of Object.entries(demo)) await input(f).fill(v);
		await save();
		await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		await tab();
		assert.equal(values.main.socks_enabled, '1'); assert.equal(values.main.http_enabled, '1');
		await flag('socks_enabled').uncheck();
		await save();
		await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		assert.equal(values.main.socks_enabled, '0'); assert.equal(values.main.http_enabled, '1');
		check(theme + ': closing only SOCKS5 from both-on preserves HTTP enabled');
		await tab(); await flag('socks_enabled').check();
		for (const [f, v] of Object.entries(demo)) await input(f).fill(v);
		await save();
		await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		await tab();
		await page.setViewportSize({ width: 360, height: 1000 });
		await shot('both-enabled-360');
		await page.setViewportSize({ width: 1320, height: 1200 });
		rejectWrite = true;
		await input('socks_port').fill('1081'); await save();
		await page.locator('#modal_overlay').filter({ hasText: tr('Save error') }).waitFor();
		assert.equal(values.main.socks_port, '1080');
		await shot('rpc-save-error');
		await page.getByRole('button', { name: tr('Dismiss'), exact: true }).click();
		rejectWrite = false;
		await page.reload(); await tab();
		for (const p of ['socks', 'http']) await flag(p + '_enabled').uncheck();
		await save();
		await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
		assert.equal(values.main.socks_enabled, '0'); assert.equal(values.main.http_enabled, '0');
		check(theme + ': RPC failure surfaced without fixture mutation; disable Save writes both zero');
		assert.ok(loaded.has('resources/view/aether-proxy/advanced.js'));
		assert.ok(loaded.has('resources/aether-proxy/model/advanced.js'));
		assert.equal(errors.length, 2, 'Only the two deliberately induced save errors are allowed');
		assert.match(errors[0], /contains an invalid input value/);
		assert.match(errors[1], /RPC call to uci\/set failed with ubus code 9/);
		assert.ok(errors.every(e => !e.includes('fictional')), 'Save errors must not echo credentials');
		report.writes.push({ theme, calls: writes });
		report.rpc.push({ theme, methods: [...calls].sort() });
		report.assets.push({ theme, currentApp: [...loaded].sort() });
	} finally { await context.close(); }
}
(async () => {
	fs.mkdirSync(out, { recursive: true });
	const browser = await chromium.launch();
	try {
		for (const [theme, stylesheet] of Object.entries(themes)) await run(browser, theme, stylesheet);
		fs.writeFileSync(path.join(out, 'results.json'), JSON.stringify(report, null, 2) + '\n');
	} finally { await browser.close(); }
})().catch(error => { console.error(String(error.stack).replace(/fictional[^\s'"<>]*/g, '[REDACTED]')); process.exitCode = 1; });
