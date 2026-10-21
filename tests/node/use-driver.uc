'use strict';

// T9.10: emulate a caller whose cursor includes a session savedir, without ever
// touching the host's global /tmp/.uci. Keep real libuci load/set/commit behavior:
// dropping the production absolute-path load must replay and commit these deltas.
import * as fs from 'fs';

let root = fs.realpath(sourcepath(0, true) + '/../..');
let src = fs.readfile(root + '/aether-proxy/src/lib/cmd/node.uc');
if (src == null)
	die(`cannot read node command: ${fs.error() ?? 'unknown error'}`);
src = replace(src, "import * as uci from 'uci';",
	"import * as real_uci from 'uci';\n"
	+ "const uci = { cursor: (dir) => real_uci.cursor(dir, getenv('USE_SAVEDIR')) };\n");
src = replace(src, 'export function run(args)', 'function run(args)');
let command = loadstring(src + '\nreturn { run };')();
exit(command.run(slice(ARGV, 1)));
