'use strict';

/* T8.8 scenarios 2,3,5-9, T10.10 progressive loading and T10.21 tabs (docs/10).
 * Real CLI in disposable directories; model/view via the shared LuCI loader.
 * Deferred RPC and timer doubles prove that only the arriving tab/region changes.
 * The tab double records panes and attachment without reimplementing LuCI tabs.
 * T10.35 uses editable widget doubles and recorded UCI writes to exercise the
 * composite trust option; status remains deferred and independent of list reads. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { loadModule, parsePo, element } = require('./loader');
const { actionRow } = require('./button-layout');
const ROOT = path.resolve(__dirname, '../..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const PO = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = s => PO[s] ?? s;
const model = () => loadModule(path.join(RES, 'aether-proxy/model/rules.js'),
	{ baseclass: { extend: o => o } }, { window: {}, document: {} });
const names = [ 'gfwlist', 'chnlist', 'apple', 'chnroute4', 'gfw_static4' ];
function cli(args) {
	const r = spawnSync(path.join(ROOT, 'tests/host/ucode'),
		[ '-S', path.join(ROOT, 'aether-proxy/src/aether-proxy'), '--', ...args, '--json' ],
		{ encoding: 'utf8' });
	assert.equal(r.error, undefined);
	assert.equal(r.stderr, '');
	return { status: r.status, value: JSON.parse(r.stdout) };
}
function sandbox(fn) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ap-rules-'));
	try { fn(dir); }
	finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
function data_fixture(dir) {
	const base = path.join(dir, 'usr/share/aether-proxy/data');
	const downloaded = path.join(dir, 'etc/aether-proxy/data');
	const run = path.join(dir, 'var/run/aether-proxy');
	for (const d of [ base, downloaded, run ])
		fs.mkdirSync(d, { recursive: true });
	for (const name of names)
		fs.writeFileSync(path.join(base, name + '.txt'), '# fixture\n\n' +
			(name.includes('4') ? '192.0.2.0/24\n' : 'sample.example\n'));
	return { base, downloaded, run };
}
test('T8.8 scenario 2: data status reports every source, hash prefix, line count and mtime', () => sandbox(dir => {
	const d = data_fixture(dir);
	for (const name of names.slice(0, 2)) {
		const file = path.join(d.downloaded, name + '.txt');
		fs.writeFileSync(file, '# comment\n\nfirst.example\nsecond.example\n');
		fs.utimesSync(file, 1700000000, 1700000000);
		// Deliberately not the file hash: .sha256 must be authoritative.
		fs.writeFileSync(path.join(d.downloaded, name + '.sha256'), 'a'.repeat(64) + '\n');
	}
	const r = cli([ 'data', 'status', '--sys-root', dir ]);
	assert.equal(r.status, 0);
	assert.deepEqual(Object.keys(r.value.items).sort(), [...names].sort());
	for (const [i, name] of names.entries()) {
		const content = fs.readFileSync(path.join(d.base, name + '.txt'));
		const hash = crypto.createHash('sha256').update(content).digest('hex');
		assert.deepEqual(r.value.items[name], {
			source: i < 2 ? 'downloaded' : 'baseline', version: i < 2 ? 'aaaaaaaaaaaa' : hash.slice(0, 12),
			lines: i < 2 ? 2 : 1, updated_at: i < 2 ? 1700000000 : null, changed: null
		});
	}
}));
test('T8.8 scenario 3: cache fields or null, with no added events', () => sandbox(dir => {
	const d = data_fixture(dir);
	const events = path.join(d.run, 'events.jsonl');
	fs.writeFileSync(events, 'sentinel\n');
	const cache = path.join(d.run, 'updates.json');
	for (const text of [ null, '{broken', JSON.stringify({ checked: 123, data: {
		gfwlist: { changed: false }, chnlist: { changed: true }
	} }) ]) {
		if (text != null)
			fs.writeFileSync(cache, text);
		const r = cli([ 'data', 'status', '--sys-root', dir ]);
		assert.equal(r.status, 0);
		assert.equal(r.value.checked, text?.startsWith('{"') ? 123 : null);
		for (const name of names)
			assert.equal(r.value.items[name].changed,
				text?.startsWith('{"') && name == 'gfwlist' ? false :
				text?.startsWith('{"') && name == 'chnlist' ? true : null);
		assert.equal(fs.readFileSync(events, 'utf8'), 'sentinel\n');
	}
	// Undefined file-error policy is conservative and equally read-only.
	fs.unlinkSync(path.join(d.base, 'apple.txt'));
	assert.equal(cli([ 'data', 'status', '--sys-root', dir ]).value.code, 'FS_FAILED');
	assert.equal(fs.readFileSync(events, 'utf8'), 'sentinel\n');
}));

// Inspect the real CLI while proving status does not write data, cache, state or events.
function read_only_status(dir, d) {
	const files = [path.join(d.run, 'updates.json'), path.join(d.run, 'events.jsonl'),
		path.join(d.run, 'state.json'), ...names.flatMap(name => [
			path.join(d.base, name + '.txt'), path.join(d.downloaded, name + '.txt'),
			path.join(d.downloaded, name + '.sha256')
		])];
	const snapshot = () => files.map(file => fs.existsSync(file) ?
		[fs.readFileSync(file, 'utf8'), fs.statSync(file).mtimeMs] : null);
	const before = snapshot();
	const r = cli(['data', 'status', '--sys-root', dir]);
	assert.equal(r.status, 0);
	assert.deepEqual(snapshot(), before, 'data status is read-only and event-free');
	return r.value;
}
const sha256 = text => crypto.createHash('sha256').update(text).digest('hex');

test('T9.11 scenario 2: live downloaded hashes detect manual changes and restoration for all five items',
	() => sandbox(dir => {
		const d = data_fixture(dir);
		const records = { checked: 123, data: {} };
		for (const name of names) {
			const content = fs.readFileSync(path.join(d.base, name + '.txt'));
			fs.writeFileSync(path.join(d.downloaded, name + '.txt'), content);
			fs.writeFileSync(path.join(d.downloaded, name + '.sha256'), sha256(content) + '\n');
			records.data[name] = { changed: true, sha256: sha256(content) };
		}
		fs.writeFileSync(path.join(d.run, 'updates.json'), JSON.stringify(records));
		fs.writeFileSync(path.join(d.run, 'events.jsonl'), 'sentinel\n');
		fs.writeFileSync(path.join(d.run, 'state.json'), '{"state":"stopped"}\n');
		let status = read_only_status(dir, d);
		assert.equal(status.checked, 123);
		for (const name of names) {
			assert.equal(status.items[name].source, 'downloaded');
			assert.equal(status.items[name].changed, false, 'live hash overrides cached true: ' + name);
		}
		for (const name of names) {
			const file = path.join(d.downloaded, name + '.txt');
			const original = fs.readFileSync(file);
			const modified = name.includes('4') ? '198.51.100.0/24\n' : 'modified.example\n';
			fs.writeFileSync(file, modified);
			// docs/08 makes the sidecar authoritative, not the downloaded text itself.
			assert.equal(read_only_status(dir, d).items[name].changed, false);
			fs.writeFileSync(path.join(d.downloaded, name + '.sha256'), sha256(modified) + '\n');
			status = read_only_status(dir, d);
			assert.equal(status.items[name].changed, true, 'manual local hash differs: ' + name);
			assert.equal(status.items[name].version, sha256(modified).slice(0, 12));
			fs.writeFileSync(file, original);
			fs.writeFileSync(path.join(d.downloaded, name + '.sha256'), sha256(original) + '\n');
			assert.equal(read_only_status(dir, d).items[name].changed, false, 'restored hash: ' + name);
		}
	}));

test('T9.11 scenario 4: live baseline hashes override cached booleans without downloaded data', () => sandbox(dir => {
	const d = data_fixture(dir);
	const records = { checked: 456, data: {} };
	for (const name of names) {
		const content = fs.readFileSync(path.join(d.base, name + '.txt'));
		records.data[name] = { changed: true, sha256: sha256(content) };
	}
	fs.writeFileSync(path.join(d.run, 'updates.json'), JSON.stringify(records));
	let status = read_only_status(dir, d);
	assert.equal(status.checked, 456);
	for (const name of names) {
		assert.equal(status.items[name].source, 'baseline');
		assert.equal(status.items[name].updated_at, null);
		assert.equal(status.items[name].changed, false, 'baseline equals manifest: ' + name);
		const file = path.join(d.base, name + '.txt');
		const original = fs.readFileSync(file);
		fs.writeFileSync(file, '# modified baseline\n' + original);
		status = read_only_status(dir, d);
		assert.equal(status.items[name].changed, true, 'baseline differs: ' + name);
		assert.equal(status.items[name].version, sha256(fs.readFileSync(file)).slice(0, 12));
		fs.writeFileSync(file, original);
		assert.equal(read_only_status(dir, d).items[name].changed, false, 'baseline restored: ' + name);
	}
}));

const good_upstreams = [ '192.0.2.53', '192.0.2.53#5353', 'tcp://192.0.2.53',
	'udp://192.0.2.53#53', 'tls://resolver.example@192.0.2.53', 'tls://_dns.example@192.0.2.53#853' ];
const bad_upstreams = [ 'https://192.0.2.53', '192.0.2.053', '192.0.2.256', 'resolver.example',
	'192.0.2.53#0', '192.0.2.53#65536', '192.0.2.53#1#2', 'tls://-bad.example@192.0.2.53',
	'tcp://192.0.2.53:53', 'tls://resolver.example@2001:db8::1', 'tls://a@b@192.0.2.53' ];
const fixtures = [];
for (const field of [ 'china_dns', 'direct_dns' ]) {
	for (const value of good_upstreams)
		fixtures.push({ field, value: [value], ok: true });
	for (const value of bad_upstreams)
		fixtures.push({ field, value: [value], ok: false });
}
fixtures.push(
	{ field: 'trust_dns', value: [], ok: false },
	{ field: 'trust_dns', value: ['192.0.2.1'], ok: true },
	{ field: 'trust_dns', value: ['tcp://8.8.8.8', 'udp://1.1.1.1'], ok: true },
	{ field: 'trust_dns', value: ['8.8.8.8#53'], ok: false },
	{ field: 'trust_dns', value: ['udp://1.1.1.1:53'], ok: false },
	{ field: 'trust_dns', value: ['tls://8.8.8.8'], ok: false },
	{ field: 'trust_dns', value: ['192.0.2.1', '198.51.100.1'], ok: true },
	{ field: 'trust_dns', value: ['192.0.2.1', '198.51.100.1', '203.0.113.1'], ok: false },
	{ field: 'trust_dns', value: ['resolver.example'], ok: false },
	{ field: 'trust_dns', value: ['2001:db8::1'], ok: false },
	{ field: 'dns_probe_domain', value: 'probe.example', ok: true },
	{ field: 'dns_probe_domain', value: '_probe.a-b.example', ok: true },
	{ field: 'dns_probe_domain', value: '-bad.example', ok: false },
	{ field: 'dns_probe_domain', value: 'bad..example', ok: false },
	{ field: 'dns_probe_domain', value: 'x'.repeat(64) + '.example', ok: false },
	{ field: 'allow_china_fallback', value: '0', ok: true },
	{ field: 'allow_china_fallback', value: '2', ok: false }
);
test('T8.8 scenario 5: DNS syntax accepts all supported forms and rejects invalid inputs', () => {
	for (const f of fixtures)
		assert.equal(model().validate(f.field, f.value) === true, f.ok, JSON.stringify(f));
});
test('T8.8 scenario 6: every DNS fixture agrees with the real CLI check', () => sandbox(dir => {
	const d = data_fixture(dir);
	for (const name of [ 'conf', 'custom', 'data' ])
		fs.mkdirSync(path.join(dir, name));
	for (const f of fixtures) {
		let text = "config global 'main'\n option enabled '0'\nconfig dns 'dns'\n";
		if (Array.isArray(f.value)) {
			// UCI has no zero-element list syntax. A blank list entry represents
			// the user's empty input; omitting it would instead test defaults.
			text += f.value.length ? f.value.map(v => ` list ${f.field} '${v}'\n`).join('') :
				` list ${f.field} ''\n`;
		}
		else
			text += ` option ${f.field} '${f.value}'\n`;
		fs.writeFileSync(path.join(dir, 'conf/aetherproxy'), text);
		const r = cli([ 'check', '--no-precheck', '--confdir', path.join(dir, 'conf'),
			'--data-dir', path.join(dir, 'data'), '--baseline-dir', d.base,
			'--custom-dir', path.join(dir, 'custom'), '--run-dir', d.run ]);
		assert.ok([0, 2].includes(r.status));
		const dns_errors = (r.value.errors ?? []).filter(e => e.field.startsWith('dns.'));
		assert.equal(dns_errors.length == 0, model().validate(f.field, f.value) === true, JSON.stringify(f));
	}
}));
test('T8.8 scenario 7: independent list-save messages preserve errors, lines and raw text', () => {
	const m = model();
	assert.equal(m.save_result({ ok: true, changed: true }).text, '已保存。');
	assert.equal(m.save_result({ ok: true, changed: false }).text, '内容未变化。');
	assert.equal(m.save_result({ ok: true, changed: true, reload: 'failed' }).text, '已保存，但重载失败。');
	const invalid = m.save_result({ ok: false, code: 'CONFIG_INVALID', detail: 'invalid list',
		errors: [{ line: 3, text: 'bad / raw' }, { line: 8, text: '<invalid>' }] });
	assert.equal(invalid.text, 'CONFIG_INVALID: invalid list');
	assert.deepEqual(invalid.errors, ['第 3 行：bad / raw', '第 8 行：<invalid>']);
	for (const code of ['USAGE', 'RPC_FAILED'])
		assert.equal(m.save_result({ ok: false, code, detail: 'reason' }).text, code + ': reason');
});
test('T8.8 scenario 8: translated data table, relative times, three states and job summary', () => {
	const m = model(), now = 200000;
	const rows = m.table({ ok: true, checked: now - 120, items: {
		gfwlist: { source: 'downloaded', version: 'abcdef012345', lines: 9, updated_at: now - 60, changed: true },
		chnlist: { source: 'baseline', version: '123', lines: 4, updated_at: null, changed: false }
	} }, now);
	assert.equal(rows.checked, '2 分钟前');
	assert.deepEqual(rows.rows.map(r => r[0]), ['被墙域名', '大陆域名', '苹果大陆域名', '大陆 IPv4 路由', '静态代理 IPv4 路由']);
	assert.deepEqual(rows.rows[0].slice(1), ['下载', 'abcdef012345', 9, '1 分钟前', '有更新']);
	assert.deepEqual(rows.rows[1].slice(1), ['包内', '123', 4, '从未', '最新']);
	assert.equal(rows.rows[2][5], '未检查');
	assert.equal(m.relative(now, now - 5), '5 秒前');
	assert.equal(m.relative(now, now - 7200), '2 小时前');
	assert.equal(m.relative(now, now - 86400), '1 天前');
	assert.deepEqual(m.job_result({ state: 'failed', result: { updated: ['gfwlist'], unchanged: ['apple'],
		failed: { chnroute4: 'hash mismatch', reload: 'exit 1' } } }),
		['已更新：被墙域名', '未变化：苹果大陆域名', '失败：大陆 IPv4 路由: hash mismatch; reload: exit 1']);
	assert.match(m.job_result({ ok: false, code: 'RPC_FAILED', detail: 'offline' }).join('\n'), /RPC_FAILED: offline/);
});
test('T8.8 scenario 9: form, independent file saves, model validation, job API and complete translations', () => {
	const view = fs.readFileSync(path.join(RES, 'view/aether-proxy/rules.js'), 'utf8');
	assert.match(view, /new form\.Map\('aetherproxy'/);
	assert.match(view, /ap\.call\('list_file'/);
	assert.match(view, /ap\.call\('save_file'/);
	assert.match(view, /model\.validate\(field\[0\], value\)/);
	assert.match(view, /ap\.run_job\('update_data', \[\]\)/);
	assert.doesNotMatch(view, /uci\.(set|add)|rpc\.declare|cbi-button-reset/);
	assert.doesNotMatch(view, /\.depends\s*=/);
	for (const match of view.matchAll(/\.depends\(([^\n]*)\)/g))
		assert.match(match[1], /^'[^']+',\s*'[^']+'$/);
	for (const file of [ 'view/aether-proxy/rules.js', 'aether-proxy/model/rules.js' ]) {
		const src = fs.readFileSync(path.join(RES, file), 'utf8');
		for (const match of src.matchAll(/_\('([^']*)', 'aether-proxy'\)/g))
			assert.ok(PO[match[1]], 'translated: ' + match[1]);
	}
	for (const name of ['direct_domain', 'proxy_domain', 'direct_ip', 'proxy_ip'])
		assert.ok(view.includes("'" + name + "'"));
	assert.match(view, /this\.show_save\(message, r\)/);
});

globalThis.E = element;
function text(node) {
	return typeof node == 'object' && node !== null ? node.children.map(text).join('') : String(node);
}
function deferred() {
	let resolve, reject;
	const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
	return { promise, resolve, reject };
}
function descendants(node) {
	if (node === null || typeof node != 'object')
		return [];
	return [node, ...node.children.flatMap(descendants)];
}
function load_view(dns_config = {}) {
	const calls = [], jobs = [], loads = [], timers = [], maps = [], tab_groups = [], writes = [], actions = [];
	const document = { body: E('body') };
	const form = {
		NamedSection: 'named', ListValue: 'select', Flag: 'flag', Value: 'value',
		DynamicList: class {
			renderWidget(section_id, index, value) {
				return E('list', { name: this.key, value }, this.label);
			}
		}
	};
	/* LuCI widget values are read through getValue(), not input DOM shortcuts.
	 * Select renders a wrapper around a native select; Combobox permits custom text. */
	class Widget {
		constructor(value, choices, options) {
			this.value = value;
			this.choices = choices;
			this.options = options;
		}
		getValue() { return this.value; }
		render() { return E('combobox', { id: this.options.id, value: this.value }); }
	}
	class Select extends Widget {
		render() {
			const select = E('select', { style: {} }, Object.entries(this.choices).map(([value, label]) =>
				E('option', { value, selected: value == this.value || null }, label)));
			const wrapper = E('div', { id: this.options.id }, [select]);
			wrapper.querySelector = selector => selector == 'select' ? select : null;
			return wrapper;
		}
	}
	form.Map = class {
		constructor(config, title) {
			this.config = config;
			this.title = title;
			this.sections = [];
			this.data = { set: (...args) => writes.push(args) };
			maps.push(this);
		}
		section(type, name, section_type, title) {
			const section = { type, name, section_type, title, options: [] };
			section.option = (kind, key, label) => {
				const option = { kind, key, label, map: this, values: [],
					cbid: section_id => 'cbid.aetherproxy.' + section_id + '.' + key,
					value(k, v) { this.values.push([k, v]); } };
				section.options.push(option);
				return option;
			};
			this.sections.push(section);
			return section;
		}
		render() {
			return Promise.resolve(E('form', {}, this.sections.map(section =>
				E('fieldset', { name: section.name }, section.options.map((option, i) => {
					const value = dns_config[option.key];
					const widget = option.renderWidget ? option.renderWidget(section.name, i, value) :
						E(option.kind == form.DynamicList ? 'list' : option.kind,
							{ name: option.key, value }, option.label);
					return E('div', { name: option.key }, [widget, option.description ?? '']);
				})))));
		}
	};
	const page = loadModule(path.join(RES, 'view/aether-proxy/rules.js'), {
		view: { extend: o => o }, form,
		uci: { load: name => { loads.push(name); return Promise.resolve('uci-loaded'); } },
		ui: {
			Combobox: Widget, Select,
			/* Like LuCI, handlers return nothing and restore the event target.
			 * Keep tasks separately so assertions never depend on a handler return value. */
			createHandlerFn: (ctx, fn) => event => {
				event.currentTarget.disabled = true;
				actions.push(Promise.resolve(fn.call(ctx, event)).finally(() => {
					event.currentTarget.disabled = false;
				}));
			},
			tabs: { initTabGroup: panes => tab_groups.push({ panes: [...panes],
				attached: panes.every(pane => descendants(document.body).includes(pane)) }) }
		},
		'aether-proxy.model.rules': model(),
		'aether-proxy.common': {
			job_progress: () => ({ stop() {} }),
			call: (method, params) => {
				const reply = deferred();
				calls.push({ method, params, ...reply });
				return reply.promise;
			},
			run_job: (kind, args) => {
				const reply = deferred();
				jobs.push({ kind, args, ...reply });
				return reply.promise;
			}
		}
	}, { window: { setTimeout: (fn, delay) => { timers.push({ fn, delay }); } }, document });
	return { page, calls, jobs, loads, maps, timers, tab_groups, document, writes, actions,
		start: () => {
			assert.equal(timers.length, 1);
			assert.equal(timers[0].delay, 0);
			timers.shift().fn();
		}
	};
}
function regions(root) {
	return {
		form: root.children[0],
		group: root.children[1],
		lists: root.children[1].children.map(node => ({
			node, input: node.children[1], button: node.children[2].children[1],
			message: node.children[2].children[0]
		})),
		inventory: root.children[3], update: root.children[4].children[2],
		summary: root.children[4].children[0], progress: root.children[4].children[1]
	};
}
const settle = () => new Promise(resolve => setImmediate(resolve));
const list_names = ['direct_domain', 'proxy_domain', 'direct_ip', 'proxy_ip'];

