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
			['3.0.0-r1', '状态：未发布\n\n## 主要变化\n\n- draft secret\n\n## 升级须知\n\n- fixture upgrade note'],
			['1.2.2-r10', '发布日期：2026-11-22\n\n## 变化\n\n- do not guess legacy prose'],
			['4.0.0-r1', '## 主要变化\n\n- undated secret']
		]) fs.writeFileSync(path.join(docs, ver + '.md'), '# ' + ver + '\n\n' + body + '\n');
	}
	for (let revision = 1; revision <= extra; revision++)
		fs.writeFileSync(path.join(docs, `5.0.0-r${revision}.md`), '发布日期：2026-11-22\n\n## 主要变化\n\n- bounded history');
	const module = path.join(tmp, 'changelog.js');
	const regenerate = () => {
		fs.copyFileSync(source, module);
		const run = spawnSync('python3', [path.join(pkg, 'tools/build-changelog.py'),
			real ? path.join(root, 'docs/releases') : docs, module], { encoding: 'utf8' });
		assert.equal(run.status, 0, run.stderr);
		return loadModule(module, { baseclass: { extend: o => o } }, { window: {}, document: {} });
	};
	return { module, docs, data: regenerate(), regenerate };
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

test('T16.105 production history stays bounded, numerically descending and excludes unpublished entries', t => {
	const { data } = generated(t, true);
	const versions = data.releases.map(r => r.version);
	assert.ok(versions.length <= 8);
	assert.deepEqual(versions, [...versions].sort((a, b) => {
		const left = a.match(/\d+/g).map(Number);
		const right = b.match(/\d+/g).map(Number);
		for (let i = 0; i < left.length; i++)
			if (left[i] !== right[i]) return right[i] - left[i];
		return 0;
	}));
	const docs = path.join(root, 'docs/releases');
	for (const file of fs.readdirSync(docs).filter(f => f.endsWith('.md'))) {
		const header = fs.readFileSync(path.join(docs, file), 'utf8').split('\n## ', 1)[0];
		if (header.includes('未发布'))
			assert.ok(!versions.includes(path.basename(file, '.md')), `${file} must not ship while unpublished`);
	}
});

test('T16.105 same isolated release transitions from draft to published by changing only its status marker', async t => {
	const fixture = generated(t);
	const draft = path.join(fixture.docs, '3.0.0-r1.md');
	const before = fs.readFileSync(draft, 'utf8');
	await t.test('draft state: excluded; r10 precedes r9', () => {
		assert.deepEqual(fixture.data.releases.map(r => r.version), ['2.0.0-r10', '2.0.0-r9', '1.2.2-r10']);
		assert.doesNotMatch(fs.readFileSync(fixture.module, 'utf8'), /draft secret|fixture upgrade note/);
	});
	fs.writeFileSync(draft, before.replace('状态：未发布', '发布日期：2026-11-24'));
	const published = fixture.regenerate();
	await t.test('published state: included at the correct position with both expected sections; r10 precedes r9', () => {
		assert.deepEqual(published.releases.map(r => r.version),
			['3.0.0-r1', '2.0.0-r10', '2.0.0-r9', '1.2.2-r10']);
		assert.deepEqual(published.releases[0].changes, ['draft secret']);
		assert.deepEqual(published.releases[0].notes, ['fixture upgrade note']);
		assert.deepEqual(published.releases.slice(1), fixture.data.releases);
	});
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
