'use strict';

import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as config from 'aetherproxy.config';
import { precheck } from 'aetherproxy.cmd.check';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const LOCAL = '{"interface":[{"interface":"lan","up":true,"device":"eth9","ipv4-address":[{"address":"192.0.2.1"},{"address":"192.0.2.2"}]}]}';

export const cases = [
	{ name: 'both disabled never query addresses', disabled: true, output: 'invalid', expect: true },
	{ name: 'both enabled share current logical LAN address', output: LOCAL, expect: true },
	{ name: 'only SOCKS enabled', http_off: true, output: LOCAL, expect: true },
	{ name: 'only HTTP enabled', socks_off: true, output: LOCAL, expect: true },
	{ name: 'nonlocal resolved address rejected', output: LOCAL, listen: '192.0.2.99', bad: true, expect: true },
	{ name: 'address on WAN cannot authorize resolved listener', output: replace(LOCAL, '"lan"', '"wan"'), bad: true, expect: true },
	{ name: 'down LAN cannot authorize resolved listener', output: replace(LOCAL, 'true', 'false'), bad: true, expect: true },
	{ name: 'main.lan_ifaces is not explicit address authority', second: true, output: LOCAL, expect: true },
	{ name: 'query error fails closed despite valid output', output: LOCAL, code: 1, bad: true, expect: true },
	{ name: 'empty output fails closed', output: '', bad: true, expect: true },
	{ name: 'malformed JSON fails closed', output: '{', bad: true, expect: true },
	{ name: 'null JSON fails closed', output: 'null', bad: true, expect: true },
	{ name: 'object JSON without interfaces fails closed', output: '{}', bad: true, expect: true },
	{ name: 'array query fails closed', output: '[]', bad: true, expect: true },
	{ name: 'null row fails closed', output: '{"interface":[null]}', bad: true, expect: true },
	{ name: 'malformed address list fails closed', output: replace(LOCAL, '[{"address":"192.0.2.1"},{"address":"192.0.2.2"}]', '{}'), bad: true, expect: true },
	{ name: 'empty interface address list rejected', output: replace(LOCAL, '[{"address":"192.0.2.1"},{"address":"192.0.2.2"}]', '[]'), bad: true, expect: true },
	{ name: 'expired address cannot authorize resolved listener', output: replace(LOCAL, '"address":"192.0.2.1"', '"address":"192.0.2.1","valid_lft":0'), bad: true, expect: true },
	{ name: 'address changed after pipeline read cannot authorize stale listener', output: replace(LOCAL, '192.0.2.1', '192.0.2.3'), bad: true, expect: true }
];

export function run(c) {
	let base = ROOT + '/tests/unit/.explicit-precheck-' + fs.readlink('/proc/self');
	let bin = base + '/bin', root = base + '/root', result;
	try {
		if (!sys.mkdir_p(bin) || !sys.mkdir_p(root + '/sys/class/net/br-lan')
			|| (c.second && !sys.mkdir_p(root + '/sys/class/net/lan2')))
			die('precheck fixture setup failed');
		if (!sys.write_atomic(base + '/addresses', c.output)) die('precheck output fixture failed');
		let ubus = '#!/bin/sh\n'
			+ 'printf "%s\\n" "$*" >> "' + base + '/calls"\n'
			+ '[ "$*" = "call network.interface dump" ] || exit 2\n'
			+ 'cat "' + base + '/addresses"\nexit ' + (c.code ?? 0) + '\n';
		for (let name in [ 'ubus', 'ip', 'nft' ]) {
			let text = name == 'ubus' ? ubus : name == 'ip' ? '#!/bin/sh\necho "fwmark FWMARK[/MASK]"\n' : '#!/bin/sh\nexit 0\n';
			if (!sys.write_atomic(bin + '/' + name, text) || !fs.chmod(bin + '/' + name, 493)) die('precheck command fixture failed');
		}
		let main = { lan_ifaces: c.second ? [ 'br-lan', 'lan2' ] : [ 'br-lan' ],
			socks_enabled: !(c.disabled || c.socks_off), socks_port: 41080,
			http_enabled: !(c.disabled || c.http_off), http_port: 41081,
			proxy_username: 'fixture', proxy_password: 'fixture' };
		let loaded = config.normalize({ main });
		if (!loaded.ok) die('unexpected normalization failure');
		loaded.snapshot.main.proxy_listen = c.listen ?? '192.0.2.1';
		let pc = precheck(loaded.snapshot, base, { sys_root: root, bin_dir: bin });
		let items = filter(pc.items, i => index(i.item, 'explicit_listen:') == 0);
		result = c.disabled ? !length(items) && fs.readfile(base + '/calls') == null
			: length(items) == int(main.socks_enabled) + int(main.http_enabled)
				&& length(filter(items, i => i.ok != !c.bad)) == 0;
	}
	catch (e) {
		sys.run([ 'rm', '-rf', base ]);
		die(e);
	}
	if (sys.run([ 'rm', '-rf', base ]).code != 0) die('precheck fixture cleanup failed');
	return result;
};