test('T10.10 scenario 1: load only loads UCI and never calls ap.call', async () => {
	const h = load_view();
	assert.equal(await h.page.load(), 'uci-loaded');
	assert.deepEqual(h.loads, ['aetherproxy']);
	assert.deepEqual(h.calls, []);
	assert.deepEqual(h.timers, []);
});
test('T10.10 scenario 2: pending RPC cannot block the complete form, safe editors or update button', async () => {
	const h = load_view();
	const root = await h.page.render();
	assert.equal(h.calls.length, 0, 'RPC must start after render resolves');
	const r = regions(root);
	assert.equal(root.children.length, 5);
	assert.equal(r.form.tag, 'form');
	assert.equal(h.maps[0].config, 'aetherproxy');
	assert.deepEqual(h.maps[0].sections.map(s => s.name), ['main', 'dns']);
	assert.deepEqual(r.form.children.flatMap(s => s.children.map(o => o.name)),
		['mode', 'china_dns', 'trust_dns', 'direct_dns', 'allow_china_fallback', 'dns_probe_domain']);
	const mode = h.maps[0].sections[0].options[0];
	assert.deepEqual(mode.values, model().modes());
	for (const option of h.maps[0].sections[1].options) {
		assert.equal(option.rmempty, false);
		const value = option.key == 'dns_probe_domain' ? 'bad..domain' : 'invalid';
		assert.equal(option.validate('dns', value), model().validate(option.key, value));
	}
	assert.deepEqual(r.lists.map(l => text(l.node.children[0])),
		['直连域名', '代理域名', '直连 IP', '代理 IP']);
	for (const list of r.lists) {
		assert.equal(list.input.disabled, true);
		assert.equal(list.input.value, '');
		assert.equal(list.input.placeholder, '读取中…');
		assert.equal(list.button.disabled, true);
		assert.equal(text(list.button), '保存名单');
		assert.equal(text(list.message), '');
	}
	assert.equal(text(r.inventory), '读取中…');
	assert.equal(text(r.update), '立即更新');
	assert.equal(r.update.disabled, false);
	h.start();
	await settle(); // All five RPC promises stay pending forever.
	assert.equal(h.calls.length, 6);
	assert.equal(text(r.inventory), '读取中…');
	assert.ok(r.lists.every(l => l.input.disabled && l.button.disabled));
});
test('T10.10 scenario 3: queue the four lists in page order before data_status and optional status', async () => {
	const h = load_view();
	await h.page.render();
	h.start();
	assert.deepEqual(h.calls.map(c => [c.method, c.params]), [
		...list_names.map(name => ['list_file', { name }]), ['data_status', undefined], ['status', undefined]
	]);
});
test('T10.10 scenario 4: each reply touches only its own editor; failures remain disabled', async () => {
	const h = load_view();
	const root = await h.page.render(), r = regions(root);
	const nodes = [...root.children];
	h.start();
	// Resolve out of order to expose accidentally shared editor references.
	h.calls[1].resolve({ ok: true, content: '# existing\nproxy.example\n' });
	await settle();
	assert.equal(r.lists[1].input.value, '# existing\nproxy.example\n');
	assert.equal(r.lists[1].input.disabled, false);
	assert.equal(r.lists[1].button.disabled, false);
	assert.equal(r.lists[1].input.placeholder, '');
	for (const i of [0, 2, 3]) {
		assert.equal(r.lists[i].input.value, '');
		assert.equal(r.lists[i].input.disabled, true);
		assert.equal(r.lists[i].button.disabled, true);
		assert.equal(r.lists[i].input.placeholder, '读取中…');
		assert.equal(text(r.lists[i].message), '');
	}
	r.lists[1].input.value = 'user edit.example';
	h.calls[2].resolve({ ok: false, code: 'RPC_FAILED', detail: 'offline',
		errors: [{ line: 2, text: '<raw>' }] });
	await settle();
	assert.equal(r.lists[2].input.disabled, true);
	assert.equal(r.lists[2].button.disabled, true);
	assert.equal(r.lists[2].input.value, '');
	assert.equal(text(r.lists[2].message), 'RPC_FAILED: offline第 2 行：<raw>');
	assert.equal(r.lists[2].input.placeholder, '');
	assert.equal(r.lists[1].input.value, 'user edit.example');
	assert.equal(text(r.lists[1].message), '');
	assert.equal(text(r.inventory), '读取中…');
	h.calls[0].resolve({ ok: true, content: '' });
	await settle();
	assert.equal(r.lists[0].input.value, '');
	assert.equal(r.lists[0].input.disabled, false, 'an empty list is still a successful read');
	assert.equal(r.lists[0].button.disabled, false);
	assert.equal(r.lists[3].input.disabled, true);
	for (const [i, node] of nodes.entries())
		assert.equal(root.children[i], node, 'no region or form may be replaced');
});
test('T10.18 scenario 3: all four loaded lists enable their textareas and Save list buttons', async () => {
	const h = load_view();
	const r = regions(await h.page.render());
	h.start();
	for (let i = 0; i < list_names.length; i++)
		h.calls[i].resolve({ ok: true, content: 'loaded-' + i });
	await settle();
	for (const [i, list] of r.lists.entries()) {
		assert.equal(list.input.value, 'loaded-' + i);
		assert.equal(list.input.disabled, false);
		assert.equal(list.button.disabled, false);
	}
});

