'use strict';

// Table-driven tests for data.uc: parse_domains, parse_cidrs and load (against fixture
// directories under tests/unit/data/; load never touches the real /etc or /usr).

import * as fs from 'fs';
import { parse_domains, parse_cidrs, load } from 'aetherproxy.data';

const FIX = fs.dirname(sourcepath()) + '/data';

function lines(...l) {
	return join('\n', l) + '\n';
}

export const cases = [
	// parse_domains
	{ name: 'domains: comments and blank lines', fn: 'domains',
	  in: lines('# comment', '', '   ', 'a.example', '  # indented comment is still a comment'),
	  expect: { items: [ 'a.example' ], errors: [] } },
	{ name: 'domains: lowercase and strip dots', fn: 'domains',
	  in: lines('Example.COM.', '.foo.org', '..bar.net..'),
	  expect: { items: [ 'bar.net', 'example.com', 'foo.org' ], errors: [] } },
	{ name: 'domains: duplicates after normalization, sorted', fn: 'domains',
	  in: lines('b.com', 'A.com', 'a.COM.', 'b.com'),
	  expect: { items: [ 'a.com', 'b.com' ], errors: [] } },
	{ name: 'domains: invalid lines report 1-based line numbers', fn: 'domains',
	  in: lines('ok.com', '# c', 'bad domain', 'a..b', '1.2.3.4', 'x.com # trailing', '-x.com'),
	  expect: { items: [ 'ok.com' ], errors: [
		{ line: 3, text: 'bad domain' }, { line: 4, text: 'a..b' }, { line: 5, text: '1.2.3.4' },
		{ line: 6, text: 'x.com # trailing' }, { line: 7, text: '-x.com' } ] } },
	{ name: 'domains: CRLF, BOM, no trailing newline', fn: 'domains',
	  in: '\uFEFFa.com\r\nb.com',
	  expect: { items: [ 'a.com', 'b.com' ], errors: [] } },
	{ name: 'domains: only dots is invalid', fn: 'domains', in: '...\n',
	  expect: { items: [], errors: [ { line: 1, text: '...' } ] } },
	{ name: 'domains: empty input', fn: 'domains', in: '', expect: { items: [], errors: [] } },

	// parse_cidrs
	{ name: 'cidrs: comments and blank lines', fn: 'cidrs',
	  in: lines('# c', '', '10.0.0.0/8', '  '), expect: { items: [ '10.0.0.0/8' ], errors: [] } },
	{ name: 'cidrs: x.x.x.x and /32 collapse to the bare address', fn: 'cidrs',
	  in: lines('1.2.3.4', '1.2.3.4/32', '1.2.3.4'), expect: { items: [ '1.2.3.4' ], errors: [] } },
	{ name: 'cidrs: numeric order, then prefix length', fn: 'cidrs',
	  in: lines('10.0.0.0/8', '9.255.255.255', '10.0.0.0/16', '2.0.0.0/8', '10.0.0.0', '0.0.0.0/0', '192.168.0.0/16'),
	  expect: { items: [ '0.0.0.0/0', '2.0.0.0/8', '9.255.255.255', '10.0.0.0/8', '10.0.0.0/16', '10.0.0.0', '192.168.0.0/16' ],
		errors: [] } },
	{ name: 'cidrs: numeric, not lexicographic', fn: 'cidrs',
	  in: lines('100.0.0.0/8', '20.0.0.0/8', '3.0.0.0/8', '255.255.255.255'),
	  expect: { items: [ '3.0.0.0/8', '20.0.0.0/8', '100.0.0.0/8', '255.255.255.255' ], errors: [] } },
	{ name: 'cidrs: invalid lines report line numbers', fn: 'cidrs',
	  in: lines('1.0.0.0/8', '192.168.1.5/24', '1.2.3', '1.2.3.4/33', '::1', '256.1.1.1', '01.2.3.4', 'a.b.c.d', '1.2.3.4 # x', '8.8.8.0/24'),
	  expect: { items: [ '1.0.0.0/8', '8.8.8.0/24' ], errors: [
		{ line: 2, text: '192.168.1.5/24' }, { line: 3, text: '1.2.3' }, { line: 4, text: '1.2.3.4/33' },
		{ line: 5, text: '::1' }, { line: 6, text: '256.1.1.1' }, { line: 7, text: '01.2.3.4' },
		{ line: 8, text: 'a.b.c.d' }, { line: 9, text: '1.2.3.4 # x' } ] } },
	{ name: 'cidrs: CRLF and BOM', fn: 'cidrs', in: '\uFEFF1.0.0.0/8\r\n2.0.0.0/8',
	  expect: { items: [ '1.0.0.0/8', '2.0.0.0/8' ], errors: [] } },
	{ name: 'cidrs: empty input', fn: 'cidrs', in: '# nothing\n', expect: { items: [], errors: [] } },

	// load
	{ name: 'load: data_dir beats baseline, custom lists read, empty vs ok', fn: 'load', in: 'full',
	  expect: { ok: true,
		data: { chnroute4: [ '10.0.0.0/8' ], gfw_static4: [ '91.108.4.0/22' ], direct_ip4: [ '1.2.3.4' ], proxy_ip4: [] },
		domains: { direct_domain: [ 'example.com' ], proxy_domain: [] },
		sources: { chnroute4: 'data:ok', gfw_static4: 'baseline:ok', direct_ip4: 'custom:ok', proxy_ip4: 'custom:missing',
			direct_domain: 'custom:ok', proxy_domain: 'custom:missing' },
		errors: [] } },
	{ name: 'load: falls back to baseline; empty file is empty, absent custom is empty', fn: 'load', in: 'baseline_only',
	  expect: { ok: true,
		data: { chnroute4: [ '1.0.0.0/8' ], gfw_static4: [], direct_ip4: [], proxy_ip4: [] },
		domains: { direct_domain: [], proxy_domain: [] },
		sources: { chnroute4: 'baseline:ok', gfw_static4: 'baseline:empty', direct_ip4: 'custom:missing', proxy_ip4: 'custom:missing',
			direct_domain: 'custom:missing', proxy_domain: 'custom:missing' },
		errors: [] } },
	{ name: 'load: an empty file in data_dir still wins over the baseline', fn: 'load', in: 'empty_wins',
	  expect: { ok: true,
		data: { chnroute4: [], gfw_static4: [], direct_ip4: [], proxy_ip4: [] },
		domains: { direct_domain: [], proxy_domain: [] },
		sources: { chnroute4: 'data:empty', gfw_static4: 'baseline:empty', direct_ip4: 'custom:missing', proxy_ip4: 'custom:missing',
			direct_domain: 'custom:missing', proxy_domain: 'custom:missing' },
		errors: [] } },
	{ name: 'load: rule data missing from both directories is an error', fn: 'load', in: 'missing_data',
	  expect: { ok: false, errors: [ 'baseline/chnroute4.txt:missing_data' ] } },
	{ name: 'load: unreadable file is an error and does not fall back', fn: 'load', in: 'unreadable',
	  expect: { ok: false, errors: [ 'data/chnroute4.txt:read_failed' ] } },
	{ name: 'load: invalid custom lines are errors with line numbers', fn: 'load', in: 'bad_custom',
	  expect: { ok: false, errors: [ 'custom/proxy_ip.txt:invalid_line:2:192.168.1.5/24', 'custom/proxy_domain.txt:invalid_line:2:bad_domain!' ] } }
];

export function run(c) {
	if (c.fn == 'domains')
		return parse_domains(c.in);

	if (c.fn == 'cidrs')
		return parse_cidrs(c.in);

	let dir = FIX + '/' + c.in;
	let r = load({ data_dir: dir + '/data', baseline_dir: dir + '/baseline', custom_dir: dir + '/custom' });
	let rel = (p) => substr(p, length(dir) + 1);

	let errors = map(r.errors, e => rel(e.file) + ':' + e.code + (e.line ? ':' + e.line + ':' + e.text : ''));

	if (!r.ok)
		return { ok: false, errors };

	let sources = {};
	for (let k, s in r.sources)
		sources[k] = s.origin + ':' + s.state;

	return { ok: r.ok, data: r.data, domains: r.domains, sources, errors };
};
