'use strict';

// DNS default/override regression tests (docs/05 "config dns 'dns'", T8.22/T9.28).
// Keep T1's trust_dns independent of the direct upstreams used by T2 and boot.

import { normalize } from 'aetherproxy.config';

const DEFAULT_DIRECT = [ 'tcp://9.9.9.9' ];
const DEFAULT_TRUST = [ '8.8.8.8', '1.1.1.1' ];

export const cases = [
	{
		name: 'missing dns section uses new direct defaults and unchanged trust defaults',
		raw: {},
		expect: { direct_dns: DEFAULT_DIRECT, trust_dns: DEFAULT_TRUST }
	},
	{
		name: 'missing direct_dns preserves explicit trust_dns',
		raw: { dns: { trust_dns: [ '9.9.9.9' ] } },
		expect: { direct_dns: DEFAULT_DIRECT, trust_dns: [ '9.9.9.9' ] }
	},
	{
		name: 'explicit old direct_dns list is not migrated',
		raw: { dns: { direct_dns: [ 'tcp://8.8.8.8', 'tcp://1.1.1.1' ] } },
		expect: { direct_dns: [ 'tcp://8.8.8.8', 'tcp://1.1.1.1' ], trust_dns: DEFAULT_TRUST }
	},
	{
		name: 'explicit single direct_dns upstream is preserved',
		raw: { dns: { direct_dns: 'tls://dns.google@8.8.8.8' } },
		expect: { direct_dns: [ 'tls://dns.google@8.8.8.8' ], trust_dns: DEFAULT_TRUST }
	}
];

export function run(c) {
	let result = normalize(c.raw);
	if (!result.ok)
		return result.errors;

	let dns = result.snapshot.dns;
	if (dns.direct_dns_enabled !== false)
		return 'FAIL: missing direct_dns_enabled must normalize to false';
	return { direct_dns: dns.direct_dns, trust_dns: dns.trust_dns };
};
