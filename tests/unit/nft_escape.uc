'use strict';

// T9.45 / docs/02 nft template: compare complete interface guard tokens, not substrings.
// Config validation stays separate from live existence checks (docs/05 rule 5).
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';

function guards(text) {
	return filter(split(text, '\n'), line => index(line, '\t\tiifname != ') == 0);
}

function token_case(name, iface, token) {
	return { name: 'T9.45 token ' + name, kind: 'token', iface, expect: [
		'\t\tiifname != { ' + token + ' } return',
		'\t\tiifname != { ' + token + ' } return'
	] };
}

function config_case(name, main, errors, ifaces) {
	return { name: 'T9.45 config ' + name, kind: 'config', main,
		expect: { errors, ifaces: length(errors) ? null : ifaces } };
}

export const cases = [
	token_case('br-lan', 'br-lan', '"br-lan"'),
	token_case('eth0.2', 'eth0.2', '"eth0.2"'),
	token_case('quote', 'br-"lan', '"br-\\"lan"'),
	token_case('backslash', 'br-\\lan', '"br-\\\\lan"'),
	token_case('quote and backslash', 'br-\\"lan', '"br-\\\\\\"lan"'),
	token_case('trailing backslash', 'lan\\', '"lan\\\\"'),
	config_case('length 1', { lan_ifaces: [ 'a' ] }, [], [ 'a' ]),
	config_case('length 15', { lan_ifaces: [ 'abcdefghijklmno' ] }, [], [ 'abcdefghijklmno' ]),
	config_case('length 0 list item', { lan_ifaces: [ '' ] }, [ 'main.lan_ifaces:invalid_value' ]),
	config_case('length 0 scalar', { lan_ifaces: '' }, [ 'main.lan_ifaces:invalid_value' ]),
	config_case('length 16', { lan_ifaces: [ 'abcdefghijklmnop' ] }, [ 'main.lan_ifaces:invalid_value' ]),
	config_case('UTF-8 15 bytes', { lan_ifaces: [ '界界界界界' ] }, [], [ '界界界界界' ]),
	config_case('UTF-8 16 bytes', { lan_ifaces: [ '界界界界界a' ] }, [ 'main.lan_ifaces:invalid_value' ]),
	config_case('missing defaults', {}, [], [ 'br-lan' ]),
	config_case('null defaults', { lan_ifaces: null }, [], [ 'br-lan' ]),
	config_case('empty array min_items', { lan_ifaces: [] }, [ 'main.lan_ifaces:too_few' ]),
	{ name: 'T9.45 sorted deduplicated complete guard tokens', kind: 'sorted', expect: [
		'\t\tiifname != { "br-lan", "eth0.2" } return',
		'\t\tiifname != { "br-lan", "eth0.2" } return'
	] },
	{ name: 'T9.45 B-question2 traffic chains remain byte-identical', kind: 'counters', expect:
		'\tcounter proxy_tx {}\n\tcounter proxy_rx {}\n' +
		'\tchain traffic_out {\n\t\ttype filter hook output priority filter; policy accept;\n' +
		'\t\tip daddr @node_ip4 counter name proxy_tx\n\t}\n' +
		'\tchain traffic_in {\n\t\ttype filter hook input priority filter - 2; policy accept;\n' +
		'\t\tip saddr @node_ip4 counter name proxy_rx\n\t}\n' }
];

// Without a verified nft hex-escape contract, no control byte may reach nft syntax.
for (let byte = 0; byte <= 127; byte++) {
	if (byte > 31 && byte != 127)
		continue;
	push(cases, config_case(sprintf('control 0x%02x rejected', byte),
		{ lan_ifaces: [ 'br-' + chr(byte) + 'lan' ] }, [ 'main.lan_ifaces:invalid_value' ]));
}

export function run(c) {
	if (c.kind == 'config') {
		let r = config.normalize({ main: c.main });
		return { errors: map(r.errors ?? [], e => e.field + ':' + e.code),
			ifaces: r.ok ? r.snapshot.main.lan_ifaces : null };
	}
	let ifaces = c.kind == 'sorted' ? [ 'eth0.2', 'br-lan', 'eth0.2' ] : [ c.iface ?? 'br-lan' ];
	let r = config.normalize({ main: { lan_ifaces: ifaces, dns_hijack: '1' } });
	if (!r.ok)
		return r.errors;
	let text = nft.render(r.snapshot, {});
	if (c.kind == 'counters') {
		let start = index(text, '\tcounter proxy_tx');
		let end = index(text, '\tchain prerouting');
		return start >= 0 && end > start ? substr(text, start, end - start) : null;
	}
	return guards(text);
};