test('T10.10 scenario 5: data_status fills the original five-row table without touching edits', async () => {
	const h = load_view();
	const root = await h.page.render(), r = regions(root);
	h.start();
	h.calls[0].resolve({ ok: true, content: 'direct.example' });
	await settle();
	r.lists[0].input.value = 'unsaved.example';
	const reply = { ok: true, checked: null, items: Object.fromEntries(names.map((name, i) => [name, {
		source: i % 2 ? 'baseline' : 'downloaded', version: 'hash-' + i, lines: i,
		updated_at: null, changed: i == 0 ? true : i == 1 ? false : null
	}])) };
	h.calls[4].resolve(reply);
	await settle();
	const vm = model().table(reply, Date.now() / 1000);
	assert.equal(text(r.inventory.children[0]), '上次检查: ' + vm.checked);
	const table = r.inventory.children[1];
	assert.equal(table.tag, 'table');
	assert.equal(table.children.length, 6);
	assert.deepEqual(table.children.slice(1).map(row => row.children.map(text)),
		vm.rows.map(row => row.map(String)));
	assert.equal(text(r.inventory.children[2]), '');
	assert.equal(r.lists[0].input.value, 'unsaved.example');
	assert.equal(r.lists[0].input.disabled, false);
	assert.ok(r.lists.slice(1).every(l => l.input.disabled && l.button.disabled));
	assert.equal(root.children[0], r.form);
	assert.equal(root.children[1].children[0], r.lists[0].node);
});
test('T10.10 scenarios 4-5: timeout and RPC failures keep lists locked and show original data errors', async () => {
	for (const code of ['TIMEOUT', 'RPC_FAILED']) {
		const h = load_view();
		const r = regions(await h.page.render());
		h.start();
		for (const call of h.calls)
			call.resolve({ ok: false, code, detail: 'read failed' });
		await settle();
		for (const list of r.lists) {
			assert.equal(list.input.disabled, true);
			assert.equal(list.button.disabled, true);
			assert.equal(list.input.value, '');
			assert.equal(text(list.message), code + ': read failed');
		}
		assert.equal(text(r.inventory.children[2]), code + ': read failed');
		assert.equal(r.update.disabled, false);
	}
});
test('T10.10 scenario 6: a loaded list saves its current text and retains all existing result messages', async () => {
	const h = load_view();
	const r = regions(await h.page.render());
	h.start();
	h.calls[3].resolve({ ok: true, content: '# original\n192.0.2.1\n' });
	await settle();
	const list = r.lists[3];
	const results = [
		{ ok: true, changed: true }, { ok: true, changed: false },
		{ ok: true, changed: true, reload: 'failed' },
		{ ok: false, code: 'CONFIG_INVALID', detail: 'invalid list', errors: [{ line: 3, text: '<bad>' }] },
		{ ok: false, code: 'RPC_FAILED', detail: 'offline' }
	];
	for (const [i, result] of results.entries()) {
		list.input.value = '# edited ' + i + '\n192.0.2.2\n';
		assert.equal(list.button.click({ currentTarget: list.button }), undefined);
		const saving = h.actions.at(-1);
		assert.equal(list.button.disabled, true);
		const call = h.calls.at(-1);
		assert.equal(call.method, 'save_file');
		assert.deepEqual(call.params, { name: 'proxy_ip', content: list.input.value });
		call.resolve(result);
		await saving;
		const vm = model().save_result(result);
		assert.deepEqual(list.message.children.map(text), [vm.text, ...vm.errors]);
		assert.equal(list.button.disabled, false);
		assert.equal(list.input.value, call.params.content);
		assert.ok(r.lists.slice(0, 3).every(l => l.button.disabled && text(l.message) == ''));
		assert.equal(text(r.inventory), '读取中…');
	}
});
test('T10.10 scenario 7: update job stays usable before reads finish and refreshes only rule data', async () => {
	const h = load_view();
	const root = await h.page.render(), r = regions(root);
	h.start();
	r.update.click({ currentTarget: r.update });
	const updating = h.actions.at(-1);
	assert.equal(r.update.disabled, true);
	assert.equal(h.jobs.length, 1);
	assert.equal(h.jobs[0].kind, 'update_data');
	assert.deepEqual(h.jobs[0].args, []);
	const job = { state: 'ok', result: {
		updated: ['gfwlist'], unchanged: ['apple'], failed: { chnroute4: 'reason' }
	} };
	h.jobs[0].resolve(job);
	await settle();
	assert.deepEqual(r.summary.children.map(text), model().job_result(job));
	assert.equal(h.calls.length, 7);
	assert.equal(h.calls[6].method, 'data_status');
	assert.equal(r.update.disabled, true, 'wait for the post-job inventory');
	h.calls[6].resolve({ ok: true, checked: null, items: { gfwlist: { version: 'new-hash', lines: 42 } } });
	await updating;
	assert.equal(r.update.disabled, false);
	assert.match(text(r.inventory), /new-hash42/);
	assert.ok(r.lists.every(l => l.input.disabled && l.button.disabled));
	assert.equal(root.children[0], r.form);
});

