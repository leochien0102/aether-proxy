'use strict';
/* Guard the Select double itself: accepting the requested value unconditionally
 * hid regressions when the actual rendered choice list could not select it. */
const test = require('node:test');
const assert = require('node:assert/strict');
const { selectWidget } = require('./subscription-select');

test('T10.40 Select contract: empty choice enables optional and array sort controls rendered order', () => {
	const choices = { '0': 'zero', '12': 'twelve', '24': 'day', '': 'follow' };
	const widget = selectWidget('24', choices, { optional: false, sort: ['', '24', '12', '0'] });
	assert.equal(widget.value, '24');
	assert.deepEqual(widget.choices.map(([key]) => key), ['', '24', '12', '0']);
	assert.equal(selectWidget(undefined, choices, { optional: false }).value, '');
});

test('T10.40 Select contract: missing choices cannot magically preserve the requested value', () => {
	const choices = { '0': 'zero', '24': 'day', '': 'follow' };
	assert.equal(selectWidget('24', choices, { sort: ['', '0'] }).value, '');
	assert.equal(selectWidget('6', { '0': 'zero', '24': 'day' }, {}).value, '0');
});
