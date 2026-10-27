'use strict';

/* Test double loader for the aether-proxy LuCI modules (docs/tasks/m8.md T8.3).
 *
 * loadModule() loads a LuCI class module the way luci-base's luci.js does it
 * (compileClass): the leading string statements are scanned for 'use strict'
 * and 'require x [as y]', the source is wrapped in
 * (function(window, document, L, <alias>…) { … }) and evaluated with the
 * requested module instances as arguments. The doubles for rpc / baseclass /
 * view live in the test files. element() supplies their shared mutable E()
 * with LuCI boolean-attribute semantics (docs/10 UI rules, T10.18).
 * Only node built-ins are used.
 */

const fs = require('node:fs');

const REQUIRE_RE = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/;
const STRICT_RE = /^use[ \t]+strict$/;

/* Character-level scanner, mirroring LuCI's compileClass so that the same
 * files resolve the same dependencies in the browser and in the tests. */
function scanRequires(source) {
	const requires = [];

	for (let i = 0, off = -1, prev = -1, quote = -1, comment = -1, esc = false; i < source.length; i++) {
		const chr = source.charCodeAt(i);

		if (esc) {
			esc = false;
		}
		else if (comment != -1) {
			if ((comment == 47 && chr == 10) || (comment == 42 && prev == 42 && chr == 47))
				comment = -1;
		}
		else if ((chr == 42 || chr == 47) && prev == 47) {
			comment = chr;
		}
		else if (chr == 92) {
			esc = true;
		}
		else if (chr == quote) {
			const s = source.substring(off, i);
			const m = REQUIRE_RE.exec(s);

			if (m)
				requires.push({ name: m[1], as: m[2] || m[1].replace(/[^a-zA-Z0-9_]/g, '_') });
			else if (!STRICT_RE.exec(s))
				break;

			off = -1;
			quote = -1;
		}
		else if (quote == -1 && (chr == 34 || chr == 39)) {
			off = i + 1;
			quote = chr;
		}

		prev = chr;
	}

	return requires;
}

/* Minimal document double: a hidden flag plus visibilitychange listeners. */
function createDocument() {
	const listeners = {};

	return {
		hidden: false,

		addEventListener(type, fn) {
			(listeners[type] = listeners[type] || []).push(fn);
		},

		removeEventListener(type, fn) {
			const l = listeners[type] || [];
			const i = l.indexOf(fn);

			if (i != -1)
				l.splice(i, 1);
		},

		/* Test helper: fire an event the way the browser would. */
		emit(type) {
			for (const fn of (listeners[type] || []).slice())
				fn({ type });
		}
	};
}

/* rpc double: records every declare() option and every issued call; the
 * handler installed by the test decides what each call returns. A handler
 * may return a value (resolved asynchronously) or a promise (fully
 * controlled resolution, rejection or pending forever). */
function createRpc() {
	const declared = [];
	const calls = [];
	let handler = null;

	return {
		declared,
		calls,

		setHandler(fn) {
			handler = fn;
		},

		declare(options) {
			declared.push(options);

			const names = options.params || [];

			return function(...args) {
				const params = {};

				/* luci-base rpc.js sets every declared name, then posts the request as
				   JSON, which drops undefined values: record what goes on the wire. */
				for (let i = 0; i < names.length; i++)
					if (args[i] !== undefined)
						params[names[i]] = args[i];

				calls.push({ object: options.object, method: options.method, params });

				if (!handler)
					return Promise.resolve({});

				return Promise.resolve().then(() => handler(options.method, params));
			};
		}
	};
}

/* Load `file` like LuCI would. `modules` maps require names to doubles;
 * `env` supplies window, document and L. Returns the module's export. */
