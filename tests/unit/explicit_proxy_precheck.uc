'use strict';

import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as config from 'aetherproxy.config';
import { precheck } from 'aetherproxy.cmd.check';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const LOCAL = '[{"ifname":"br-lan","addr_info":[{"family":"inet","local":"192.0.2.1"},{"family":"inet","local":"192.0.2.2"}]}]';

export const cases = [
	{ name: 'both disabled never query addresses', disabled: true, output: 'invalid', expect: true },
	{ name: 'both enabled local primary and secondary addresses', output: LOCAL, expect: true },
	{ name: 'only SOCKS enabled', http_off: true, output: LOCAL, expect: true },
	{ name: 'only HTTP enabled', socks_off: true, output: LOCAL, expect: true },
	{ name: 'nonlocal address rejected', output: LOCAL, listen: '192.0.2.99', bad: true, expect: true },
	{ name: 'address on nonLAN interface rejected', output: replace(LOCAL, 'br-lan', 'wan'), bad: true, expect: true },
	{ name: 'interface missing despite successful ip fixture', absent: true, output: LOCAL, bad: true, expect: true },
	{ name: 'query error fails closed despite valid output', output: LOCAL, code: 1, bad: true, expect: true },
	{ name: 'empty output fails closed', output: '', bad: true, expect: true },
	{ name: 'malformed JSON fails closed', output: '{', bad: true, expect: true },
	{ name: 'null JSON fails closed', output: 'null', bad: true, expect: true },
	{ name: 'object JSON fails closed', output: '{}', bad: true, expect: true },
	{ name: 'empty query array fails closed', output: '[]', bad: true, expect: true },
	{ name: 'null row fails closed', output: '[null]', bad: true, expect: true },
	{ name: 'malformed address list fails closed', output: '[{"ifname":"br-lan","addr_info":{}}]', bad: true, expect: true },
	{ name: 'empty interface address list rejected', output: '[{"ifname":"br-lan","addr_info":[]}]', bad: true, expect: true },
	{ name: 'IPv6 cannot authorize IPv4', output: replace(LOCAL, 'inet', 'inet6'), bad: true, expect: true },
	{ name: 'query failure on another configured LAN fails closed', second: true, output: LOCAL, bad: true, expect: true }
];

export function run(c) {
	let base = ROOT + '/tests/unit/.explicit-precheck-' + fs.readlink('/proc/self');
	let bin = base + '/bin';
	let root = base + '/root';
	let result;
	try {
		if (!sys.mkdir_p(bin) || !sys.mkdir_p(root + '/sys/class/net'))
			die('precheck fixture setup failed: ' + sys.error());
		if (!c.absent && !fs.mkdir(root + '/sys/class/net/br-lan'))
			die('precheck interface fixture failed: ' + fs.error());
		if (c.second && !fs.mkdir(root + '/sys/class/net/lan2'))
			die('precheck second interface fixture failed: ' + fs.error());
		if (!sys.write_atomic(base + '/addresses', c.output))
			die('precheck output fixture failed');
		let ip = '#!/bin/sh\n'
			+ 'if [ "$*" = "rule help" ]; then echo "fwmark FWMARK[/MASK]"; exit 0; fi\n'
			+ 'printf "%s\\n" "$*" >> "' + base + '/calls"\n'
			+ '[ "$*" = "-j -4 addr show dev br-lan" ] || exit 2\n'
			+ 'cat "' + base + '/addresses"\nexit ' + (c.code ?? 0) + '\n';
		for (let name in [ 'ip', 'nft' ]) {
			if (!sys.write_atomic(bin + '/' + name, name == 'ip' ? ip : '#!/bin/sh\nexit 0\n')
				|| !fs.chmod(bin + '/' + name, 493))
				die('precheck command fixture failed');
		}
		let main = {
			lan_ifaces: c.second ? [ 'br-lan', 'lan2' ] : [ 'br-lan' ],
			socks_enabled: !(c.disabled || c.socks_off), socks_listen: c.listen ?? '192.0.2.1', socks_port: 41080,
			socks_username: 'fixture', socks_password: 'fixture',
			http_enabled: !(c.disabled || c.http_off), http_listen: c.listen ?? '192.0.2.2', http_port: 41081,
			http_username: 'fixture', http_password: 'fixture'
		};
		let loaded = config.normalize({ main });
		if (!loaded.ok)
			die('unexpected normalization failure');
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
	if (sys.run([ 'rm', '-rf', base ]).code != 0)
		die('precheck fixture cleanup failed');
	return result;
};
