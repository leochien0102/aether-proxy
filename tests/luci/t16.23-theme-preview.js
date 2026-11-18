'use strict';
/* Offline visual check with a built OpenWrt root and Playwright/Chromium.
 * NODE_PATH=<Playwright node_modules> node tests/luci/t16.23-theme-preview.js <root/www> <output dir>
 * The real LuCI SDK and theme assets render the app; only backend data is mocked.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');
const [www, out] = process.argv.slice(2).map(p => path.resolve(p));
const app = path.resolve(__dirname, '../../luci-app-aether-proxy');
const messages = parsePo(fs.readFileSync(path.join(app, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const staticRoot = path.join(www, 'luci-static');
const themePaths = { 'bootstrap-dark': 'bootstrap/cascade.css', 'argon-light': 'argon-plus/css/cascade.css' };
const entries = [
	['main', 'main', { node: 'n_a', failover_nodes: ['n_b'] }],
	['sub', 'sub', { failover: '0' }],
	['s_a', 'subscription', { name: '示例订阅', url: 'https://example.org/subscription' }],
	['s_b', 'subscription', { name: '备用订阅', url: 'https://example.net/subscription' }],
	['n_a', 'node', { label: '手动 · 香港', source: 'manual', protocol: 'vless', security: 'reality' }],
	['n_b', 'node', { label: '订阅 · 东京', source: 's_a', protocol: 'vless', transport: 'ws', security: 'tls' }],
	['n_c', 'node', { label: '订阅 · 新加坡', source: 's_a', protocol: 'trojan', security: 'tls' }]
];
const values = Object.fromEntries(entries.map(([id, type, options], index) =>
	[id, { '.name': id, '.type': type, '.index': index, ...options }]));

(async () => {
	const browser = await chromium.launch();
	fs.mkdirSync(out, { recursive: true });
	try {
		for (const [theme, stylesheet] of Object.entries(themePaths)) {
			const dark = theme === 'bootstrap-dark';
			const page = await browser.newPage({ viewport: { width: 1320, height: 1200 },
				colorScheme: dark ? 'dark' : 'light', reducedMotion: 'reduce' });
			await page.route('**/*', async route => {
				const url = new URL(route.request().url());
				if (url.hostname !== 'luci.test')
					return route.abort();
				if (url.pathname === '/')
					return route.fulfill({ contentType: 'text/html', body: `<!doctype html>
<html lang="zh-Hans" data-darkmode="${dark}"><meta charset="utf-8">
<link rel="stylesheet" href="/luci-static/${stylesheet}">
<script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script>
<body class="lang_zh-cn" data-page="admin-services-aether-proxy-nodes"><main class="main">
<div class="main-right"><div id="maincontent" class="container"><div class="container" id="view"></div></div></div>
</main><script>
const messages = ${JSON.stringify(messages).replace(/</g, '\\u003c')};
window._ = key => Object.hasOwn(messages, key) ? messages[key] : key === 'This section contains no values yet' ? '暂无记录' : key;
window.L = new LuCI({ scriptname: '/cgi-bin/luci', resource: '/luci-static/resources',
  base_url: '/luci-static/resources', media: '/luci-static/${stylesheet.split('/')[0]}',
  ubuspath: '/ubus', sessionid: '00000000000000000000000000000000',
  nodespec: { satisfied: true, readonly: false } });
window.ready = Promise.all(['uci', 'aether-proxy.common'].map(m => L.require(m)))
.then(([uci, ap]) => {
  uci.state.values.aetherproxy = ${JSON.stringify(values)};
  uci.changes = async () => ({});
  ap.call = async method => method === 'version' ? { ok: true, version: '1.2.0' }
    : method === 'sub_status' ? { ok: true, subs: {} } : { ok: true, finished: true, done: 0, total: 0, nodes: {} };
  return L.require('view.aether-proxy.nodes');
});
</script>` });
				if (url.pathname === '/ubus' || url.pathname.startsWith('/cgi-bin')) {
					const request = route.request().postDataJSON();
					const reply = call => ({ jsonrpc: '2.0', id: call?.id ?? 0,
						result: [0, call?.params?.[1] === 'session' ? { access: true } : {}] });
					return route.fulfill({ json: Array.isArray(request) ? request.map(reply) : reply(request) });
				}
				const name = url.pathname.replace(/^\/luci-static\//, '');
				const source = [path.join(app, 'htdocs/luci-static', name), path.join(staticRoot, name)]
					.find(file => fs.existsSync(file) && fs.statSync(file).isFile());
				return source ? route.fulfill({ path: source }) : route.fulfill({ status: 404 });
			});
			page.on('pageerror', error => console.error(error));
			page.setDefaultTimeout(5000);
			await page.goto('http://luci.test/');
			await page.evaluate(() => window.ready.then(() => null));
			await page.locator('.aether-node-current').waitFor({ timeout: 5000 });
			await page.evaluate(() => document.fonts.ready.then(() => null));
			const subscription = page.locator('details.aether-subscription-list');
			const box = subscription.locator('[data-name="_failover"] input').first();
			const dot = page.locator('.aether-node-current');
			assert.equal(await box.evaluate(el => el.indeterminate), true);
			assert.equal(await dot.count(), 1);
			const names = await page.locator('.aether-node-name > span:last-child').all();
			assert.equal(names.length, 3);
			const nameBoxes = await Promise.all(names.map(el => el.boundingBox()));
			assert.ok(nameBoxes.every(rect => Math.abs(rect.x - nameBoxes[0].x) < 1),
				'all node names start at the same x-coordinate');
			const mark = await dot.boundingBox();
			assert.ok(mark.x + mark.width < nameBoxes[0].x, 'the marker occupies its own gutter');
			const general = page.locator('.aether-failover-setting');
			const flagInput = general.locator('input[type="checkbox"]');
			const flag = await flagInput.boundingBox();
			const help = await general.locator(':scope > span:last-child').boundingBox();
			assert.ok(flag.x + flag.width < help.x);
			assert.ok(Math.abs(flag.y + flag.height / 2 - help.y - help.height / 2) < 2,
				`${theme}: the inline explanation follows its checkbox on the same line (${JSON.stringify({ flag, help })})`);
			assert.equal(await dot.evaluate(el => getComputedStyle(el).animationName), 'none');
			assert.match(await box.getAttribute('title'), /半选 · 1\/2/);
			const cellStyle = prop => box.evaluate((el, p) => getComputedStyle(el.parentElement)[p], prop);
			assert.equal(await cellStyle('whiteSpace'), 'nowrap');
			assert.equal(await cellStyle('textAlign'), 'left');
			assert.equal(await box.evaluate(el => getComputedStyle(el).appearance), 'auto');
			assert.deepEqual(await page.locator('#view h3').allTextContents(), ['通用设置', '订阅', '节点']);
			for (const toolbar of await page.locator('.aether-section-toolbar').all()) {
				const descr = await toolbar.locator(':scope > .cbi-map-descr').boundingBox();
				const firstButton = await toolbar.locator('button').first().boundingBox();
				assert.ok(descr.x + descr.width <= firstButton.x);
				assert.ok(Math.abs(descr.y + descr.height / 2 - firstButton.y - firstButton.height / 2) < 2,
					'the description and action buttons are centered on the same line');
			}
			await page.screenshot({ path: path.join(out, `${theme}.png`), fullPage: true });
			await flagInput.click();
			assert.doesNotMatch(await box.getAttribute('title'), /总开关未开启/);
			await flagInput.click();
			assert.match(await box.getAttribute('title'), /总开关未开启/);
			await box.click();
			assert.equal(await box.isChecked(), true);
			assert.equal(await box.evaluate(el => el.indeterminate), false);
			await subscription.locator('summary').click();
			assert.equal(await box.isVisible(), false);
			assert.equal(await page.getByRole('button', { name: '全部更新', exact: true }).isVisible(), true);
			await page.evaluate(async () => { await (await L.require('aether-proxy.subscriptions-block')).map.reset(); });
			assert.equal(await subscription.evaluate(el => el.open), false);
			console.log(`PASS ${theme}: aligned node names, inline Flag explanation, shared toolbar line, collapsible list, native mixed → checked`);
			await page.close();
		}
	}
	finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
