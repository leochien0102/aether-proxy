'use strict';
// Host test runner (docs/12-ucode.md "Test runner").
//
//   tests/host/ucode tests/run.uc [-- --update] [filter...]
//
// ucode itself parses leading-dash options, so runner options go after `--`
// (the bare word `update` is accepted as an alias).
//
// Golden fixtures:  tests/fixtures/<case>/aetherproxy        UCI config (fixed name)
//                   tests/fixtures/<case>/context.json       optional render context
//                                                            ({data, runtime, paths})
//                   tests/fixtures/<case>/expected/<file>    expected render output
//                   tests/fixtures/<case>/expected/snapshot.json  the normalized config snapshot
//                                                            (%.2J of config.load().snapshot)
//                   tests/fixtures/<case>/expected/error.json  expect validation failure
//                   A fixture whose expected/ holds only snapshot.json runs no renderers.
// Unit tests:       tests/unit/*.uc, each exporting `cases` (array) and run(case).
//                   A case passes when run(case) deep-equals case.expect.
//
// Exit code: 0 all passed (skips do not fail), 1 otherwise.

import * as fs from 'fs';
import * as uci from 'uci';

const ROOT = fs.realpath(sourcepath(0, true) + '/..');
const LIB_DIR = ROOT + '/aether-proxy/src/lib';
const FIXTURE_DIR = ROOT + '/tests/fixtures';
const UNIT_DIR = ROOT + '/tests/unit';

// Self-test renderer: dumps the snapshot's `main` section. Deterministic.
function builtin_echo(snapshot, ctx) {
	return sprintf('%.2J', snapshot.main) + '\n';
}

// Artifact table: expected file name -> renderer. Adding a real renderer in M1
// needs no change here: the four entries already exist and are activated simply
// by the module file appearing in aether-proxy/src/lib. A renderer module must
// export render(snapshot, ctx) returning a string.
// `builtin` entries are harness-only (self-test) renderers that run only for
// fixtures that ship the matching expected file.
const ARTIFACTS = [
	{ file: 'aether-proxy.nft', module: 'aetherproxy.render.nft' },
	{ file: 'chinadns.conf',    module: 'aetherproxy.render.chinadns' },
	{ file: 'dnsmasq.conf',     module: 'aetherproxy.render.dnsmasq' },
	{ file: 'xray.json',        module: 'aetherproxy.render.xray' },
	{ file: 'echo.json',        builtin: true, render: builtin_echo },
];

// ---------------------------------------------------------------- helpers

function module_exists(name) {
	let rel = replace(replace(name, /^aetherproxy\./, ''), '.', '/');
	return fs.stat(LIB_DIR + '/' + rel + '.uc') != null;
}

// require() cannot load files that use `export`, and import is static, so
// compile a tiny stub that imports the module and hands back its namespace.
function import_module(name) {
	let fn = loadstring(sprintf("import * as m from '%s'; return m;", name));
	return fn();
}

function read_required(path) {
	let s = fs.readfile(path);
	if (s == null) {
		warn(sprintf('cannot read %s: %s\n', path, fs.error()));
		exit(1);
	}
	return s;
}

function list_dirs(dir) {
	let names = fs.lsdir(dir);
	if (names == null)
		return [];
	return sort(filter(names, n => fs.stat(dir + '/' + n)?.type == 'directory'));
}

function split_lines(s) {
	let lines = split(s, '\n');
	// "a\nb\n" -> [a, b]; remember whether the last line was unterminated.
	let nl = true;
	if (length(lines) && lines[length(lines) - 1] == '')
		pop(lines);
	else if (length(lines))
		nl = false;
	return { lines, nl };
}

