'use strict';
// docs/04 rule-data cache: instrument source copies, leaving production exports unchanged.
// Temporary files live inside this worktree; no UCI cursor or host savedir is used.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as nft from 'aetherproxy.render.nft';

const ROOT = sourcepath(0, true) + '/../..';

function need(ok, message) {
	if (!ok)
		die(message);
}

function command(argv) {
	let r = sys.run(argv, { timeout: 10 });
	need(r.code == 0, join(' ', argv) + ': ' + r.stderr);
	return trim(r.stdout);
}

function source(path) {
	let s = fs.readfile(ROOT + '/aether-proxy/src/lib/' + path);
	need(s != null, 'source read failed: ' + fs.error());
	return s;
}

function measured_data() {
	let s = replace(source('data.uc'), /export function /g, 'function ');
	s = replace(s, 'let text = fs.readfile(path);', 'reads++; let text = fs.readfile(path);');
	return loadstring('let reads = 0;\n' + s + '\nreturn { load, reads: () => reads };')();
}

function measured_nft() {
	let s = replace(source('render/nft.uc'), 'export function render(', 'function render(');
	s = replace(s, 'function sort_ips(list) {', 'function sort_ips(list) { push(inputs, list);');
	return loadstring('let inputs = [];\n' + s + '\nreturn { render, inputs };')();
}

function put(path, text) {
	need(sys.write_atomic(path, text), 'write failed: ' + sys.error());
}

// Deliberately bypass atomic writes only to model an external in-place file editor.
function overwrite(path, text, mtime) {
	let f = fs.open(path, 'w');
	need(f != null, 'open failed: ' + fs.error());
	need(f.write(text) == length(text), 'write failed: ' + fs.error());
	need(f.close(), 'close failed: ' + fs.error());
	command([ 'touch', '-m', '-d', '@' + mtime, path ]);
}

function same(a, b) {
	return sprintf('%.J', a) == sprintf('%.J', b);
}

export const cases = [
	{ name: 'T9.24 repeated load deep-equal with zero further readfile calls and stable arrays',
	  kind: 'hit', expect: 'PASS' },
	{ name: 'T9.24 same-size in-place edit invalidates on mtime', kind: 'mtime', expect: 'PASS' },
	{ name: 'T9.24 same-mtime in-place edit invalidates on size', kind: 'size', expect: 'PASS' },
	{ name: 'T9.24 atomic mv invalidates on inode despite equal size and mtime', kind: 'inode', expect: 'PASS' },
	{ name: 'T9.24 deletion falls back or errors and custom deletion becomes empty', kind: 'delete', expect: 'PASS' },
	{ name: 'T9.24 invalid_line is retried even with unchanged stat metadata', kind: 'invalid', expect: 'PASS' },
	{ name: 'T9.24 read_failed is retried and does not fall back to baseline', kind: 'read_error', expect: 'PASS' },
	{ name: 'T9.24 nft same arrays skip sorting and fresh arrays sort with identical bytes',
	  kind: 'nft', expect: 'PASS' }
];