test('T10.27 scenario 1: four list saves and rule update have spaced right-aligned rows with text first', async () => {
	const h = load_view();
	const root = await h.page.render(), r = regions(root);
	for (const list of r.lists) {
		const row = actionRow(list.node, ['保存名单'], [list.message]);
		list.message.textContent = 'save result';
		assert.equal(list.node.children.at(-1), row, 'save row is below the textarea');
		assert.equal(list.node.children.at(-2), list.input);
	}
	r.summary.textContent = 'update result';
	r.progress.textContent = 'elapsed';
	const row = actionRow(root, ['立即更新'], [r.summary, r.progress]);
	assert.equal(root.children.at(-1), row, 'update row is at the bottom of the rule-data block');
	assert.equal(root.children.at(-2), r.inventory);
});

test('T10.21 scenario 1: initialize exactly the four ordered list tabs after attachment', async () => {
	const h = load_view();
	const root = await h.page.render(), r = regions(root);
	const panes = r.lists.map(list => list.node);
	assert.deepEqual(h.tab_groups, [], 'do not initialize detached panes during render');
	assert.deepEqual(panes.map(pane => pane.attrs['data-tab']), list_names);
	assert.deepEqual(panes.map(pane => pane.attrs['data-tab-title']),
		['直连域名', '代理域名', '直连 IP', '代理 IP']);
	assert.ok(panes.every(pane => pane.tag == 'div'));
	assert.deepEqual(descendants(root).filter(node => node.attrs['data-tab'] != null), panes);
	assert.deepEqual(r.group.children, panes, 'one group contains only the list panes');
	for (const pane of panes) {
		const contents = descendants(pane);
		for (const outside of [r.form, r.inventory, r.update, r.summary])
			assert.ok(!contents.includes(outside), 'forms, rule data and update remain outside tabs');
	}
	assert.ok(descendants(r.form).some(node => node.name == 'mode'));
	assert.ok(descendants(r.form).some(node => node.name == 'china_dns'));
	// Model LuCI attaching render()'s result before the scheduled next turn.
	h.document.body.replaceChildren(root);
	h.start();
	assert.equal(h.tab_groups.length, 1);
	assert.deepEqual(h.tab_groups[0], { panes, attached: true });
	h.calls.forEach(call => call.resolve({ ok: true, content: 'loaded' }));
	await settle();
	assert.equal(h.tab_groups.length, 1, 'RPC replies must not initialize another group');
});

