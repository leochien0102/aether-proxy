'use strict';

// Rule data and custom list reading (docs/05 "文件", docs/08 "数据格式").
//
// parse_domains() and parse_cidrs() are pure (docs/12 rule 1). load() is the only function in
// this module that reads files.
//
// Output normalization (the same everywhere, so renderers can rely on it):
//  - domains: lowercase, leading and trailing dots removed, sorted lexicographically;
//  - CIDRs: a /32 is written as a bare address (`1.2.3.4`, never `1.2.3.4/32`), which is also how
//    `nft list` prints a single-address element and how config.uc treats the pair
//    (docs/12 "已定的归一化细节"); every other prefix is written `a.b.c.d/len`. Sorted by network
//    address, then prefix length. Nested and overlapping prefixes are all kept (the nft sets use
//    auto-merge).
// Both are de-duplicated after normalization.

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import { domain, cidr_parts } from 'aetherproxy.net';

const BOM = '\uFEFF';  // encodes to the UTF-8 bytes EF BB BF

// Calls fn(line_no, text) for every non-blank, non-comment line. Line numbers are 1-based.
// A `#` only starts a comment at the beginning of a line (docs/05); a trailing comment makes
// the line invalid rather than being silently cut.
function each_line(text, fn) {
	let lines = split(text, '\n');

	for (let i, raw in lines) {
		let t = trim(raw);

		if (i == 0 && substr(t, 0, 3) == BOM)
			t = trim(substr(t, 3));

		if (t == '' || substr(t, 0, 1) == '#')
			continue;

		fn(i + 1, t);
	}
}

export function parse_domains(text) {
	let seen = {};
	let errors = [];

	each_line(text, (n, t) => {
		let d = replace(lc(t), /^\.+|\.+$/g, '');

		// An address-looking line is a mistake in a domain list, not a domain.
		if (domain(d) == null || match(d, /^[0-9.]+$/) != null)
			push(errors, { line: n, text: t });
		else
			seen[d] = true;
	});

	return { items: sort(keys(seen)), errors };
};

export function parse_cidrs(text) {
	let seen = {};
	let errors = [];

	each_line(text, (n, t) => {
		let c = cidr_parts(t);

		if (c == null) {
			push(errors, { line: n, text: t });
			return;
		}

		let o = [ (c.addr >> 24) & 255, (c.addr >> 16) & 255, (c.addr >> 8) & 255, c.addr & 255 ];
		let s = join('.', o) + (c.len == 32 ? '' : '/' + c.len);

		// Prefix lengths are below 64, so this packs (addr, len) into one sortable integer.
		seen[s] = c.addr * 64 + c.len;
	});

	let items = sort(keys(seen), (a, b) => seen[a] - seen[b]);

	return { items, errors };
};

// ------------------------------------------------------------------ loading

// Reads one file. Returns { state: 'ok', text } | { state: 'missing' } | { state: 'error', detail }.
// "Does not exist" is told apart from every other failure by the error text: this ucode has no
// numeric errno from fs.error(), and musl and glibc both say "No such file or directory".
function read_file(path) {
	let st = fs.stat(path);

	if (st == null) {
		let err = fs.error() ?? 'unknown error';

		return err == 'No such file or directory' ? { state: 'missing' } : { state: 'error', detail: err };
	}

	let text = fs.readfile(path);

	if (text == null)
		return { state: 'error', detail: fs.error() ?? 'unknown error' };

	return { state: 'ok', text };
}

