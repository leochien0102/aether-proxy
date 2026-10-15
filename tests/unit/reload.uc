'use strict';

import * as reload from 'aetherproxy.reload';

const SAME = { nft: 'n1', xray: 'x1', chinadns: 'c1', dnsmasq: 'd1' };

export const cases = [
	{ name: 'unchanged outputs produce no actions', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { ...SAME }, enabled: true }, actions: [] },
	{ name: 'mode-like changes reload nft and chinadns only', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { ...SAME, nft: 'n2', chinadns: 'c2' }, enabled: true }, actions: [ 'nft_replace', 'restart_chinadns' ] },
	{ name: 'node-like change restarts Xray only', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { ...SAME, xray: 'x2' }, enabled: true }, actions: [ 'restart_xray' ] },
	{ name: 'dnsmasq-only change restarts dnsmasq', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { ...SAME, dnsmasq: 'd2' }, enabled: true }, actions: [ 'dnsmasq_restart' ] },
	{ name: 'chinadns-only change restarts chinadns', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { ...SAME, chinadns: 'c2' }, enabled: true }, actions: [ 'restart_chinadns' ] },
	{ name: 'multiple changes keep action order', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { nft: 'n2', xray: 'x2', chinadns: 'c2', dnsmasq: 'd2' }, enabled: true }, actions: [ 'nft_replace', 'restart_xray', 'restart_chinadns', 'dnsmasq_restart' ] },
	{ name: 'disable stops without follow-up actions', expect: 'PASS', old: { hashes: SAME, enabled: true }, fresh: { hashes: { nft: 'n2', xray: 'x2', chinadns: 'c2', dnsmasq: 'd2' }, enabled: false }, actions: [ 'stop' ] },
	{ name: 'missing old hashes schedule changed artifacts', expect: 'PASS', old: { hashes: {}, enabled: true }, fresh: { hashes: SAME, enabled: true }, actions: [ 'nft_replace', 'restart_xray', 'restart_chinadns', 'dnsmasq_restart' ] }
];

export function run(c) {
	let actual = reload.plan(c.old, c.fresh);
	return sprintf('%.J', actual) == sprintf('%.J', c.actions)
		? 'PASS'
		: `FAIL: actions ${sprintf('%.J', actual)}`;
};
