'use strict';

// T9.33: host `ip` accepts start-end ranges (docs/05 `config host`). Validation, duplicate
// check, nft element order, and that ip_or_cidr (dynamic set paths) stays range-free.
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';
import { ip_or_cidr } from 'aetherproxy.net';

const CTX = { paths: {
	gfwlist: '/etc/aether-proxy/data/gfwlist.txt',
	chnlist: '/etc/aether-proxy/data/chnlist.txt', apple: '/etc/aether-proxy/data/apple.txt'
} };

function errors(hosts) {
	return map(config.normalize({ hosts }).errors ?? [], e => e.field + ':' + e.code);
}

function validation(c) {
	return errors(c.hosts);
}

function normalised(c) {
	let r = config.normalize({ hosts: [ { ip: c.ip } ] });
	return r.ok ? r.snapshot.hosts[0].ip : errors([ { ip: c.ip } ]);
}

function host_set(c) {
	let r = config.normalize({ hosts: c.hosts });
	if (!r.ok)
		return errors(c.hosts);
	let m = match(nft.render(r.snapshot, CTX), /\tset host_direct4 \{[^\n]*elements = \{ ([^}]*) \}/);
	return m ? m[1] : null;
}

function dynamic(c) {
	return ip_or_cidr(c.value) == null;
}

export const cases = [
	{ name: 'range passes', fn: 'validation', hosts: [ { ip: '192.168.8.250-192.168.8.254' } ], expect: [] },
	{ name: 'range with reversed ends is rejected', fn: 'validation',
		hosts: [ { ip: '192.168.8.254-192.168.8.250' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'range with missing end is rejected', fn: 'validation',
		hosts: [ { ip: '192.168.8.250-' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'range with missing start is rejected', fn: 'validation',
		hosts: [ { ip: '-192.168.8.250' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'non-address range is rejected', fn: 'validation',
		hosts: [ { ip: 'a-b' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'range with spaces is rejected', fn: 'validation',
		hosts: [ { ip: '192.168.8.250 - 192.168.8.254' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'range with CIDR end is rejected', fn: 'validation',
		hosts: [ { ip: '192.168.8.250-192.168.8.0/24' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'range with three parts is rejected', fn: 'validation',
		hosts: [ { ip: '192.168.8.1-192.168.8.2-192.168.8.3' } ], expect: [ 'host[0].ip:invalid_cidr' ] },
	{ name: 'x-x normalises to x', fn: 'normalised', ip: '192.168.8.7-192.168.8.7', expect: [ '192.168.8.7' ] },
	{ name: 'valid range is kept as written', fn: 'normalised',
		ip: '192.168.8.250-192.168.8.254', expect: [ '192.168.8.250-192.168.8.254' ] },
	{ name: 'same range in two hosts is duplicate', fn: 'validation',
		hosts: [ { ip: '192.168.8.250-192.168.8.254' }, { ip: '192.168.8.250-192.168.8.254' } ],
		expect: [ 'host[1].ip:duplicate' ] },
	{ name: 'x-x duplicates the single address in another host', fn: 'validation',
		hosts: [ { ip: '192.168.8.7' }, { ip: '192.168.8.7-192.168.8.7' } ], expect: [ 'host[1].ip:duplicate' ] },
	{ name: 'range and an address inside it coexist', fn: 'validation',
		hosts: [ { ip: '192.168.8.250-192.168.8.254' }, { ip: '192.168.8.252' } ], expect: [] },
	{ name: 'partially overlapping ranges coexist', fn: 'validation',
		hosts: [ { ip: '192.168.8.250-192.168.8.254' }, { ip: '192.168.8.252-192.168.8.253' } ], expect: [] },
	{ name: 'nft elements: mixed order by start, ranges as a-b', fn: 'host_set',
		hosts: [ { ip: [ '192.168.8.250-192.168.8.254', '192.168.8.20', '192.168.8.0/28', '192.168.8.100-192.168.8.100' ], policy: 'direct' } ],
		expect: '192.168.8.0/28, 192.168.8.20, 192.168.8.100, 192.168.8.250-192.168.8.254' },
	{ name: 'nft elements: same start, wider block first', fn: 'host_set',
		hosts: [ { ip: [ '10.0.0.1', '10.0.0.0-10.0.0.9', '10.0.0.0/30' ], policy: 'direct' } ],
		expect: '10.0.0.0-10.0.0.9, 10.0.0.0/30, 10.0.0.1' },
	{ name: 'nft elements: range spelling a CIDR block is written once', fn: 'host_set',
		hosts: [ { ip: [ '10.0.0.0/24', '10.0.0.0-10.0.0.255' ], policy: 'direct' } ],
		expect: '10.0.0.0/24' },
	{ name: 'ip_or_cidr (dynamic sets) still rejects ranges', fn: 'dynamic', value: '1.1.1.1-1.1.1.9', expect: true },
	{ name: 'ip_or_cidr still rejects x-x', fn: 'dynamic', value: '1.1.1.1-1.1.1.1', expect: true }
];

export function run(c) {
	switch (c.fn) {
	case 'validation': return validation(c);
	case 'normalised': return normalised(c);
	case 'host_set': return host_set(c);
	case 'dynamic': return dynamic(c);
	}
	return false;
};
