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

/* docs/10 「rpcd 插件」: the 12 ubus methods with their declared params. */
const PLUGIN_METHODS = {
	version: [],
	status: [],
	service: [ 'action' ],
	check: [],
	job_start: [ 'kind', 'args' ],
	job_status: [ 'id' ],
	events: [ 'since', 'level' ],
	probe_results: [],
	log: [ 'source', 'lines' ],
	node_import: [ 'uri' ],
	list_file: [ 'name' ],
	save_file: [ 'name', 'content' ]
};

test('scenario 9: static checks — page requires, rpc.declare only in common.js with the 12 plugin methods, no cbi-button-reset, po complete', async (t) => {
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

	/* common.js declares exactly the 12 plugin methods with the documented
	   params — cross-checked against the ACL and the plugin source */
	const acl = JSON.parse(read(ACL));
	const aclMethods = [
		...acl['luci-app-aether-proxy'].read.ubus.aetherproxy,
		...acl['luci-app-aether-proxy'].write.ubus.aetherproxy
	].sort();

	assert.deepEqual(aclMethods, Object.keys(PLUGIN_METHODS).sort(), 'ACL sanity: exactly the 12 methods');

	const rpc = createRpc();
	loadModule(COMMON, { rpc, baseclass: { extend: (o) => o } }, { window: {}, document: { addEventListener() {}, removeEventListener() {} } });

	const declared = {};
	for (const d of rpc.declared)
		declared[d.method] = d;

	assert.deepEqual(Object.keys(declared).sort(), Object.keys(PLUGIN_METHODS).sort(),
		'common.js declares exactly the 12 plugin methods');
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
		for (const m of src.matchAll(/_\('([^']*)'\)/g))
			msgids.add(m[1]);

	for (const id of msgids) {
		assert.ok(id in po, `po has an entry for "${id}"`);
		assert.ok(po[id].length > 0, `po translation for "${id}" is non-empty`);
	}
});
