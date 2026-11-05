'use strict';
import * as uloop from 'uloop';
import * as supervise from 'aetherproxy.supervise';
import * as log from 'aetherproxy.log';
import * as fs from 'fs';
let dir = ARGV[0];
uloop.init();
log.set_run_dir(dir);
let events = [];
let child = supervise.create({ name: 'raw-log', raw_log: true, run_dir: dir,
	argv: [ '/bin/sh', ARGV[1], dir, ARGV[2] ], backoff: [ 0.01 ],
	on_event: (kind, info) => push(events, { kind, ...info }) });
child.start();
let stop = uloop.timer(1000, () => child.stop(() => uloop.end()));
uloop.run();
stop.cancel();
uloop.done();
fs.writefile(`${dir}/observed.json`, sprintf('%J', events));
