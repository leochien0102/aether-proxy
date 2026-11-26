'use strict';

// Exercise the production UCI loader and renderer, never a reconstructed snapshot.
import * as pipeline from 'aetherproxy.pipeline';
import * as xray from 'aetherproxy.render.xray';
import * as sys from 'aetherproxy.sys';

let loaded = pipeline.read({ confdir: ARGV[0], data_dir: ARGV[2] + '/data',
	baseline_dir: ARGV[2] + '/base', custom_dir: ARGV[2] + '/custom',
	run_dir: ARGV[2] + '/cli-run', bin_dir: ARGV[2] + '/bin' });
if (!loaded.ok) {
	// Error details may contain rejected credentials.
	warn('explicit-proxy: pipeline.read rejected the UCI fixture\n');
	exit(1);
}
let artifact = xray.render(loaded.snapshot, { runtime: { node_ip: null } });
// The same atomic writer used for daemon artifacts must protect embedded secrets.
if (!sys.write_atomic(ARGV[1], artifact)) {
	warn('explicit-proxy: could not write rendered artifact\n');
	exit(1);
}
print(sprintf('%.J', { main: loaded.snapshot.main, config: json(artifact) }), '\n');
