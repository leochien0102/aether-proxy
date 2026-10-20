'use strict';

/* Global translation gate for docs/tasks/m9.md T9.1, m10.md T10.1/T10.2 and docs/10 UI rules.
 * Inspect source without executing app code; negative cases only alter in-memory
 * copies. Existing page tests still own event/skip-reason semantics and wording.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.resolve(__dirname, '../..');
const APP = 'luci-app-aether-proxy';
const PO_FILE = APP + '/po/zh_Hans/aether-proxy.po';
const MENU_DIR = APP + '/root/usr/share/luci/menu.d';

/* Keys must be repository-relative "file:argument source", values must explain
 * why extraction cannot use literals. No current call needs an exception.
 */
const NON_LITERAL_ALLOWLIST = new Map();

/* Keys are exact source texts, values explain why the program name remains.
 * Reject unused entries so this temporary allowance cannot outlive its page card.
 */
const DISPLAY_NAME_ALLOWLIST = new Map([
	[ 'aether-proxy version', '随概览页的卡移除' ]
]);

function files_under(dir, suffix) {
	return fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })
		.sort((a, b) => a.name.localeCompare(b.name))
		.flatMap(entry => {
			const file = dir + '/' + entry.name;
			return entry.isDirectory() ? files_under(file, suffix) : entry.name.endsWith(suffix) ? [ file ] : [];
		});
}

function line_at(source, offset) {
	return source.slice(0, offset).split(/\r\n|[\n\r\u2028\u2029]/).length;
}

/* Keep strings, comments, regexes and templates opaque so apparent _() text in
 * them is not mistaken for code. Template interpolations are scanned separately.
 * A closing control-condition parenthesis allows a regex statement, unlike a
 * closing call parenthesis (which may be followed by division).
 */
function lex(source) {
	let pos = 0;
	function quoted(quote) {
		const start = pos++;
		while (pos < source.length) {
			const ch = source[pos++];
			if (ch === '\\')
				pos++;
			else if (ch === quote)
				return source.slice(start, pos);
		}
		throw new SyntaxError('Unterminated string at line ' + line_at(source, start));
	}

	function template() {
		const start = pos++;
		const children = [];
		while (pos < source.length) {
			const ch = source[pos++];
			if (ch === '\\')
				pos++;
			else if (ch === '`')
				return { kind: 'template', raw: source.slice(start, pos), start, end: pos, children };
			else if (ch === '$' && source[pos] === '{') {
				pos++;
				children.push(scan(true));
			}
		}
		throw new SyntaxError('Unterminated template at line ' + line_at(source, start));
	}

	function regex() {
		const start = pos++;
		let in_class = false;
		while (pos < source.length) {
			const ch = source[pos++];
			if (ch === '\\')
				pos++;
			else if (ch === '[')
				in_class = true;
			else if (ch === ']')
				in_class = false;
			else if (ch === '/' && !in_class) {
				while (/[a-z]/i.test(source[pos] || '') && pos < source.length)
					pos++;
				return source.slice(start, pos);
			}
		}
		throw new SyntaxError('Unterminated regex at line ' + line_at(source, start));
	}

	function regex_allowed(prev) {
		if (!prev || prev.control_end)
			return true;
		if (prev.kind === 'word')
			return /^(return|throw|case|delete|void|typeof|instanceof|in|of|yield|await|else|do)$/.test(prev.raw);
		/* A closing brace can end an object expression: treating its following
		 * division as a regex could hide real _() calls in the denominator. */
		return prev.kind === 'punct' && ![ ')', ']', '}', '.', '++', '--' ].includes(prev.raw);
	}

	function scan(interpolation = false) {
		const tokens = [], parens = [];
		let braces = 0;
		while (pos < source.length) {
			const start = pos, ch = source[pos], prev = tokens[tokens.length - 1];
			if (/\s/.test(ch)) {
				pos++;
				continue;
			}
			if (source.startsWith('//', pos)) {
				while (pos < source.length && !/[\r\n\u2028\u2029]/.test(source[pos]))
					pos++;
				continue;
			}
			if (source.startsWith('/*', pos)) {
				const end = source.indexOf('*/', pos + 2);
				if (end < 0)
					throw new SyntaxError('Unterminated comment at line ' + line_at(source, pos));
				pos = end + 2;
				continue;
			}
			if (ch === '}' && interpolation && braces === 0) {
				pos++;
				return tokens;
			}
			if (ch === '`') {
				tokens.push(template());
				continue;
			}
			let kind = 'punct', raw;
			if (ch === "'" || ch === '"') {
				kind = 'string';
				raw = quoted(ch);
			}
			else if (ch === '/' && regex_allowed(prev)) {
				kind = 'regex';
				raw = regex();
			}
			else {
				const word = /^[\p{ID_Start}_$][\p{ID_Continue}$]*/u.exec(source.slice(pos));
				const number = /^\d+(?:\.\d*)?/.exec(source.slice(pos));
				if (word || number) {
					kind = word ? 'word' : 'number';
					raw = (word || number)[0];
				}
				else
					raw = /^(?:=>|\+\+|--|\?\.)/.exec(source.slice(pos))?.[0] || ch;
				pos += raw.length;
			}
			const token = { kind, raw, start, end: pos };
			if (raw === '(')
				parens.push(prev?.kind === 'word' && /^(if|while|for|with|switch|catch)$/.test(prev.raw));
			if (raw === ')')
				token.control_end = parens.pop();
			if (raw === '{')
				braces++;
			if (raw === '}')
				braces--;
			tokens.push(token);
		}
		if (interpolation)
			throw new SyntaxError('Unterminated template interpolation');
		return tokens;
	}
	return scan();
}

