'use strict';
// docs/04 reload: installed bytes must match source rendering with the frozen paths
// required by T9.43, including restored nft sets, without rewriting other staged outputs.
import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';

let label = shift(ARGV);
let restored = json(shift(ARGV));
let parsed = pipeline.parse_args(ARGV);
if (parsed.error != null)
	die(parsed.error);
let opts = parsed.opts;
let dir = (opts.sys_root ?? '') + pipeline.run_dir(opts);
let text = fs.readfile(`${dir}/${C.STATE_FILE}`);
if (text == null)
	die(`cannot read state: ${fs.error() ?? 'unknown error'}`);
let state = json(text);
let loaded = pipeline.read(opts);
if (!loaded.ok)
	die(pipeline.describe_errors(loaded));
// Applications deliberately no longer have CLI paths. Verify every frozen byte against
// its source, then render with the installed generation; CLI build itself remains unchanged.
let parent = `${dir}/${C.APPLIED_SUBDIR}`;
let generations = fs.lsdir(parent);
if (generations == null || length(generations) != 1)
	die('expected exactly one applied generation');
for (let key, file in C.APPLIED_FILES) {
	let source = loaded.paths[key];
	if (fs.stat((opts.sys_root ?? '') + source) != null)
		source = (opts.sys_root ?? '') + source;
	let frozen = `${parent}/${generations[0]}/${file}`;
	if (fs.readfile(frozen) != (fs.readfile(source) ?? ''))
		die(`frozen ${key} does not match its source`);
	loaded.paths[key] = frozen;
}
let built = pipeline.render(loaded, { node_ip: state.node_ip, dns_tier: state.dns_tier, restored });
if (!built.ok)
	die(pipeline.describe_errors(built));
let failed = false;
for (let name, file in C.ARTIFACT_FILES) {
	let actual = fs.readfile(`${dir}/${C.DAEMON_CURRENT_DIR}/${file}`);
	if (actual == null)
		die(`cannot read ${file}: ${fs.error() ?? 'unknown error'}`);
	let equal = actual == built.artifacts[name];
	print(`${equal ? 'PASS' : 'FAIL'}  T9.9 ${label} installed ${name} matches source build with frozen paths\n`);
	failed ||= !equal;
}
exit(failed ? 1 : 0);
