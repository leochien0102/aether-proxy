'use strict';

// T16.124: run the installed SDK, not tests/luci/form-sdk.js, in a real browser.
// Only the remote RPC boundary is replaced by an isolated configuration store.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { scanRequires } = require('../luci/loader');
const ROOT = path.resolve(__dirname, '../..');
const SDK = process.env.LUCI_SDK_RESOURCES ||
	'/workspace/openwrt/openwrt-actions/build/rockchip/feeds/luci/modules/luci-base/htdocs/luci-static/resources';
const APP = path.join(ROOT, 'luci-app-aether-proxy/htdocs/luci-static/resources');
const output = process.argv[2];
assert.ok(output, 'usage: node tests/t16-124/sdk-save.cjs <snapshot.json>');
assert.ok(process.env.T124_DEFAULT_UA, 'T124_DEFAULT_UA must come from the real backend constants');
assert.ok(path.resolve(output).startsWith(ROOT + path.sep), 'scratch output must stay inside this worktree');
process.env.TMPDIR = path.dirname(path.resolve(output));
const sources = {};
for (const name of ['uci', 'validation', 'ui', 'form', 'aether-proxy.form-defaults',
	'aether-proxy.model.subscriptions', 'aether-proxy.common', 'aether-proxy.subscriptions-block']) {
	const file = path.join(name.startsWith('aether-proxy.') ? APP : SDK, name.replaceAll('.', '/') + '.js');
	const text = fs.readFileSync(file, 'utf8');
	sources[name] = { text, requires: scanRequires(text) };
}
const luci = fs.readFileSync(path.join(SDK, 'luci.js'), 'utf8');
assert.equal(luci.split('window.LuCI = LuCI;').length, 2, 'SDK runtime export marker changed');

