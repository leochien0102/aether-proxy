'use strict';

/* T8.8 scenarios 2,3,5-9. Real CLI in disposable directories, pure LuCI
 * model via the shared loader. Fixtures never need networking or system config. */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { loadModule, parsePo } = require('./loader');
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
