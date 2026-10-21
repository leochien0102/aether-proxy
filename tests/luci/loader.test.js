'use strict';

/* Shared E() contract from docs/10 UI rules (T10.18). Attribute presence,
 * not JavaScript truthiness, determines initial boolean DOM properties.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { element: E } = require('./loader');

for (const key of [ 'disabled', 'checked', 'selected', 'readonly', 'hidden', 'multiple' ]) {
	test(`T10.18 scenario 1: ${key} follows attribute presence and later DOM assignment`, () => {
		for (const value of [ false, true, '', key, 0 ]) {
			const node = E('input', { [key]: value });
			assert.equal(node[key], true, `${key}=${JSON.stringify(value)} still sets the attribute`);
			node[key] = false;
			assert.equal(node[key], false, 'later DOM assignment overrides initial state');
		}
		assert.equal(E('input', { [key]: null })[key], false);
		assert.equal(E('input', { [key]: undefined })[key], false);
		assert.equal(E('input')[key], false);
	});
}

test('T10.18 shared E: short calls, text-only children, selected options and mutable contents', () => {
	const node = E('p', '<img src=x>');
	assert.equal(node.textContent, '<img src=x>');
	assert.equal(node.childNodes[0].tag, '#text');
	assert.equal(node.childNodes[0].text, '<img src=x>');
	assert.equal(E([node]).lastChild, node);
	const select = E('select', {}, [
		E('option', { value: 'a' }, 'A'), E('option', { value: 'b', selected: true }, 'B')
	]);
	assert.equal(select.value, 'b');
	assert.equal(E('select', {}, [E('option', { value: 'a' }, 'A')]).value, 'a');
	node.replaceChildren(E('span', {}, 'new'), ' text');
	assert.equal(node.textContent, 'new text');
	node.textContent = 'replacement';
	assert.deepEqual(node.children, ['replacement']);
});
