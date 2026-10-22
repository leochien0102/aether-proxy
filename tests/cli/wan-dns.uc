'use strict';

// T9.23: inspect the real pipeline without replacing I/O or renderer implementations.
import * as pipeline from 'aetherproxy.pipeline';
let parsed = pipeline.parse_args(ARGV);
if (parsed.error)
	die(parsed.error);
let loaded = pipeline.read(parsed.opts);
let built = loaded.ok ? pipeline.render(loaded, { dns_tier: 'T3' }) : loaded;
print(sprintf('%.J', built), '\n');
exit(built.ok ? 0 : 1);
