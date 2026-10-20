'use strict';

// T9.3 host oracle: build the sample using repository data, then render with the exact
// installed paths used by smoke.sh. Only ctx.paths changes: no output bytes are normalized.
// tests/fixtures/sample has no renderer goldens, so CI prepares these with pinned host ucode.
import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';
import * as sys from 'aetherproxy.sys';
import * as nft from 'aetherproxy.render.nft';
import * as chinadns from 'aetherproxy.render.chinadns';
import * as dnsmasq from 'aetherproxy.render.dnsmasq';
import * as xray from 'aetherproxy.render.xray';

if (length(ARGV) != 2) {
	warn('Usage: smoke-golden.uc <repo-dir> <output-dir>\n');
	exit(2);
}
let repo = ARGV[0];
let output = ARGV[1];
let empty = output + '/empty';
if (!sys.mkdir_p(empty)) {
	warn('cannot create golden directory: ' + sys.error() + '\n');
	exit(1);
}
let built = pipeline.build({
	confdir: repo + '/tests/fixtures/sample',
	baseline_dir: repo + '/aether-proxy/files/data',
	data_dir: empty,
	custom_dir: empty,
	run_dir: empty
});
if (!built.ok) {
	warn(pipeline.describe_errors(built) + '\n');
	exit(1);
}
built.ctx.paths = {
	gfwlist: C.BASELINE_DATA_DIR + '/' + C.DATA_DOMAIN_FILES.gfwlist,
	chnlist: C.BASELINE_DATA_DIR + '/' + C.DATA_DOMAIN_FILES.chnlist,
	apple: C.BASELINE_DATA_DIR + '/' + C.DATA_DOMAIN_FILES.apple,
	proxy_domain: C.CUSTOM_DIR + '/' + C.CUSTOM_DOMAIN_FILES.proxy_domain,
	direct_domain: C.CUSTOM_DIR + '/' + C.CUSTOM_DOMAIN_FILES.direct_domain,
	boot_list: C.RUN_DIR + '/' + C.BOOT_LIST_FILE
};
for (let kind, renderer in { nft, chinadns, dnsmasq, xray }) {
	let text = renderer.render(built.snapshot, built.ctx);
	if (!sys.write_atomic(output + '/' + C.ARTIFACT_FILES[kind], text)) {
		warn('cannot write ' + kind + ' golden: ' + sys.error() + '\n');
		exit(1);
	}
	print('PASS  host golden ' + kind + '\n');
}