/* Only a lexically isolated quoted token reaches the JS evaluator, never an
 * expression or app source. Strict JS supplies escape/continuation semantics.
 */
function js_string(raw) {
	return vm.runInNewContext('"use strict"; (' + raw + ')', Object.create(null), { timeout: 100 });
}

/* Split only at call-level commas; commas inside dynamic expressions must not
 * masquerade as a context argument. The lexer keeps quoted commas opaque. */
function call_arguments(tokens) {
	const args = [[]];
	let depth = 0;
	for (const token of tokens) {
		if (token.raw === ',' && depth === 0)
			args.push([]);
		else
			args[args.length - 1].push(token);
		if ([ '(', '[', '{' ].includes(token.raw))
			depth++;
		if ([ ')', ']', '}' ].includes(token.raw))
			depth--;
	}
	return tokens.length ? args : [];
}

function js_entries(file, source) {
	const entries = [], dynamic = [], errors = [];
	function calls(tokens) {
		for (let i = 0; i < tokens.length; i++) {
			const token = tokens[i];
			for (const child of token.children || [])
				calls(child);
			if (token.kind !== 'word' || token.raw !== '_' || tokens[i + 1]?.raw !== '(')
				continue;
			if ([ '.', '?.' ].includes(tokens[i - 1]?.raw))
				continue;
			let end = i + 2, depth = 1;
			for (; end < tokens.length; end++) {
				if (tokens[end].raw === '(')
					depth++;
				if (tokens[end].raw === ')' && --depth === 0)
					break;
			}
			assert.ok(end < tokens.length, file + ': unclosed _()');
			const args = call_arguments(tokens.slice(i + 2, end));
			const entry = { file, line: line_at(source, token.start), context: 'aether-proxy' };
			const location = `${file}:${entry.line}`;
			if (args.length !== 2) {
				errors.push(`${location} _() requires exactly 2 arguments; got ${args.length}`);
				continue;
			}
			if (args[1].length !== 1 || args[1][0].kind !== 'string') {
				errors.push(`${location} _() context must be a single string literal`);
				continue;
			}
			const context = js_string(args[1][0].raw);
			if (context !== entry.context) {
				errors.push(`${location} _() context must be "aether-proxy"; got ${JSON.stringify(context)}`);
				continue;
			}
			const literal = args[0].length % 2 === 1 && args[0].every((arg, n) =>
				n % 2 === 0 ? arg.kind === 'string' : arg.raw === '+');
			if (literal)
				entries.push({ ...entry, msgid: args[0].filter((_, n) => n % 2 === 0)
					.map(arg => js_string(arg.raw)).join('') });
			else {
				const start = args[0][0]?.start ?? tokens[i + 1].end;
				const stop = args[0][args[0].length - 1]?.end ?? start;
				dynamic.push({ ...entry, raw: source.slice(start, stop).trim() });
			}
		}
	}
	calls(lex(source));
	return { entries, dynamic, errors };
}

/* PO uses C escapes, not JS escapes: in particular octal is valid, whereas
 * \uXXXX is not. Decode continuations before comparing logical msgids.
 */
