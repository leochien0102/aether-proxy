'use strict';

// Default-mode CLI entry (docs/10 "切换默认模式"). Node and mode selection
// deliberately share parsing context, UCI commit, service detection and reload.
import * as node from 'aetherproxy.cmd.node';

export function run(args) {
	return node.run_mode(args);
};