'use strict';
// docs/04 reload: reuse a read result, preserve build() output and render only the
// requested artifact. Direct renderer comparisons guard the compatibility wrapper too.
import * as pipeline from 'aetherproxy.pipeline';
import * as nft from 'aetherproxy.render.nft';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as dnsmasq from 'aetherproxy.render.dnsmasq';
import * as xray from 'aetherproxy.render.xray';

const ROOT = sourcepath(0, true) + '/../..';
const OPTS = {
	confdir: ROOT + '/tests/fixtures/sample',
	data_dir: ROOT + '/tests/unit/data/full/data',
	baseline_dir: ROOT + '/aether-proxy/files/data',
	custom_dir: ROOT + '/tests/unit/data/full/custom',
	run_dir: ROOT + '/tests/unit/data/full/run'
};
const RENDERERS = { nft, chinadns, dnsmasq, xray };
const LIVE = {
	node_ip: '198.51.100.7', dns_tier: 'T1',
	restored: { gfw4: [ '203.0.113.9', '198.51.100.1' ], udirect4: [ '192.0.2.1' ], uproxy4: [ '192.0.2.2' ] }
};

export const cases = [
	{ name: 'T9.9 split and build four artifacts match byte for byte with default runtime', expect: 'PASS' },
	{ name: 'T9.9 split and build four artifacts match byte for byte with live sets', runtime: LIVE, expect: 'PASS' },
	{ name: 'T9.9 render only nft preserves build bytes with exported sets', only: 'nft', expect: 'PASS' },
	{ name: 'T9.9 render only chinadns preserves build bytes', only: 'chinadns', expect: 'PASS' },
	{ name: 'T9.9 render only dnsmasq preserves build bytes', only: 'dnsmasq', expect: 'PASS' },
	{ name: 'T9.9 render only xray preserves build bytes', only: 'xray', expect: 'PASS' },
	{ name: 'T9.9 reuse read result retains runtime isolation and all six paths', isolation: true, expect: 'PASS' },
	{ name: 'T9.9 invalid configuration keeps build failure contract', invalid: true, expect: 'PASS' },
	{ name: 'T9.9 unknown renderer fails closed', unknown: true, expect: 'PASS' }
];

function equal(a, b) {
	return sprintf('%.J', a) == sprintf('%.J', b);
}

export function run(c) {
	let opts = c.invalid ? { ...OPTS, confdir: ROOT + '/tests/fixtures/t11-err-bad-enum' } : OPTS;
	let loaded = pipeline.read(opts);
	if (c.invalid) {
		let built = pipeline.build(opts);
		return !loaded.ok && loaded.code == 'CONFIG_INVALID' && loaded.exit == 2 &&
			equal(loaded, built) && equal(pipeline.render(loaded, LIVE), loaded) ? 'PASS' : 'FAIL: failure contract';
	}
	if (!loaded.ok)
		return 'FAIL: ' + pipeline.describe_errors(loaded);
	if (c.unknown) {
		let bad = pipeline.render(loaded, LIVE, 'unknown');
		return !bad.ok && bad.code == 'RENDER_INVALID' && bad.exit == 1 ? 'PASS' : 'FAIL: unknown renderer';
	}
	if (c.isolation) {
		let before = sprintf('%.J', loaded);
		// T9.28: default T1 now equals LIVE's tier; compare T3/T1 to keep testing
		// runtime isolation without re-enabling direct DNS in shared fixtures.
		let initial = pipeline.render(loaded, { dns_tier: 'T3' });
		let live = pipeline.render(loaded, LIVE);
		let again = pipeline.render(loaded, { dns_tier: 'T3' });
		if (!initial.ok || !live.ok || !again.ok)
			return 'FAIL: runtime render';
		let changed = initial.artifacts.nft != live.artifacts.nft &&
			initial.artifacts.xray != live.artifacts.xray && initial.artifacts.chinadns != live.artifacts.chinadns;
		return changed && equal(initial, again) && before == sprintf('%.J', loaded) &&
			length(keys(loaded.paths)) == 6 ? 'PASS' : 'FAIL: read result mutated or runtime ignored';
	}
	let runtime = c.only != null ? LIVE : c.runtime;
	let split = pipeline.render(loaded, runtime, c.only);
	let built = pipeline.build({ ...opts, runtime });
	if (!split.ok || !built.ok)
		return 'FAIL: render failed';
	if (length(keys(split.artifacts)) != (c.only != null ? 1 : 4))
		return 'FAIL: wrong artifact selection';
	for (let name, text in split.artifacts) {
		if (text != built.artifacts[name] || text != RENDERERS[name].render(loaded.snapshot, built.ctx))
			return `FAIL: ${name} bytes differ`;
	}
	if (c.only == 'nft' && index(split.artifacts.nft, '198.51.100.1, 203.0.113.9') < 0)
		return 'FAIL: exported sets missing or unsorted';
	return 'PASS';
};
