'use strict';

/* Static source checks for the LuCI app (docs/tasks/m8.md T8.3 scenario 9). */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { createRpc, loadModule, parsePo } = require('./loader.js');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const HTDOCS = path.join(APP, 'htdocs', 'luci-static', 'resources');
const VIEWS = path.join(HTDOCS, 'view', 'aether-proxy');
const COMMON = path.join(HTDOCS, 'aether-proxy', 'common.js');
const PLUGIN = path.join(APP, 'root', 'usr', 'share', 'rpcd', 'ucode', 'aetherproxy.uc');
const ACL = path.join(APP, 'root', 'usr', 'share', 'rpcd', 'acl.d', 'luci-app-aether-proxy.json');
const MENU = path.join(APP, 'root', 'usr', 'share', 'luci', 'menu.d', 'luci-app-aether-proxy.json');
const PO = path.join(APP, 'po', 'zh_Hans', 'aether-proxy.po');

function read(p) {
	return fs.readFileSync(p, 'utf8');
}

function viewSources() {
	const map = new Map();

	for (const f of fs.readdirSync(VIEWS).sort())
		if (f.endsWith('.js'))
			map.set(f, read(path.join(VIEWS, f)));

	return map;
}

/* The pure view-model modules next to common.js; their _() strings must be
   translated just like the views' ones (docs/10 「页面卡的写法」). */
function modelSources() {
	const dir = path.join(HTDOCS, 'aether-proxy', 'model');
	const map = new Map();

	if (!fs.existsSync(dir))
		return map;

	for (const f of fs.readdirSync(dir).sort())
		if (f.endsWith('.js'))
			map.set(path.join('aether-proxy', 'model', f), read(path.join(dir, f)));

	return map;
}

/* docs/10 「rpcd 插件」: the current ubus methods with their declared params. */
const PLUGIN_METHODS = {
	version: [],
	status: [],
	service: [ 'action' ],
	check: [],
	job_start: [ 'kind', 'args' ],
	job_status: [ 'id' ],
	events: [ 'since', 'level' ],
	probe_results: [],
	probe_now: [],
	sub_status: [],
	data_status: [],
	stats: [],
	log: [ 'source', 'lines' ],
	node_import: [ 'uri' ],
	list_file: [ 'name' ],
	save_file: [ 'name', 'content' ]
};

