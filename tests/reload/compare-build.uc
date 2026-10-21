'use strict';
// docs/04 reload: installed bytes must match the compatibility build() entry point,
// including nft restored sets, without replacing the other three staged outputs.
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
let built = pipeline.build({ ...opts, runtime: { node_ip: state.node_ip, dns_tier: state.dns_tier, restored } });
if (!built.ok)
	die(pipeline.describe_errors(built));
let failed = false;
for (let name, file in C.ARTIFACT_FILES) {
	let actual = fs.readfile(`${dir}/${C.DAEMON_CURRENT_DIR}/${file}`);
	if (actual == null)
		die(`cannot read ${file}: ${fs.error() ?? 'unknown error'}`);
	let equal = actual == built.artifacts[name];
	print(`${equal ? 'PASS' : 'FAIL'}  T9.9 ${label} installed ${name} matches pipeline.build bytes\n`);
	failed ||= !equal;
}
exit(failed ? 1 : 0);
