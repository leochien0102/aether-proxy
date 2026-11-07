'use strict';
// Pure selection/validation contracts for T15.4; network cases use bootstrap-dns/run.sh.
import * as chinadns from 'aetherproxy.render.chinadns';
import * as dns from 'aetherproxy.bootstrap_dns';

export const cases = [
	{ name: 'Q1 boot selection preserves WAN expansion order and upstream syntax', expect: 'PASS', kind: 'boot' },
	{ name: 'Q2 explicit endpoint and domain validation rejects invalid inputs', expect: 'PASS', kind: 'validate' }
];

export function run(c) {
	if (c.kind == 'boot') {
		let china = [ 'wan', 'tcp://192.0.2.1#5353' ];
		let direct = [ 'tls://host.test@192.0.2.2#853', 'udp://192.0.2.3#54' ];
		let ctx = { wan_dns: [ '192.0.2.4', '192.0.2.5' ] };
		for (let enabled in [ false, true ]) {
			let snapshot = { dns: { china_dns: china, direct_dns: direct, direct_dns_enabled: enabled } };
			let want = enabled ? direct : [ '192.0.2.4', '192.0.2.5', 'tcp://192.0.2.1#5353' ];
			let actual = chinadns.boot_upstreams(snapshot, ctx);
			if (join(',', actual) != join(',', want))
				return 'boot helper mismatch';
			let text = chinadns.render(snapshot, ctx);
			if (index(text, 'group boot\ngroup-upstream ' + join(',', want) + '\n') < 0)
				return 'renderer/helper mismatch';
		}
		let expanded = { dns: { china_dns: [ '192.0.2.6' ] } };
		if (join(',', chinadns.boot_upstreams(expanded, ctx)) != '192.0.2.6')
			return 'already-expanded snapshot changed';
		return length(chinadns.boot_upstreams({ dns: { china_dns: [ 'wan' ] } }, {})) > 0 ? 'PASS' : 'missing WAN fallback';
	}
	let endpoint = { address: '127.0.0.1', port: 40000 };
	for (let name in [ '', '.test', 'test.', 'a..test', 'bad/name', sprintf('%064d', 0) + '.test',
		join('.', map([ 1, 2, 3, 4, 5 ], x => sprintf('%060d', x))) ])
		if (dns.validate(name, endpoint).ok)
			return 'invalid domain accepted';
	for (let port in [ null, '40000', 40000.5, 0, -1, 65536, 53, 31053, 31082, 31083 ])
		if (dns.validate('node.test', { address: '127.0.0.1', port }).ok)
			return 'invalid port accepted';
	for (let address in [ 'localhost', '0.0.0.0', '127.0.0.2', '192.0.2.1', 'udp://127.0.0.1' ])
		if (dns.validate('node.test', { address, port: 40000 }).ok)
			return 'invalid endpoint accepted';
	for (let timeout in [ 0, -1, 3001, 1.5, '10' ])
		if (dns.validate('node.test', endpoint, timeout).ok)
			return 'invalid timeout accepted';
	return dns.validate('Node.Test', endpoint, 1).ok && dns.validate('node.test', endpoint, 3000).ok
		? 'PASS' : 'valid input rejected';
};
