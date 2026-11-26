'use strict';
/* Real SDK views and native indicator/modal. All transport is intercepted;
 * fixture pending state survives full navigation in the same browser session.
 * NODE_PATH=<playwright modules> node <this file> <SDK root/www> [output dir] [--expect-leak]
 * Default is the security acceptance gate (currently expected to fail).
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');
const [www, output] = process.argv.slice(2).filter(a => a !== '--expect-leak');
assert.ok(www, 'Supply an offline SDK root/www');
const out = output || path.join(__dirname, 'evidence/t16.111-cross-page');
const expectLeak = process.argv.includes('--expect-leak');
const sdk = path.resolve(www, 'luci-static');
const app = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static');
const messages = parsePo(fs.readFileSync(path.join(app, '../../po/zh_Hans/aether-proxy.po'), 'utf8'));
const tr = s => messages[s] || s;
const origin = 'http://luci.test';
const credentials = Object.fromEntries(['socks', 'http'].flatMap(p => ['username', 'password']
	.map(s => [p + '_' + s, 'fictional-cross-page-' + p + '-' + s])));
const initial = { main: { '.name': 'main', '.type': 'global', '.index': 0, lan_ifaces: ['br-lan'], port_scope: 'all', log_level: 'notice' },
	...Object.fromEntries(['dns', 'probe', 'stats'].map((s, i) => [s, { '.name': s, '.type': s, '.index': i + 1 }])) };
let committed = structuredClone(initial), pending = structuredClone(initial), changes = [], applies = 0, reverts = 0;
const results = { boundary: 'Offline SDK UI + in-memory HTTP/ubus fixtures only; no device, real apply, or raw credentials exported.', checks: [], navigations: [], summaries: [], writes: [] };
const check = name => { results.checks.push(name); console.log('PASS ' + name); };
const shell = advanced => `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="/luci-static/bootstrap/cascade.css">
<script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script></head>
<body><div id="indicators"></div><div id="maincontent"><div id="view"></div></div><script>
const messages=${JSON.stringify(messages).replace(/</g, '\\u003c')};window._=s=>messages[s]||s;
window.L=new LuCI({scriptname:'/cgi-bin/luci',resource:'/luci-static/resources',base_url:'/luci-static/resources',media:'/luci-static/bootstrap',
ubuspath:'/ubus',sessionid:'00000000000000000000000000000000',nodespec:{satisfied:true,readonly:false},
apply_holdoff:0,apply_timeout:5,apply_rollback:30,apply_display:3600});
window.ready=L.require('${advanced ? 'view.aether-proxy.advanced' : 'view.system.reboot'}');</script></body></html>`;
const fixtures = {
	'session.access': () => ({ access: true }), 'luci.getFeatures': () => ({}), 'luci.getInitList': () => ({}),
	'uci.get': ({ config }) => ({ values: config === 'aetherproxy' ? pending : {} }),
	'uci.changes': () => ({ changes: changes.length ? { aetherproxy: changes } : {} }),
	'uci.set': ({ config, section, values }) => {
		assert.ok(config === 'aetherproxy', 'Only fixture configuration may be saved');
		Object.assign(pending[section], values);
		for (const [field, value] of Object.entries(values)) changes.push(['set', section, field, value]);
		results.writes.push({ section, fields: Object.keys(values).sort() });
		return {};
	},
	'network.get_proto_handlers': () => ({}), 'network.interface.dump': () => ({ interface: [] }),
	'luci-rpc.getBoardJSON': () => ({}), 'luci-rpc.getHostHints': () => ({}),
	'luci-rpc.getNetworkDevices': () => ({ 'br-lan': { name: 'br-lan', devtype: 'bridge', up: true } })
};
(async () => {
	fs.mkdirSync(out, { recursive: true });
	const browser = await chromium.launch();
	const context = await browser.newContext({ serviceWorkers: 'block' });
	let navigation, page;
	const errors = [];
	try {
		await context.route('**/*', async route => {
			const req = route.request(), url = new URL(req.url());
			assert.ok(url.origin === origin, 'External request forbidden');
			if (url.pathname === '/advanced' || url.pathname === '/unrelated')
				return route.fulfill({ contentType: 'text/html', body: shell(url.pathname === '/advanced') });
			if (url.pathname === '/cgi-bin/luci/admin/uci/apply_rollback') {
				assert.ok(req.method() === 'POST', 'Native apply uses POST');
				committed = structuredClone(pending); changes = []; applies++;
				return route.fulfill({ json: { token: 'fixture-only' } });
			}
			if (url.pathname === '/cgi-bin/luci/admin/uci/confirm') return route.fulfill({ status: 200, body: '' });
			if (url.pathname === '/cgi-bin/luci/admin/uci/revert') {
				assert.ok(req.method() === 'POST', 'Native revert uses POST');
				pending = structuredClone(committed); changes = []; reverts++;
				return route.fulfill({ status: 200, body: '' });
			}
			if (url.pathname === '/cgi-bin/cgi-exec') {
				const params = new URLSearchParams(req.postData());
				assert.ok(params.get('command') === '/usr/libexec/luci-peeraddr', 'Only fixture connectivity probe allowed');
				return route.fulfill({ json: {} });
			}
			if (url.pathname === '/ubus') {
				const reply = call => {
					if (call.method === 'list') return { jsonrpc: '2.0', id: call.id, result: {} };
					const [, object, method, params] = call.params, key = `${object}.${method}`;
					assert.ok(fixtures[key], 'Missing RPC fixture: ' + key);
					return { jsonrpc: '2.0', id: call.id, result: [0, fixtures[key](params || {})] };
				};
				const data = req.postDataJSON();
				return route.fulfill({ json: Array.isArray(data) ? data.map(reply) : reply(data) });
			}
			if (url.pathname.startsWith('/luci-static/')) {
				const name = url.pathname.slice('/luci-static/'.length);
				const file = [path.join(app, name), path.join(sdk, name)].find(f => fs.statSync(f, { throwIfNoEntry: false })?.isFile());
				assert.ok(file, 'Missing local asset: ' + name);
				navigation.assets.push(name);
				return route.fulfill({ path: file });
			}
			throw new Error('Unexpected local request: ' + url.pathname);
		});
		page = await context.newPage(); page.setDefaultTimeout(8000);
		page.on('pageerror', () => errors.push('pageerror'));
		async function goto(kind) {
			navigation = { page: kind, assets: [] }; results.navigations.push(navigation);
			await page.goto(origin + '/' + kind);
			await page.evaluate(() => window.ready.then(() => null));
		}
		async function saveAdvanced(overrides = {}) {
			await goto('advanced');
			await page.locator('.cbi-tabmenu a').filter({ hasText: tr('LAN explicit proxy') }).click();
			const row = f => page.locator(`[data-name="${f}"]`);
			for (const p of ['socks', 'http']) await row(p + '_enabled').locator('input[type=checkbox]').check();
			const values = { socks_listen: '192.0.2.1', http_listen: '192.0.2.1', socks_port: '1080', http_port: '8080', ...credentials, ...overrides };
			for (const [field, value] of Object.entries(values)) await row(field).locator('input').first().fill(value);
			const count = results.writes.length;
			await page.locator('.cbi-page-actions .cbi-button-save').click();
			await page.waitForFunction(() => !document.querySelector('.cbi-page-actions .cbi-button-save').disabled);
			assert.ok(results.writes.length > count, 'Save reached fixture UCI');
		}
		async function openUnrelatedSummary(stage) {
			await goto('unrelated'); // Full document navigation, not L.require inside the advanced document.
			assert.ok(navigation.assets.includes('resources/view/system/reboot.js'), 'Unmodified system view loaded');
			assert.ok(!navigation.assets.some(s => s.includes('aether-proxy')), 'Fresh unrelated page loaded no application modules');
			await page.getByRole('button', { name: 'Perform reboot', exact: true }).waitFor(); // Never clicked.
			await page.locator('[data-indicator="uci-changes"]').click();
			await page.locator('.uci-change-list').waitFor();
			const text = await page.locator('#modal_overlay .uci-change-list').innerText();
			const exposedFields = Object.keys(credentials).filter(k => text.includes(pending.main[k]));
			assert.ok(text.includes(pending.main.socks_port) && text.includes(pending.main.http_port), 'Ordinary port values remain readable');
			results.summaries.push({ stage, exposedFields, ordinaryFieldsReadable: true, actualModalDOMInspected: true });
			check(stage + ': clicked native indicator on fresh system/reboot page; ordinary fields readable');
			return exposedFields;
		}
		await saveAdvanced();
		assert.ok(applies === 0 && reverts === 0 && !committed.main.socks_password && !committed.main.http_password, 'Save did not commit/apply');
		for (const [field, value] of Object.entries(credentials)) assert.ok(pending.main[field] === value, field + ' retained in pending fixture');
		check('Advanced Save stages both protocols without applying');
		const exposed = await openUnrelatedSummary('before-apply');
		console.log('OBSERVED exposed credential field count=' + exposed.length + ' (values not exported)');
		// Click the actual modal button; no direct displayChanges/apply invocation.
		await page.locator('#modal_overlay .cbi-dropdown.cbi-button-positive').click({ position: { x: 10, y: 10 } });
		await page.waitForFunction(() => document.querySelector('#modal_overlay')?.textContent.includes('Configuration changes applied.'));
		assert.ok(applies === 1 && changes.length === 0, 'Native apply consumed pending fixture');
		for (const [field, value] of Object.entries(credentials)) assert.ok(committed.main[field] === value, field + ' applied original value');
		check('Native modal Save & Apply uses original values for all four credentials in fixture');
		const baseline = JSON.stringify(committed);
		await saveAdvanced({ socks_port: '1081', http_port: '8081', socks_password: 'fictional-cross-page-replacement-socks', http_password: 'fictional-cross-page-replacement-http' });
		await openUnrelatedSummary('before-revert');
		await page.locator('#modal_overlay').getByRole('button', { name: 'Revert', exact: true }).click();
		await page.waitForFunction(() => document.querySelector('#modal_overlay')?.textContent.includes('Changes have been reverted.'));
		assert.ok(reverts === 1 && changes.length === 0 && JSON.stringify(pending) === baseline && JSON.stringify(committed) === baseline, 'Revert restored fixture and did not commit replacements');
		check('Native modal Revert discards staged replacements and preserves applied originals');
		await goto('unrelated');
		assert.ok(await page.locator('[data-indicator="uci-changes"]').count() === 0, 'Reverted changes absent after full reload');
		assert.ok(errors.length === 0, 'No browser page errors');
		check('Native indicator gone after revert and full reload');
		results.securityAcceptance = exposed.length === 0 ? 'PASS' : 'FAIL';
		results.expectedLeakReproduced = exposed.length === 4;
		fs.writeFileSync(path.join(out, 'results.json'), JSON.stringify(results, null, 2) + '\n');
		if (expectLeak) assert.ok(exposed.length === 4, 'Expected baseline cross-page exposure of four credentials');
		else assert.ok(exposed.length === 0, 'SECURITY FAIL: fresh unrelated page exposes inbound credentials in actual Changes DOM');
	} finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(String(error.message).replace(/fictional[^\s'"<>]*/g, '[REDACTED]')); process.exitCode = 1; });