test('T10.21 scenario 2: saving the second tab uses only its text, file and result region', async () => {
	const h = load_view();
	const r = regions(await h.page.render());
	h.start();
	for (const [i, call] of h.calls.slice(0, 4).entries())
		call.resolve({ ok: true, content: 'original-' + i });
	await settle();
	for (const [i, list] of r.lists.entries()) {
		list.input.value = 'unsaved-' + i;
		list.message.replaceChildren(E('p', {}, 'previous-' + i));
	}
	const second = r.lists[1];
	second.button.click({ currentTarget: second.button });
	const saving = h.actions.at(-1);
	const saves = h.calls.filter(call => call.method == 'save_file');
	assert.equal(saves.length, 1);
	assert.deepEqual(saves[0].params, { name: 'proxy_domain', content: 'unsaved-1' });
	assert.equal(second.button.disabled, true);
	assert.ok(r.lists.filter(list => list !== second).every(list => !list.button.disabled));
	saves[0].resolve({ ok: true, changed: true });
	await saving;
	assert.equal(second.button.disabled, false);
	assert.equal(text(second.message), '已保存。');
	assert.equal(h.calls.filter(call => call.method == 'save_file').length, 1);
	for (const [i, list] of r.lists.entries()) {
		assert.equal(list.input.value, 'unsaved-' + i);
		assert.ok(descendants(list.node).includes(list.input));
		assert.ok(descendants(list.node).includes(list.button));
		assert.ok(descendants(list.node).includes(list.message));
		if (i != 1)
			assert.equal(text(list.message), 'previous-' + i);
	}
	assert.equal(text(r.inventory), '读取中…');
	assert.equal(text(r.summary), '');
});