test('scenario 9: static checks — shared RPC method set, page requires, no reset buttons, po complete', async (t) => {
	const common = read(COMMON);
	const views = viewSources();

	/* every page either requires the common module or does not touch rpc at all;
	   rpc.declare may only appear in common.js */
	for (const [ name, src ] of views) {
		const requiresCommon = /'require aether-proxy\.common as ap'/.test(src);
		const usesRpc = /(^|[^\w.])rpc\./.test(src);

		assert.ok(requiresCommon || !usesRpc, `${name}: requires the common module or does not call rpc`);
		assert.ok(!/rpc\s*\.\s*declare/.test(src), `${name}: must not rpc.declare`);
	}

	assert.match(common, /rpc\s*\.\s*declare/, 'common.js declares the rpc methods');

	/* common.js declares exactly the current plugin methods with the documented
	   params — cross-checked against the ACL and the plugin source */
	const acl = JSON.parse(read(ACL));
	const aclMethods = [
		...acl['luci-app-aether-proxy'].read.ubus.aetherproxy,
		...acl['luci-app-aether-proxy'].write.ubus.aetherproxy
	].sort();

	assert.deepEqual(aclMethods, Object.keys(PLUGIN_METHODS).sort(), 'ACL sanity: exactly the current methods');

	const rpc = createRpc();
	loadModule(COMMON, { rpc, baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });

	const declared = {};
	for (const d of rpc.declared)
		declared[d.method] = d;

	assert.deepEqual(Object.keys(declared).sort(), Object.keys(PLUGIN_METHODS).sort(),
		'common.js declares exactly the current plugin methods');
	assert.deepEqual(rpc.declared.filter((d) => d.object != 'aetherproxy'), [],
		'all declarations target the aetherproxy object');

	for (const [ method, params ] of Object.entries(PLUGIN_METHODS))
		assert.deepEqual(declared[method].params, params, `declaration of ${method} carries the documented params`);

	const plugin = read(PLUGIN);
	for (const method of Object.keys(PLUGIN_METHODS))
		assert.match(plugin, new RegExp(`^\\s*${method}:\\s*\\{`, 'm'), `the plugin implements ${method}`);

	/* docs/10 「UI 规则」: never use cbi-button-reset */
	for (const [ name, src ] of views)
		assert.ok(!src.includes('cbi-button-reset'), `${name}: no cbi-button-reset`);
	assert.ok(!common.includes('cbi-button-reset'), 'common.js: no cbi-button-reset');

	/* placeholder pages and overview provide no save/reset buttons (pages that
	   build real forms with 'require form' are exempt) */
	for (const [ name, src ] of views) {
		if (/'require form'/.test(src))
			continue;

		for (const handler of [ 'handleSave', 'handleSaveApply', 'handleReset' ])
			assert.match(src, new RegExp(`\\b${handler}:\\s*null\\b`), `${name}: ${handler} is null`);
	}

	/* po: every menu title and every _() string of the sources (views, common
	   and the model modules) has a non-empty Chinese translation */
	const po = parsePo(read(PO));
	const msgids = new Set();

	for (const node of Object.values(JSON.parse(read(MENU))))
		msgids.add(node.title);

	for (const src of [ common, ...views.values(), ...modelSources().values() ])
		for (const m of src.matchAll(/_\('([^']*)', 'aether-proxy'\)/g))
			msgids.add(m[1]);

	for (const id of msgids) {
		assert.ok(id in po, `po has an entry for "${id}"`);
		assert.ok(po[id].length > 0, `po translation for "${id}" is non-empty`);
	}
});

/* LuCI form options: `depends` is a method. Assigning to it (`o.depends = {…}`)
   replaces the method and registers no condition, so the option always shows;
   an array value (`{ key: [a, b] }`) never matches, because form.js isEqual()
   compares a string form value with the array and fails on the type. Use one
   call per accepted value: o.depends('key', 'a'); o.depends('key', 'b'). Found
   in the T8.7 review (the T8.5 nodes page had both forms). */
test('views call depends() with scalar values only', () => {
	for (const name of fs.readdirSync(VIEWS).filter((f) => f.endsWith('.js'))) {
		const src = read(path.join(VIEWS, name));

		assert.doesNotMatch(src, /\.depends\s*=/, `${name}: depends is assigned instead of called`);
		assert.doesNotMatch(src, /\.depends\(\s*\{[^}]*\[/, `${name}: depends() with an array value never matches`);
		assert.doesNotMatch(src, /\.depends\(\s*'[^']*'\s*,\s*\[/, `${name}: depends() with an array value never matches`);
	}
});

/* Context is part of a PO key: menu and page entries may share a msgid. This
 * small helper follows the real catalog's one-line fields; the global gate
 * additionally decodes escapes and continuation lines in synthetic cases. */
function poKeys(text) {
	return text.trim().split(/\n\s*\n/).flatMap(block => {
		const id = /^msgid "((?:[^"\\]|\\.)*)"$/m.exec(block)?.[1];
		const context = /^msgctxt "((?:[^"\\]|\\.)*)"$/m.exec(block)?.[1] ?? '';
		return id ? [ JSON.stringify([ context, id ]) ] : [];
	});
}

// msgfmt rejects a catalog with a repeated key; parallel page cards each append to the po.
test('po has no duplicate msgid', () => {
	const ids = poKeys(fs.readFileSync(path.join(APP, 'po', 'zh_Hans', 'aether-proxy.po'), 'utf8'));
	const repeated = ids.filter((id, i) => ids.indexOf(id) != i);
	assert.deepEqual(repeated, []);
});