function po_string(raw) {
	assert.match(raw, /^"(?:[^"\\]|\\.)*"$/);
	const escapes = { a: '\x07', b: '\b', f: '\f', n: '\n', r: '\r', t: '\t', v: '\v', '\\': '\\', '"': '"' };
	const text = raw.slice(1, -1), bytes = [];
	let start = 0;
	for (const match of text.matchAll(/\\([0-7]{1,3}|x[0-9a-fA-F]+|.)/g)) {
		bytes.push(Buffer.from(text.slice(start, match.index)));
		const escape = match[1];
		/* Numeric C escapes represent bytes in this UTF-8 catalog, not JS
		 * code points; e.g. \\303\\251 is one character, not two. */
		if (/^[0-7]/.test(escape))
			bytes.push(Buffer.from([ parseInt(escape, 8) ]));
		else if (escape[0] === 'x')
			bytes.push(Buffer.from([ parseInt(escape.slice(1), 16) ]));
		else {
			assert.ok(Object.hasOwn(escapes, escape), 'Unsupported PO escape: \\' + escape);
			bytes.push(Buffer.from(escapes[escape]));
		}
		start = match.index + match[0].length;
	}
	bytes.push(Buffer.from(text.slice(start)));
	return Buffer.concat(bytes).toString('utf8');
}

/* A tuple encoding avoids collisions even if a msgid contains a separator. */
function catalog_key(entry) {
	return JSON.stringify([ entry.context ?? '', entry.msgid ]);
}

function parse_po(source) {
	const catalog = new Map();
	let entry = null, field = null;
	function flush() {
		if (!entry)
			return;
		assert.ok(Object.hasOwn(entry, 'msgid'), 'PO entry without msgid');
		const key = catalog_key({ context: entry.msgctxt, msgid: entry.msgid });
		assert.ok(!catalog.has(key), 'Duplicate translation key: ' + key);
		catalog.set(key, entry.msgstr ?? '');
	}
	for (const raw of source.split(/\r?\n/)) {
		const line = raw.trim();
		if (!line || line.startsWith('#'))
			continue;
		const directive = /^(msgctxt|msgid|msgstr)\s+(".*")$/.exec(line);
		if (directive) {
			field = directive[1];
			if (field === 'msgctxt' || (field === 'msgid' && entry?.msgid !== undefined)) {
				flush();
				entry = null;
			}
			if (!entry && (field === 'msgctxt' || field === 'msgid'))
				entry = {};
			assert.ok(entry, 'msgstr before msgid');
			entry[field] = po_string(directive[2]);
		}
		else {
			assert.ok(entry && field && line.startsWith('"'), 'Unsupported PO line: ' + line);
			entry[field] += po_string(line);
		}
	}
	flush();
	return catalog;
}

function menu_entries(file, source) {
	JSON.parse(source);
	const tokens = lex(source), entries = [];
	for (let i = 0; i < tokens.length - 2; i++) {
		if (tokens[i].kind !== 'string' || JSON.parse(tokens[i].raw) !== 'title' || tokens[i + 1].raw !== ':')
			continue;
		const title = tokens[i + 2];
		assert.equal(title.kind, 'string', file + ': menu title must be a string');
		entries.push({ file, line: line_at(source, title.start), context: '', msgid: JSON.parse(title.raw) });
	}
	return entries;
}

function display_name_errors(entries, allowlist = DISPLAY_NAME_ALLOWLIST) {
	const errors = [], used_exceptions = new Set();
	for (const entry of entries) {
		if (!/aether-proxy/i.test(entry.msgid))
			continue;
		if (allowlist.has(entry.msgid) && allowlist.get(entry.msgid).trim())
			used_exceptions.add(entry.msgid);
		else
			errors.push(`${entry.file}:${entry.line} program name in UI text: ${JSON.stringify(entry.msgid)}`);
	}
	for (const key of allowlist.keys())
		if (!used_exceptions.has(key))
			errors.push('Unused display-name exception: ' + key);
	return errors;
}

function missing_translations(entries, catalog) {
	return entries.filter(entry => !catalog.has(catalog_key(entry)) || catalog.get(catalog_key(entry)).length === 0)
		.map(entry => `${entry.file}:${entry.line} missing translation: ${JSON.stringify(entry.msgid)}`);
}