function loadModule(file, modules, env) {
	const source = fs.readFileSync(file, 'utf8');
	const requires = scanRequires(source);
	const params = [ 'window', 'document', 'L' ];

	for (const r of requires)
		params.push(r.as);

	const factory = new Function(params.join(', '), source);

	const instances = requires.map(function(r) {
		/* Always exercise the real shared save adapter in older page tests too.
		 * It has no runtime dependency beyond baseclass, unlike form/uci doubles. */
		if (r.name == 'aether-proxy.form-defaults' && !(r.name in modules))
			return loadModule(require('node:path').resolve(__dirname,
				'../../luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/form-defaults.js'),
			{ baseclass: { extend: object => object } }, env);
		/* Node-only tests stub subscription loading/rendering, not the shared
		 * modal guard. Exercise the shipped guard rather than a no-op copy. */
		if (r.name == 'aether-proxy.subscriptions-block' && modules[r.name] && !modules[r.name].required_options) {
			const block = loadModule(require('node:path').resolve(__dirname,
				'../../luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/subscriptions-block.js'),
			{ ...modules, baseclass: { extend: object => object },
				'aether-proxy.model.subscriptions': {} }, env);
			modules[r.name].required_options = block.required_options;
		}
		if (!(r.name in modules))
			throw new Error('loader: no double provided for require "' + r.name + '"');

		return modules[r.name];
	});

	return factory.apply(null, [ env.window, env.document, env.L ?? {} ].concat(instances));
}

/* po entries as msgid → msgstr; msgid and msgstr must sit on adjacent lines.
 * Shared by the tests that use the po as the _() translation double. */
function parsePo(text) {
	const entries = {};
	const lines = text.split('\n');

	for (let i = 0; i < lines.length - 1; i++) {
		const id = /^msgid "(.+)"$/.exec(lines[i]);
		const str = /^msgstr "(.*)"$/.exec(lines[i + 1]);

		if (id && str)
			entries[id[1]] = str[1];
	}

	return entries;
}

/* Text node double. Real `document.createTextNode()` produces exactly this:
 * a node whose text is never parsed as markup. `children` is an empty list so
 * traversal helpers can treat every node the same way. */
function textNode(text) {
	const value = String(text);

	return { tag: '#text', text: value, textContent: value, childNodes: [], children: [], attrs: {} };
}

/* DOM node discriminator: only nodes created by this double carry a string
 * `tag` (elements, fragments and #text nodes). Used where luci-base calls
 * `dom.elem(node)` before deciding between appendChild and innerHTML. */
function isDomNode(node) {
	return node != null && typeof node === 'object' && typeof node.tag === 'string';
}

/* Elements and document fragments (everything except text nodes). */
function isElement(node) {
	return isDomNode(node) && node.tag !== '#text';
}

/* Shared mutable E() double (docs/10 UI rules, T10.18, T9.42). LuCI skips only
 * null/undefined attributes: even false creates a boolean HTML attribute.
 * Keep raw attrs for source-level assertions, but read runtime state through
 * DOM properties so a later `button.disabled = false` takes effect.
 *
 * Children follow luci-base `dom.create()` -> `dom.append()` (luci.js:1311-1335,
 * :1504-1543 in 24.10.8, same logic in 25.12.5):
 *   - an ARRAY appends every item: a DOM node keeps its identity, any other
 *     value (including null/undefined and array holes) becomes a text node;
 *   - a FUNCTION is called with the target node and its result is appended;
 *   - a DOM node is appended as-is;
 *   - any other non-null value is converted to a string and assigned to
 *     `innerHTML`, which replaces the previous children.
 * Scalar writes are recorded in `html` so a test can assert that user text
 * never took the HTML path; the double has no HTML parser, so a scalar that
 * contains `<` produces no text node (the browser would parse elements).
 * Text children are synthesized on read, except text nodes passed in as
 * children: those keep their identity, exactly like appendChild(textNode).
 */
