'use strict';

/* Global translation gate for docs/tasks/m9.md T9.1 and docs/10 UI rules.
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

function js_entries(file, source) {
	const entries = [], dynamic = [];
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
			const args = tokens.slice(i + 2, end);
			const literal = args.length % 2 === 1 && args.every((arg, n) =>
				n % 2 === 0 ? arg.kind === 'string' : arg.raw === '+');
			const entry = { file, line: line_at(source, token.start) };
			if (literal)
				entries.push({ ...entry, msgid: args.filter((_, n) => n % 2 === 0)
					.map(arg => js_string(arg.raw)).join('') });
			else
				dynamic.push({ ...entry, raw: source.slice(tokens[i + 1].end, tokens[end].start).trim() });
		}
	}
	calls(lex(source));
	return { entries, dynamic };
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

function parse_po(source) {
	const catalog = new Map();
	let entry = null, field = null;
	function flush() {
		if (!entry)
			return;
		assert.ok(!catalog.has(entry.msgid), 'Duplicate msgid: ' + entry.msgid);
		catalog.set(entry.msgid, entry.msgstr ?? '');
	}
	for (const raw of source.split(/\r?\n/)) {
		const line = raw.trim();
		if (!line || line.startsWith('#'))
			continue;
		const directive = /^(msgid|msgstr)\s+(".*")$/.exec(line);
		if (directive) {
			field = directive[1];
			if (field === 'msgid') {
				flush();
				entry = {};
			}
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
		entries.push({ file, line: line_at(source, title.start), msgid: JSON.parse(title.raw) });
	}
	return entries;
}

function missing_translations(entries, catalog) {
	return entries.filter(entry => !catalog.has(entry.msgid) || catalog.get(entry.msgid).length === 0)
		.map(entry => `${entry.file}:${entry.line} missing translation: ${JSON.stringify(entry.msgid)}`);
}

function check_catalog(sources, menus, po, allowlist = NON_LITERAL_ALLOWLIST) {
	const catalog = parse_po(po), entries = [], errors = [], used_exceptions = new Set();
	for (const [ file, source ] of sources) {
		const found = js_entries(file, source);
		entries.push(...found.entries);
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
	const used = new Set(entries.map(entry => entry.msgid));
	const unused = [ ...catalog.keys() ].filter(id => id !== '' && !used.has(id)).sort();
	return { errors, entries, unused };
}

const read = file => fs.readFileSync(path.join(ROOT, file), 'utf8');
const sources = new Map(files_under(APP + '/htdocs', '.js').map(file => [ file, read(file) ]));
const menus = new Map(files_under(MENU_DIR, '.json').map(file => [ file, read(file) ]));
const real_po = read(PO_FILE);
const real = check_catalog(sources, menus, real_po);
const po_entry = (id, str = '译文') => 'msgid ' + JSON.stringify(id) + '\nmsgstr ' + JSON.stringify(str) + '\n';

function assert_clean(result) {
	assert.deepEqual(result.errors, [], result.errors.join('\n'));
}

test('T9.1 scenario 1: all htdocs JS and menu titles have non-empty translations', t => {
	assert.ok(sources.size > 0, 'must discover JS files');
	assert.ok(menus.size > 0, 'must discover menu files');
	assert.ok(real.entries.length > 0, 'must extract translations');
	t.diagnostic(`Scanned ${sources.size} JS files, ${menus.size} menu files, ${real.entries.length} references`);
	t.diagnostic(`Unused msgids: ${real.unused.length}; first 10: ${JSON.stringify(real.unused.slice(0, 10))}`);
	assert_clean(real);
});

test('T9.1 scenario 2: empty or removed used msgstr reports every affected file and line', () => {
	/* Mutate every used entry, not just a handpicked easy-to-match literal. */
	const catalog = parse_po(real_po);
	for (const id of new Set(real.entries.map(entry => entry.msgid))) {
		for (const mutation of [ 'empty', 'absent-entry', 'absent-msgstr' ]) {
			const copy = [ ...catalog ].map(([ key, value ]) => {
				if (key !== id)
					return po_entry(key, value);
				if (mutation === 'absent-entry')
					return '';
				if (mutation === 'absent-msgstr')
					return 'msgid ' + JSON.stringify(key) + '\n';
				return po_entry(key, '');
			}).join('\n');
			/* One representative id traverses the full gate for each mutation.
			 * Reuse its scan for the rest: only the catalog changes, and hundreds
			 * of redundant source scans would slow down the whole LuCI suite. */
			const errors = id === real.entries[0].msgid ? check_catalog(sources, menus, copy).errors :
				missing_translations(real.entries, parse_po(copy));
			const expected = real.entries.filter(entry => entry.msgid === id).map(entry =>
				`${entry.file}:${entry.line} missing translation: ${JSON.stringify(id)}`);
			assert.deepEqual(errors, expected, mutation + ' must fail at each use of ' + id);
		}
	}
});

