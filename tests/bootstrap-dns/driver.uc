'use strict';
// Real module driver: the Python authority only produces wire data, never resolves it.
import * as dns from 'aetherproxy.bootstrap_dns';
import * as apply from 'aetherproxy.apply';
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as log from 'aetherproxy.log';

let opts = json(ARGV[0]);
if (!uloop.init())
	die('uloop.init failed');
let stopped = false;
let signal = uloop.signal('SIGTERM', () => { stopped = true; });
if (signal == null)
	die('signal registration failed');
let callback = () => stopped;
let ctx = { state_dir: opts.dir + '/state', run_dir: opts.dir + '/run' };
// Warm caller-owned event-loop/syslog resources before measuring query socket lifetimes.
// Debug events go only to syslog, not to the tested persistent event history.
uloop.run(1);
log.set_level('debug');
log.event('debug', 'CMD_RUN', { test: 'T15.4 FD baseline' });
log.set_level('notice');
let before_fds = map(fs.lsdir('/proc/self/fd'), n => fs.readlink('/proc/self/fd/' + n));
let before = length(before_fds);
let results = [];
// The parent waits for this line before delivering a real signal.
warn('READY\n');
fs.stderr.flush();
for (let i = 0; i < (opts.repeat ?? 1); i++) {
	stopped = false;
	let r = opts.apply
		? apply.resolve_node_explicit(ctx, opts.domain ?? 'node.test', opts.endpoint, callback)
		: dns.lookup(opts.domain ?? 'node.test', opts.endpoint, callback, opts.timeout);
	push(results, r);
}
let after = length(fs.lsdir('/proc/self/fd'));
let after_fds = map(fs.lsdir('/proc/self/fd'), n => fs.readlink('/proc/self/fd/' + n));
print(sprintf('%.J\n', { results, before, after, stopped, before_fds, after_fds }));
signal.delete();
uloop.done();