function exercise(kind, dir) {
	let mod = measured_data();
	let opts = { data_dir: dir + '/data', baseline_dir: dir + '/base', custom_dir: dir + '/custom' };
	for (let d in [ opts.data_dir, opts.baseline_dir, opts.custom_dir ])
		need(fs.mkdir(d), 'mkdir failed: ' + fs.error());
	let path = opts.data_dir + '/chnroute4.txt';
	put(path, '1.0.0.0/8\n');
	put(opts.baseline_dir + '/chnroute4.txt', '2.0.0.0/8\n');
	put(opts.baseline_dir + '/gfw_static4.txt', '91.108.4.0/22\n');
	for (let name in [ 'direct_ip', 'proxy_ip', 'direct_domain', 'proxy_domain' ])
		put(opts.custom_dir + '/' + name + '.txt', '');
	let first = mod.load(opts);
	need(first.ok, 'initial load failed');
	let count = mod.reads();
	let st = fs.stat(path);

	if (kind == 'hit') {
		let next = mod.load(opts);
		need(same(first, next), 'results differ');
		need(mod.reads() == count && count == 6, 'cache hit read files');
		need(first.data.chnroute4 == next.data.chnroute4, 'array identity lost');
		return;
	}
	if (kind == 'mtime') {
		overwrite(path, '3.0.0.0/8\n', st.mtime + 10);
		need(fs.stat(path).inode == st.inode && fs.stat(path).size == st.size, 'not an equal-size in-place edit');
	}
	else if (kind == 'size') {
		overwrite(path, '3.0.0.0/8\n4.0.0.0/8\n', st.mtime);
		need(fs.stat(path).inode == st.inode && fs.stat(path).mtime == st.mtime, 'metadata not preserved');
	}
	else if (kind == 'inode') {
		put(path, '3.0.0.0/8\n');
		command([ 'touch', '-m', '-d', '@' + st.mtime, path ]);
		let after = fs.stat(path);
		need(after.inode != st.inode && after.size == st.size && after.mtime == st.mtime, 'not inode-only replacement');
	}
	else if (kind == 'delete') {
		need(fs.unlink(path), 'unlink data failed');
		let fallback = mod.load(opts);
		need(fallback.ok && fallback.data.chnroute4[0] == '2.0.0.0/8', 'deleted data did not fall back');
		need(fs.unlink(opts.baseline_dir + '/chnroute4.txt'), 'unlink baseline failed');
		need(fs.unlink(opts.custom_dir + '/direct_ip.txt'), 'unlink custom failed');
		let missing = mod.load(opts);
		need(!missing.ok && missing.errors[0].code == 'missing_data', 'deleted baseline reused stale parse');
		need(missing.sources.direct_ip4.state == 'missing' && !length(missing.data.direct_ip4),
			'deleted custom not empty');
		put(path, '3.0.0.0/8\n');
	}
	else if (kind == 'invalid') {
		overwrite(path, 'bad line!\n', st.mtime + 10);
		let bad = mod.load(opts);
		need(!bad.ok && bad.errors[0].code == 'invalid_line', 'invalid line accepted');
		let reads = mod.reads();
		need(!mod.load(opts).ok && mod.reads() == reads + 1, 'invalid parse cached');
		let invalid_st = fs.stat(path);
		overwrite(path, '3.0.0.0/8\n', invalid_st.mtime);
		need(fs.stat(path).size == invalid_st.size && fs.stat(path).inode == invalid_st.inode,
			'repair metadata changed');
	}
	else if (kind == 'read_error') {
		need(fs.unlink(path) && fs.mkdir(path), 'cannot create unreadable directory');
		let bad = mod.load(opts);
		need(!bad.ok && bad.errors[0].code == 'read_failed', 'read error fell back or reused stale parse');
		let reads = mod.reads();
		need(!mod.load(opts).ok && mod.reads() == reads + 1, 'read failure cached');
		need(fs.rmdir(path), 'rmdir failed');
		put(path, '3.0.0.0/8\n');
	}
	else if (kind == 'nft') {
		let renderer = measured_nft();
		let snapshot = { main: { mode: 'gfw' }, hosts: [] };
		let ctx = { data: first.data, runtime: { restored: { gfw4: [ '9.0.0.1' ] } } };
		let before = sprintf('%.J', ctx);
		let a = renderer.render(snapshot, ctx);
		let b = renderer.render(snapshot, ctx);
		for (let name, list in ctx.data)
			need(length(filter(renderer.inputs, x => x == list)) == 1, name + ' sorted twice');
		need(a == b && before == sprintf('%.J', ctx), 'render changed output or inputs');
		let fresh = {};
		for (let name, list in ctx.data)
			fresh[name] = [ ...list ];
		let c = renderer.render(snapshot, { ...ctx, data: fresh });
		for (let name, list in fresh)
			need(length(filter(renderer.inputs, x => x == list)) == 1, name + ' fresh array not sorted');
		need(c == a && nft.render(snapshot, ctx) == a, 'fresh or production output differs');
		push(ctx.runtime.restored.gfw4, '8.0.0.1');
		need(renderer.render(snapshot, ctx) != a, 'mutable restored data cached');
		return;
	}
	let next = mod.load(opts);
	need(next.ok && next.data.chnroute4[0] == '3.0.0.0/8', 'new contents not loaded');
	need(next.data.chnroute4 != first.data.chnroute4 && mod.reads() > count, 'changed file reused cached array');
	if (kind == 'size')
		need(length(next.data.chnroute4) == 2, 'size change lost new item');
}

export function run(c) {
	let dir = command([ 'mktemp', '-d', ROOT + '/tests/unit/.T9.24.XXXXXX' ]);
	try {
		exercise(c.kind, dir);
	}
	catch (e) {
		command([ 'rm', '-rf', dir ]);
		return 'FAIL: ' + (e.message ?? e);
	}
	command([ 'rm', '-rf', dir ]);
	return 'PASS';
};