function element(tag, attrs = {}, children = []) {
	if (Array.isArray(tag)) {
		children = tag;
		tag = 'fragment';
	}
	if (typeof attrs === 'string' || Array.isArray(attrs) || typeof attrs === 'function') {
		children = attrs;
		attrs = {};
	}
	attrs ??= {};

	const node = {
		tag, attrs, ...attrs, value: attrs.value ?? '',
		/* Raw child list: values exactly as appended (strings stay strings, so
		 * tests can inspect the arguments that produced the DOM). */
		children: [],
		html: [],
		scalarHtml: false,
		get childNodes() {
			/* children are already materialized nodes: appendChildren pushes text
			 * nodes for non-node values, and an innerHTML write materializes its
			 * markup-free text immediately (so lastChild keeps its identity). */
			return this.children.slice();
		},
		get lastChild() { return this.childNodes.at(-1) ?? null; },
		get firstChild() { return this.childNodes[0] ?? null; },
		get innerHTML() { return this.html.join(''); },
		set innerHTML(value) {
			/* HTML spec: [LegacyNullToEmptyString] DOMString. */
			this.html = value === null ? [] : [ String(value) ];
			this.children = [];
			this.scalarHtml = true;
			materializeHtml(this);
		},
		get textContent() {
			return this.childNodes.map(child => child.textContent).join('');
		},
		set textContent(value) {
			/* HTML spec: [LegacyNullToEmptyString] DOMString; null becomes '',
			 * undefined becomes "undefined" (WebIDL DOMString conversion). */
			this.html = [];
			this.scalarHtml = false;
			this.children = [ textNode(value === null ? '' : String(value)) ];
		},
		replaceChildren(...nodes) {
			/* replaceChildren() converts DOMString arguments to text nodes; it
			 * never parses markup (unlike innerHTML). */
			this.html = [];
			this.scalarHtml = false;
			this.children = nodes.map(node => isDomNode(node) ? node : textNode(node));
		},
		// T10.40: wrapper tooltips are removed when the row becomes available.
		setAttribute(name, value) { this.attrs[name] = this[name] = String(value); },
		removeAttribute(name) { delete this.attrs[name]; delete this[name]; },
		addEventListener(event, fn) { this.attrs[event] = fn; this[event] = fn; }
	};

	appendChildren(node, children);

	for (const name of [ 'disabled', 'checked', 'selected', 'readonly', 'hidden', 'multiple' ])
		node[name] = attrs[name] != null;
	if (tag === 'select') {
		const options = node.childNodes;
		node.value = (options.find(option => option?.selected) ?? options[0])?.value ?? '';
	}
	return node;
}

/* innerHTML without a parser: a markup-free scalar is one text node; markup
 * would be parsed into elements by the browser, so this double leaves the
 * subtree empty and only records the write in `html`. */
function materializeHtml(node) {
	const html = node.html.join('');
	if (html.length && !html.includes('<'))
		node.children.push(textNode(html));
}

/* LuCI `dom.append()` semantics for an existing node. Shared by the
 * `dom.content` doubles in the test files so every page is held to the same
 * rendering rules (T9.42/R2). Returns what luci-base returns: the appended
 * node for a single DOM child, the new last child for arrays and innerHTML
 * writes, null when nothing was appended. */
function appendChildren(node, children) {
	/* luci.js returns null when the target is not a DOM elem (undefined slots
	 * included), so callers cannot trip over a missing container. */
	if (!isDomNode(node))
		return null;
	if (typeof children === 'function')
		return appendChildren(node, children(node));

	if (Array.isArray(children)) {
		/* Index loop, not map(): a real array hole must become the text
		 * "undefined" (the SDK interpolates children[i] with a template string). */
		for (let i = 0; i < children.length; i++) {
			const child = children[i];
			node.children.push(isDomNode(child) ? child : textNode(child));
		}

		return node.lastChild;
	}

	if (isDomNode(children)) {
		/* A DOM node (element or text node) keeps its identity, like appendChild(). */
		node.children.push(children);
		return children;
	}

	if (children !== null && children !== undefined) {
		/* innerHTML assignment replaces the previous children; returns lastChild
		 * in the SDK (null here when the markup contains '<'). */
		node.children.length = 0;
		node.html = [ String(children) ];
		node.scalarHtml = true;
		materializeHtml(node);
		return node.lastChild;
	}

	return null;
}

/* LuCI `dom.content()`: drop the children, then append following the rules. */
function contentChildren(node, children) {
	if (!isDomNode(node))
		return null;
	node.html = [];
	node.scalarHtml = false;
	node.children.length = 0;
	return appendChildren(node, children);
}

/* Every innerHTML write recorded by the double, including nested children.
 * Tests use it to show that user-controlled text never took the HTML path. */
function htmlWrites(node) {
	if (!node || typeof node !== 'object')
		return [];
	return [ ...(node.html ?? []) ].concat((node.children ?? []).flatMap(htmlWrites));
}

module.exports = {
	scanRequires, createDocument, createRpc, loadModule, parsePo, element,
	textNode, isDomNode, isElement, appendChildren, contentChildren, htmlWrites
};
