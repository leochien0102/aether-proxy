'use strict';

// T9.28: docs/03 optional direct DNS. Keep opt-in output byte compatible and
// exercise boot WAN expansion without mutating the historical golden inputs.
import * as config from 'aetherproxy.config';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as fs from 'fs';
import * as uci from 'uci';
import * as sys from 'aetherproxy.sys';

export const cases = [
	{ name: 'direct DNS switch defaults false and accepts explicit 0/1', kind: 'schema', expect: true },
	{ name: 'direct DNS switch rejects invalid bool', kind: 'invalid', expect: true },
	{ name: 'disabled boot uses expanded deduplicated china DNS', kind: 'boot', expect: true },
	{ name: 'disabled boot uses WAN fallback without live lookup', kind: 'fallback', expect: true },
	{ name: 'disabled renderer defaults T1 and rejects stale T2 upstreams', kind: 'tier', expect: true },
	{ name: 'enabled renderer starts T2 and boot uses direct DNS unchanged', kind: 'enabled', expect: true },
	/* The historical case compares byte-for-byte with the frozen 7 files under
	   tests/unit/data/direct_dns_enabled/, not just a few strings. */
	{ name: 'enabled historical chinadns configurations remain byte identical', kind: 'historical', expect: true }
];

function group_boot(text) {
	return split(split(text, 'group boot\n')[1], '\n')[0];
}

function render(dns, ctx) {
	let snapshot = config.normalize({ dns }).snapshot;
	return chinadns.render(snapshot, ctx ?? {});
}

export function run(c) {
	if (c.kind == 'schema') {
		for (let value in [ null, '0', '1' ]) {
			let raw = value == null ? {} : { dns: { direct_dns_enabled: value } };
			let cfg = config.normalize(raw);
			if (!cfg.ok || cfg.snapshot.dns.direct_dns_enabled !== (value == '1'))
				return false;
		}
		return true;
	}
	if (c.kind == 'invalid') {
		let cfg = config.normalize({ dns: { direct_dns_enabled: 'yes' } });
		return !cfg.ok && cfg.errors[0].field == 'dns.direct_dns_enabled' && cfg.errors[0].code == 'invalid_bool';
	}
	if (c.kind == 'boot') {
		let text = render({ china_dns: [ 'wan', '114.114.114.114' ] },
			{ wan_dns: [ '192.0.2.53', '114.114.114.114' ] });
		return group_boot(text) == 'group-upstream 192.0.2.53,114.114.114.114';
	}
	if (c.kind == 'fallback')
		return group_boot(render({ china_dns: [ 'wan', '114.114.114.114' ] })) ==
			'group-upstream 223.5.5.5,114.114.114.114';
	if (c.kind == 'tier') {
		let text = render({});
		return index(text, 'trust-dns tcp://127.0.0.1#31082,tcp://127.0.0.1#31083\n') >= 0 &&
			text == render({}, { runtime: { dns_tier: 'T2' } });
	}
	if (c.kind == 'enabled') {
		let text = render({ direct_dns_enabled: '1', direct_dns: [ 'tcp://8.8.8.8', 'tcp://1.1.1.1' ] });
		return index(text, 'trust-dns tcp://8.8.8.8,tcp://1.1.1.1\n') >= 0 &&
			group_boot(text) == 'group-upstream tcp://8.8.8.8,tcp://1.1.1.1';
	}
	// Only a transient in-memory flag is changed: never rewrite fixture inputs/expected.
	let made = sys.run([ 'mktemp', '-d', 'tests/unit/.T9.28.XXXXXX' ]);
	if (made.code != 0)
		return false;
	let tmp = trim(made.stdout);
	let good = true;
	for (let name in [ 't14-gfw-t1', 't14-bypass-cn-t1', 't14-bypass-cn-t2', 't14-bypass-cn-t3',
		't14-global-t1', 't14-no-v6-filter', 't14-single-trust' ]) {
		let dir = `tests/fixtures/${name}`;
		let cfg = config.load(uci.cursor(dir, tmp + '/savedir'));
		if (!cfg.ok) {
			good = false;
			break;
		}
		cfg.snapshot.dns.direct_dns_enabled = true;
		// This fixture omitted direct_dns: compare its pre-T9.28 effective snapshot,
		// since the separately tested new default intentionally has one upstream.
		if (name == 't14-single-trust')
			cfg.snapshot.dns.direct_dns = [ 'tcp://9.9.9.9', 'tcp://8.8.8.8' ];
		let ctx = json(fs.readfile(dir + '/context.json'));
		// Frozen pre-T9.28 outputs: the fixtures' own expected files now show the default (off).
		if (chinadns.render(cfg.snapshot, ctx) != fs.readfile(`tests/unit/data/direct_dns_enabled/${name}.conf`))
			good = false;
	}
	let removed = sys.run([ 'rm', '-rf', tmp ]);
	return good && removed.code == 0;
};
