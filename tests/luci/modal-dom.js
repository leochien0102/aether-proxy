'use strict';

/* Local modal DOM surface for required-field tests. Keep the shared E's
 * attribute semantics; add only tree queries, styles and bubbling events. */
const { element } = require('./loader');
function matches(node, selector) {
	if (selector.startsWith('.'))
		return node.classList.contains(selector.slice(1));
	return node.tag === selector;
}
function modalElement(...args) {
	const node = element(...args);
	const declarations = typeof node.style === 'string' ? node.style.split(';') : [];
	node.style = {};
	for (const declaration of declarations) {
		const [key, value] = declaration.split(':');
		if (key)
			node.style[key.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
	}
	const classes = new Set((node.class ?? '').split(/\s+/).filter(Boolean));
	node.classList = {
		contains: value => classes.has(value),
		add: value => classes.add(value), remove: value => classes.delete(value)
	};
	const adopt = child => {
		if (child && typeof child === 'object')
			child.parentNode = node;
		return child;
	};
	node.children.forEach(adopt);
	node.appendChild = child => { node.children.push(adopt(child)); return child; };
	node.insertBefore = (child, before) => {
		const index = node.children.indexOf(before);
		node.children.splice(index < 0 ? node.children.length : index, 0, adopt(child));
	};
	node.remove = () => {
		if (node.parentNode) {
			const siblings = node.parentNode.children;
			siblings.splice(siblings.indexOf(node), 1);
			node.parentNode = null;
		}
	};
	const descendants = root => root.children.filter(child => child && typeof child === 'object')
		.flatMap(child => [child, ...descendants(child)]);
	node.querySelectorAll = selector => descendants(node).filter(child =>
		selector.split(/,\s*/).some(part => matches(child, part)));
	node.querySelector = selector => node.querySelectorAll(selector)[0] ?? null;
	const listeners = {};
	node.addEventListener = (event, fn) => (listeners[event] ??= []).push(fn);
	node.emit = event => {
		for (const fn of listeners[event] ?? [])
			fn({ target: node });
		node.parentNode?.emit(event);
	};
	return node;
}
module.exports = { modalElement };
