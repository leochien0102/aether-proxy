'use strict';

/* T10.47 / docs/10 r14: pin the shared validation double's save behavior so
 * page tests cannot pass by silently skipping the optional add-box validator.
 * Dropdown/create-item-input and plain text add boxes use the same validation
 * contract; widget layout and datatype parsing remain outside this double.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { renderList, parseList } = require('./dynamic-list');

for (const values of [[], ['https://one.example', 'https://two.example']]) {
	test('T10.47 scenario 3: list double validates each item and the empty add box: ' + values.length + ' items', () => {
		const calls = [], writes = [];
		const option = { key: 'channel_urls', validate: (section, value) => {
			calls.push([section, value]);
			return true;
		} };
		const input = renderList(option, 'update', values);
		assert.deepEqual(calls, [...values, ''].map(value => ['update', value]));
		assert.equal(input.isValid(), true);
		assert.deepEqual(input.value, values, 'the unused add box is not an item');
		parseList(option, 'update', input, values, value => writes.push(value), () => {});
		assert.deepEqual(writes, []);
		input.value = ['https://changed.example'];
		input.triggerValidation();
		parseList(option, 'update', input, values, value => writes.push(value), () => {});
		assert.deepEqual(writes, [['https://changed.example']], 'editing a valid list still writes it');
	});
}

test('T10.47 scenario 3: optional empty add-box failure makes the rendered option invalid and blocks Save', () => {
	const writes = [];
	const option = { key: 'channel_urls', validate: (section, value) => value === '' ? 'bad add box' : true };
	const input = renderList(option, 'update', ['https://valid.example']);
	assert.equal(input.isValid(), false, 'optional is not a bypass for custom validation');
	assert.equal(input.getValidationError(), 'bad add box');
	assert.throws(() => parseList(option, 'update', input, ['https://valid.example'],
		value => writes.push(value), () => writes.push('remove')), /bad add box/);
	assert.deepEqual(writes, []);
});
