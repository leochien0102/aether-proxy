'use strict';

// T9.45 / docs/05: live existence checks and nft string encoding are independent.
// The command stubs deliberately do NOT claim to validate nft syntax.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';
import { precheck } from 'aetherproxy.cmd.check';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const IFACE = 'br-\\"lan';
const GUARD = '\t\tiifname != { "br-\\\\\\"lan" } return';

export const cases = [
	{ name: 'T9.45 existing quoted interface still needs complete token encoding', present: true,
		expect: { items: [ { item: 'lan_iface:' + IFACE, ok: true } ], guards: [ GUARD, GUARD ] } },
	{ name: 'T9.45 missing quoted interface fails existence despite correct encoding', present: false,
		expect: { items: [ { item: 'lan_iface:' + IFACE, ok: false,
			detail: 'interface ' + IFACE + ' does not exist' } ], guards: [ GUARD, GUARD ] } }
];

export function run(c) {
	let base = ROOT + '/tests/unit/.t945-precheck-' + fs.readlink('/proc/self');
	let bin = base + '/bin';
	let root = base + '/root';
	let net = root + '/sys/class/net';
	let result;
	try {
		if (!sys.mkdir_p(bin) || !sys.mkdir_p(net))
			die('precheck setup: ' + sys.error());
		for (let name in [ 'nft', 'ip', 'xray', 'chinadns-ng' ]) {
			let body = name == 'ip' ? 'echo "fwmark FWMARK[/MASK]"\n' : 'exit 0\n';
			if (!sys.write_atomic(bin + '/' + name, '#!/bin/sh\n' + body) || !fs.chmod(bin + '/' + name, 493))
				die('cannot create precheck stub ' + name + ': ' + (sys.error() ?? fs.error()));
		}
		if (c.present && !fs.mkdir(net + '/' + IFACE))
			die('cannot create interface fixture: ' + fs.error());
		let loaded = config.normalize({ main: { lan_ifaces: [ IFACE ], dns_hijack: '1' } });
		if (!loaded.ok)
			die(sprintf('unexpected config errors: %.J', loaded.errors));
		let pc = precheck(loaded.snapshot, base, { sys_root: root, bin_dir: bin });
		result = {
			items: filter(pc.items, item => index(item.item, 'lan_iface:') == 0),
			guards: filter(split(nft.render(loaded.snapshot, {}), '\n'), line => index(line, '\t\tiifname != ') == 0)
		};
	}
	catch (e) {
		let removed = sys.run([ 'rm', '-r', base ]);
		if (removed.code != 0)
			die('precheck cleanup failed: rm exit ' + removed.code + '; original error: ' + e);
		die(e);
	}
	let removed = sys.run([ 'rm', '-r', base ]);
	if (removed.code != 0)
		die('precheck cleanup failed: rm exit ' + removed.code);
	return result;
};