// Unified diff (3 lines of context) between two strings.
function unified_diff(a_name, b_name, a, b) {
	let A = split_lines(a), B = split_lines(b);
	let x = A.lines, y = B.lines;
	let n = length(x), m = length(y);

	let pre = 0;
	while (pre < n && pre < m && x[pre] == y[pre])
		pre++;
	let suf = 0;
	while (suf < n - pre && suf < m - pre && x[n - 1 - suf] == y[m - 1 - suf])
		suf++;

	// LCS over the differing middle part only.
	let xn = n - pre - suf, ym = m - pre - suf;
	let L = [];
	for (let i = 0; i <= xn; i++) {
		let row = [];
		for (let j = 0; j <= ym; j++)
			push(row, 0);
		push(L, row);
	}
	for (let i = xn - 1; i >= 0; i--)
		for (let j = ym - 1; j >= 0; j--)
			L[i][j] = x[pre + i] == y[pre + j] ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1]);

	// ops: [kind, text, a_line, b_line] kind in ' ', '-', '+'
	let ops = [];
	for (let i = 0; i < pre; i++)
		push(ops, [' ', x[i]]);
	let i = 0, j = 0;
	while (i < xn || j < ym) {
		if (i < xn && j < ym && x[pre + i] == y[pre + j]) {
			push(ops, [' ', x[pre + i]]); i++; j++;
		}
		else if (j < ym && (i == xn || L[i][j + 1] >= L[i + 1][j])) {
			push(ops, ['+', y[pre + j]]); j++;
		}
		else {
			push(ops, ['-', x[pre + i]]); i++;
		}
	}
	for (let k = n - suf; k < n; k++)
		push(ops, [' ', x[k]]);

	let out = [ '--- ' + a_name, '+++ ' + b_name ];
	if (A.nl != B.nl)
		push(out, '(trailing newline differs)');

	// Group into hunks.
	const CTX = 3;
	let changed = [];
	for (let k = 0; k < length(ops); k++)
		if (ops[k][0] != ' ')
			push(changed, k);

	let k = 0;
	while (k < length(changed)) {
		let start = max(changed[k] - CTX, 0);
		let end = changed[k];
		while (k < length(changed) && changed[k] - end <= 2 * CTX + 1) {
			end = changed[k];
			k++;
		}
		end = min(end + CTX, length(ops) - 1);

		let a_start = 0, b_start = 0;
		for (let p = 0; p < start; p++) {
			if (ops[p][0] != '+') a_start++;
			if (ops[p][0] != '-') b_start++;
		}
		let a_len = 0, b_len = 0, body = [];
		for (let p = start; p <= end; p++) {
			if (ops[p][0] != '+') a_len++;
			if (ops[p][0] != '-') b_len++;
			push(body, ops[p][0] + ops[p][1]);
		}
		push(out, sprintf('@@ -%d,%d +%d,%d @@', a_len ? a_start + 1 : a_start, a_len,
			b_len ? b_start + 1 : b_start, b_len));
		push(out, ...body);
	}
	return join('\n', out) + '\n';
}

function indent(s) {
	return join('\n', map(split(trim(s, '\n'), '\n'), l => '    ' + l)) + '\n';
}

// Deep equality via canonical JSON (keys sorted by the serializer? no: ucode keeps
// insertion order), so normalise by sorting keys recursively.
function canon(v) {
	if (type(v) == 'array')
		return map(v, canon);
	if (type(v) == 'object') {
		let o = {};
		for (let k in sort(keys(v)))
			o[k] = canon(v[k]);
		return o;
	}
	return v;
}
function same(a, b) {
	return sprintf('%.J', canon(a)) == sprintf('%.J', canon(b));
}

// ---------------------------------------------------------------- state

let update = false;
let filters = [];
for (let a in ARGV) {
	if (a == '--update' || a == 'update')
		update = true;
	else if (a == '-h' || a == '--help') {
		print('usage: tests/host/ucode tests/run.uc [-- --update] [name-filter...]\n');
		exit(0);
	}
	else if (substr(a, 0, 2) == '--') {
		warn(sprintf('unknown option %s\n', a));
		exit(2);
	}
	else
		push(filters, a);
}

let stats = { pass: 0, fail: 0, skip: 0, updated: 0 };

function selected(name) {
	if (!length(filters))
		return true;
	for (let f in filters)
		if (index(name, f) >= 0)
			return true;
	return false;
}

function report(status, name, note) {
	stats[status]++;
	print(sprintf('%-5s %s%s\n', uc(status), name, note ? ' (' + note + ')' : ''));
}

// ---------------------------------------------------------------- fixtures

function compare_output(name, art, actual, dir) {
	let path = dir + '/expected/' + art;
	let expected = fs.readfile(path);
	if (update) {
		if (expected == actual) {
			report('pass', name + '/' + art);
			return;
		}
		fs.mkdir(dir + '/expected');
		if (fs.writefile(path, actual) == null) {
			warn(sprintf('cannot write %s: %s\n', path, fs.error()));
			exit(1);
		}
		stats.updated++;
		report('pass', name + '/' + art, 'updated');
		return;
	}
	if (expected == null) {
		report('fail', name + '/' + art, 'expected file missing; run with --update');
		return;
	}
	if (expected == actual) {
		report('pass', name + '/' + art);
		return;
	}
	report('fail', name + '/' + art);
	print(indent(unified_diff('expected/' + art, 'actual/' + art, expected, actual)));
}