function check_catalog(sources, menus, po, allowlist = NON_LITERAL_ALLOWLIST) {
	const catalog = parse_po(po), entries = [], errors = [], used_exceptions = new Set();
	for (const [ file, source ] of sources) {
		const found = js_entries(file, source);
		entries.push(...found.entries);
		errors.push(...found.errors);
		for (const call of found.dynamic) {
			const key = file + ':' + call.raw;
			if (allowlist.has(key) && allowlist.get(key).trim())
				used_exceptions.add(key);
			else
				errors.push(`${file}:${call.line} non-literal _(): ${call.raw}`);
		}
	}
	for (const [ file, source ] of menus)
		entries.push(...menu_entries(file, source));
	errors.push(...missing_translations(entries, catalog));
	for (const key of allowlist.keys())
		if (!used_exceptions.has(key))
			errors.push('Unused non-literal exception: ' + key);
	const used = new Set(entries.map(catalog_key));
	const menu_titles = new Set(entries.filter(entry => entry.context === '').map(entry => entry.msgid));
	const metadata = catalog_key({ msgid: '' });
	const unused = [ ...catalog.keys() ].filter(key => key !== metadata && !used.has(key)).sort();
	for (const key of catalog.keys()) {
		if (key === metadata)
			continue;
		const [ context, msgid ] = JSON.parse(key);
		if (context !== '' && context !== 'aether-proxy')
			errors.push(`PO context must be "aether-proxy": ${key}`);
		else if (context === '' && !menu_titles.has(msgid))
			errors.push(`PO entry without context is not a menu title: ${JSON.stringify(msgid)}`);
		else if (!used.has(key))
			errors.push('Unused translation: ' + key);
	}
	return { errors, entries, unused };
}

const read = file => fs.readFileSync(path.join(ROOT, file), 'utf8');
const sources = new Map(files_under(APP + '/htdocs', '.js').map(file => [ file, read(file) ]));
const menus = new Map(files_under(MENU_DIR, '.json').map(file => [ file, read(file) ]));
const real_po = read(PO_FILE);
const real = check_catalog(sources, menus, real_po);
const po_entry = (id, str = '译文', context = 'aether-proxy') =>
	(context ? 'msgctxt ' + JSON.stringify(context) + '\n' : '') +
	'msgid ' + JSON.stringify(id) + '\nmsgstr ' + JSON.stringify(str) + '\n';

function assert_clean(result) {
	assert.deepEqual(result.errors, [], result.errors.join('\n'));
}

test('T10.2 scenario 1: menu and overview titles use Aether Proxy with their own Chinese contexts', () => {
	const menu_file = MENU_DIR + '/luci-app-aether-proxy.json';
	const view_file = APP + '/htdocs/luci-static/resources/view/aether-proxy/overview.js';
	const menu = JSON.parse(menus.get(menu_file));
	assert.equal(menu['admin/services/aether-proxy'].title, 'Aether Proxy');
	assert.match(sources.get(view_file), /E\('h2', \{\}, _\('Aether Proxy', 'aether-proxy'\)\)/);
	const catalog = parse_po(real_po);
	for (const [ file, context ] of [ [ menu_file, '' ], [ view_file, 'aether-proxy' ] ]) {
		const entry = real.entries.find(item => item.file === file && item.msgid === 'Aether Proxy');
		assert.ok(entry, file + ': must reference the display name');
		assert.equal(entry.context, context);
		assert.equal(catalog.get(catalog_key(entry)), '以太跃迁');
		assert.equal(catalog.has(catalog_key({ context, msgid: 'aether-proxy' })), false);
	}
});

test('T10.2 scenario 2: real UI texts pass the program-name gate with only the version exception', () => {
	assert.deepEqual([ ...DISPLAY_NAME_ALLOWLIST.keys() ], [ 'aether-proxy version' ]);
	assert.deepEqual(display_name_errors(real.entries), []);
});

test('T10.2 scenario 2: JS and menu program names fail once each with exact file and line', () => {
	const js = js_entries('name.js', "// title\n_('About aether-' + 'proxy', 'aether-proxy');").entries;
	const menu = menu_entries('name.json', '{\n"item": { "title": "Aether-Proxy" }\n}');
	assert.deepEqual(display_name_errors([ ...js, ...menu ], new Map()), [
		'name.js:2 program name in UI text: "About aether-proxy"',
		'name.json:2 program name in UI text: "Aether-Proxy"'
	]);
});

