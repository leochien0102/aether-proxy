'use strict';
// T15.6 private rendering shares B1 selection, without changing formal artifacts.
import * as bootstrap from 'aetherproxy.bootstrap';
import * as chinadns from 'aetherproxy.render.chinadns';
export const cases = [
	{ name: 'C2 private full upstream syntax order and direct switch preserved', expect: 'PASS' },
	{ name: 'C11 private config contains no ordinary lists sets or handoff', expect: 'PASS' }
];
export function run(c) {
	let china = [ 'udp://192.0.2.1#1053', '192.0.2.2', 'tcp://host.test@192.0.2.3#2053' ];
	let direct = [ 'tls://boot.test@192.0.2.4#853', 'tcp://192.0.2.5', 'udp://192.0.2.6#3053' ];
	for (let enabled in [ false, true ]) {
		let snapshot = { dns: { china_dns: china, direct_dns: direct, direct_dns_enabled: enabled } };
		let text = bootstrap.render(snapshot, { address: '127.0.0.1', port: 40001 });
		let upstreams = join(',', chinadns.boot_upstreams(snapshot));
		if (index(text, `china-dns ${upstreams}\n`) < 0 || index(text, `trust-dns ${upstreams}\n`) < 0)
			return 'private upstream syntax/order changed';
		for (let forbidden in [ 'group ', 'list-file ', 'group-dnl ', 'inet@', 'server=', 'hosts', 'cache-db' ])
			if (index(text, forbidden) >= 0)
				return `unwanted private directive ${forbidden}`;
		if (index(text, 'default-tag gfw\nipset-name4 null\nipset-name6 null\ncache 0\n') < 0)
			return 'private engine contract changed';
	}
	return 'PASS';
};