test('T10.21 scenario 4: update renders only nonempty categories and preserves job errors', async () => {
	const categories = [
		['updated', ['gfwlist'], '已更新：被墙域名'],
		['unchanged', ['apple'], '未变化：苹果大陆域名'],
		['failed', { chnroute4: 'hash mismatch' }, '失败：大陆 IPv4 路由: hash mismatch']
	];
	// All eight subsets cover three lines, Updated alone and every empty category.
	for (let mask = 0; mask < 8; mask++) {
		const h = load_view();
		const r = regions(await h.page.render());
		const result = { updated: [], unchanged: [], failed: {} }, expected = [];
		for (const [i, [key, value, line]] of categories.entries()) {
			if (mask & (1 << i)) {
				result[key] = value;
				expected.push(line);
			}
		}
		r.update.click({ currentTarget: r.update });
		const updating = h.actions.at(-1);
		h.jobs[0].resolve({ state: 'ok', result });
		await settle();
		assert.deepEqual(r.summary.children.map(text), expected, 'visible lines for subset ' + mask);
		assert.equal(h.calls.length, 1);
		assert.equal(h.calls[0].method, 'data_status');
		h.calls[0].resolve({ ok: true, items: {} });
		await updating;
		assert.equal(r.update.disabled, false);
	}
	const m = model();
	assert.deepEqual(m.job_result({ state: 'ok', result: {} }), []);
	assert.deepEqual(m.job_result({ ok: false, code: 'RPC_FAILED', detail: 'offline' }),
		['RPC_FAILED: offline']);
	assert.deepEqual(m.job_result({ ok: false, code: 'TIMEOUT', detail: 'late',
		result: { updated: ['gfwlist'] } }), ['已更新：被墙域名', 'TIMEOUT: late']);
});

