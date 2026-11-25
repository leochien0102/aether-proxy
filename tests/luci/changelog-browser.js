'use strict';
// Optional offline browser evidence: NODE_PATH=<existing playwright install> node ... <unpacked resources> <output dir>
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');
const root = path.resolve(__dirname, '../..');
const resources = process.argv[2];
const out = process.argv[3];
if (!resources || !out) throw new Error('expected unpacked resources and output directory');
fs.mkdirSync(out, { recursive: true });
const sources = Object.fromEntries(['aether-proxy/changelog.js', 'aether-proxy/model/updates.js', 'view/aether-proxy/updates.js']
	.map(file => [file, fs.readFileSync(path.join(resources, file), 'utf8')]));
const po = parsePo(fs.readFileSync(path.join(root, 'luci-app-aether-proxy/po/zh_Hans/aether-proxy.po'), 'utf8'));
(async () => {
	const browser = await chromium.launch({ headless: true });
	try {
		const context = await browser.newContext({ viewport: { width: 360, height: 900 }, offline: true });
		const page = await context.newPage();
		let requests = 0;
		page.on('request', () => requests++);
		await page.setContent('<!doctype html><meta charset="utf-8"><style>body{margin:12px;font:14px sans-serif}table{width:100%;border-collapse:collapse}td,th{padding:6px;text-align:left}button{white-space:nowrap}details{padding:8px}summary{cursor:pointer}li{margin:8px 0}@media(max-width:600px){tr{display:block;border-bottom:1px solid #ddd}td,th{display:block}tr:first-child{display:none}}</style><main></main>');
		await page.evaluate(async ({ sources, po }) => {
			window._ = s => po[s] ?? s;
			String.prototype.format = function(...args) { let i = 0; return this.replace(/%s/g, () => args[i++]); };
			window.E = (tag, attrs = {}, children = []) => {
				const node = document.createElement(tag);
				for (const [key, value] of Object.entries(attrs)) {
					if (value == null || value === false) continue;
					if (typeof value === 'function') node.addEventListener(key, value);
					else node.setAttribute(key, value === true ? '' : value);
				}
				for (const child of Array.isArray(children) ? children : [children])
					node.append(child instanceof Node ? child : document.createTextNode(String(child)));
				return node;
			};
			const baseclass = { extend: o => o };
			const changelog = new Function('baseclass', sources['aether-proxy/changelog.js'])(baseclass);
			const model = new Function('baseclass', sources['aether-proxy/model/updates.js'])(baseclass);
			const form = { Map: class {
				section() { return { option: () => ({ value() {} }) }; }
				render() { return Promise.resolve(E('h2', {}, '更新策略（表单桩）')); }
			} };
			const ap = { form_section() {}, section: s => E('section', {}, [
				...(s.title ? [E('h3', {}, s.title)] : []), ...(s.body ?? [])]) };
			const defaults = { integer() {}, section() {} };
			const view = new Function('view', 'form', 'form_defaults', 'ui', 'ap', 'model', 'changelog',
				sources['view/aether-proxy/updates.js'])(baseclass, form, defaults,
				{ createHandlerFn: (self, fn) => fn.bind(self) }, ap, model, changelog);
			// Keep the existing deferred status request local and deterministic.
			const timer = window.setTimeout;
			window.setTimeout = () => 0;
			const dom = await view.render();
			window.setTimeout = timer;
			view.status = { updates_available: { packages: Object.fromEntries(
				['aether-proxy', 'aether-xray', 'luci-app-aether-proxy'].map(name => [name,
					{ installed: '1.2.2-r10', available: '1.3.0-r1', newer: true, asset: 'test.ipk' }])) } };
			view.show_inventory();
			document.querySelector('main').append(dom);
			dom.lastChild.open = true;
			window.fixture = { changelog, view };
		}, { sources, po });
		const evidence = await page.evaluate(() => {
			const link = document.querySelector('a[href$="v1.3.0-r1"]');
			const button = link.parentNode.querySelector('button');
			const a = link.getBoundingClientRect(), b = button.getBoundingClientRect();
			if (a.top < b.bottom || b.width < 60 || document.documentElement.scrollWidth > 360)
				throw new Error('narrow-screen button/link layout failed');
			return { width: innerWidth, scrollWidth: document.documentElement.scrollWidth,
				button: { x: b.x, y: b.y, width: b.width, height: b.height },
				link: { x: a.x, y: a.y, width: a.width, height: a.height },
				links: [...document.querySelectorAll('a')].map(a => a.href),
				text: document.querySelector('main').innerText };
		});
		if (requests) throw new Error(`unexpected network requests: ${requests}`);
		fs.writeFileSync(path.join(out, 'offline-360-dom.json'), JSON.stringify({ requests, ...evidence }, null, 2));
		fs.writeFileSync(path.join(out, 'offline-360.html'), await page.content());
		await page.screenshot({ path: path.join(out, 'offline-360.png'), fullPage: true });
		console.log('PASS offline actual packaged view/data: zero requests; 360px no overflow; link below unchanged button');
	} finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
