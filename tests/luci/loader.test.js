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

test('T10.40 shared E: wrapper title attribute can be set and completely removed', () => {
	const wrapper = E('span');
	wrapper.setAttribute('title', 'Please save and apply first');
	assert.equal(wrapper.attrs.title, 'Please save and apply first');
	assert.equal(wrapper.title, 'Please save and apply first');
	wrapper.removeAttribute('title');
	assert.equal(Object.hasOwn(wrapper.attrs, 'title'), false);
	assert.equal(Object.hasOwn(wrapper, 'title'), false);
});

test('T10.18 shared E: short calls, text-only children, selected options and mutable contents', () => {
	const node = E('p', {}, '<img src=x>');
	/* A single string child is an innerHTML write in luci-base, so it is markup,
	 * not a text node (D-F3/T9.42). Markup writes are recorded for assertions. */
	assert.equal(node.innerHTML, '<img src=x>');
	assert.equal(node.scalarHtml, true);
	assert.deepEqual(node.childNodes, []);
	assert.equal(E([node]).lastChild, node);
	const select = E('select', {}, [
		E('option', { value: 'a' }, 'A'), E('option', { value: 'b', selected: true }, 'B')
	]);
	assert.equal(select.value, 'b');
	assert.equal(E('select', {}, [E('option', { value: 'a' }, 'A')]).value, 'a');
	node.replaceChildren(E('span', {}, 'new'), ' text');
	assert.equal(node.textContent, 'new text');
	node.textContent = 'replacement';
	assert.equal(node.childNodes[0].tag, '#text');
	assert.equal(node.textContent, 'replacement');
});

/* T9.42/D-F3: the double must follow luci-base `dom.append()` for every input
 * shape, because the whole XSS gate depends on "array = text, scalar = HTML".
 * Markup is recorded, never parsed: an element child is kept as an element and
 * a text child is a `#text` node, exactly like `document.createTextNode()`. */
test('T9.42: E() children follow the SDK append contract for scalars and arrays', () => {
	const payloads = [ '', '<>&"\'', '名称 — ünïcode', 'x'.repeat(4096), 'plain text' ];

	for (const payload of payloads) {
		/* Array item: a text node, never markup. */
		const text = E('p', {}, [ payload ]);
		assert.equal(text.childNodes.length, 1, 'array child becomes one node');
		assert.equal(text.childNodes[0].tag, '#text');
		assert.equal(text.childNodes[0].text, payload);
		assert.equal(text.textContent, payload);
		assert.deepEqual(text.html, [], 'an array child never uses the HTML path');

		/* Scalar: recorded as an innerHTML write. Markup-free text still reads
		 * back as the string (a browser would parse it into one text node). */
		const html = E('p', {}, payload);
		assert.deepEqual(html.html, [ payload ], 'a scalar child is an innerHTML write');
		assert.equal(html.scalarHtml, true);
		if (payload.includes('<'))
			assert.equal(html.textContent, '', 'markup is not text without a parser');
		else
			assert.equal(html.textContent, payload);
	}

	/* DOM child and nested function child. */
	const span = E('span', {}, [ 'child' ]);
	assert.equal(E('p', {}, span).childNodes[0], span);
	assert.equal(E('p', {}, () => [ 'from function' ]).textContent, 'from function');

	/* Array holes/null items: lucid append stringifies every non-element item. */
	assert.equal(E('p', {}, [ null ]).textContent, 'null');
	assert.equal(E('p', {}, [ undefined ]).textContent, 'undefined');

	/* An empty array adds nothing; null and an omitted child add nothing either. */
	assert.deepEqual(E('p', {}, []).childNodes, []);
	assert.deepEqual(E('p', {}, null).childNodes, []);
	assert.deepEqual(E('p', {}).childNodes, []);
	assert.deepEqual(E('p', {}, null).html, [], 'null is not an HTML write');
});

test('T9.42: dom.content/contentChildren applies the same rules as E()', () => {
	const { appendChildren, contentChildren } = require('./loader');
	const node = E('div', {}, [ 'old' ]);
	contentChildren(node, '<img src=x>');
	assert.deepEqual(node.children, []);
	assert.equal(node.innerHTML, '<img src=x>');

	contentChildren(node, [ '<img src=x>' ]);
	assert.equal(node.innerHTML, '');
	assert.equal(node.textContent, '<img src=x>');
	assert.equal(node.childNodes[0].tag, '#text');

	appendChildren(node, [ E('b', {}, [ 'x' ]) ]);
	assert.equal(node.childNodes.length, 2);
	assert.equal(node.childNodes[1].tag, 'b');
	assert.ok(!node.childNodes.some(child => child.tag === 'img'));
});

