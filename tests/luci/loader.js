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

/* Shared mutable E() double (docs/10 UI rules, T10.18). LuCI skips only
 * null/undefined attributes: even false creates a boolean HTML attribute.
 * Keep raw attrs for source-level assertions, but read runtime state through
 * DOM properties so a later `button.disabled = false` takes effect.
 * Children stay inspectable without a browser; childNodes exposes text nodes
 * for the log-page injection tests, never parses strings as HTML.
 */
function element(tag, attrs = {}, children = []) {
	if (Array.isArray(tag)) {
		children = tag;
		tag = 'fragment';
	}
	if (typeof attrs === 'string' || Array.isArray(attrs)) {
		children = attrs;
		attrs = {};
	}
	attrs ??= {};
	const node = {
		tag, attrs, ...attrs, value: attrs.value ?? '',
		children: Array.isArray(children) ? children : [children],
		get childNodes() {
			return this.children.map(child => typeof child === 'string'
				? { tag: '#text', text: child, textContent: child, childNodes: [] } : child);
		},
		get lastChild() { return this.children.at(-1); },
		get textContent() {
			return this.children.map(child => child != null && typeof child === 'object'
				? child.textContent : String(child ?? '')).join('');
		},
		set textContent(value) { this.children = [String(value)]; },
		replaceChildren(...nodes) { this.children = nodes; },
		// T10.40: wrapper tooltips are removed when the row becomes available.
		setAttribute(name, value) { this.attrs[name] = this[name] = String(value); },
		removeAttribute(name) { delete this.attrs[name]; delete this[name]; },
		addEventListener(event, fn) { this.attrs[event] = fn; this[event] = fn; }
	};
	for (const name of [ 'disabled', 'checked', 'selected', 'readonly', 'hidden', 'multiple' ])
		node[name] = attrs[name] != null;
	if (tag === 'select') {
		const options = node.children;
		node.value = (options.find(option => option?.selected) ?? options[0])?.value ?? '';
	}
	return node;
}

module.exports = { scanRequires, createDocument, createRpc, loadModule, parsePo, element };