// Locates the rule-data domain lists that chinadns-ng reads directly (docs/05 "列表文件的解析规则"):
// data_dir first, then the packaged baseline. The files are not parsed here (chnlist has 50k+
// lines and chinadns-ng does its own parsing); only their existence is checked, so that a
// missing file is an error instead of an omitted config line.
// opts: same as load(). Returns { ok, paths: { gfwlist, chnlist, apple }, errors: [ { file, code, detail? } ] }.
export function resolve_domain_paths(opts) {
	let dirs = [
		{ dir: opts?.data_dir ?? C.DATA_DIR },
		{ dir: opts?.baseline_dir ?? C.BASELINE_DATA_DIR }
	];
	let out = { ok: true, paths: {}, errors: [] };

	for (let name, file in C.DATA_DOMAIN_FILES) {
		let found = false;

		for (let d in dirs) {
			let path = d.dir + '/' + file;

			if (fs.stat(path) != null) {
				out.paths[name] = path;
				found = true;
				break;
			}

			let err = fs.error() ?? 'unknown error';

			if (err != 'No such file or directory') {
				push(out.errors, { file: path, code: 'read_failed', detail: err });
				found = true;  // reported; no silent fallback to the baseline
				break;
			}
		}

		if (!found)
			push(out.errors, { file: dirs[1].dir + '/' + file, code: 'missing_data' });
	}

	out.ok = !length(out.errors);

	return out;
};

// opts (all optional, for tests): { data_dir, baseline_dir, custom_dir }.
//
// Returns
//   { ok, data: { chnroute4, gfw_static4, direct_ip4, proxy_ip4 },     // render context `data`
//     domains: { direct_domain, proxy_domain },                         // validated custom domain lists
//     sources: { <name>: { path, origin: 'data'|'baseline'|'custom', state: 'ok'|'empty'|'missing' } },
//     errors: [ { file, code, line?, text?, detail? } ] }
// error codes: read_failed, missing_data, invalid_line.
//
// Rule data (data_dir first, then the packaged baseline): a file present in data_dir is used even
// when empty, and when it cannot be read that is an error, never a silent fallback to the
// baseline. A file absent from both directories is `missing_data`, because an empty chnroute4
// would quietly send everything through the proxy.
// Custom lists: an absent file is an empty list (the user never created it); other read errors
// are reported.
// Any invalid line in any file is an error; nothing is dropped silently.
// TODO(design): docs do not say what to do with invalid lines in an updated data file (08 only
// has CI-side sanity checks); failing the whole load is the conservative choice.
export function load(opts) {
	let data_dir = opts?.data_dir ?? C.DATA_DIR;
	let baseline_dir = opts?.baseline_dir ?? C.BASELINE_DATA_DIR;
	let custom_dir = opts?.custom_dir ?? C.CUSTOM_DIR;

	let out = { ok: true, data: {}, domains: {}, sources: {}, errors: [] };

	function take(name, file, dirs, parser, dest, missing_is_error) {
		let r, origin, path;

		for (let d in dirs) {
			path = d.dir + '/' + file;
			origin = d.origin;
			r = read_file(path);

			if (r.state != 'missing')
				break;
		}

		if (r.state == 'error') {
			push(out.errors, { file: path, code: 'read_failed', detail: r.detail });
			out.sources[name] = { path, origin, state: 'error' };
			return;
		}

		if (r.state == 'missing') {
			out.sources[name] = { path, origin, state: 'missing' };

			if (missing_is_error)
				push(out.errors, { file: path, code: 'missing_data' });
			else
				dest[name] = [];

			return;
		}

		let p = parser(r.text);

		for (let e in p.errors)
			push(out.errors, { file: path, code: 'invalid_line', line: e.line, text: e.text });

		dest[name] = p.items;
		out.sources[name] = { path, origin, state: length(p.items) ? 'ok' : 'empty' };
	}

	let rule_dirs = [ { dir: data_dir, origin: 'data' }, { dir: baseline_dir, origin: 'baseline' } ];
	let custom_dirs = [ { dir: custom_dir, origin: 'custom' } ];

	for (let name, file in C.DATA_IP_FILES)
		take(name, file, rule_dirs, parse_cidrs, out.data, true);

	for (let name, file in C.CUSTOM_IP_FILES)
		take(name, file, custom_dirs, parse_cidrs, out.data, false);

	for (let name, file in C.CUSTOM_DOMAIN_FILES)
		take(name, file, custom_dirs, parse_domains, out.domains, false);

	out.ok = !length(out.errors);

	return out;
};
