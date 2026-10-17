'use strict';

// Exercise the degraded renderer without a configured node (docs/10 Dashboard part 1).
import * as nft from 'aetherproxy.render.nft';
print(nft.render({ main: {} }, { runtime: { node_ip: null } }));
