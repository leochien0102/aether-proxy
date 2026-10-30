'use strict';

// T9.45 revision / docs/02: nft quoted strings have no C-style escape processing.
// Compare complete guard tokens; test config errors separately from render defenses.
import * as config from 'aetherproxy.config';
import * as nft from 'aetherproxy.render.nft';
import * as pipeline from 'aetherproxy.pipeline';

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
	config_case('quote rejected', { lan_ifaces: [ 'br-"lan' ] }, [ 'main.lan_ifaces:invalid_value' ]),
	token_case('literal backslash', 'br-\\lan', '"br-\\lan"'),
	config_case('quote and backslash rejected', { lan_ifaces: [ 'br-\\"lan' ] },
		[ 'main.lan_ifaces:invalid_value' ]),
	token_case('literal trailing backslash', 'lan\\', '"lan\\"'),
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

// Hex spellings are literal text in nft, not an encoding for control bytes.
for (let byte = 0; byte <= 127; byte++) {
	if (byte > 31 && byte != 127)
		continue;
	push(cases, config_case(sprintf('control 0x%02x rejected', byte),
		{ lan_ifaces: [ 'br-' + chr(byte) + 'lan' ] }, [ 'main.lan_ifaces:invalid_value' ]));
}

push(cases, token_case('two literal backslashes', 'br-\\\\lan', '"br-\\\\lan"'));
for (let iface in [ 'br-"lan', 'br-\\"lan' ])
	push(cases, { name: 'T9.45 quote error explains nft limitation ' + sprintf('%.J', iface),
		kind: 'detail', iface, expect: [ { field: 'main.lan_ifaces', code: 'invalid_value',
			detail: 'item 0: nft quoted strings cannot represent double quotes' } ] });

function defensive_case(name, iface) {
	return { name: 'T9.45 render rejects ' + name, kind: 'defensive', iface,
		expect: { rejected: true, ok: false, code: 'RENDER_INVALID', exit: 1, no_artifacts: true } };
}

push(cases, defensive_case('quote', 'br-"lan'));
push(cases, defensive_case('quote and backslash', 'br-\\"lan'));
for (let byte = 0; byte <= 127; byte++) {
	if (byte > 31 && byte != 127)
		continue;
	push(cases, defensive_case(sprintf('control 0x%02x', byte), 'br-' + chr(byte) + 'lan'));
}

function defensive(iface) {
	let snapshot = { main: { lan_ifaces: [ iface ] } };
	let rejected = false;
	try {
		nft.render(snapshot, {});
	}
	catch (e) {
		rejected = index(e.message ?? '', 'invalid nft interface string:') >= 0;
	}
	let r = pipeline.render({ ok: true, snapshot }, {}, 'nft');
	return { rejected, ok: r.ok, code: r.code, exit: r.exit, no_artifacts: r.artifacts == null };
}

export function run(c) {
	if (c.kind == 'defensive')
		return defensive(c.iface);
	if (c.kind == 'detail')
		return config.normalize({ main: { lan_ifaces: [ c.iface ] } }).errors ?? [];
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
