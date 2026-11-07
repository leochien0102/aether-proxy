'use strict';
// Real module driver: Python owns listeners, never the readiness decision.
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as ready from 'aetherproxy.xray_ready';
let spec = json(fs.readfile(ARGV[0]));
uloop.init();
let stopped = false, checks = 0, pid = spec.pid;
let signal = uloop.signal('SIGTERM', () => { stopped = true; uloop.end(); });
let timer = spec.cancel_ms ? uloop.timer(spec.cancel_ms, () => { stopped = true; uloop.end(); }) : null;
let changed = spec.change_ms ? uloop.timer(spec.change_ms, () => { pid = spec.other_pid; }) : null;
let ctx = { root: spec.root ?? '' };
let child = { pid: () => pid };
let t = clock(true);
let before = length(fs.lsdir('/proc/self/fd'));
let result;
for (let i = 0; i < (spec.repeat ?? 1); i++) {
	result = ready.wait(ctx, child, spec.required, () => {
		checks++;
		return stopped || (spec.cancel_at_check != null && checks >= spec.cancel_at_check);
	});
	if (!result.ok)
		break;
}
let after = length(fs.lsdir('/proc/self/fd'));
let end = clock(true);
print(sprintf('%.J', { ...result, elapsed_ms: (end[0] - t[0]) * 1000 + (end[1] - t[1]) / 1000000,
	fd_delta: after - before, checks }), '\n');
if (timer != null) timer.cancel();
if (changed != null) changed.cancel();
signal.delete();
uloop.done();
