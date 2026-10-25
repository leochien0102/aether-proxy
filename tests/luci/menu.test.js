'use strict';

/* Menu structure test (docs/tasks/m8.md T8.3 scenario 8).
 * T10.64 follows docs/10 r18: advanced precedes updates; logs is last.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const MENU = path.join(APP, 'root', 'usr', 'share', 'luci', 'menu.d', 'luci-app-aether-proxy.json');
const VIEWS = path.join(APP, 'htdocs', 'luci-static', 'resources', 'view', 'aether-proxy');

/* docs/10 「节点与订阅合并为一页」: seven visible pages and a hidden legacy alias. */
const PAGES = [ 'overview', 'nodes', 'access', 'rules', 'advanced', 'updates', 'logs' ];

test('scenario 8: menu — firstchild parent, seven visible pages in order, existing views, ACL dependency', () => {
	const menu = JSON.parse(fs.readFileSync(MENU, 'utf8'));
	const parent = 'admin/services/aether-proxy';

	assert.ok(menu[parent], 'the parent node exists');
	assert.equal(menu[parent].action.type, 'firstchild', 'the parent is a firstchild node');

	const childKeys = Object.keys(menu).filter((k) => k != parent && menu[k].title);
	assert.deepEqual(childKeys, PAGES.map((name) => `${parent}/${name}`),
		'exactly the seven documented visible pages, in the documented order');

	const visibleByOrder = childKeys.slice().sort((a, b) => menu[a].order - menu[b].order);
	assert.deepEqual(visibleByOrder, PAGES.map(name => `${parent}/${name}`),
		'T10.64: LuCI numeric order matches the documented visible page order');

	assert.equal(Object.keys(menu).length, 9, 'parent, seven pages and one legacy alias');
	assert.equal(menu[`${parent}/nodes`].title, 'Nodes & Subscriptions');
	const alias = menu[`${parent}/subscriptions`];
	assert.equal(Object.hasOwn(alias, 'title'), false, 'the legacy address is not a visible menu item');
	assert.deepEqual(alias.action, { type: 'alias', path: `${parent}/nodes` });
	assert.deepEqual(alias.depends.acl, ['luci-app-aether-proxy']);
	assert.equal(fs.existsSync(path.join(VIEWS, 'subscriptions.js')), false, 'the obsolete view is removed');

	let lastOrder = 0;

	for (const name of PAGES) {
		const node = menu[`${parent}/${name}`];

		assert.equal(node.action.type, 'view', `${name}: action type is view`);
		assert.equal(node.action.path, `aether-proxy/${name}`, `${name}: view path is aether-proxy/${name}`);
		assert.ok(Array.isArray(node.depends.acl) && node.depends.acl.includes('luci-app-aether-proxy'),
			`${name}: depends on the ACL luci-app-aether-proxy`);

		assert.ok(node.order > lastOrder, `${name}: menu order follows the docs order`);
		lastOrder = node.order;

		assert.ok(fs.existsSync(path.join(VIEWS, `${name}.js`)), `${name}: the view file exists`);
	}
});
