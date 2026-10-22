'use strict';
// Adapt CLI cleanup options and results to the daemon's idempotent cleanup implementation.
// Design: docs/04「停止（daemon 收到 SIGTERM；`cleanup` 是同样的步骤，只是不依赖 daemon 存活）」
// and docs/04「进程模型（已定）」.

import * as daemon from 'aetherproxy.daemon';

export function run(args) {
	let parsed = daemon.parse_options(args, false, true);
	if (parsed.error) {
		warn(`cleanup: ${parsed.error}\n`
			+ 'Usage: aether-proxy cleanup [--wait <seconds>] [--sys-root <dir>] '
			+ '[--bin-dir <dir>] [--confdir <dir>]\n');
		return 2;
	}
	let result = daemon.cleanup_run(parsed.opts);
	if (!result.ok) {
		warn(`cleanup failed: ${result.detail}\n`);
		return result.code;
	}
	print('cleanup: ok\n');
	return 0;
};
