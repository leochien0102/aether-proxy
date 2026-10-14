#!/usr/bin/env ucode
'use strict';

import * as sys from 'aetherproxy.sys';

// Thin layer: no logic here, only forwarding to the aether-proxy command (docs/10).
// quiet: a failure is reported in the reply instead of via syslog, because opening
// the syslog with our tag would change the ident of the rpcd process itself.
function call_cli(argv) {
	let res = sys.run([ '/usr/bin/aether-proxy', ...argv ], { timeout: 10, quiet: true });

	if (res.code != 0)
		return { ok: false, code: 'CMD_FAILED', detail: `exit ${res.code}: ${trim(res.stderr)}` };

	let obj = json(res.stdout);

	if (type(obj) != 'object')
		return { ok: false, code: 'CMD_FAILED', detail: 'invalid JSON from aether-proxy' };

	return obj;
}

const methods = {
	status: {
		call: function() {
			// Placeholder: the real `status` subcommand arrives in a later milestone.
			let r = call_cli([ 'version', '--json' ]);

			return r.ok ? { version: r.version } : r;
		}
	}
};

return { aetherproxy: methods };
