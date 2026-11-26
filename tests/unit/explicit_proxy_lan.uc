'use strict';

import * as pipeline from 'aetherproxy.pipeline';

function lan(addresses, extra) {
	return { interface: 'lan', up: true, 'ipv4-address': addresses, ...(extra ?? {}) };
}
const ADDRESS = { address: '192.0.2.1', mask: 24 };

export const cases = [
	{ name: 'logical LAN does not need a default route or br-lan device', dump: { interface: [lan([ADDRESS], { device: 'eth9' })] }, expect: ['192.0.2.1'] },
	{ name: 'deduplicate current local LAN IPv4 addresses', dump: { interface: [lan([ADDRESS, { address: '192.0.2.2' }, ADDRESS])] }, expect: ['192.0.2.1', '192.0.2.2'] },
	{ name: 'WAN and default routes cannot authorize addresses', dump: { interface: [lan([ADDRESS], { interface: 'wan', route: [{target:'0.0.0.0',mask:0}] })] }, expect: [] },
	{ name: 'br-lan device name cannot substitute logical LAN', dump: { interface: [lan([ADDRESS], { interface: 'br-lan', device: 'br-lan' })] }, expect: [] },
	{ name: 'down LAN ignored', dump: { interface: [lan([ADDRESS], { up: false })] }, expect: [] },
	{ name: 'numeric up cannot authorize LAN address', dump: { interface: [lan([ADDRESS], { up: 1 })] }, expect: [] },
	{ name: 'string up cannot authorize LAN address', dump: { interface: [lan([ADDRESS], { up: '1' })] }, expect: [] },
	{ name: 'missing up ignored', dump: { interface: [{ interface: 'lan', 'ipv4-address': [ADDRESS] }] }, expect: [] },
	{ name: 'invalid expired and non-unicast addresses ignored', dump: { interface: [lan([
		null, false, 1, {}, { address: '192.0.2.1', valid: false }, { address: '192.0.2.7', valid: 0 }, { address: '192.0.2.2', valid_lft: 0 },
		{ address: '192.0.2.3', valid_lft: '0' }, { address: '192.0.2.4', 'valid-lifetime': 0 },
		{ address: '192.0.2.5', valid_lifetime: 0 }, { address: '192.0.2.6', 'valid-until': 0 },
		{ address: '0.0.0.0' }, { address: '127.1.2.3' }, { address: '224.0.0.1' }, { address: '255.255.255.255' },
		{ address: '::1' }, { address: '192.0.2.256' }, { address: '192.00.2.1' }, { address: '192.0.2.9', valid_lft: 10 }
	])] }, expect: ['192.0.2.9'] },
	{ name: 'single candidate automatic even with stale selection', resolve: true, addresses: ['192.0.2.2'], selected: '192.0.2.1', expect: ['192.0.2.2', []] },
	{ name: 'multiple candidates need explicit selection', resolve: true, addresses: ['192.0.2.1','192.0.2.2'], expect: [null, ['selection_required']] },
	{ name: 'multiple candidates honor current selected address', resolve: true, addresses: ['192.0.2.1','192.0.2.2'], selected: '192.0.2.2', expect: ['192.0.2.2', []] },
	{ name: 'stale selection cannot authorize multiple candidates', resolve: true, addresses: ['192.0.2.1','192.0.2.2'], selected: '192.0.2.3', expect: [null, ['selection_required']] },
	{ name: 'no address fails closed and clears previous runtime address', resolve: true, addresses: [], expect: [null, ['no_lan_address']] },
	{ name: 'both disabled do not require an address and discard old runtime value', resolve: true, disabled: true, addresses: [], expect: [null, []] }
];
for (let i, dump in [null, [], false, 1, '', {}, { interface: null }, { interface: {} },
	{ interface: [null, false, 1, [], {}, lan(null), lan({}), lan([null])] }])
	push(cases, { name: 'malformed dump safely yields no candidates ' + i, dump, expect: [] });

export function run(c) {
	if (!c.resolve) {
		let before = sprintf('%.J', c.dump);
		let result = pipeline.explicit_lan_from_dump(c.dump);
		if (result.interface != 'lan' || sprintf('%.J', c.dump) != before) return null;
		return result.addresses;
	}
	let main = { socks_enabled: !c.disabled, proxy_address: c.selected, proxy_listen: '192.0.2.99' };
	let errors = pipeline.resolve_proxy_listen(main, { addresses: c.addresses });
	return [main.proxy_listen, map(errors, e => e.code)];
};
