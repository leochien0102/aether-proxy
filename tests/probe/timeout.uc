'use strict';

// T9.50 / docs/10: inspect real RPC forwarding deadlines without waiting on rpcd.
// Only UCI and process execution are replaced; the production method table is unchanged.
import * as fs from 'fs';

let source = fs.readfile(ARGV[0] + '/luci-app-aether-proxy/root/usr/share/rpcd/ucode/aetherproxy.uc');
if (source == null)
	die('cannot read rpcd plugin: ' + (fs.error() ?? 'unknown error'));
source = replace(source, "import * as uci from 'uci';",
	"const uci = { cursor: () => ({ get: () => '30' }) };");
source = replace(source, "import * as sys from 'aetherproxy.sys';",
	"const sys = { run: (argv, opts) => ({ stdout: sprintf('%J', { timeout: opts.timeout }) }) };");
let methods = loadstring(source)().aetherproxy;
for (let method, expected in { probe_url: 35, check: 30, status: 10, components: 15 }) {
	let reply = methods[method].call({ args: method == 'probe_url' ? { site: 'google' } : {} });
	if (reply.timeout != expected)
		die(`${method}: expected ${expected}s, got ${reply.timeout}`);
	printf('PASS  T9.50 RPC %s budget exactly %ds\n', method, expected);
}