/* T9.42/R2: the review compared the double with the real SDK `append()` and
 * found five differences (function argument, true sparse arrays, text-node
 * identity, state after an innerHTML write, return values). These cases pin
 * the SDK behaviour; they are a contract test, not a browser HTML parser. */
test('T9.42/R2: E()/append() match the SDK for functions, holes, text nodes and returns', () => {
	const { appendChildren, textNode, isDomNode } = require('./loader');

	/* A function child is called with the target node; its result is appended. */
	let seen = null;
	const fn = E('div', {}, node => { seen = node; return [ 'from function' ]; });
	assert.equal(seen, fn, 'the callback receives the node being built');
	assert.equal(fn.textContent, 'from function');

	/* Array holes and null items become text, exactly like `${children[i]}`. */
	const sparse = E('p', {}, Array(1));
	assert.equal(sparse.childNodes.length, 1);
	assert.equal(sparse.childNodes[0].tag, '#text');
	assert.equal(sparse.childNodes[0].text, 'undefined');
	assert.equal(E('p', {}, [ undefined ]).textContent, 'undefined');
	assert.equal(E('p', {}, [ null ]).textContent, 'null');

	/* Scalar null/undefined/'' append nothing (no innerHTML write). */
	for (const absent of [ null, undefined, '' ]) {
		const node = E('p', {}, absent);
		assert.deepEqual(node.childNodes, []);
		assert.equal(node.textContent, '');
	}
	assert.deepEqual(E('p', {}, null).html, [], 'null is not an HTML write');

	/* Text nodes keep their identity in both the array and scalar position. */
	const direct = textNode('direct');
	assert.equal(E('p', {}, direct).childNodes[0], direct);
	const nested = textNode('nested');
	assert.equal(E('p', {}, [ nested ]).childNodes[0], nested);

	/* A text node or fragment is a DOM node (never stringified); plain objects
	 * are not, so they become text. */
	assert.equal(isDomNode(textNode('x')), true);
	assert.equal(isDomNode(E([ 'x' ])), true, 'a fragment is a DOM node');
	assert.equal(isDomNode({ tag: undefined }), false);
	assert.equal(E('p', {}, E([ E('b', {}, [ 'x' ]) ])).textContent, 'x',
		'a fragment is appended as a node instead of "[object Object]"');

	/* Appending after an innerHTML write keeps the earlier content. */
	const mixed = E('p', {}, 'before');
	assert.equal(appendChildren(mixed, [ 'after' ]), mixed.lastChild);
	assert.equal(mixed.textContent, 'beforeafter');
	assert.deepEqual(mixed.childNodes.map(node => node.tag), [ '#text', '#text' ]);

	/* Return values follow luci.js append(). */
	const block = E('div');
	assert.equal(appendChildren(block, [ 'a', 'b' ]), block.lastChild);
	const span = E('span');
	assert.equal(appendChildren(block, span), span, 'a DOM child is returned as-is');
	assert.equal(appendChildren(block, 'html'), block.lastChild, 'innerHTML writes return lastChild');
	assert.equal(appendChildren(block, '<img src=x>'), null, 'markup has no parsed lastChild here');
	assert.equal(appendChildren(block, null), null);

	/* DOMString conversions: LegacyNullToEmptyString for innerHTML/textContent. */
	assert.equal(E('p', {}, '').innerHTML, '');
	const writers = E('p');
	writers.innerHTML = null;
	assert.equal(writers.innerHTML, '', 'innerHTML = null is the empty string');
	writers.innerHTML = undefined;
	assert.equal(writers.innerHTML, 'undefined');
	writers.textContent = null;
	assert.equal(writers.children.length, 1);
	assert.equal(writers.children[0].tag, '#text');
	assert.equal(writers.textContent, '', 'textContent = null is the empty string');
	writers.textContent = undefined;
	assert.equal(writers.textContent, 'undefined');

	/* replaceChildren() never parses markup: strings become text nodes. */
	const replaced = E('p');
	replaced.replaceChildren('<img src=x>');
	assert.equal(replaced.innerHTML, '');
	assert.equal(replaced.textContent, '<img src=x>');
	assert.equal(replaced.childNodes[0].tag, '#text');
});
