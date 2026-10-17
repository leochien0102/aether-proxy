'use strict';
// Render the volatile DNS handoff fragment without changing the user's DHCP configuration.
// Design: docs/03「dnsmasq 对接」.

import * as C from 'aetherproxy.const';

// Pure renderer: the conf-dir snippet that points the system dnsmasq at chinadns-ng.
// The snippet only lives in tmpfs and is removed on reboot (docs/03-dns.md "dnsmasq 对接").
export function render(snapshot, ctx) {
	return join('\n', [
		'no-resolv',
		'server=127.0.0.1#' + C.CHINADNS_PORT,
	]) + '\n';
};
