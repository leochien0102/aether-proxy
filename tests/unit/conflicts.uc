'use strict';
// T9.34: exact family/name matching, one snapshot per nft query and no event writes.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as conflicts from 'aetherproxy.conflicts';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
let serial = 0;
export const cases = [
	{ name: 'ssr-plus inet ss_spec', tables: 'table inet ss_spec\n', want: [ 'ssr-plus' ] },
	{ name: 'ssr-plus ip ss_spec_mangle', tables: 'table ip ss_spec_mangle\n', want: [ 'ssr-plus' ] },
	{ name: 'ssr-plus two tables deduplicated', tables: 'table inet ss_spec\ntable ip ss_spec_mangle\n', want: [ 'ssr-plus' ] },
	{ name: 'passwall exact table', tables: 'table inet passwall\n', want: [ 'passwall' ] },
	{ name: 'passwall2 exact table', tables: 'table inet passwall2\n', want: [ 'passwall2' ] },
	{ name: 'homeproxy fw4 chain prefix', chains: 'table inet fw4 {\n chain homeproxy_prerouting {\n }\n}\n', want: [ 'homeproxy' ] },
	{ name: 'openclash fw4 chain prefix', chains: 'table inet fw4 {\n chain openclash_mangle {\n }\n}\n', want: [ 'openclash' ] },
	{ name: 'openclash installed process', process: 'clash\n', init: 'openclash', want: [ 'openclash' ] },
	{ name: 'nikki nft table', tables: 'table inet nikki\n', want: [ 'nikki' ] },
	{ name: 'nikki installed process', process: 'mihomo\n', init: 'nikki', want: [ 'nikki' ] },
	{ name: 'independent clash', process: 'clash\n', want: [ 'clash' ] },
	{ name: 'independent mihomo', process: 'mihomo\n', want: [ 'mihomo' ] },
	{ name: 'openclash chain plus core deduplicated', chains: 'chain openclash {\n', process: 'clash\n', want: [ 'openclash' ] },
	{ name: 'nikki table plus core deduplicated', tables: 'table inet nikki\n', process: 'mihomo\n', want: [ 'nikki' ] },
	{ name: 'unverified names wrong families and non-prefix chains ignored',
	  tables: 'table ip ss_spec\ntable inet ss_spec_mangle\ntable ip passwall\ntable inet passwall_extra\ntable inet homeproxy\ntable inet dae\n',
	  chains: 'chain xhomeproxy_test {\nchain homeproxy {\nchain xopenclash {\n', want: [] },
	{ name: 'missing fw4 table is harmless', chains_rc: 1, want: [] },
	{ name: 'chain failure ignores even partial output', chains_rc: 2, chains: 'chain homeproxy_test {\n', want: [] },
	{ name: 'table query failure remains fatal', tables_rc: 2, want: [], error: true }
];
for (let c in cases) c.expect = 'PASS';

export function run(c) {
	let base = `/tmp/aether-conflicts-${fs.readlink('/proc/self')}-${++serial}`;
	let bin = `${base}/bin`, log = `${base}/calls`;
	if (!sys.mkdir_p(bin) || !sys.mkdir_p(`${base}/etc/init.d`))
		return 'FAIL: cannot prepare private directory';
	let outcome = 'PASS';
	try {
		for (let name in [ 'common.sh', 'nft', 'killall' ]) {
			fs.writefile(`${bin}/${name}`, fs.readfile(`${ROOT}/tests/stubs/bin/${name}`));
			fs.chmod(`${bin}/${name}`, 493);
		}
		if (c.init != null)
			fs.writefile(`${base}/etc/init.d/${c.init}`, 'installed');
		for (let name in [ 'tables', 'chains', 'process' ])
			fs.writefile(`${base}/${name}`, c[name] ?? '');
		fs.writefile(`${base}/stub.env`, `STUB_LOG='${log}'\nSTUB_NFT_TABLES_FILE='${base}/tables'\nSTUB_NFT_CHAINS_FILE='${base}/chains'\nSTUB_PROCESSES_FILE='${base}/process'\nSTUB_NFT_TABLES_RC=${c.tables_rc ?? 0}\nSTUB_NFT_CHAINS_RC=${c.chains_rc ?? 0}\n`);
		let r = conflicts.inspect({ root: base, bin_dir: bin });
		if (r.ok == !!c.error || sprintf('%J', r.conflicts) != sprintf('%J', c.want))
			outcome = `FAIL: ${sprintf('%J', r)}`;
		let calls = filter(split(fs.readfile(log) ?? '', '\n'), line => line != '');
		let expected = c.error ? [ 'nft list tables' ] : [ 'nft list tables', 'nft list chains inet fw4', 'killall -0 clash', 'killall -0 mihomo' ];
		if (sprintf('%J', calls) != sprintf('%J', expected))
			outcome = `FAIL: command counts/order ${sprintf('%J', calls)}`;
		if (length(fs.glob(`${base}/**/events.jsonl`)))
			outcome = 'FAIL: readonly scan wrote events';
	}
	catch (e) {
		outcome = `FAIL: ${e}`;
	}
	sys.run([ 'rm', '-rf', base ]);
	return outcome;
};
