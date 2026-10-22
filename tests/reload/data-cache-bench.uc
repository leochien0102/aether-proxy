'use strict';
// Host hotspot gate and repeatable before/after timings for docs/04 rule-data caching.
// From the repository root, pass a private temporary directory (including savedir).
// A second argument "pipeline-only" measures a fresh process without hotspot priming.
import * as fs from 'fs';
import * as uci from 'uci';
import * as config from 'aetherproxy.config';
import * as data from 'aetherproxy.data';
import * as pipeline from 'aetherproxy.pipeline';
import * as nft from 'aetherproxy.render.nft';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as dnsmasq from 'aetherproxy.render.dnsmasq';
import * as xray from 'aetherproxy.render.xray';

function now() {
	let t = clock(true);
	return t[0] * 1000 + t[1] / 1000000.0;
}

function hotspots(opts, tmp, runtime) {
	let cursor = uci.cursor(opts.confdir, tmp + '/savedir');
	let started = now();
	let cfg = config.load(cursor);
	let config_ms = now() - started;
	started = now();
	let d = data.load(opts);
	let data_ms = now() - started;
	if (!cfg.ok || !d.ok)
		die('baseline configuration/data load failed\n');
	let ctx = { data: d.data, runtime };
	let render_ms = {};
	for (let name, mod in { nft, chinadns, dnsmasq, xray }) {
		started = now();
		mod.render(cfg.snapshot, ctx);
		render_ms[name] = now() - started;
	}
	// Attribute nft time using an instrumented source copy, not production timers.
	let source = fs.readfile('aether-proxy/src/lib/render/nft.uc');
	if (source == null)
		die('cannot read nft source: ' + fs.error() + '\n');
	source = replace(source, 'export function render(', 'function render(');
	let sort_fn = index(source, 'function sort_data(') >= 0 ? 'sort_data' : 'sort_ips';
	source = replace(source, 'function sort_strings(list) {',
		'let sorting_ms = 0; function timed_sort(a, b) { ' +
		'let t = clock(true); let result = ' + sort_fn + '(a, b); let e = clock(true); ' +
		'sorting_ms += (e[0]-t[0])*1000+(e[1]-t[1])/1000000.0; return result; } function sort_strings(list) {');
	if (sort_fn == 'sort_data')
		source = replace(source, /sort_data\('/g, "timed_sort('");
	else
		source = replace(source, /sort_ips\((data\.|restored\.|host\[)/g, 'timed_sort($1');
	let measured = loadstring(source + '\nreturn { render, sorting: () => sorting_ms };')();
	measured.render(cfg.snapshot, ctx);
	printf('hotspots %.J\n', { config_ms, data_ms, render_ms, nft_sort_ms: measured.sorting(),
		chnroute4_entries: length(d.data.chnroute4) });
}

let tmp = ARGV[0];
if (!tmp)
	die('pass a private temporary directory\n');
let opts = {
	confdir: 'tests/fixtures/sample', data_dir: tmp + '/data',
	baseline_dir: 'aether-proxy/files/data', custom_dir: tmp + '/custom', run_dir: tmp
};
let runtime = { node_ip: '198.51.100.7', dns_tier: 'T2', restored: {} };
if (ARGV[1] != 'pipeline-only')
	hotspots(opts, tmp, runtime);

// Production read-only pipeline APIs; no writes via UCI, no staged fixture changes.
for (let i = 1; i <= 2; i++) {
	let started = now();
	let loaded = pipeline.read(opts);
	let read_ms = now() - started;
	started = now();
	let built = pipeline.render(loaded, runtime);
	let render_ms = now() - started;
	started = now();
	let with_sets = pipeline.render(loaded, { ...runtime, restored: { gfw4: [ '203.0.113.9' ] } }, 'nft');
	let nft_render_ms = now() - started;
	if (!built.ok || !with_sets.ok)
		die('pipeline failed\n');
	printf('pipeline %.J\n', { iteration: i, read_ms, render_ms, nft_render_ms,
		total_ms: read_ms + render_ms + nft_render_ms });
}
