'use strict';
// T9.48: Q1 quarantine is shared by startup and monitor (docs/04 dynamic sets).
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as apply from 'aetherproxy.apply';
import * as C from 'aetherproxy.const';

export const cases = map([
	{ name: 'bad JSON quarantines once and later corruption replaces the only bad file', text: '{broken' },
	{ name: 'non-object saved sets quarantine once', text: '[]' },
	{ name: 'null saved sets quarantine once', text: 'null' },
	{ name: 'missing dynamic set quarantines once', text: '{"gfw4":[],"udirect4":[]}' },
	{ name: 'non-array dynamic set quarantines once', text: '{"gfw4":{},"udirect4":[],"uproxy4":[]}' },
	{ name: 'non-IPv4 element quarantines once', text: '{"gfw4":["::1"],"udirect4":[],"uproxy4":[]}' },
	{ name: 'non-string element quarantines once', text: '{"gfw4":[42],"udirect4":[],"uproxy4":[]}' },
	{ name: 'missing save ignores bad file and emits no event', mode: 'absent' },
	{ name: 'read failure is fatal without quarantine', mode: 'read' },
	{ name: 'dangling save symlink is a read failure, not an absent save', mode: 'symlink' },
	{ name: 'non-directory parent is a read failure, not an absent save', mode: 'notdir' },
	{ name: 'rename failure emits FS_FAILED without changing source', mode: 'rename' }
], c => ({ ...c, expect: 'PASS' }));
let serial = 0;
const EMPTY = { gfw4: [], udirect4: [], uproxy4: [] };
function write(path, text) {
	if (!sys.write_atomic(path, text)) die(`fixture write: ${sys.error()}`);
};
function events(dir) {
	return map(filter(split(fs.readfile(`${dir}/${C.EVENTS_FILE}`) ?? '', '\n'), l => l != ''), l => json(l));
};
function is_empty(r) {
	return r.ok && sprintf('%.J', r.sets) == sprintf('%.J', EMPTY);
};
function exercise(c, dir) {
	let ctx = { run_dir: dir }, path = `${dir}/${C.SETS_SAVE_FILE}`, bad = `${path}.bad`;
	if (c.mode == 'absent') {
		write(bad, '{old bad');
		return is_empty(apply.sets_load(ctx)) && !length(events(dir)) && fs.readfile(bad) == '{old bad';
	}
	if (c.mode == 'read') {
		// Reading a directory fails even as root; unlike chmod this is deterministic on CI.
		if (!fs.mkdir(path)) die(`fixture mkdir: ${fs.error()}`);
		let r = apply.sets_load(ctx);
		return !r.ok && fs.stat(path)?.type == 'directory' && fs.stat(bad) == null &&
			!length(filter(events(dir), e => e.code == 'SETS_RESTORE_FAILED'));
	}
	if (c.mode == 'symlink') {
		if (!fs.symlink(`${dir}/missing-target`, path)) die(`fixture symlink: ${fs.error()}`);
		let r = apply.sets_load(ctx);
		return !r.ok && fs.lstat(path)?.type == 'link' && fs.stat(bad) == null &&
			!length(filter(events(dir), e => e.code == 'SETS_RESTORE_FAILED'));
	}
	if (c.mode == 'notdir') {
		write(`${dir}/parent`, 'not a directory');
		let r = apply.sets_load({ run_dir: `${dir}/parent` });
		return !r.ok && fs.readfile(`${dir}/parent`) == 'not a directory' && fs.stat(bad) == null;
	}
	if (c.mode == 'rename') {
		write(path, '{broken');
		if (!fs.mkdir(bad)) die(`fixture mkdir: ${fs.error()}`);
		let r = apply.sets_load(ctx), es = events(dir);
		return !r.ok && fs.readfile(path) == '{broken' && fs.stat(bad)?.type == 'directory' &&
			length(es) == 1 && es[0].code == 'FS_FAILED' && es[0].args.op == 'rename';
	}
	write(bad, 'old quarantine');
	for (let text in [ c.text, c.text + '\n' ]) {
		write(path, text);
		let before = length(events(dir)), r = apply.sets_load(ctx), es = events(dir);
		if (!is_empty(r) || fs.stat(path) != null || fs.readfile(bad) != text || length(es) != before + 1)
			return false;
		let last = es[length(es) - 1];
		if (last.code != 'SETS_RESTORE_FAILED' || last.level != 'warn' || !length(last.args.detail ?? ''))
			return false;
		if (!is_empty(apply.sets_load(ctx)) || length(events(dir)) != length(es))
			return false;
		let retained = filter(fs.lsdir(dir), name => index(name, 'sets.save') == 0);
		if (join(',', retained) != 'sets.save.bad') return false;
	}
	return true;
};
export function run(c) {
	let dir = sourcepath(0, true) + `/.sets-recovery-${fs.readlink('/proc/self')}-${serial++}`;
	if (!fs.mkdir(dir)) die(`fixture mkdir: ${fs.error()}`);
	let ok = exercise(c, dir);
	for (let name in fs.lsdir(dir)) {
		let path = `${dir}/${name}`;
		if (fs.lstat(path)?.type == 'directory') {
			if (!fs.rmdir(path)) die(`fixture rmdir: ${fs.error()}`);
		}
		else if (!fs.unlink(path)) die(`fixture unlink: ${fs.error()}`);
	}
	if (!fs.rmdir(dir)) die(`fixture rmdir: ${fs.error()}`);
	return ok ? 'PASS' : `FAIL: ${c.name}`;
};
