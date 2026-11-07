'use strict';
// Real resource/B1 driver. Python supplies authority packets and sends real signals;
// production bootstrap/supervise own the child, readiness, resolver and cleanup.
import * as fs from 'fs';
import * as uloop from 'uloop';
import * as bootstrap from 'aetherproxy.bootstrap';
import * as apply from 'aetherproxy.apply';
uloop.init();
let p = json(ARGV[0]);
let ctx = { root: '', run_dir: p.dir, state_dir: p.state_dir ?? p.dir + '/state' };
let stopped = false;
let term = uloop.signal('SIGTERM', () => { stopped = true; ctx.stopping_requested = true; uloop.end(); });
let on_signal = () => stopped;
let snapshot = { main: { node: 'current' }, nodes: { current: { address: p.address ?? 'node.startup.test' } },
	dns: { direct_dns_enabled: p.direct ?? false, china_dns: p.china ?? [ p.upstream ], direct_dns: p.direct_dns ?? [ p.upstream ] } };
function emit(value) {
	print('RESULT ', sprintf('%.J', value), '\n');
	fs.stdout.flush();
};
if (p.action == 'recover') {
	emit(bootstrap.recover(ctx));
}
else if (p.action == 'resolve') {
	let before = length(fs.lsdir('/proc/self/fd'));
	let value = bootstrap.resolve(ctx, snapshot, p.engine, on_signal);
	emit({ ...value, before, after: length(fs.lsdir('/proc/self/fd')) });
}
else {
	let before = length(fs.lsdir('/proc/self/fd'));
	let results = [];
	for (let i = 0; i < (p.repeat ?? 1); i++) {
		let begun = bootstrap.start(ctx, snapshot, p.engine, on_signal);
		if (!begun.ok) {
			emit(begun);
			break;
		}
		let h = begun.handle;
		emit({ started: true, path: h.path, endpoint: h.endpoint, pid: h.child.pid(), record: h.record });
		if (p.action == 'hold') {
			while (!stopped)
				uloop.run(100);
		}
		let value = apply.resolve_node_explicit(ctx, snapshot.nodes.current.address, h.endpoint, on_signal);
		if (p.action == 'unconfirmed') {
			// Fixture: the real child exits/reaps, but completion delivery to the
			// resource handle is withheld. This is not a real D-state experiment.
			let real = h.child, callback = false;
			h.child = { stop: done => real.stop(() => { callback = true; }), pid: real.pid };
			let start = clock(true);
			let end = bootstrap.stop(h);
			let finish = clock(true);
			emit({ ...end, callback, record_retained: fs.stat(h.path + '/owner.json') != null,
				elapsed_ms: (finish[0] - start[0]) * 1000 + (finish[1] - start[1]) / 1000000 });
			break;
		}
		let end = bootstrap.stop(h);
		let again = bootstrap.stop(h);
		push(results, { value, end, again, gone: fs.stat(h.path) == null });
	}
	if (length(results))
		emit({ results, before, after: length(fs.lsdir('/proc/self/fd')) });
}
term.delete();
uloop.done();
