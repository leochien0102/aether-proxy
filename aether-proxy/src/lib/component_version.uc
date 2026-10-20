'use strict';

// Component version discovery shared by daemon and CLI (docs/04 "components" versions,
// docs/10 "概览页真机修正"). Parsing stays pure; discovery is quiet and bounded.
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
export function parse_version(text) {
	let first = trim(split(text ?? '', '\n')[0]);
	if (first == '')
		return null;
	let fields = split(first, /\s+/);
	return length(fields) >= 2 ? fields[1] : null;
};

// Informational failures must not emit CMD_FAILED or block startup. Keep the daemon's
// original timeout by default; the live inventory uses its own shorter budget.
export function read_component_version(binary, arg, timeout) {
	let result = sys.run([ binary, arg ], { timeout: timeout ?? C.COMPONENT_VERSION_TIMEOUT_SECS, quiet: true });
	return result.code == 0 ? parse_version(result.stdout) : null;
};