test('T10.2 scenario 2: display-name exceptions must appear, match exactly and explain why', () => {
	assert.deepEqual(display_name_errors([]), [ 'Unused display-name exception: aether-proxy version' ]);
	const entry = { file: 'version.js', line: 3, msgid: 'aether-proxy version' };
	assert.deepEqual(display_name_errors([ entry ]), []);
	assert.deepEqual(display_name_errors([ { ...entry, msgid: 'Aether-Proxy version' } ]), [
		'version.js:3 program name in UI text: "Aether-Proxy version"',
		'Unused display-name exception: aether-proxy version'
	]);
	assert.deepEqual(display_name_errors([ entry ], new Map([ [ entry.msgid, ' ' ] ])), [
		'version.js:3 program name in UI text: "aether-proxy version"',
		'Unused display-name exception: aether-proxy version'
	]);
});

test('T9.1 scenario 1: all htdocs JS and menu titles have non-empty translations', t => {
	assert.ok(sources.size > 0, 'must discover JS files');
	assert.ok(menus.size > 0, 'must discover menu files');
	assert.equal(real.entries.length, 450, 'context migration must preserve the reference count');
	assert.deepEqual(real.unused, [], 'all non-metadata entries must be referenced');
	t.diagnostic(`Scanned ${sources.size} JS files, ${menus.size} menu files, ${real.entries.length} references`);
	t.diagnostic(`Unused msgids: ${real.unused.length}; first 10: ${JSON.stringify(real.unused.slice(0, 10))}`);
	assert_clean(real);
});

test('T9.1 scenario 2: empty or removed used msgstr reports every affected file and line', () => {
	/* Mutate every used entry, not just a handpicked easy-to-match literal. */
	const catalog = parse_po(real_po);
	for (const key of new Set(real.entries.map(catalog_key))) {
		const [ context, id ] = JSON.parse(key);
		for (const mutation of [ 'empty', 'absent-entry', 'absent-msgstr' ]) {
			const copy = [ ...catalog ].map(([ entry_key, value ]) => {
				const [ entry_context, entry_id ] = JSON.parse(entry_key);
				if (entry_key !== key)
					return po_entry(entry_id, value, entry_context);
				if (mutation === 'absent-entry')
					return '';
				if (mutation === 'absent-msgstr')
					return (context ? 'msgctxt ' + JSON.stringify(context) + '\n' : '') +
						'msgid ' + JSON.stringify(id) + '\n';
				return po_entry(id, '', context);
			}).join('\n');
			/* One representative id traverses the full gate for each mutation.
			 * Reuse its scan for the rest: only the catalog changes, and hundreds
			 * of redundant source scans would slow down the whole LuCI suite. */
			const errors = key === catalog_key(real.entries[0]) ? check_catalog(sources, menus, copy).errors :
				missing_translations(real.entries, parse_po(copy));
			const expected = real.entries.filter(entry => catalog_key(entry) === key).map(entry =>
				`${entry.file}:${entry.line} missing translation: ${JSON.stringify(id)}`);
			assert.deepEqual(errors, expected, mutation + ' must fail at each use of ' + id);
		}
	}
});

test('T9.1 scenario 3: concatenated literals and JS/PO escapes match decoded msgids', () => {
	const source = String.raw`_('a ' + 'b', 'aether-proxy');
_('it\'s', 'aether-proxy');
_("double \"quote\"" + '\nnext', "aether-proxy");
_('\x41\u0042\u{1f600}\t\\', 'aether-proxy');
_('line\
continuation', 'aether-proxy');
_("café", 'aether-proxy');`;
	const po = String.raw`msgctxt "aether-"
"proxy"
msgid "a "
"b"
msgstr "拼接"
msgctxt "aether-proxy"
msgid "it's"
msgstr "撇号"
msgctxt "aether-proxy"
msgid "double \"quote\"\n"
"next"
msgstr "双引号"
"及换行"
msgctxt "aether-proxy"
msgid "\101B😀\t\\"
msgstr "转义"
msgctxt "aether-proxy"
msgid "linecontinuation"
msgstr "续行"
msgctxt "aether-proxy"
msgid "caf\303\251"
msgstr "UTF-8"
`;
	const result = check_catalog(new Map([ [ 'escape.js', source ] ]), new Map(), po);
	assert.deepEqual(result.entries.map(entry => entry.msgid),
		[ 'a b', "it's", 'double "quote"\nnext', 'AB😀\t\\', 'linecontinuation', 'café' ]);
	assert_clean(result);
});

