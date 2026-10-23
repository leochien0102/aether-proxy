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

/* T10.44: inspect populated feedback too, not just its empty placeholder.
 * Paragraphs have browser-default vertical margins; spans/divs do not.
 */
function marginlessMessages(messages) {
	for (const node of messages.flatMap(descendants)) {
		const style = node.style?.cssText ?? node.style ?? '';
		if (node.tag === 'p' || /margin(?:-top|-bottom|-block)?\s*:/.test(style))
			assert.match(style, /(?:^|;)\s*margin\s*:\s*0(?:\s*;|$)/,
				'feedback has no vertical margins: ' + node.tag);
	}
}

function nowrapActions(cell, labels) {
	assert.equal(cell.tag, 'td', 'keep the theme action cell for narrow-screen cards');
	assert.match(cell.class, /\bcbi-section-actions\b/, 'keep LuCI action-cell classes');
	const row = cell.lastChild;
	const buttons = descendants(row).filter(node => node.tag === 'button');
	assert.deepEqual(buttons.map(button => button.textContent), labels, 'preserve action order');
	for (const button of buttons)
		assert.match(button.style?.cssText ?? button.style ?? '', /white-space:\s*nowrap/,
			'button text stays on one line: ' + button.textContent);
	for (const rule of [/display:\s*flex/, /flex-wrap:\s*nowrap/, /align-items:\s*center/, /gap:\s*0\.25em/])
		assert.match(row.style?.cssText ?? row.style ?? '', rule, 'actions size to their content');
	for (const node of descendants(cell)) {
		const style = node.style?.cssText ?? node.style ?? '';
		assert.doesNotMatch(style, /(?:^|;)\s*(?:width|max-width)\s*:\s*[^;]+/,
			'no fixed width constrains the action cell, wrapper or buttons');
		assert.equal(node.attrs?.width, undefined, 'no width attribute constrains actions');
	}
}

module.exports = { actionRow, beforeTable, descendants, marginlessMessages, nowrapActions };
