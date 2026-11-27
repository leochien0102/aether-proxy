'use strict';

/* Local modal DOM surface for required-field tests. Keep the shared E's
 * attribute semantics; add only tree queries, styles and bubbling events. */
const { element } = require('./loader');
function matches(node, selector) {
	/* querySelectorAll returns elements only: skip text nodes and plain values. */
	if (typeof node?.tag !== 'string' || node.tag === '#text')
		return false;
	if (selector.startsWith('.'))
		return node.classList?.contains(selector.slice(1)) === true;
	return node.tag === selector;
}
function modalElement(...args) {
	const node = element(...args);
	const declarations = typeof node.style === 'string' ? node.style.split(';') : [];
	node.style = {};
	Object.defineProperty(node.style, 'setProperty', {
		enumerable: false,
		value(name, value, priority = '') {
			this[name.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
			(this.priorities ??= {})[name] = priority;
		}
	});
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
	Object.defineProperties(node, {
		parentElement: { get: () => node.parentNode ?? null },
		nextElementSibling: { get: () => {
			const siblings = node.parentNode?.children ?? [];
			return siblings.slice(siblings.indexOf(node) + 1).find(child =>
				typeof child?.tag === 'string' && child.tag !== '#text') ?? null;
		} }
	});
	node.appendChild = child => { node.children.push(adopt(child)); return child; };
	node.append = (...children) => children.forEach(child => node.appendChild(child));
	node.contains = other => other === node || node.children.some(child => child?.contains?.(other));
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
	const descendants = root => (root.children ?? []).filter(child =>
		child && typeof child === 'object' && child.tag !== '#text')
		.flatMap(child => [child, ...descendants(child)]);
	node.querySelectorAll = selector => descendants(node).filter(child =>
		selector.split(/,\s*/).some(part => matches(child, part)));
	node.querySelector = selector => node.querySelectorAll(selector)[0] ?? null;
	const listeners = {};
	node.addEventListener = (event, fn) => (listeners[event] ??= []).push(fn);
	node.emit = event => {
		const ev = typeof event === 'string' ? { type: event, target: node, bubbles: true } : event;
		for (const fn of listeners[ev.type] ?? [])
			fn(ev);
		if (ev.bubbles)
			node.parentNode?.emit(ev);
	};
	node.dispatchEvent = event => {
		node.emit({ type: event.type, target: node, bubbles: event.bubbles });
		return true;
	};
	node.focus = () => {
		const previous = modalDocument.activeElement;
		modalDocument.activeElement = node;
		previous?.emit({ type: 'focusout', target: previous, relatedTarget: node, bubbles: true });
		node.emit('focusin');
	};
	for (const method of ['setAttribute', 'removeAttribute']) {
		const original = node[method];
		node[method] = function(name, ...values) {
			original.call(this, name, ...values);
			for (const observer of node.attributeObservers ?? [])
				if (observer.attributes.includes(name)) observer.callback();
		};
	}
	return node;
}
const modalDocument = {
	activeElement: null,
	createElementNS: (namespace, tag) => modalElement(tag)
};
// This double has no layout engine; actual rendering/observer timing stays in Chromium gates.
class ModalMutationObserver {
	constructor(callback) { this.callback = callback; }
	observe(node, options) {
		(node.attributeObservers ??= []).push({ callback: this.callback, attributes: options.attributeFilter });
	}
}
module.exports = { modalElement, modalDocument, ModalMutationObserver };