async function main() {
	// Reuse an existing installation. Never install packages or download browsers here.
	const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
	const browser = await chromium.launch({ headless: true,
		...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}) });
	try {
		const page = await browser.newPage();
		const pageErrors = [];
		page.on('pageerror', error => pageErrors.push(error.message));
		await page.route('**/*', route => route.abort());
		console.log('Chromium: ' + browser.version());
		await page.setContent('<main id="maincontent"><div id="view"><div id="test"></div></div></main>');
		await page.addScriptTag({ content: fs.readFileSync(path.join(SDK, 'cbi.js'), 'utf8') });
		// Expose SDK builtins without running LuCI.__init__(), which contacts a router.
		// No SDK method is replaced: Class, DOM, form, UI and UCI execute as shipped.
		await page.addScriptTag({ content: luci.replace('window.LuCI = LuCI;',
			'window.LuCI = LuCI; window.__sdkClasses = classes;') });
		const result = await page.evaluate(async ({ sources, defaultUA }) => {
			window.L = Object.create(window.LuCI.prototype);
			L.env = { sessionid: null, pollinterval: 5 };
			window._ = text => text;
			const modules = window.__sdkClasses;
			let remote, writes;
			const copy = value => JSON.parse(JSON.stringify(value));
			const assert = (condition, message) => { if (!condition) throw new Error(message); };
			const passes = [], snapshots = [];
			modules.rpc = { declare(spec) {
				return async (...args) => {
					const p = Object.fromEntries((spec.params || []).map((key, i) => [key, args[i]]));
					if (spec.object === 'aetherproxy') {
						if (spec.method === 'version') return { ok: true, version: defaultUA.slice('aether-proxy/'.length) };
						if (spec.method === 'sub_status') return { ok: true, subs: {} };
					}
					if (spec.object === 'session' && spec.method === 'access') return true;
					if (spec.object !== 'uci') throw new Error('Unexpected RPC ' + spec.object + '.' + spec.method);
					if (spec.method === 'get') return p.config === 'aetherproxy' ? copy(remote) : {};
					if (spec.method === 'changes') return {};
					assert(p.config === 'aetherproxy', 'write outside the test config');
					writes.push({ method: spec.method, ...copy(p) });
					if (spec.method === 'set') Object.assign(remote[p.section], p.values);
					else if (spec.method === 'delete' && p.options)
						for (const key of p.options) delete remote[p.section][key];
					else throw new Error('Unexpected UCI write ' + spec.method);
					return 0;
				};
			} };
			// File upload is unused. Fail, rather than silently emulate any call to it.
			modules.fs = new Proxy({}, { get: (_, key) => { throw new Error('Unexpected fs.' + String(key)); } });
			function load(name) {
				if (modules[name]) return modules[name];
				const source = sources[name];
				assert(source, 'Missing real SDK/app module ' + name);
				const params = ['window', 'document', 'L', ...source.requires.map(r => r.as)];
				const args = [window, document, L, ...source.requires.map(r => load(r.name))];
				const factory = new Function(...params, source.text);
				const value = factory.apply(factory, args);
				modules[name] = modules.baseclass.isSubclass(value) ? new value() : value;
				return modules[name];
			}
			const form = load('form'), ui = load('ui'), uci = load('uci'), dom = modules.dom;
			L.ui = ui;
			const blockType = load('aether-proxy.subscriptions-block').constructor;
			const id = 's_00000001';
			function base(common, own) {
				const sections = {
					main: { '.type': 'global', enabled: '0' },
					sub: { '.type': 'sub', ...(common == null ? {} : { user_agent: common }) },
					[id]: { '.type': 'subscription', name: 'Fixture', url: 'http://127.0.0.1/sub',
						fetch_via: 'direct', ...(own == null ? {} : { user_agent: own }) }
				};
				Object.entries(sections).forEach(([name, s], index) => Object.assign(s,
					{ '.name': name, '.index': index, '.anonymous': false }));
				return sections;
			}
			async function mount(common, own, modal) {
				ui.hideModal();
				remote = base(common, own);
				writes = [];
				uci.unload('aetherproxy');
				await uci.load('aetherproxy');
				const block = new blockType();
				const root = await block.render(() => {});
				document.getElementById('test').replaceChildren(root);
				await block.read_version();
				let map = block.map;
				if (modal) {
					await block.grid.renderMoreOptionsModal(id);
					map = dom.findClassInstance(block.grid.getActiveModalMap());
					assert(map instanceof form.Map, 'GridSection must create the real SDK modal Map');
				}
				assert(map.save === form.Map.prototype.save && map.parse === form.Map.prototype.parse,
					'test must use the real SDK Map parse/save methods');
				const sid = modal ? id : 'sub';
				const option = map.children.flatMap(s => s.children).find(o => o.option === 'user_agent');
				const frame = () => map.findElement('data-field', option.cbid(sid));
				const select = () => frame().querySelector('select');
				const text = () => frame().querySelector('input[type="text"]');
				return { block, map, sid, option, select, text,
					choose(value) {
						select().value = value;
						select().dispatchEvent(new Event('change', { bubbles: true }));
					},
					custom(value) {
						this.choose('@custom');
						text().value = value;
						text().dispatchEvent(new Event('keyup', { bubbles: true }));
						text().dispatchEvent(new Event('change', { bubbles: true }));
					},
					async save() {
						option.triggerValidation(sid);
						await map.save(null, true);
					}
				};
			}
			function snapshot(name, expected) {
				assert(!Object.values(remote).some(s => Object.keys(s).some(k => k.includes('choice') || k.includes('mode'))),
					'no UA mode field may be persisted');
				assert(remote[id].fetch_via === 'direct', 'UA selection changed fetch_via');
				snapshots.push({ name, expected, sections: copy(remote) });
				passes.push(name);
			}
			for (const modal of [false, true]) {
				const where = modal ? 'subscription modal' : 'general settings';
				let h = await mount(null, null, modal);
				assert(h.select().value === '', where + ': absent UA selects default/inheritance');
				assert(h.text().getClientRects().length === 0, where + ': noncustom text must be hidden');
				await h.save();
				assert(writes.length === 0, where + ': unchanged absent UA caused RPC writes');
				snapshot(where + ' unchanged absent', defaultUA);

				h = await mount('Common/1', modal ? 'Legacy/1 (+unchanged)' : null, modal);
				assert(h.select().value === '@custom', where + ': classification');
				const original = remote[h.sid].user_agent;
				await h.save();
				assert(remote[h.sid].user_agent === original && writes.length === 0,
					where + ': unchanged custom/legacy UA was rewritten');
				snapshot(where + ' unchanged explicit', original);

				h = await mount(null, null, modal);
				h.choose('v2rayN');
				await h.save();
				assert(remote[h.sid].user_agent === 'v2rayN', where + ': preset was not saved');
				snapshot(where + ' preset', 'v2rayN');

				h = await mount(null, null, modal);
				h.custom('T16.124 custom/1 (+spaces)');
				assert(h.text().getClientRects().length > 0, where + ': custom input must be visible');
				h.choose('v2rayN');
				h.choose('@custom');
				assert(h.text().value === 'T16.124 custom/1 (+spaces)', where + ': custom draft lost');
				await h.save();
				assert(remote[h.sid].user_agent === 'T16.124 custom/1 (+spaces)', where + ': custom value changed');
				snapshot(where + ' custom', 'T16.124 custom/1 (+spaces)');

				h = await mount('Common/1', modal ? 'Legacy/1' : null, modal);
				h.choose('');
				await h.save();
				assert(!Object.hasOwn(remote[h.sid], 'user_agent'), where + ': restore did not remove override');
				snapshot(where + ' restored', modal ? 'Common/1' : defaultUA);
			}
			const inherited = await mount('Common/1', null, true);
			await inherited.save();
			assert(writes.length === 0 && !Object.hasOwn(remote[id], 'user_agent'), 'inheritance was materialized');
			snapshot('unchanged inheritance from common', 'Common/1');
			for (const ua of ['Common/1', 'v2rayN', defaultUA, '<b>legacy</b>']) {
				const h = await mount(ua, ua, true);
				const name = h.map.children.flatMap(s => s.children).find(o => o.option === 'name');
				name.getUIElement(id).setValue('Renamed only');
				await h.save();
				assert(remote[id].user_agent === ua, 'unrelated save changed an explicit UA equal to common/default');
				assert(!writes.some(w => w.values && Object.hasOwn(w.values, 'user_agent')),
					'unrelated save wrote the old UA');
				snapshot('unrelated name edit preserves ' + ua, ua);
			}
			const general = await mount(defaultUA, null, false);
			await general.save();
			assert(writes.length === 0 && remote.sub.user_agent === defaultUA, 'explicit application default was cleared');
			snapshot('unchanged explicit application default', defaultUA);
			return { passes, snapshots };
		}, { sources, defaultUA: process.env.T124_DEFAULT_UA });
		assert.deepEqual(pageErrors, [], 'browser event handlers must not throw');
		for (const name of result.passes) console.log('PASS T16.124 real SDK Map.save: ' + name);
		fs.writeFileSync(output, JSON.stringify(result.snapshots, null, 2) + '\n');
		console.log('SDK resources: ' + SDK);
		for (const name of ['cbi', 'luci', 'form', 'ui', 'uci', 'validation']) {
			const file = path.join(SDK, name + '.js');
			console.log('SDK SHA256 ' + name + '.js ' + createHash('sha256').update(fs.readFileSync(file)).digest('hex'));
		}
	} finally {
		await browser.close();
	}
}
main().catch(error => { console.error(error); process.exitCode = 1; });
