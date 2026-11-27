'use strict';

/* Local modal DOM surface for required-field tests. Keep the shared E's
 * attribute semantics; add only tree queries, styles and bubbling events. */
const { element } = require('./loader');
function matches(node, selector) {
	/* Only the CSS surface used by the widgets; no layout/visibility emulation. */
	if (typeof node?.tag !== 'string' || node.tag === '#text')
		return false;
	const chain = selector.match(/^(.*?)\s*(>)\s*([^>]+)$/);
	if (chain)
		return matches(node, chain[3]) && matches(node.parentNode, chain[1].trim());
	const descendant = selector.match(/^(.*?)\s+([^ ]+)$/);
	if (descendant) {
		if (!matches(node, descendant[2])) return false;
		for (let parent = node.parentNode; parent; parent = parent.parentNode)
			if (matches(parent, descendant[1])) return true;
		return false;
	}
	let excluded = false;
	selector = selector.replace(/:not\(([^)]+)\)/g, (_, part) => {
		excluded ||= matches(node, part);
		return '';
	});
	if (excluded) return false;
	const tag = selector.match(/^[a-zA-Z][\w-]*/)?.[0];
	if (tag && node.tag !== tag) return false;
	for (const name of selector.matchAll(/\.([\w-]+)/g))
		if (!node.classList?.contains(name[1])) return false;
	for (const attr of selector.matchAll(/\[([\w-]+)(?:=["']?([^\]"']*)["']?)?\]/g)) {
		if (!Object.hasOwn(node.attrs, attr[1])) return false;
		if (attr[2] !== undefined && String(node.attrs[attr[1]]) !== attr[2]) return false;
	}
	return true;
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
		const [key, value] = declaration.split(':').map(part => part.trim());
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
		} },
		readOnly: { get: () => node.readonly, set: value => { node.readonly = value; } }
	});
	node.appendChild = child => { child.remove?.(); node.children.push(adopt(child)); return child; };
	node.append = (...children) => children.forEach(child => node.appendChild(child));
	node.contains = other => other === node || node.children.some(child => child?.contains?.(other));
	node.insertBefore = (child, before) => {
		child.remove?.();
		const index = node.children.indexOf(before);
		node.children.splice(index < 0 ? node.children.length : index, 0, adopt(child));
	};
	node.before = child => node.parentNode.insertBefore(child, node);
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
	node.matches = selector => matches(node, selector);
	node.closest = selector => {
		for (let current = node; current; current = current.parentNode)
			if (matches(current, selector)) return current;
		return null;
	};
	const listeners = {};
	node.addEventListener = (event, fn) => {
		if (!listeners[event]) {
			// Keep E's original event attribute, then all registered listeners.
			listeners[event] = typeof node.attrs[event] === 'function' ? [node.attrs[event]] : [];
			node.attrs[event] = node[event] = ev => node.emit({ type: event, ...ev });
		}
		listeners[event].push(fn);
	};
	node.emit = event => {
		const ev = typeof event === 'string' ? { type: event, bubbles: true } : event;
		ev.target ??= node;
		ev.currentTarget = node;
		ev.stopPropagation ??= () => { ev.cancelBubble = true; };
		ev.preventDefault ??= () => { ev.defaultPrevented = true; };
		// attrs.change(), emit() and dispatchEvent() share exactly one delivery
		// path. An original E attribute handler must not run a second time.
		let result;
		const handlers = listeners[ev.type] ?? (typeof node.attrs[ev.type] === 'function' ? [node.attrs[ev.type]] : []);
		for (const fn of handlers)
			result = fn.call(node, ev);
		if (ev.bubbles && !ev.cancelBubble)
			node.parentNode?.emit(ev);
		return result;
	};
	node.dispatchEvent = event => {
		const ev = { type: event.type, target: node, bubbles: event.bubbles, relatedTarget: event.relatedTarget };
		node.emit(ev);
		return !ev.defaultPrevented;
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
	addEventListener() {}, removeEventListener() {},
	createElementNS: (namespace, tag) => modalElement(tag)
};
// This double has no layout engine; actual rendering/observer timing stays in Chromium gates.
class ModalMutationObserver {
	constructor(callback) { this.callback = callback; }
	observe(node, options) {
		(node.attributeObservers ??= []).push({ callback: this.callback, attributes: options.attributeFilter });
	}
}
// Unit DOM has no geometry; observe registration is modeled, not fake pixel
// sizes. Native resize delivery and border boxes are exercised by Chromium.
class ModalResizeObserver {
	constructor(callback) { this.callback = callback; }
	observe(node, options) {
		(node.resizeObservers ??= []).push({ callback: this.callback, box: options?.box });
	}
}
globalThis.MutationObserver ??= ModalMutationObserver;
globalThis.ResizeObserver ??= ModalResizeObserver;
module.exports = { modalElement, modalDocument, ModalMutationObserver, ModalResizeObserver };
