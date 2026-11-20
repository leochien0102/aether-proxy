'use strict';
import * as sys from 'aetherproxy.sys';

const UCODE = sourcepath(0, true) + '/../host/ucode';

export const cases = [
	{ name: 'debug level emits debug output', level: 'debug', expect: { accepted: true, emitted: true } },
	{ name: 'unknown level leaves debug enabled', level: 'nonsense', expect: { accepted: false, emitted: true } },
	{ name: 'null level leaves debug enabled', level: null, expect: { accepted: false, emitted: true } }
];

export function run(c) {
	// Use an isolated process so neither the threshold nor libc's syslog state
	// leaks into other unit tests. LOG_PERROR (32) mirrors real syslog to stderr.
	let probe = `
		import * as log from 'aetherproxy.log';
		import * as syslog from 'log';
		log.set_level('debug');
		log.debug('initialize syslog');
		syslog.openlog('log-level-test', 32, 'daemon');
		let accepted = log.set_level(%.J);
		log.debug('log-level marker');
		print(sprintf('%%J', accepted));
	`;
	let result = sys.run([ UCODE, '-e', sprintf(probe, c.level) ], { quiet: true, timeout: 5 });
	if (result.code != 0)
		return result.stderr;
	return { accepted: json(result.stdout), emitted: index(result.stderr, 'log-level-test: log-level marker') >= 0 };
};
