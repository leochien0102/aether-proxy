'use strict';
// Forward the procd-facing CLI command to the lifecycle owner, keeping startup logic shared.
// Design: docs/04「进程模型（已定）」.

import * as daemon from 'aetherproxy.daemon';

export function run(args) {
	return daemon.run(args);
};
