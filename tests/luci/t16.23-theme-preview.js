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
	['main', 'main', { node: 'n_a', failover_nodes: ['n_b', 'n_d', ...Array.from({ length: 7 }, (_, i) => `n_extra_${i}`)] }],
	['sub', 'sub', { failover: '0' }],
	['s_a', 'subscription', { name: '示例订阅', url: 'https://example.org/subscription' }],
	['s_b', 'subscription', { name: '备用订阅', url: 'https://example.net/subscription' }],
	['s_c', 'subscription', { name: '全选订阅', url: 'https://example.com/subscription' }],
	['n_a', 'node', { label: '手动 · 香港', source: 'manual', protocol: 'vless', security: 'reality' }],
	['n_b', 'node', { label: '订阅 · 东京', source: 's_a', protocol: 'vless', transport: 'ws', security: 'tls' }],
	['n_c', 'node', { label: '订阅 · 新加坡', source: 's_a', protocol: 'trojan', security: 'tls' }],
	['n_d', 'node', { label: '订阅 · 台北', source: 's_c', protocol: 'vless', security: 'tls' }],
	...Array.from({ length: 8 }, (_, i) => [`n_extra_${i}`, 'node',
		{ label: `订阅 · 示例 ${i + 1}`, source: 's_a', protocol: 'trojan', security: 'tls' }])
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
				colorScheme: dark ? 'dark' : 'light', reducedMotion: 'reduce', hasTouch: true, deviceScaleFactor: 2 });
			await page.route('**/*', async route => {
				const url = new URL(route.request().url());
				if (url.hostname !== 'luci.test')
					return route.abort();
				if (url.pathname === '/')
					return route.fulfill({ contentType: 'text/html', body: `<!doctype html>
<html lang="zh-Hans" data-darkmode="${dark}"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/luci-static/${stylesheet}">
${dark ? '<link rel="stylesheet" href="/luci-static/bootstrap/mobile.css">' : ''}
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
			const box = subscription.locator('[data-name="_failover"] .aether-tri').first();
			const dot = page.locator('.aether-node-current');
			assert.equal(await box.getAttribute('aria-checked'), 'mixed');
			assert.equal(await dot.count(), 1);
			const names = await page.locator('.aether-node-name > span:last-child').all();
			assert.equal(names.length, 12);
			const nameBoxes = await Promise.all(names.map(el => el.boundingBox()));
			const textBox = locator => locator.evaluate(el => {
				const range = document.createRange();
				range.selectNodeContents(el);
				return range.getBoundingClientRect().toJSON();
			});
			const nameHeader = await textBox(page.locator('.aether-node-name-title'));
			assert.ok(nameBoxes.every(rect => Math.abs(rect.x - nameHeader.x) < 1),
				'all node names start at the same x-coordinate as their header');
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
			assert.match(await box.getAttribute('title'), /半选 · 8\/10/);
			const cellStyle = prop => box.evaluate((el, p) => getComputedStyle(el.parentElement)[p], prop);
			assert.equal(await cellStyle('whiteSpace'), 'nowrap');
			assert.equal(await cellStyle('textAlign'), 'center');
			const tables = await page.locator('.table:has(.aether-failover-title)').all();
			assert.equal(tables.length, 2);
			for (const table of tables) {
				const cx = rect => rect.x + rect.width / 2;
				const heading = await textBox(table.locator('.aether-failover-title'));
				for (const control of await table.locator('[data-name="_failover"] .aether-tri').all())
					assert.ok(Math.abs(cx(await control.boundingBox()) - cx(heading)) < 1,
						`${theme}: failover controls share their heading's centerline`);
			}
			assert.deepEqual(await page.locator('#view h3').allTextContents(), ['通用设置', '订阅', '节点']);
			for (const toolbar of await page.locator('.aether-section-toolbar').all()) {
				const descr = await toolbar.locator(':scope > .cbi-map-descr').boundingBox();
				const firstButton = await toolbar.locator('button').first().boundingBox();
				assert.ok(descr.x + descr.width <= firstButton.x);
				assert.ok(Math.abs(descr.y + descr.height / 2 - firstButton.y - firstButton.height / 2) < 2,
					'the description and action buttons are centered on the same line');
			}
			const nodeTable = tables[1];
			assert.equal(await nodeTable.getByText('启用', { exact: true }).count(), 0);
			assert.equal(await nodeTable.locator('[data-name="_enabled"]').count(), 0);
			const result = subscription.locator('[data-name="_result"]').first();
			assert.equal(await result.textContent(), '尚未更新');
			assert.equal(await result.locator('br').count(), 0);
			assert.equal(await result.getByText('尚未更新', { exact: true })
				.evaluate(el => getComputedStyle(el).whiteSpace), 'nowrap');
			const inspect = locator => locator.evaluate(el => {
				const css = getComputedStyle(el.firstElementChild);
				const mark = getComputedStyle(el.children[1], '::after');
				const probe = el.appendChild(document.createElement('span'));
				probe.style.color = 'var(--background-color, Canvas)';
				const canvas = getComputedStyle(probe).color;
				probe.remove();
				return { fill: css.backgroundColor, gradient: css.backgroundImage, border: css.borderColor,
					box: [css.width, css.height, css.borderRadius, css.borderTopWidth],
					opacity: css.opacity, transition: css.transitionDuration, mark: mark.content,
					markFill: mark.backgroundColor, markBorder: mark.borderLeftColor,
					markWidth: mark.width, markHeight: mark.height, transform: mark.transform, canvas,
					count: el.querySelector('.aether-tri-count')?.textContent };
			});
			const warning = page.getByRole('button', { name: '自动切换风险说明' });
			const bubble = warning.locator('span');
			const checkWarning = async open => {
				assert.equal(await warning.getAttribute('aria-expanded'), String(open));
				assert.equal(await bubble.isVisible(), open);
				assert.equal(await flagInput.isChecked(), false);
			};
			await checkWarning(false);
			await warning.scrollIntoViewIfNeeded();
			const rect = await general.locator('..').locator('..').boundingBox();
			const clip = { x: Math.max(0, rect.x - 10), y: Math.max(0, rect.y - 5),
				width: Math.min(700, rect.width), height: 155 };
			if (dark)
				await page.screenshot({ path: path.join(out, 'warning-closed.png'), clip });
			await warning.tap();
			await checkWarning(true);
			if (dark)
				await page.screenshot({ path: path.join(out, 'warning-open.png'), clip });
			await warning.tap({ position: { x: 5, y: 5 } });
			await checkWarning(false);
			await warning.press('Enter');
			await checkWarning(true);
			await warning.press('Escape');
			await checkWarning(false);
			assert.equal(await cellStyle('opacity'), '0.65');
			await flagInput.click();
			await page.mouse.move(0, 0);
			assert.equal(await cellStyle('opacity'), '1');
			assert.doesNotMatch(await box.getAttribute('title'), /总开关未开启/);
			const offControl = subscription.locator('.aether-tri[aria-checked="false"]');
			const onControl = subscription.locator('.aether-tri[aria-checked="true"]');
			const off = await inspect(offControl);
			const on = await inspect(onControl);
			const mixed = await inspect(box);
			assert.deepEqual(off.box.slice(0, 3), ['17px', '17px', '4px']);
			assert.ok(['1px', '1.5px'].includes(off.box[3]), 'Chromium can round fractional borders');
			assert.equal(off.opacity, '0.55');
			assert.equal(off.transition, '0s');
			assert.equal(off.fill, 'rgba(0, 0, 0, 0)');
			assert.equal(off.gradient, 'none');
			assert.equal(off.mark, 'none');
			assert.equal(off.count, undefined);
			assert.equal(on.fill, on.border);
			assert.equal(on.markBorder, on.canvas);
			assert.notEqual(on.markBorder, on.fill);
			assert.deepEqual([on.markWidth, on.markHeight], ['9px', '5px']);
			assert.notEqual(on.transform, 'none');
			assert.equal(on.count, undefined);
			assert.equal(mixed.fill, off.fill);
			assert.equal(mixed.gradient, 'none');
			assert.equal(mixed.border, on.fill);
			assert.equal(mixed.markFill, on.fill);
			assert.deepEqual([mixed.markWidth, mixed.markHeight, mixed.count], ['9px', '2px', '8/10']);
			await offControl.hover();
			assert.equal((await inspect(offControl)).border, on.fill);
			await page.mouse.move(0, 0);
			await page.screenshot({ path: path.join(out, `tri-${theme}.png`) });
			await flagInput.click();
			assert.match(await box.getAttribute('title'), /总开关未开启/);
			await page.keyboard.press('Tab');
			await box.focus();
			assert.equal(await box.evaluate(el => getComputedStyle(el).outlineStyle), 'solid');
			await page.keyboard.press('Space');
			assert.equal(await box.getAttribute('aria-checked'), 'true');
			// A click in the cell padding and a real bubbled mark click each toggle exactly once.
			const current = nodeTable.locator('tr:has(.aether-node-current) .aether-tri');
			const currentCell = nodeTable.locator('tr:has(.aether-node-current) [data-name="_failover"]');
			await currentCell.click({ position: { x: 3, y: 3 } });
			assert.equal(await current.getAttribute('aria-checked'), 'true');
			await current.locator('.aether-tri-box').click();
			assert.equal(await current.getAttribute('aria-checked'), 'false');
			await subscription.locator('summary').click();
			assert.equal(await box.isVisible(), false);
			assert.equal(await page.getByRole('button', { name: '全部更新', exact: true }).isVisible(), true);
			await page.evaluate(async () => { await (await L.require('aether-proxy.subscriptions-block')).map.reset(); });
			assert.equal(await subscription.evaluate(el => el.open), false);
			await page.evaluate(async () => {
				const [uci, view] = await Promise.all([L.require('uci'), window.ready]);
				uci.set('aetherproxy', 'n_c', 'disabled', '1');
				await view.nodeMap.reset();
			});
			assert.equal(await nodeTable.locator('th').getByText('启用', { exact: true }).count(), 1);
			assert.deepEqual(await nodeTable.locator('[data-name="_enabled"]').allTextContents(), ['启用', '启用', '已停用', ...Array(9).fill('启用')]);
			for (const label of ['订阅 · 东京', '订阅 · 示例 1'])
				await nodeTable.locator('tr').filter({ hasText: label }).locator('.aether-tri').press('Enter');
			await page.setViewportSize({ width: 360, height: 800 });
			if (dark)
				assert.equal(await page.evaluate(() => matchMedia('(max-device-width: 600px)').matches), true);
			await subscription.locator('summary').click();
			const column = subscription.locator('th:has(.aether-failover-title)');
			const width = async () => (await column.boundingBox()).width;
			const narrowWidth = await width();
			assert.equal(await box.locator('.aether-tri-count').textContent(), '8/10');
			await box.press('Enter');
			assert.equal(await box.getAttribute('aria-checked'), 'true');
			assert.equal(await width(), narrowWidth, 'the narrow column reserves mixed-count width');
			for (const selector of ['.aether-subscription-scroll', '.aether-node-scroll']) {
				const scroll = page.locator(selector);
				const scrollMetrics = await scroll.evaluate(el => {
					el.scrollLeft = el.scrollWidth;
					return { client: el.clientWidth, width: el.scrollWidth, left: el.scrollLeft, viewport: window.innerWidth };
				});
				assert.ok(scrollMetrics.client <= scrollMetrics.viewport && scrollMetrics.width > scrollMetrics.client
					&& scrollMetrics.left > 0, `${theme}: ${selector} overflow is local (${JSON.stringify(scrollMetrics)})`);
				assert.equal(await scroll.locator('.cbi-section-table .tr').last()
					.evaluate(el => getComputedStyle(el).display), 'table-row');
				assert.equal(await scroll.locator('.cbi-section-table .th').first()
					.evaluate(el => getComputedStyle(el).display), 'table-cell');
			}
			assert.equal(await result.getByText('尚未更新', { exact: true })
				.evaluate(el => getComputedStyle(el).whiteSpace), 'nowrap');
			const css = await page.locator('#view style').evaluateAll(styles =>
				styles.find(style => style.textContent.includes('.aether-warning')).textContent);
			assert.match(css, /border: 1\.5px solid currentColor/);
			assert.doesNotMatch(css, /#(?:fff|ffffff|000|000000)\b|:\s*(?:white|black)\b/i);
			const fallback = await browser.newPage();
			await fallback.setContent(`<style>${css}</style><span class="aether-tri aether-tri--on">
				<span class="aether-tri-box"></span><span class="aether-tri-check"></span></span>`);
			const fallbackColors = await fallback.locator('.aether-tri').evaluate(el => {
				const swatch = document.createElement('span');
				swatch.style.cssText = 'color:Highlight;background:Canvas';
				document.body.appendChild(swatch);
				const defaults = getComputedStyle(swatch);
				return [getComputedStyle(el.firstElementChild).backgroundColor, defaults.color,
					getComputedStyle(el.children[1], '::after').borderLeftColor, defaults.backgroundColor];
			});
			assert.equal(fallbackColors[0], fallbackColors[1]);
			assert.equal(fallbackColors[2], fallbackColors[3]);
			await fallback.close();
			console.log(`PASS ${theme}: conditional column, single-line placeholder, narrow table scroll, existing alignment, three failover states, focus, Space, cell and mark clicks`);
			await page.close();
		}
	}
	finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