test('T9.1 scenario 4: variables, templates and calls are non-literal with exact positions', () => {
	const source = '_(name, "aether-proxy");\n_(`x${y}`, "aether-proxy");\n' +
		'_(get_name(), "aether-proxy");\n_("prefix" + name, "aether-proxy");';
	const result = check_catalog(new Map([ [ 'dynamic.js', source ] ]), new Map(), '');
	assert.deepEqual(result.errors, [
		'dynamic.js:1 non-literal _(): name',
		'dynamic.js:2 non-literal _(): `x${y}`',
		'dynamic.js:3 non-literal _(): get_name()',
		'dynamic.js:4 non-literal _(): "prefix" + name'
	]);
});

test('T9.1 scenario 5: missing menu title translation fails with its JSON file and line', () => {
	const menu = '{\n  "admin/services/test": {\n    "title": ' + JSON.stringify('Menu "title"') + '\n  }\n}';
	const input = new Map([ [ 'menu.json', menu ] ]);
	assert_clean(check_catalog(new Map(), input, po_entry('Menu "title"', '译文', '')));
	const result = check_catalog(new Map(), input, '');
	assert.deepEqual(result.errors, [ 'menu.json:3 missing translation: "Menu \\"title\\""' ]);
});

test('T9.1 lexer: ignore decoys, retain division and scan nested template interpolations', () => {
	const source = String.raw`// _('comment')
/* _("block comment") */
const text = "_('string')";
const pattern = /_\('regex'\)[/]/g;
if (ready) /_\('conditional regex'\)/.test(text);
const quotient = total / count;
const object_division = {} / _('denominator', 'aether-proxy') / count;
_( 'a' /* comment */ + " b", 'aether-proxy' );
const template = \`raw _('template text') \${_('inside', 'aether-proxy')} \${\`nested \${_(name, 'aether-proxy')}\`}\`;
other._(ignored);`;
	/* String.raw keeps the outer fixture safe while preserving literal backticks. */
	const code = source.replaceAll('\\`', '`').replaceAll('\\${', '${');
	const result = check_catalog(new Map([ [ 'lex.js', code ] ]), new Map(),
		po_entry('a b') + po_entry('inside') + po_entry('denominator'));
	assert.deepEqual(result.entries.map(entry => entry.msgid), [ 'denominator', 'a b', 'inside' ]);
	assert.deepEqual(result.errors, [ 'lex.js:9 non-literal _(): name' ]);
});

test('T9.1 allowlist: file and exact argument require a reason; stale exceptions fail', () => {
	const input = new Map([ [ 'one.js', '_(name, "aether-proxy");' ],
		[ 'two.js', '_(name, "aether-proxy");' ] ]);
	const allowlist = new Map([ [ 'one.js:name', 'Synthetic case verifies exception scoping.' ] ]);
	assert.deepEqual(check_catalog(input, new Map(), '', allowlist).errors,
		[ 'two.js:1 non-literal _(): name' ]);
	assert.deepEqual(check_catalog(new Map(), new Map(), '', allowlist).errors,
		[ 'Unused non-literal exception: one.js:name' ]);
	assert.equal(check_catalog(input, new Map(), '', new Map([ [ 'one.js:name', '' ] ])).errors.length, 3);
});

test('T10.1 unused entries: fail, exclude PO metadata and retain decoded keys', () => {
	const po = po_entry('', 'metadata', '') + Array.from({ length: 12 }, (_, n) => po_entry('unused ' + n)).join('');
	const result = check_catalog(new Map(), new Map(), po);
	assert.equal(result.unused.length, 12);
	assert.equal(result.unused.slice(0, 10).length, 10);
	assert.ok(!result.unused.includes(catalog_key({ msgid: '' })));
	assert.deepEqual(result.errors.slice().sort(), result.unused.map(key => 'Unused translation: ' + key));
});

test('T10.1 scenario 2: missing, wrong, variable and concatenated contexts report exact locations', () => {
	const source = "// context failures\n_('X');\n_('X', 'other');\n_('X', ctx);\n" +
		"_('X', 'aether' + '-proxy');";
	const result = check_catalog(new Map([ [ 'context.js', source ] ]), new Map(), '');
	assert.deepEqual(result.errors, [
		'context.js:2 _() requires exactly 2 arguments; got 1',
		'context.js:3 _() context must be "aether-proxy"; got "other"',
		'context.js:4 _() context must be a single string literal',
		'context.js:5 _() context must be a single string literal'
	]);
});

