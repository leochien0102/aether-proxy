'use strict';
// M4-07: exercise production admission and command helpers with a controlled clock.
// Extract helpers rather than sleeping for 180s or starting real flash writes.
import * as fs from 'fs';
import * as C from 'aetherproxy.const';

let source = fs.readfile(ARGV[0]);
function helper(start_name, end_name) {
	let start = index(source, `function ${start_name}(`);
	let end = index(source, `\nfunction ${end_name}(`, start);
	return substr(source, start, end - start);
}

let factory = loadstring('(function(clock, chain_deadline, C) { '
	+ helper('budget_left', 'run') + ' return { left: budget_left, ready: budget_ready }; })')();
let now = () => [ 10, 500000000 ];
if (factory(now, 10.75, C).left() != 0.25 || factory(now, 10.25, C).left() != -0.25)
	die('fractional budget arithmetic extended the deadline');
print('PASS  M4-07 fractional monotonic budget never replenishes\n');
if (C.UPDATE_CHAIN_MIN_BUDGET_SECS != 180)
	die('unexpected admission threshold');
let below = factory(now, 190.499, C);
let equal = factory(now, 190.5, C);
let above = factory(now, 190.501, C);
if (below.ready() || !equal.ready() || !above.ready())
	die('admission must reject <180 and accept >=180 seconds');
print('PASS  M4-07 budget threshold rejects below 180 and admits exactly 180\n');

let installs = 0;
let gate = loadstring('(function(budget_ready, incomplete, component_version, C, install) { '
	+ helper('install_target', 'continue_chain')
	+ ' return install_target({}, {}, {}, "0.7.0-r1", install); })')();
let incomplete_result = () => ({ ok: false, code: 'BRIDGE_INCOMPLETE' });
let install = () => { installs++; return { ok: true }; };
let version = { version_cmp: () => -1 };
if (gate(below.ready, incomplete_result, version, C, install).code != 'BRIDGE_INCOMPLETE' || installs != 0)
	die('low budget started a target transaction');
if (!gate(equal.ready, incomplete_result, version, C, install).ok || installs != 1)
	die('exact threshold did not admit target transaction');
print('PASS  M4-07 install admission below threshold has no calls; exactly 180 starts once\n');

let handoffs = 0;
let child_run = (argv, opts) => {
	handoffs++;
	if (opts.timeout != null)
		die('ancestor timeout could interrupt an admitted child flash write');
	return { code: 0, stdout: '{"ok":true,"code":"UPDATE_UP_TO_DATE"}', stderr: '' };
};
let handoff = loadstring('(function(budget_ready, incomplete, version_newer, run, budget_left, chain_deadline, C) { '
	+ helper('continue_chain', 'package_update_selected')
	+ ' return continue_chain({}, { bin_dir: "/new" }, "aether-proxy", "0.6.3-r1", "0.7.0-r1", 1); })')();
let newer = () => true;
if (handoff(below.ready, incomplete_result, newer, child_run, below.left, 190.499, C).code != 'BRIDGE_INCOMPLETE'
	|| handoffs != 0)
	die('low budget started a handoff');
if (!handoff(equal.ready, incomplete_result, newer, child_run, equal.left, 190.5, C).ok || handoffs != 1)
	die('exact threshold did not admit handoff');
print('PASS  M4-07 handoff admission below threshold has no calls; exactly 180 starts once\n');

let calls = [];
let observed_sys = { run: (argv, opts) => { push(calls, { argv, opts }); return { code: 0 }; } };
// A deliberately truncating run adapter makes this fail if install_package uses it again.
let clipped_run = (argv, opts) => observed_sys.run(argv, { ...opts, timeout: 1 });
let installer = loadstring('(function(sys, C, run) { ' + helper('install_package', 'xray_binary')
	+ ' return install_package; })')()(observed_sys, C, clipped_run);
for (let pm in [ 'opkg', 'apk' ]) {
	for (let previous in [ false, true ]) {
		if (!installer({ pm_bin: pm }, pm, '/verified-package', previous).ok)
			die('install adapter failed');
		let call = calls[length(calls) - 1];
		if (call.opts.timeout != C.JOB_TIMEOUT_SECS || call.argv[0] != pm)
			die('flash write timeout was clipped to remaining budget');
	}
}
print('PASS  M4-07 opkg/apk forward and rollback installs retain JOB_TIMEOUT_SECS=600\n');
