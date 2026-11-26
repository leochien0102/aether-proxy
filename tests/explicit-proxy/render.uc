'use strict';

// Exercise the production UCI loader and renderer, never a reconstructed snapshot.
import * as uci from 'uci';
import * as config from 'aetherproxy.config';
import * as xray from 'aetherproxy.render.xray';
import * as sys from 'aetherproxy.sys';

let loaded = config.load(uci.cursor(ARGV[0]));
if (!loaded.ok) {
	// Error details may contain rejected credentials.
	warn('explicit-proxy: config.load rejected the UCI fixture\n');
	exit(1);
}
let artifact = xray.render(loaded.snapshot, { runtime: { node_ip: null } });
// The same atomic writer used for daemon artifacts must protect embedded secrets.
if (!sys.write_atomic(ARGV[1], artifact)) {
	warn('explicit-proxy: could not write rendered artifact\n');
	exit(1);
}
print(sprintf('%.J', { main: loaded.snapshot.main, config: json(artifact) }), '\n');
