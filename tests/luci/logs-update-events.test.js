'use strict';

// M4-04: real translations and templates must describe installation boundaries.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadModule, parsePo } = require('./loader');
const APP = path.resolve(__dirname, '../../luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const baseclass = { extend: value => value };

function model(translate) {
	globalThis._ = translate;
	const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'), { baseclass }, {});
	return loadModule(path.join(RES, 'aether-proxy/model/logs.js'), {
		baseclass, 'aether-proxy.model.conflicts': conflicts
	}, {});
}

test('M4-04 V6: exact Chinese and English start/finish templates and unknown fallback', () => {
	const args = Object.freeze({ package: 'aether-proxy', version: '1.0.0-r1' });
	for (const [translate, start, finish] of [
		[text => po[text] ?? text, '开始更新：', '已完成更新：'],
		[text => text, 'Update started: ', 'Update finished: ']
	]) {
		const logs = model(translate);
		assert.equal(logs.message({ code: 'UPDATE_STARTED', args }), start + 'aether-proxy 1.0.0-r1');
		assert.equal(logs.message({ code: 'UPDATE_INSTALLED', args }), finish + 'aether-proxy 1.0.0-r1');
		assert.equal(logs.message({ code: 'FUTURE_EVENT', args: { value: 1 } }),
			'FUTURE_EVENT {"value":1}');
	}
});

test('M4-04 V7: both contextual msgids have exact Chinese translations; old msgid removed', () => {
	assert.equal(po['Update started: {package} {version}'], '开始更新：{package} {version}');
	assert.equal(po['Update finished: {package} {version}'], '已完成更新：{package} {version}');
	assert.equal(po['Installed {package} version {version}'], undefined);
});
