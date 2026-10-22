'use strict';

/* Shared T10.27 assertions for rendered action rows (docs/10 "UI 规则").
 * Inspect the actual parent, not a source string: a correctly styled decoy
 * must not hide a button left outside the row or a detached result region.
 */
const assert = require('node:assert/strict');

function descendants(node) {
	if (!node || typeof node !== 'object')
		return [];
	return [node, ...(node.children ?? []).flatMap(descendants)];
}

function actionRow(root, labels, messages = []) {
	const nodes = descendants(root);
	const buttons = labels.map(label => {
		const matches = nodes.filter(node => node.tag === 'button' && node.textContent === label);
		assert.equal(matches.length, 1, 'one action button: ' + label);
		return matches[0];
	});
	const row = nodes.find(node => node.children?.includes(buttons[0]));
	assert.equal(row?.tag, 'div', 'a separate action row contains the buttons');
	for (const rule of [ /display:\s*flex/, /justify-content:\s*flex-end/, /align-items:\s*center/,
		/gap:\s*0\.5em/, /flex-wrap:\s*wrap/, /margin:\s*0\.5em\s+0\s+1em/ ])
		assert.match(row.attrs.style, rule, labels.join(', '));
	assert.deepEqual(row.children.filter(node => node?.tag === 'button'), buttons, 'button order is unchanged');
	for (const message of messages) {
		assert.ok(row.children.includes(message), 'result/progress shares the action row');
		assert.ok(row.children.indexOf(message) < row.children.indexOf(buttons[0]), 'text precedes every button');
		assert.equal(nodes.filter(node => node === message).length, 1, 'result is mounted exactly once');
	}
	return row;
}

function beforeTable(root, row, table) {
	const nodes = descendants(root);
	assert.ok(nodes.includes(table), 'rendered table/form exists');
	assert.ok(!descendants(row).includes(table), 'table is not inside the action row');
	assert.ok(nodes.indexOf(row) < nodes.indexOf(table), 'table-level actions precede the table');
}

module.exports = { actionRow, beforeTable, descendants };
