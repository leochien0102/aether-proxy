'use strict';

// T16.82: engine-specific DNS upstream precheck covers only upstreams handed to the DNS engine.
import * as check from 'aetherproxy.cmd.check';

function snap(dns) {
	return {
		main: { mode: 'bypass_cn', node: 'n_00000000000000000000000000000001' },
		dns: {
			china_dns: [ '114.114.114.114' ],
			trust_dns: [ '8.8.8.8' ],
			direct_dns_enabled: false,
			direct_dns: [ 'tcp://9.9.9.9' ],
			...(dns ?? {})
		},
		nodes: {
			n_00000000000000000000000000000001: {
				protocol: 'trojan', security: 'tls', address: '203.0.113.10', port: 443
			}
		}
	};
}

export const cases = [
	{
		name: 'aether-dns rejects tls:// in china_dns',
		path: '/usr/bin/aether-dns',
		snapshot: snap({ china_dns: [ 'wan', 'tls://dns.alidns.com@223.5.5.5#853' ] }),
		expect: [ {
			item: 'dns_upstream:aether-dns:dns.china_dns',
			detail: 'aether-dns does not support tls:// upstream in dns.china_dns: tls://dns.alidns.com@223.5.5.5#853'
		} ]
	},
	{
		name: 'aether-dns rejects tls:// in direct_dns when direct_dns_enabled=true',
		path: '/usr/bin/aether-dns',
		snapshot: snap({ direct_dns_enabled: true, direct_dns: [ 'tcp://9.9.9.9', 'tls://dns.google@8.8.8.8' ] }),
		expect: [ {
			item: 'dns_upstream:aether-dns:dns.direct_dns',
			detail: 'aether-dns does not support tls:// upstream in dns.direct_dns: tls://dns.google@8.8.8.8'
		} ]
	},
	{
		name: 'aether-dns allows tls:// in direct_dns when direct_dns_enabled=false',
		path: '/usr/bin/aether-dns',
		snapshot: snap({ direct_dns_enabled: false, direct_dns: [ 'tls://dns.google@8.8.8.8' ] }),
		expect: []
	},
	{
		name: 'aether-dns reports both china_dns and enabled direct_dns TLS upstreams',
		path: '/usr/bin/aether-dns',
		snapshot: snap({
			china_dns: [ 'tls://223.5.5.5' ],
			direct_dns_enabled: true,
			direct_dns: [ 'tls://1.1.1.1#853' ]
		}),
		expect: [
			{
				item: 'dns_upstream:aether-dns:dns.china_dns',
				detail: 'aether-dns does not support tls:// upstream in dns.china_dns: tls://223.5.5.5'
			},
			{
				item: 'dns_upstream:aether-dns:dns.direct_dns',
				detail: 'aether-dns does not support tls:// upstream in dns.direct_dns: tls://1.1.1.1#853'
			}
		]
	},
	{
		name: 'aether-dns accepts ordinary UDP/TCP/wan upstreams',
		path: '/usr/bin/aether-dns',
		snapshot: snap({
			china_dns: [ 'wan', '114.114.114.114', 'udp://223.5.5.5#53' ],
			direct_dns_enabled: true,
			direct_dns: [ 'tcp://9.9.9.9', '8.8.8.8#53' ]
		}),
		expect: []
	},
	{
		name: 'chinadns-ng allows valid tls:// in china_dns and enabled direct_dns',
		path: '/usr/bin/chinadns-ng',
		snapshot: snap({
			china_dns: [ 'tls://dns.alidns.com@223.5.5.5' ],
			direct_dns_enabled: true,
			direct_dns: [ 'tls://dns.google@8.8.8.8' ]
		}),
		expect: []
	},
	{
		name: 'custom or missing DNS binary path is not falsely rejected',
		path: '/opt/custom-dns',
		snapshot: snap({
			china_dns: [ 'tls://223.5.5.5' ],
			direct_dns_enabled: true,
			direct_dns: [ 'tls://8.8.8.8' ]
		}),
		expect: []
	},
	{
		name: 'null DNS binary path is not falsely rejected',
		path: null,
		snapshot: snap({ china_dns: [ 'tls://223.5.5.5' ] }),
		expect: []
	}
];

export function run(c) {
	return check.dns_upstream_issues(c.snapshot, c.path);
};