test('T9.1 scenario 3: concatenated literals and JS/PO escapes match decoded msgids', () => {
	const source = String.raw`_('a ' + 'b');
_('it\'s');
_("double \"quote\"" + '\nnext');
_('\x41\u0042\u{1f600}\t\\');
_('line\
continuation');
_("café");`;
	const po = String.raw`msgid "a "
"b"
msgstr "拼接"
msgid "it's"
msgstr "撇号"
msgid "double \"quote\"\n"
"next"
msgstr "双引号"
"及换行"
msgid "\101B😀\t\\"
msgstr "转义"
msgid "linecontinuation"
msgstr "续行"
msgid "caf\303\251"
msgstr "UTF-8"
`;
	const result = check_catalog(new Map([ [ 'escape.js', source ] ]), new Map(), po);
	assert.deepEqual(result.entries.map(entry => entry.msgid),
		[ 'a b', "it's", 'double "quote"\nnext', 'AB😀\t\\', 'linecontinuation', 'café' ]);
	assert_clean(result);
});

test('T9.1 scenario 4: variables, templates and calls are non-literal with exact positions', () => {
	const source = '_(name);\n_(`x${y}`);\n_(get_name());\n_("prefix" + name);';
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
	assert_clean(check_catalog(new Map(), input, po_entry('Menu "title"')));
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
const object_division = {} / _('denominator') / count;
_( 'a' /* comment */ + " b" );
const template = \`raw _('template text') \${_('inside')} \${\`nested \${_(name)}\`}\`;
other._(ignored);`;
	/* String.raw keeps the outer fixture safe while preserving literal backticks. */
	const code = source.replaceAll('\\`', '`').replaceAll('\\${', '${');
	const result = check_catalog(new Map([ [ 'lex.js', code ] ]), new Map(),
		po_entry('a b') + po_entry('inside') + po_entry('denominator'));
	assert.deepEqual(result.entries.map(entry => entry.msgid), [ 'denominator', 'a b', 'inside' ]);
	assert.deepEqual(result.errors, [ 'lex.js:9 non-literal _(): name' ]);
});

test('T9.1 allowlist: file and exact argument require a reason; stale exceptions fail', () => {
	const input = new Map([ [ 'one.js', '_(name);' ], [ 'two.js', '_(name);' ] ]);
	const allowlist = new Map([ [ 'one.js:name', 'Synthetic case verifies exception scoping.' ] ]);
	assert.deepEqual(check_catalog(input, new Map(), '', allowlist).errors,
		[ 'two.js:1 non-literal _(): name' ]);
	assert.deepEqual(check_catalog(new Map(), new Map(), '', allowlist).errors,
		[ 'Unused non-literal exception: one.js:name' ]);
	assert.equal(check_catalog(input, new Map(), '', new Map([ [ 'one.js:name', '' ] ])).errors.length, 3);
});

test('T9.1 unused entries: report only, exclude PO metadata and retain decoded ids', () => {
	const po = po_entry('', 'metadata') + Array.from({ length: 12 }, (_, n) => po_entry('unused ' + n)).join('');
	const result = check_catalog(new Map(), new Map(), po);
	assert_clean(result);
	assert.equal(result.unused.length, 12);
	assert.equal(result.unused.slice(0, 10).length, 10);
	assert.ok(!result.unused.includes(''));
});