function load_snapshot(dir, cursor) {
	if (module_exists('aetherproxy.config')) {
		let config = import_module('aetherproxy.config');
		return config.load(cursor);
	}
	// Placeholder until config.uc lands (M1): minimal snapshot.
	let main = cursor.get_all('aetherproxy', 'main') ?? {};
	let clean = {};
	for (let k in keys(main))
		if (substr(k, 0, 1) != '.')
			clean[k] = main[k];
	return { ok: true, snapshot: { main: clean } };
}

function run_fixture(name) {
	let dir = FIXTURE_DIR + '/' + name;
	if (fs.stat(dir + '/aetherproxy') == null) {
		report('fail', name, 'missing UCI file "aetherproxy"');
		return;
	}
	let ctx = {};
	if (fs.stat(dir + '/context.json') != null)
		ctx = json(read_required(dir + '/context.json'));

	let cursor = uci.cursor(dir);
	let res = load_snapshot(dir, cursor);

	if (fs.stat(dir + '/expected/error.json') != null) {
		if (!module_exists('aetherproxy.config')) {
			report('skip', name + '/error.json', 'missing module aetherproxy.config');
			return;
		}
		let actual = res.ok ? '{"errors":[]}\n' : sprintf('%.2J', { errors: res.errors }) + '\n';
		if (res.ok) {
			report('fail', name + '/error.json', 'expected validation failure, config.load succeeded');
			return;
		}
		compare_output(name, 'error.json', actual, dir);
		return;
	}
	if (!res.ok) {
		report('fail', name, 'config.load failed: ' + sprintf('%.J', res.errors));
		return;
	}

	let has_snapshot = fs.stat(dir + '/expected/snapshot.json') != null;
	if (has_snapshot) {
		if (!module_exists('aetherproxy.config'))
			report('skip', name + '/snapshot.json', 'missing module aetherproxy.config');
		else
			compare_output(name, 'snapshot.json', sprintf('%.2J', res.snapshot) + '\n', dir);
	}

	// A snapshot-only fixture (no renderer output expected) does not exercise the renderers.
	let wants_render = !has_snapshot;
	for (let art in ARTIFACTS)
		if (fs.stat(dir + '/expected/' + art.file) != null)
			wants_render = true;

	for (let art in ARTIFACTS) {
		if (!wants_render)
			break;

		let render;
		if (art.builtin) {
			// Harness-only renderer: only for fixtures that opt in with the file.
			if (fs.stat(dir + '/expected/' + art.file) == null)
				continue;
			render = art.render;
		}
		else if (!module_exists(art.module)) {
			report('skip', name + '/' + art.file, 'missing module ' + art.module);
			continue;
		}
		else
			render = import_module(art.module).render;

		let actual = render(res.snapshot, ctx);
		if (type(actual) != 'string') {
			report('fail', name + '/' + art.file, 'renderer did not return a string');
			continue;
		}
		compare_output(name, art.file, actual, dir);
	}
}

// ---------------------------------------------------------------- unit tests

function run_unit(file) {
	let base = replace(file, /\.uc$/, '');
	let src = read_required(UNIT_DIR + '/' + file);

	// Skip (not fail) when the test imports an aetherproxy module that is not on this branch yet.
	let missing = [];
	for (let m in match(src, /from\s+['"](aetherproxy\.[A-Za-z0-9_.]+)['"]/g) ?? []) {
		if (!module_exists(m[1]))
			push(missing, m[1]);
	}
	if (length(missing)) {
		report('skip', 'unit/' + base, 'missing module ' + join(', ', missing));
		return;
	}

	let mod = import_module(UNIT_DIR + '/' + file);
	if (type(mod?.cases) != 'array' || type(mod?.run) != 'function') {
		report('fail', 'unit/' + base, 'must export `cases` array and run(case)');
		return;
	}
	let idx = 0;
	for (let c in mod.cases) {
		let label = sprintf('unit/%s[%d]%s', base, idx++, c.name ? ' ' + c.name : '');
		let got = mod.run(c);
		if (same(got, c.expect))
			report('pass', label);
		else {
			report('fail', label);
			print(sprintf('    expected: %.J\n    actual:   %.J\n', c.expect, got));
		}
	}
}

// ---------------------------------------------------------------- main

for (let name in list_dirs(FIXTURE_DIR))
	if (selected(name))
		run_fixture(name);

let unit_files = fs.lsdir(UNIT_DIR) ?? [];
for (let f in sort(filter(unit_files, f => match(f, /\.uc$/))))
	if (selected('unit/' + f))
		run_unit(f);

print(sprintf('\n%d passed, %d failed, %d skipped%s\n', stats.pass, stats.fail, stats.skip,
	update ? sprintf(', %d expected file(s) updated', stats.updated) : ''));
exit(stats.fail ? 1 : 0);