function dns_option(h, key) {
	return h.maps[0].sections[1].options.find(option => option.key == key);
}

test('T10.35 scenario 1: all three preset groups have exact values and translated labels', async () => {
	const m = model();
	const expected = {
		china_dns: [
			['wan', '运营商下发的 DNS'], ['223.5.5.5', '阿里（223.5.5.5）'],
			['223.6.6.6', '阿里（223.6.6.6）'], ['114.114.114.114', '114 DNS（114.114.114.114）'],
			['114.114.115.115', '114 DNS（114.114.115.115）'], ['180.76.76.76', '百度（180.76.76.76）']
		],
		trust_dns: [
			['8.8.8.8', 'Google（8.8.8.8）'], ['8.8.4.4', 'Google（8.8.4.4）'],
			['1.1.1.1', 'Cloudflare（1.1.1.1）'], ['1.0.0.1', 'Cloudflare（1.0.0.1）'],
			['9.9.9.9', 'Quad9（9.9.9.9）'], ['208.67.222.222', 'OpenDNS（208.67.222.222）']
		],
		direct_dns: [
			['tcp://9.9.9.9', 'Quad9（tcp://9.9.9.9）'], ['tcp://8.8.8.8', 'Google（tcp://8.8.8.8）'],
			['tcp://1.1.1.1', 'Cloudflare（tcp://1.1.1.1）']
		]
	};
	const h = load_view({ trust_dns: ['8.8.8.8'] });
	await h.page.render();
	for (const [field, choices] of Object.entries(expected)) {
		assert.deepEqual(m.presets(field), choices);
		const option = dns_option(h, field);
		if (field == 'trust_dns') {
			assert.equal(option.kind, 'value', 'fixed rows, not DynamicList');
			for (const row of option.widgets.dns)
				assert.deepEqual(Object.entries(row.address.choices), choices);
		}
		else {
			assert.deepEqual(option.values, choices, 'DynamicList keeps its free-entry widget');
		}
	}
	assert.equal(m.validate('china_dns', ['198.51.100.53']), true, 'custom domestic address');
	assert.equal(m.validate('direct_dns', ['tls://dns.example@198.51.100.53#853']), true, 'custom upstream');
	const trust = dns_option(h, 'trust_dns');
	trust.widgets.dns[0].address.value = '198.51.100.53';
	assert.equal(trust.isValid('dns'), true, 'custom trusted address');
	assert.deepEqual(trust.formvalue('dns'), ['198.51.100.53']);
});

test('T10.35 scenario 2: domestic wan validation and existing configuration stay unchanged on render', async () => {
	const existing = ['223.5.5.5', 'tcp://1.1.1.1#53'];
	const h = load_view({ china_dns: existing, trust_dns: ['8.8.8.8'] });
	const root = await h.page.render();
	const option = dns_option(h, 'china_dns');
	for (const value of ['wan', '223.5.5.5', 'tcp://1.1.1.1#53'])
		assert.equal(option.validate('dns', [value]), true, value);
	for (const value of ['wan2', 'udp://wan', 'bad', '999.1.1.1'])
		assert.notEqual(option.validate('dns', [value]), true, value);
	assert.deepEqual(descendants(root).find(node => node.tag == 'list' && node.name == 'china_dns').value,
		existing, 'the original list reaches the LuCI widget verbatim');
	assert.match(text(root), /部分运营商 DNS 会把不存在的域名解析到广告页；介意的话改用公共 DNS。/);
	h.start();
	h.calls.find(call => call.method == 'status').resolve({ ok: true, state: 'running', wan_dns: ['10.0.0.1'] });
	await settle();
	assert.deepEqual(h.writes, [], 'rendering and runtime hints cannot write UCI');
	assert.deepEqual(existing, ['223.5.5.5', 'tcp://1.1.1.1#53']);
});

