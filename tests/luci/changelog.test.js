'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadModule, element, htmlWriteMark, htmlWritesSince } = require('./loader');
const { descendants } = require('./button-layout');
const root = path.resolve(__dirname, '../..');
const pkg = path.join(root, 'luci-app-aether-proxy');
const source = path.join(pkg, 'htdocs/luci-static/resources/aether-proxy/changelog.js');
globalThis._ = s => s;
globalThis.E = element;
const text = n => n.textContent ?? (n.children ?? []).map(text).join('');

function generated(t, real = false, extra = 0) {
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 't16105-'));
	t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
	const docs = path.join(tmp, 'releases');
	fs.mkdirSync(docs);
	if (!real) {
		for (const [ver, body] of [
			['2.0.0-r9', '发布日期：2026-11-22\n\n## 主要变化\n\n- optional notes absent'],
			['2.0.0-r10', '发布日期：2026-11-23\n\n## 主要变化\n\n- <img src=x onerror=alert(1)> & **text**\n  continuation\n\n## 升级须知\n\n- upgrade action\n\n## 维护者核对\n\nprivate internal text'],
			['3.0.0-r1', '状态：未发布\n发布日期：2026-11-24\n\n## 主要变化\n\n- draft secret'],
			['1.2.2-r10', '发布日期：2026-11-22\n\n## 变化\n\n- do not guess legacy prose'],
			['4.0.0-r1', '## 主要变化\n\n- undated secret']
		]) fs.writeFileSync(path.join(docs, ver + '.md'), '# ' + ver + '\n\n' + body + '\n');
	}
	for (let revision = 1; revision <= extra; revision++)
		fs.writeFileSync(path.join(docs, `5.0.0-r${revision}.md`), '发布日期：2026-11-22\n\n## 主要变化\n\n- bounded history');
	const module = path.join(tmp, 'changelog.js');
	fs.copyFileSync(source, module);
	const run = spawnSync('python3', [path.join(pkg, 'tools/build-changelog.py'),
		real ? path.join(root, 'docs/releases') : docs, module], { encoding: 'utf8' });
	assert.equal(run.status, 0, run.stderr);
	return { module, data: loadModule(module, { baseclass: { extend: o => o } }, { window: {}, document: {} }) };
}

test('T16.105 build extracts only dated user sections, numeric order and optional notes', t => {
	const { data, module } = generated(t);
	assert.deepEqual(data.releases.map(r => r.version), ['2.0.0-r10', '2.0.0-r9', '1.2.2-r10']);
	assert.deepEqual(data.releases[0].notes, ['upgrade action']);
	assert.deepEqual(data.releases[1].notes, []);
	assert.deepEqual(data.releases[2].changes, []);
	assert.match(data.releases[0].changes[0], /continuation$/);
	assert.doesNotMatch(fs.readFileSync(module, 'utf8'), /draft secret|undated secret|private internal text|guess legacy/);
});

test('T16.105 recent history is bounded to eight numerically sorted versions', t => {
	const { data } = generated(t, false, 12);
	assert.equal(data.releases.length, 8);
	assert.deepEqual(data.releases.map(r => r.version), Array.from({ length: 8 }, (_, i) => `5.0.0-r${12 - i}`));
});

test('T16.105 production excludes real draft, bounds recent entries and keeps r10 before r9', t => {
	const { data } = generated(t, true);
	assert.ok(data.releases.length > 0 && data.releases.length <= 8);
	assert.deepEqual(data.releases.slice(0, 2).map(r => r.version), ['1.2.2-r10', '1.2.2-r9']);
	assert.ok(!data.releases.some(r => r.version === '1.3.0-r1'));
});

test('T16.105 offline DOM uses text, expands exact installed version only, never substitutes latest', t => {
	const { data } = generated(t);
	const mark = htmlWriteMark();
	for (const installed of ['2.0.0-r9', '2.0.0-r10', '1.2.2-r10', '9.0.0-r1', undefined]) {
		const dom = data.render(installed);
		const details = descendants(dom).filter(n => n.tag === 'details');
		const current = data.releases.find(r => r.version === installed);
		assert.equal(details.filter(n => n.attrs.open).length, current ? 1 : 0);
		if (current) assert.equal(text(details[0].children[0]), installed);
		else assert.match(text(dom), /No bundled summary for the installed application version/);
		assert.equal(descendants(dom).filter(n => n.tag === 'img').length, 0);
		assert.match(text(dom), /<img src=x onerror=alert\(1\)> & \*\*text\*\*/);
	}
	assert.ok(!htmlWritesSince(mark).some(write => /onerror|upgrade action/.test(JSON.stringify(write))));
});

test('T16.105 exact official release URL validates the full version', t => {
	const { data } = generated(t);
	assert.equal(data.url('2.0.0-r10'), 'https://github.com/leochien0102/aether-proxy/releases/tag/v2.0.0-r10');
	for (const value of ['latest', 'v2.0.0-r1', '2.0-r1', '2.0.0-r0', '2.0.0-r1/../../', '<script>', null, '2.0.0-r1\n'])
		assert.equal(data.url(value), null);
});
