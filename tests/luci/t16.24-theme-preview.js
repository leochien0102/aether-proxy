'use strict';
/* Offline desktop evidence; requires a built OpenWrt root, Playwright, Chromium,
 * and a Chinese system font. No local web server or router is used.
 * NODE_PATH=<Playwright node_modules> node tests/luci/t16.24-theme-preview.js <root/www> [output dir]
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');

const [www, out = path.join(__dirname, 'evidence/t16.24')] = process.argv.slice(2);
assert.ok(www, 'Supply the <root/www> containing the LuCI SDK and both themes.');
const staticRoot = path.resolve(www, 'luci-static');
const app = path.resolve(__dirname, '../../luci-app-aether-proxy');
const appStatic = path.join(app, 'htdocs/luci-static');
const messages = parsePo(fs.readFileSync(path.join(app, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const tr = key => messages[key] || key;
const themes = { 'bootstrap-dark': 'bootstrap/cascade.css', 'argon-light': 'argon-plus/css/cascade.css' };
const pages = { overview: 'Aether Proxy', access: 'Access Control', rules: 'Rules and DNS',
	advanced: 'Advanced', updates: 'Updates', logs: 'Logs' };
for (const asset of ['resources/luci.js', 'resources/cbi.js', 'bootstrap/mobile.css', ...Object.values(themes)])
	assert.ok(fs.existsSync(path.join(staticRoot, asset)), `Missing built asset: ${asset}`);

const origin = 'http://luci.test';
const now = new Date('2026-11-19T02:00:00Z');
const time = now.getTime() / 1000;
const macLaptop = '02:00:00:00:00:10';
const macPhone = '02:00:00:00:00:11';
function uciValues(entries) {
	return Object.fromEntries(entries.map(([id, type, options], index) =>
		[id, { '.name': id, '.type': type, '.index': index, ...options }]));
}
const configs = {
	aetherproxy: uciValues([
		['main', 'global', { enabled: '1', mode: 'bypass_cn', node: 'n_tokyo', unlisted_policy: 'follow',
			lan_ifaces: ['br-lan'], port_scope: 'common_extra', extra_ports: '8080, 5000-5002', log_level: 'notice' }],
		['dns', 'dns', { china_dns: ['wan', '114.114.114.114'], trust_dns: ['tcp://8.8.8.8', 'udp://1.1.1.1'] }],
		['probe', 'probe', {}],
		['update', 'update', { xray_auto: 'notify', data_auto: '1' }],
		['stats', 'stats', { heatmap_enabled: '1' }],
		['n_tokyo', 'node', { label: '示例 · 东京', source: 'manual', protocol: 'vless' }],
		['n_taipei', 'node', { label: '示例 · 台北', source: 's_demo', protocol: 'trojan' }],
		['s_demo', 'subscription', { name: '示例订阅', url: 'https://subscription.example/' }],
		['h_laptop', 'host', { name: '工作笔记本', enabled: '1', policy: 'proxy', mac: [macLaptop], udp: '1' }],
		['h_phone', 'host', { name: '家庭手机', enabled: '1', policy: 'direct', mac: [macPhone] }],
		['h_tv', 'host', { name: '客厅电视', enabled: '0', policy: 'direct', ip: ['192.0.2.23'] }]
	]),
	network: uciValues([['lan', 'interface', { proto: 'static', device: 'br-lan' }]])
};
const components = {
	xray: { found: true, version: '26.10.21', installed: '26.10.21-r1', path: '/usr/bin/aether-xray' },
	dns: { found: true, version: '2026.10.1', path: '/usr/bin/chinadns-ng' }
};
const status = { ok: true, state: 'running', since: time - 8340, node_id: 'n_tokyo', node_ip: '203.0.113.18',
	mode: 'bypass_cn', dns_tier: 'T1', wan_dns: ['192.0.2.53'], components,
	last_probe: { ok: true, at: time - 37, latency_ms: 47 }, updates_available: {
		checked: time - 3600, arch: 'aarch64_generic', url: 'https://updates.example/stable/', packages: {
			'aether-xray': { installed: '26.10.21-r1', available: '26.11.1-r1', previous: '26.9.30-r1', asset: 'aether-xray.ipk', newer: true },
			...Object.fromEntries(['aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'].map(name =>
				[name, { installed: '1.2.0-r5', available: '1.2.0-r5', asset: `${name}.ipk`, newer: false }]))
		}
	} };
const datasets = [['gfwlist', 9482], ['chnlist', 11951], ['apple', 3055], ['chnroute4', 6184], ['gfw_static4', 32]];
const lists = { direct_domain: 'nas.example\nintranet.example\n', proxy_domain: 'media.example\n',
	direct_ip: '192.0.2.0/24\n', proxy_ip: '203.0.113.0/24\n' };
const events = [
	{ ts: time - 8340, level: 'notice', code: 'SERVICE_STARTED', params: { elapsed_ms: 412, mode: 'bypass_cn' } },
	{ ts: time - 4000, level: 'notice', code: 'NODE_SWITCHED', params: { from: 'n_taipei', to: 'n_tokyo' } },
	{ ts: time - 400, level: 'notice', code: 'SUB_UPDATED', params: { sub: 's_demo', nodes: 2 } }
];
const proxy = { tx_bytes: 596_202_399, rx_bytes: 2_948_091_277 };
const rpcFixtures = {
	'session.access': () => ({ access: true }),
	'luci.getFeatures': () => ({}),
	'luci.getInitList': () => ({}),
	'uci.get': ({ config }) => ({ values: configs[config] ?? {} }),
	'uci.changes': () => ({ changes: {} }),
	'network.get_proto_handlers': () => ({}),
	'network.interface.dump': () => ({ interface: [{ interface: 'lan', proto: 'static', device: 'br-lan', l3_device: 'br-lan', up: true }] }),
	'luci-rpc.getBoardJSON': () => ({}),
	'luci-rpc.getNetworkDevices': () => ({ 'br-lan': { name: 'br-lan', devtype: 'bridge', up: true,
		macaddr: '02:00:00:00:00:01', ipaddrs: [{ address: '192.0.2.1', netmask: '255.255.255.0' }] } }),
	'luci-rpc.getHostHints': () => ({ [macLaptop]: { name: 'work-laptop', ipaddrs: ['192.0.2.10'] },
		[macPhone]: { name: 'home-phone', ipaddrs: ['192.0.2.11'] } }),
	'aetherproxy.version': () => ({ ok: true, version: '1.2.0-r5' }),
	'aetherproxy.status': () => status,
	'aetherproxy.components': () => ({ ok: true, components }),
	'aetherproxy.probe_sites': () => ({ ok: true, sites: [{ name: 'demo', label: '示例站点' }] }),
	'aetherproxy.stats': () => ({ ok: true, at_ms: now.getTime(), proxy,
		wan: { dev: 'eth0', tx_bytes: 802_977_864, rx_bytes: 4_511_420_408 }, connections: { proxy: 23, total: 49 } }),
	'aetherproxy.stats_history': () => ({ ok: true, enabled: true, updated_at: time, days:
		Array.from({ length: 45 }, (_, i) => ({ date: new Date(now.getTime() - (44 - i) * 86400000).toISOString().slice(0, 10),
			tx: (i % 7 + 1) * 31000000, rx: (i % 13 + 1) * 91000000, observed: 86400, healthy: i % 11 ? 86400 : 82200 })) }),
	'aetherproxy.data_status': () => ({ ok: true, checked: time - 3600,
		items: Object.fromEntries(datasets.map(([name, lines], i) => [name, { lines,
			source: i === 4 ? 'baseline' : 'downloaded', version: `2026.11.${18 - i}`, updated_at: time - 86400, changed: i === 0 }])) }),
	'aetherproxy.list_file': ({ name }) => ({ ok: true, content: lists[name] }),
	'aetherproxy.events': () => ({ ok: true, events }),
};

function shell(view, stylesheet, dark) {
	return `<!doctype html>
<html lang="zh-Hans" data-darkmode="${dark}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="/luci-static/${stylesheet}">
${dark ? '<link rel="stylesheet" href="/luci-static/bootstrap/mobile.css">' : ''}
<script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script>
</head><body class="lang_zh-cn" data-page="admin-services-aether-proxy-${view}"><main class="main">
<div class="main-right"><div id="maincontent" class="container"><div class="container" id="view"></div></div></div>
</main><script>
const messages = ${JSON.stringify(messages).replace(/</g, '\\u003c')};
window._ = key => Object.hasOwn(messages, key) ? messages[key] : key;
window.L = new LuCI({ scriptname: '/cgi-bin/luci', resource: '/luci-static/resources',
  base_url: '/luci-static/resources', media: '/luci-static/${stylesheet.split('/')[0]}',
  ubuspath: '/ubus', sessionid: '00000000000000000000000000000000',
  nodespec: { satisfied: true, readonly: false } });
window.ready = L.require('view.aether-proxy.${view}');
</script></body></html>`;
}

async function verify(page, view) {
	const ready = {
		overview: ['#view td', '/usr/bin/aether-xray'],
		access: ['#view tr[data-sid="h_laptop"]', '工作笔记本'],
		rules: ['#view td', '2026.11.18'],
		advanced: ['#view .cbi-section', '8080, 5000-5002'],
		updates: ['#view td', '26.11.1-r1'],
		logs: ['#view td', 'SERVICE_STARTED'],
	};
	const [selector, text] = ready[view];
	if (view === 'advanced') {
		const input = page.locator('[data-name="extra_ports"] input');
		await input.waitFor();
		assert.equal(await input.inputValue(), text);
	} else {
		await page.locator(selector).filter({ hasText: text }).first().waitFor();
	}
	const root = page.locator('#view');
	const heading = root.getByRole('heading', { name: tr(pages[view]), exact: true, level: 2 });
	await heading.waitFor();
	assert.equal(await heading.evaluate(el => Boolean(el.closest('.cbi-section'))), false);
	assert.equal(await root.locator('.cbi-map-descr:not(.cbi-section > .cbi-map-descr)').count(), 0);
	assert.equal(await root.locator('.aether-section-actions:not(.cbi-section > .aether-section-actions)').count(), 0);
	if (view === 'logs') {
		const row = root.locator('.aether-section-actions');
		assert.deepEqual(await row.locator('button').allTextContents(),
			['Events', 'Raw logs', 'Clear logs', 'Truncate to last startup'].map(tr));
	}
	const rowCounts = { overview: 3, access: 3, rules: 5, updates: 4, logs: 3 };
	if (view in rowCounts) {
		const table = root.locator('table').filter({ has: page.locator('td').filter({ hasText: text }) });
		assert.equal(await table.locator('tr:has(td):visible').count(), rowCounts[view], `${view}: rendered data rows`);
		if (view === 'rules' && page.viewportSize().height > 1200)
			assert.ok(await table.evaluate(el => el.getBoundingClientRect().bottom <= window.innerHeight),
				'Argon’s inner scroller must fit the rule-data table in the captured viewport');
	}
	if (view === 'rules') {
		const list = root.locator('[data-tab="direct_domain"][data-tab-active="true"] textarea');
		assert.equal(await list.inputValue(), lists.direct_domain);
	}
	if (view === 'overview')
		await root.locator('.ap-heat-grid').waitFor();
}

async function capture(browser, theme, stylesheet, view) {
	const dark = theme === 'bootstrap-dark';
	// Argon uses an inner scroller; its tall Rules page needs a larger viewport
	// since fullPage only expands the document's own scroll area.
	const height = !dark && view === 'rules' ? 2000 : 1200;
	const context = await browser.newContext({ viewport: { width: 1320, height }, deviceScaleFactor: 1,
		colorScheme: dark ? 'dark' : 'light', reducedMotion: 'reduce', locale: 'zh-CN',
		timezoneId: 'Asia/Shanghai', serviceWorkers: 'block' });
	const errors = [];
	const requests = new Set();
	try {
		await context.route('**/*', async route => {
			const request = route.request();
			const url = new URL(request.url());
			if (url.origin !== origin) {
				errors.push(`Blocked non-preview URL ${url.href}`);
				return route.abort();
			}
			if (url.pathname === '/')
				return route.fulfill({ contentType: 'text/html', body: shell(view, stylesheet, dark) });
			if (url.pathname === '/ubus') {
				const data = request.postDataJSON();
				const reply = call => {
					if (call.method === 'list')
						return { jsonrpc: '2.0', id: call.id, result: {} };
					const [, object, method, params] = call.params;
					const key = `${object}.${method}`;
					const fixture = rpcFixtures[key];
					requests.add(key);
					if (!fixture) {
						errors.push(`Missing RPC fixture: ${key}`);
						return { jsonrpc: '2.0', id: call.id, result: [3] };
					}
					return { jsonrpc: '2.0', id: call.id, result: [0, fixture(params ?? {})] };
				};
				return route.fulfill({ json: Array.isArray(data) ? data.map(reply) : reply(data) });
			}
			if (url.pathname.startsWith('/luci-static/')) {
				const name = url.pathname.slice('/luci-static/'.length);
				const asset = [path.join(appStatic, name), path.join(staticRoot, name)]
					.find(file => fs.statSync(file, { throwIfNoEntry: false })?.isFile());
				if (asset)
					return route.fulfill({ path: asset });
			}
			return route.fulfill({ status: 404 });
		});
		const page = await context.newPage();
		page.on('pageerror', error => errors.push(error.message));
		page.on('response', response => {
			if (!response.ok())
				errors.push(`HTTP ${response.status()} ${response.url()}`);
		});
		page.setDefaultTimeout(5000);
		await page.clock.setFixedTime(now);
		await page.goto(origin);
		await page.evaluate(() => window.ready.then(() => null));
		await verify(page, view);
		await page.evaluate(() => document.fonts.ready.then(() => null));
		assert.ok(await page.evaluate(href => Array.from(document.styleSheets).some(sheet => sheet.href === href),
			`${origin}/luci-static/${stylesheet}`), 'Theme stylesheet was applied');
		assert.deepEqual(errors, [], `Browser errors on ${view}/${theme}`);
		const file = path.join(out, `${view}-${theme}.png`);
		const png = await page.screenshot({ path: file, fullPage: true, animations: 'disabled' });
		assert.equal(png.readUInt32BE(16), 1320, `${file}: desktop PNG width`);
		assert.ok(png.readUInt32BE(20) >= 1200, `${file}: full-page PNG height`);
		console.log(`PASS ${view}/${theme} ${png.readUInt32BE(16)}×${png.readUInt32BE(20)} ${file} (${[...requests].join(', ')})`);
	} catch (error) {
		throw new Error(`${view}/${theme}: ${error.message}${errors.length ? `\n${errors.join('\n')}` : ''}`, { cause: error });
	} finally {
		await context.close();
	}
}

(async () => {
	const browser = await chromium.launch();
	fs.mkdirSync(out, { recursive: true });
	try {
		for (const [theme, stylesheet] of Object.entries(themes))
			for (const view of Object.keys(pages))
				await capture(browser, theme, stylesheet, view);
	} finally {
		await browser.close();
	}
})().catch(error => { console.error(error); process.exitCode = 1; });