test('T10.35 scenario 3: deferred status shows current WAN DNS or fallback only while active', async () => {
	const cases = [
		[{ ok: true, state: 'running', wan_dns: ['10.0.0.1', '10.0.0.2'] },
			'运营商下发的 DNS 当前为 10.0.0.1、10.0.0.2'],
		[{ ok: true, state: 'running', wan_dns: [] }, '运营商下发的 DNS 暂未取得，临时使用 223.5.5.5'],
		[{ ok: true, state: 'degraded', wan_dns: ['10.0.0.1'] }, '运营商下发的 DNS 当前为 10.0.0.1'],
		[{ ok: true, state: 'running', wan_dns: null }, null],
		[{ ok: true, state: 'stopped', wan_dns: ['10.0.0.1'] }, null],
		[{ ok: true, state: 'error', wan_dns: [] }, null],
		[{ ok: false, code: 'RPC_FAILED', wan_dns: ['10.0.0.1'] }, null],
		[{ ok: true, state: 'running' }, null],
		// The real CLI status is state.json itself, without an ok field.
		[{ state: 'running', wan_dns: ['10.0.0.3'] }, '运营商下发的 DNS 当前为 10.0.0.3'],
		[{ state: 'running', wan_dns: [] }, '运营商下发的 DNS 暂未取得，临时使用 223.5.5.5'],
		[new Error('offline'), null]
	];
	for (const [reply, expected] of cases) {
		const h = load_view();
		await h.page.load();
		const root = await h.page.render();
		assert.deepEqual(h.calls, [], 'status must not delay the page framework');
		h.document.body.replaceChildren(root);
		h.start();
		const calls = h.calls.filter(call => call.method == 'status');
		assert.equal(calls.length, 1, 'read status once, after attachment');
		if (reply instanceof Error)
			calls[0].reject(reply);
		else
			calls[0].resolve(reply);
		await settle();
		const current = descendants(root).filter(node => node.tag == 'div' &&
			node.children.length == 1 && typeof node.children[0] == 'string' &&
			node.children[0].startsWith('运营商下发的 DNS '));
		assert.deepEqual(current.map(text), expected == null ? [] : [expected]);
		assert.equal(text(regions(root).inventory), '读取中…', 'hint is independent of other pending reads');
		assert.deepEqual(h.writes, []);
	}
});

test('T10.35 scenario 4: trusted rows read TCP aliases and UDP, then serialize a single UCI list', async () => {
	for (const first of ['8.8.8.8', 'tcp://8.8.8.8']) {
		const h = load_view({ trust_dns: [first, 'udp://1.1.1.1'] });
		const root = await h.page.render();
		const option = dns_option(h, 'trust_dns');
		const rows = option.widgets.dns;
		assert.deepEqual(rows.map(row => [row.address.getValue(), row.protocol.getValue()]),
			[['8.8.8.8', 'tcp'], ['1.1.1.1', 'udp']]);
		assert.match(text(root), /可信 DNS 1/);
		assert.match(text(root), /可信 DNS 2（可选）/);
		assert.match(text(root), /UDP 用于不支持 TCP 查询的 DNS，需要节点支持 UDP 转发；两项可以用不同协议互为备份。/);
		assert.deepEqual(Object.entries(rows[0].protocol.choices), [['tcp', 'TCP（默认）'], ['udp', 'UDP']]);
		assert.ok(descendants(root).filter(node => node.tag == 'select' && typeof node.style == 'object')
			.every(node => node.style.width == 'auto'), 'protocol selects do not fill a flex row');
		assert.deepEqual(h.writes, [], 'reading a TCP alias never rewrites it during render');
		assert.equal(option.isValid('dns'), true);
		option.write('dns', option.formvalue('dns'));
		assert.deepEqual(h.writes.at(-1), ['aetherproxy', 'dns', 'trust_dns', ['8.8.8.8', 'udp://1.1.1.1']]);
		rows[0].protocol.value = 'udp';
		rows[1].protocol.value = 'tcp';
		assert.deepEqual(option.formvalue('dns'), ['udp://8.8.8.8', '1.1.1.1'], 'each protocol is independent');
		rows[1].address.value = '';
		assert.equal(option.isValid('dns'), true);
		option.write('dns', option.formvalue('dns'));
		assert.deepEqual(h.writes.at(-1), ['aetherproxy', 'dns', 'trust_dns', ['udp://8.8.8.8']]);
	}
});

test('T10.35 scenario 4: empty first row, ports, TLS and non-IPv4 cannot pass form validation', async () => {
	const h = load_view({ trust_dns: ['8.8.8.8', '1.1.1.1'] });
	await h.page.render();
	const option = dns_option(h, 'trust_dns'), rows = option.widgets.dns;
	for (const i of [0, 1]) {
		const invalid = ['8.8.8.8#53', '8.8.8.8:53', 'tls://8.8.8.8', 'resolver.example', '::1', '256.0.0.1'];
		if (i == 0)
			invalid.push('');
		for (const value of invalid) {
			rows[i].address.value = value;
			assert.notEqual(rows[i].address.options.validate(value), true, value);
			assert.equal(option.isValid('dns'), false, 'AbstractValue.parse rejects: ' + value);
			assert.equal(option.getValidationError('dns'), 'IPv4 地址无效。');
		}
		rows[i].address.value = i == 0 ? '8.8.8.8' : '1.1.1.1';
	}
	rows[0].address.value = '';
	assert.deepEqual(option.formvalue('dns'), ['', '1.1.1.1'], 'second row must not replace missing first');
	assert.notEqual(option.validate('dns', option.formvalue('dns')), true);
	assert.deepEqual(h.writes, [], 'invalid form checks never write configuration');
});

test('T10.35 scenario 5: direct presets retain upstream editing and explain the preferred TCP resolver', async () => {
	const h = load_view();
	const root = await h.page.render();
	const option = dns_option(h, 'direct_dns');
	assert.deepEqual(option.values.map(item => item[0]), ['tcp://9.9.9.9', 'tcp://8.8.8.8', 'tcp://1.1.1.1']);
	assert.equal(option.description, '部分网络里 8.8.8.8、1.1.1.1 的 TCP 查询会被重置，可优先试 tcp://9.9.9.9');
	assert.ok(text(root).includes(option.description));
	assert.equal(option.validate('dns', ['udp://198.51.100.53#5353']), true);
	assert.notEqual(option.validate('dns', ['wan']), true, 'wan is domestic-only');
});

test('T10.35 review: Map.checkDepends can validate the trust rows without recursing', async () => {
	const h = load_view({ trust_dns: ['8.8.8.8'] });
	await h.page.render();
	const option = dns_option(h, 'trust_dns');
	let triggered = 0;
	for (const row of option.widgets.dns)
		row.address.triggerValidation = () => { triggered++; return true; };
	// In LuCI, getUIElement() walks up to this option's own frame and returns the option.
	option.getUIElement = () => option;
	assert.equal(option.triggerValidation('dns'), true);
	assert.equal(triggered, 2);
	option.widgets.dns[0].address.value = '';
	assert.equal(option.triggerValidation('dns'), false);
});
