'use strict';
// T9.7: drive the real supervisor while the Python harness observes pids/FIFOs (docs/04,09).
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as supervise from 'aetherproxy.supervise';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';

let root = ARGV[0], mode = ARGV[1], python = ARGV[2], child_script = ARGV[3];
let name = 'fixture $(echo INJECTED)';
let dir = `${root}/run ' directory`;
if (!sys.mkdir_p(dir) || !uloop.init())
	die('cannot set up supervisor test');
log.set_run_dir(dir);
let observed = [], child, stopped = false;
let watchdog = uloop.timer(12000, () => die('supervisor watchdog expired'));
child = supervise.create({
	name, run_dir: dir, argv: [ python, child_script, root, mode, 'arg \' " ; $(touch SENTINEL)' ],
	backoff: [ 0.15, 0.3 ], stable_secs: 300,
	on_event: (kind, info) => {
		push(observed, { kind, ...info });
		if (kind == 'started' && (mode != 'crash' || length(filter(observed, e => e.kind == 'started')) == 2)) {
			uloop.timer(1600, () => child.stop(() => {
				stopped = true;
				uloop.end();
			}));
		}
	}
});
child.start();
uloop.run();
watchdog.cancel();
uloop.done();
if (!stopped || !sys.write_atomic(`${root}/observed.json`, sprintf('%.J', observed)))
	die('supervisor did not stop or could not save observations');
// No pid file: cleanup must still remove a FIFO left by an interrupted launch.
let stale = `${dir}/${name}.log.fifo`;
let made = sys.run([ 'mkfifo', stale ], { quiet: true });
if (made.code == 0) {
	let clean = supervise.kill_stale(dir, name, root);
	if (!clean.ok || fs.lstat(stale) != null)
		die('cleanup left an orphan FIFO');
}
exit(0);
