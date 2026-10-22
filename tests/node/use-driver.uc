'use strict';

// T9.10/T9.20: keep real libuci but inject a private session savedir. Optional
// commit tracing proves a combined selection publishes both values only once.
// Never create or modify the host's global /tmp/.uci.
import * as fs from 'fs';

let root = fs.realpath(sourcepath(0, true) + '/../..');
let src = fs.readfile(root + '/aether-proxy/src/lib/cmd/node.uc');
if (src == null)
	die(`cannot read node command: ${fs.error() ?? 'unknown error'}`);
src = replace(src, "import * as uci from 'uci';", `
import * as real_uci from 'uci';
const uci = { cursor: (dir) => {
	let c = real_uci.cursor(dir, getenv('USE_SAVEDIR'));
	return {
		load: (path) => c.load(path),
		get: (...args) => c.get(...args),
		set: (...args) => c.set(...args),
		error: () => c.error(),
		commit: (pkg) => {
			let trace = getenv('USE_TRACE');
			if (trace != null) {
				let f = fs.open(trace, 'a');
				if (f == null) die('cannot open commit trace');
				if (!f.write(sprintf('%J', {
					node: c.get(pkg, 'main', 'node'), mode: c.get(pkg, 'main', 'mode')
				}) + '\\n') || !f.close()) die('cannot write commit trace');
			}
			return getenv('USE_COMMIT_FAIL') ? false : c.commit(pkg);
		}
	};
} };
`);
src = replace(src, 'export function run_mode(args)', 'function run_mode(args)');
src = replace(src, 'export function run(args)', 'function run(args)');
let command = loadstring(src + '\nreturn { run, run_mode };')();
exit(ARGV[0] == 'mode' ? command.run_mode(slice(ARGV, 1)) : command.run(slice(ARGV, 1)));
