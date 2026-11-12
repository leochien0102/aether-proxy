'use strict';

// M4-09 (docs/02, docs/05): inactive values stay inert, active input is bounded,
// and only the prerouting policy jump may change (including explicit proxy hosts).
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';

export const cases = [
	{ name: 'P1 missing scope and all are byte-identical', kind: 'default', expect: true },
	{ name: 'P2 common exact TCP condition and unconditional UDP jump', kind: 'common', expect: true },
	{ name: 'P3 extra ranges expand sort and deduplicate', kind: 'extra', expect: true },
	{ name: 'P4 accepts 64 unique entries and rejects 65', kind: 'limit', expect: true },
	{ name: 'P4 deduplicates before the entry limit', kind: 'dedup', expect: true },
	{ name: 'P5 DNS QUIC and host chains remain byte-identical', kind: 'unchanged', expect: true }
];
for (let v in [ '0', '65536', '5000-4999', 'abc', '80,', '1.5', '-1', '1-65536', '1; jump proxy' ])
	push(cases, { name: 'P4 invalid extra_ports ' + v + ' reports field error', kind: 'invalid', v, expect: true });
for (let scope in [ 'all', 'common' ])
	push(cases, { name: 'P4 inactive invalid extra_ports ignored in ' + scope,
		kind: 'inactive', scope, expect: true });
push(cases, { name: 'P4 unknown scope reports enum field error', kind: 'enum', expect: true });

function load(main) {
	return config.normalize({ main, hosts: [ { policy: 'proxy', ip: '192.168.1.2', udp: '1' } ] });
}

function rules(main) {
	let r = load(main);
	return r.ok ? nft.render(r.snapshot, {}) : '';
}

const COMMON = '22, 53, 80, 143, 443, 465, 587, 853, 993, 995, 9418';
const JUMP = '\t\tjump host_policy\n';
function scoped(ports) {
	return '\t\tmeta l4proto tcp tcp dport { ' + ports + ' } jump host_policy\n' +
		'\t\tmeta l4proto udp jump host_policy\n';
}

export function run(c) {
	if (c.kind == 'default')
		return rules({}) == rules({ port_scope: 'all', extra_ports: 'invalid' }) &&
			index(rules({}), JUMP) >= 0;
	if (c.kind == 'common')
		return rules({ port_scope: 'common' }) == replace(rules({}), JUMP, scoped(COMMON));
	if (c.kind == 'extra') {
		let main = { port_scope: 'common_extra', extra_ports: '8080, 5000-5002, 05000,80,5001-5002' };
		return rules(main) == replace(rules({}), JUMP,
			scoped('22, 53, 80, 143, 443, 465, 587, 853, 993, 995, 5000, 5001, 5002, 8080, 9418'));
	}
	if (c.kind == 'unchanged') {
		// Exact whole-output delta also protects DNS hijack and QUIC mark/reject order.
		return rules({ port_scope: 'common_extra', extra_ports: '1-3' }) == replace(rules({}), JUMP,
			scoped('1, 2, 3, ' + COMMON));
	}
	if (c.kind == 'inactive')
		return load({ port_scope: c.scope, extra_ports: '0,bad' }).ok;
	if (c.kind == 'dedup') {
		let values = [];
		for (let i = 0; i < 100; i++)
			push(values, '0080');
		let r = load({ port_scope: 'common_extra', extra_ports: join(',', values) });
		return r.ok && r.snapshot.main.extra_ports == '80';
	}
	if (c.kind == 'limit') {
		let values = [];
		for (let i = 1; i <= 64; i++)
			push(values, '' + i);
		let good = load({ port_scope: 'common_extra', extra_ports: join(',', values) });
		push(values, '65');
		let bad = load({ port_scope: 'common_extra', extra_ports: join(',', values) });
		return good.ok && !bad.ok && bad.errors[0].field == 'main.extra_ports';
	}
	let r = load(c.kind == 'enum' ? { port_scope: 'other' }
		: { port_scope: 'common_extra', extra_ports: c.v });
	return !r.ok && r.errors[0].field == (c.kind == 'enum' ? 'main.port_scope' : 'main.extra_ports');
};