test('T10.1 arity: zero or extra arguments fail and nested commas remain in the first argument', () => {
	const source = "_();\n_('X', 'aether-proxy', 'extra');\n" +
		"_(choose('X', ['Y', 'Z'], { a: 1, b: 2 }), 'aether-proxy');";
	const result = check_catalog(new Map([ [ 'arity.js', source ] ]), new Map(), '');
	assert.deepEqual(result.errors, [
		'arity.js:1 _() requires exactly 2 arguments; got 0',
		'arity.js:2 _() requires exactly 2 arguments; got 3',
		"arity.js:3 non-literal _(): choose('X', ['Y', 'Z'], { a: 1, b: 2 })"
	]);
});

test('T10.1 scenario 3: JS and menus cannot borrow translations from the other context', () => {
	const js = new Map([ [ 'view.js', "_('X', 'aether-proxy');" ] ]);
	const menu = new Map([ [ 'menu.json', '{\n"item": { "title": "X" }\n}' ] ]);
	/* A real menu use makes the context-free entry valid, but not valid for JS. */
	assert.deepEqual(check_catalog(js, menu, po_entry('X', '菜单', '')).errors,
		[ 'view.js:1 missing translation: "X"' ]);
	assert.deepEqual(check_catalog(js, menu, po_entry('X')).errors,
		[ 'menu.json:2 missing translation: "X"' ]);
	assert_clean(check_catalog(js, menu, po_entry('X') + po_entry('X', '菜单', '')));
});

test('T10.1 scenario 4: invalid PO contexts, context-free non-menu and unused entries fail once each', () => {
	const po = po_entry('Other', '其他', 'other') + po_entry('No context', '无上下文', '') + po_entry('Unused');
	assert.deepEqual(check_catalog(new Map(), new Map(), po).errors, [
		'PO context must be "aether-proxy": ["other","Other"]',
		'PO entry without context is not a menu title: "No context"',
		'Unused translation: ["aether-proxy","Unused"]'
	]);
});

test('T10.1 scenario 4: duplicate checks use the decoded context plus msgid key', () => {
	const both = po_entry('X') + po_entry('X', '菜单', '');
	assert.equal(parse_po(both).size, 2, 'same msgid in two contexts is not a duplicate');
	assert.throws(() => parse_po(both + po_entry('X')), /Duplicate translation key: \["aether-proxy","X"\]/);
	assert.throws(() => parse_po(both + po_entry('X', '菜单', '')), /Duplicate translation key: \["","X"\]/);
	const escaped_context = String.raw`msgctxt "aether\055proxy"
msgid "X"
msgstr "译文"
`;
	assert.throws(() => parse_po(po_entry('X') + escaped_context), /Duplicate translation key/);
});

/* Old page checks must not pass vacuously after the call signature changes.
 * Exercise their actual extraction patterns, without executing page tests. */
test('T10.1 scenario 6: legacy page translation scanners still extract context-qualified calls', () => {
	for (const file of [ 'advanced', 'logs', 'overview', 'rules', 'static', 'updates' ]) {
		const tokens = lex(read('tests/luci/' + file + '.test.js'));
		const patterns = tokens.filter((token, index) => token.kind === 'regex' &&
			token.raw.startsWith('/_\\(') && tokens[index - 2]?.raw === 'matchAll');
		assert.equal(patterns.length, 1, file + ': must find the legacy translation scanner');
		const pattern = vm.runInNewContext(patterns[0].raw);
		const extracted = [ ..."_('X', 'aether-proxy')".matchAll(pattern) ].map(match => match[1]);
		assert.deepEqual(extracted, [ 'X' ], file + ': context-qualified calls must not be skipped');
	}
});

test('T10.1 allowlist: a non-literal exception never exempts the context requirement', () => {
	const allowlist = new Map([ [ 'dynamic.js:name', 'Synthetic exception.' ] ]);
	const result = check_catalog(new Map([ [ 'dynamic.js', '_(name, ctx);' ] ]), new Map(), '', allowlist);
	assert.deepEqual(result.errors, [
		'dynamic.js:1 _() context must be a single string literal',
		'Unused non-literal exception: dynamic.js:name'
	]);
});
