'use strict';

/* Menu structure test (docs/tasks/m8.md T8.3 scenario 8). */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const MENU = path.join(APP, 'root', 'usr', 'share', 'luci', 'menu.d', 'luci-app-aether-proxy.json');
const VIEWS = path.join(APP, 'htdocs', 'luci-static', 'resources', 'view', 'aether-proxy');

/* docs/10 「LuCI 页面」 and 「公共模块与菜单」: the 8 pages in their order. */
const PAGES = [ 'overview', 'nodes', 'subscriptions', 'access', 'rules', 'updates', 'logs', 'advanced' ];

test('scenario 8: menu — firstchild parent, exactly the 8 child pages in order, existing views, ACL dependency', () => {
	const menu = JSON.parse(fs.readFileSync(MENU, 'utf8'));
	const parent = 'admin/services/aether-proxy';

	assert.ok(menu[parent], 'the parent node exists');
	assert.equal(menu[parent].action.type, 'firstchild', 'the parent is a firstchild node');

	const childKeys = Object.keys(menu).filter((k) => k != parent);
	assert.deepEqual(childKeys, PAGES.map((name) => `${parent}/${name}`),
		'exactly the 8 documented child pages, in the documented order');

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
