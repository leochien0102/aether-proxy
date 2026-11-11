'use strict';
// M4-07 review: cross the deadline inside a successful download, not before the hop.
// Execute the actual A2/A5 helpers with a controlled clock and real temporary files.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as C from 'aetherproxy.const';

let source = fs.readfile(ARGV[0]);
let directory = ARGV[1];
let mode = ARGV[2];
if (index([ 'proxy', 'companion' ], mode) < 0)
	die('expected proxy or companion test path');

function helper(start_name, end_name) {
	let start = index(source, `function ${start_name}(`);
	let end = index(source, `\nfunction ${end_name}(`, start);
	if (start < 0 || end < start)
		die(`production helper missing: ${start_name}`);
	return substr(source, start, end - start) + '\n';
}

let dependencies = [ 'clock', 'chain_deadline', 'C', 'fs', 'log', 'installed_version',
	'service_state', 'download_asset', 'install_package', 'verify_package',
	'verify_installed_version', 'package_asset', 'version_newer' ];
let function_name = mode == 'proxy' ? 'install_with_rollback' : 'update_companion';
let function_end = mode == 'proxy' ? 'update_companion' : 'update_together';
let factory = loadstring('(function(' + join(', ', dependencies) + ') { '
	+ helper('budget_left', 'run') + helper('group_failure', 'fs_error')
	+ helper('fs_error', 'system_path') + helper('unlink_file', 'asset_filename')
	+ helper(function_name, function_end)
	+ ` return { call: ${function_name}, ready: budget_ready, left: budget_left }; })`)();

for (let pm in [ 'opkg', 'apk' ]) {
	let folder = `${directory}/post-download-${mode}-${pm}`;
	if (!sys.mkdir_p(folder))
		die(`cannot create test folder: ${folder}`);
	let inventory = `${folder}/inventory`;
	let asset_path = `${folder}/candidate.${pm == 'opkg' ? 'ipk' : 'apk'}`;
	let old = '0.7.0-r1\n';
	let asset = { version: '0.7.1-r1', url: 'candidate' };
	if (!sys.write_atomic(inventory, old))
		die('cannot initialize inventory');
	let seconds = 10, downloads = 0, installs = [], verifies = [], events = [];
	let clock = () => [ seconds, 0 ];
	let observed_log = { event: (level, code, args) => push(events, { level, code, args }) };
	let installed_version = () => ({ ok: true, version: trim(fs.readfile(inventory)) });
	let download_asset = () => {
		downloads++;
		if (!sys.write_atomic(asset_path, 'verified asset\n') || fs.stat(asset_path) == null)
			die('download did not materialize its temporary asset');
		// Simulate a successful but slow download: start with 390s, finish 1s overdue.
		seconds = 401;
		return { ok: true, path: asset_path };
	};
	let install_package = (ctx, manager, path, previous) => {
		push(installs, { manager, path, previous });
		if (!sys.write_atomic(inventory, asset.version + '\n'))
			die('cannot record simulated installation');
		return { ok: true };
	};
	let verify_package = () => { push(verifies, 'restart/check'); return true; };
	let tested = factory(clock, 400, C, fs, observed_log, installed_version,
		() => ({ state: 'stopped' }), download_asset, install_package, verify_package,
		() => trim(fs.readfile(inventory)) == asset.version, () => asset, () => true);
	if (!tested.ready() || tested.left() != 390)
		die('test must enter with enough budget to start, not fail the first admission');
	let selected = { urls: [ 'signed-channel' ], manifest: {} };
	let name = mode == 'proxy' ? C.PROG : C.UPDATE_COMPANIONS[0];
	let result = mode == 'proxy'
		? tested.call({}, {}, selected, name, 'all', pm, asset, false)
		: tested.call({}, {}, selected, { arch: 'all', pm }, name);
	let label = `M4-07 ${pm} ${mode} post-download`;
	if (downloads != 1 || tested.left() != -1)
		die(`${label}: download must cross the actual scheduling deadline`);
	if (result.code != 'BRIDGE_INCOMPLETE')
		die(`${label}: expected BRIDGE_INCOMPLETE after download`);
	if (length(installs) != 0 || length(verifies) != 0)
		die(`${label}: download expiry started install/restart`);
	if (fs.stat(asset_path) != null)
		die(`${label}: temporary asset was not cleaned`);
	if (fs.readfile(inventory) != old)
		die(`${label}: installed inventory changed`);
	if (index(map(events, event => event.code), 'UPDATE_STARTED') >= 0)
		die(`${label}: rejected installation emitted UPDATE_STARTED`);
	if (index(map(events, event => event.code), 'BRIDGE_INCOMPLETE') < 0)
		die(`${label}: missing budget event`);
	print(`PASS  ${label}: incomplete, no install/restart, asset cleaned, inventory unchanged\n`);
}
