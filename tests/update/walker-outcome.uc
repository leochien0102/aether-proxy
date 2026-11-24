'use strict';
// T16.76: exercise production package_update() outer return path with a controlled clock.
// Budget gates admission; once a transaction completes, expiry must not rewrite its outcome.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as C from 'aetherproxy.const';

let source = fs.readfile(ARGV[0]);
let directory = ARGV[1];

function helper(start_name, end_name) {
	let start = index(source, `function ${start_name}(`);
	let end = index(source, `\nfunction ${end_name}(`, start);
	if (start < 0 || end < start)
		die(`production helper missing: ${start_name}`);
	return substr(source, start, end - start) + '\n';
}

let selected_start = index(source, 'function package_update_selected(');
let update_start = index(source, 'export function package_update(');
if (selected_start < 0 || update_start < selected_start)
	die('production functions missing: package_update_selected/package_update');
let package_update_selected_src = substr(source, selected_start, update_start - selected_start) + '\n';
let package_update_src = replace(substr(source, update_start), /^export /, '');

let dependencies = [ 'clock', 'getenv', 'C', 'fs', 'log', 'fetch_manifest', 'platform',
	'installed_version', 'service_state', 'download_asset', 'install_package',
	'verify_package', 'verify_installed_version', 'package_asset', 'activate_rollback',
	'write_updates', 'version_newer', 'bridge_plan', 'terminal_companions',
	'install_target', 'update_together', 'continue_chain' ];

let factory = loadstring('(function(' + join(', ', dependencies) + ') { '
	+ 'let chain_deadline = null;\n'
	+ helper('budget_left', 'run')
	+ helper('group_failure', 'fs_error')
	+ helper('fs_error', 'system_path')
	+ helper('system_path', 'read_object')
	+ helper('unlink_file', 'asset_filename')
	+ helper('install_with_rollback', 'companion_candidate')
	+ package_update_selected_src
	+ package_update_src
	+ '\nreturn { package_update, ready: budget_ready, left: budget_left }; })')();

let failures = 0;
function fail(message) {
	failures++;
	print(`FAIL  ${message}\n`);
}

function run_case(pm, scenario) {
	let folder = `${directory}/outcome-${scenario}-${pm}`;
	if (!sys.mkdir_p(folder))
		die(`cannot create test folder: ${folder}`);
	let inventory = `${folder}/inventory`;
	let old_ver = '1.8.0-r1';
	let new_ver = '1.8.1-r1';
	let ext = pm == 'opkg' ? 'ipk' : 'apk';
	let new_asset = { version: new_ver, url: `xray-core_${new_ver}.${ext}`, size: 16, sha256: 'a' };
	let prev_asset = { version: old_ver, url: `xray-core_${old_ver}.${ext}`, size: 16, sha256: 'b' };
	if (!sys.write_atomic(inventory, old_ver + '\n'))
		die('cannot initialize inventory');

	let seconds = scenario == 'expired-entry' ? 401 : 100;
	let deadline_text = '400';
	let fetches = 0, downloads = 0, installs = 0, rollbacks = 0, activates = 0, refreshes = 0;
	let events = [];
	let clock = () => [ seconds, 0 ];
	let env = { AETHER_PROXY_CHAIN_DEADLINE: deadline_text };
	let fake_getenv = key => env[key];
	let observed_log = {
		set_run_dir: () => {},
		event: (level, code, args) => push(events, { level, code, args })
	};
	let fetch_manifest = () => {
		fetches++;
		return { ok: true, ctx: { root: '', run_dir: folder }, manifest: { packages: {} }, base: 'ch1', urls: [ 'ch1' ] };
	};
	let platform = () => ({ ok: true, arch: 'all', pm });
	let installed_version = () => ({ ok: true, version: trim(fs.readfile(inventory)) });
	let download_asset = (opts, urls, asset, name) => {
		downloads++;
		let path = `${folder}/${name}`;
		if (!sys.write_atomic(path, 'verified asset\n'))
			die('cannot materialize asset');
		return { ok: true, path };
	};
	let install_package = (ctx, manager, path, is_previous) => {
		if (is_previous) {
			rollbacks++;
			if (!sys.write_atomic(inventory, old_ver + '\n'))
				die('cannot restore inventory');
			return { ok: true };
		}
		installs++;
		// Cross the scheduling deadline during the admitted install transaction.
		seconds = 401;
		if (!sys.write_atomic(inventory, new_ver + '\n'))
			die('cannot update inventory');
		return { ok: true };
	};
	let verify_package = () => scenario == 'success-after-expiry';
	let verify_installed_version = (ctx, manager, name, version) => trim(fs.readfile(inventory)) == version;
	let package_asset = (manifest, name, arch, manager, previous) => previous ? prev_asset : new_asset;
	let activate_rollback = () => { activates++; };
	let write_updates = () => { refreshes++; return { ok: true, exit: 0 }; };
	let unused = () => die('unexpected call in outcome test');

	let tested = factory(clock, fake_getenv, C, fs, observed_log, fetch_manifest, platform,
		installed_version, () => ({ state: 'stopped' }), download_asset, install_package,
		verify_package, verify_installed_version, package_asset, activate_rollback,
		write_updates, unused, unused, unused, unused, unused, unused);

	let result = tested.package_update({ run_dir: folder }, C.XRAY_CORE_PACKAGE, false);
	let codes = map(events, e => e.code);
	let label = `T16.76 ${pm} ${scenario}`;

	if (scenario == 'success-after-expiry') {
		if (!result.ok || result.exit != 0 || result.code != null)
			return fail(`${label}: expected success, got ok=${result.ok} exit=${result.exit} code=${result.code}`);
		if (!result.value?.ok || result.value.from != old_ver || result.value.to != new_ver || result.value.rolled_back != false || result.value.code != null)
			return fail(`${label}: unexpected result value: ${sprintf('%.J', result.value)}`);
		if (installs != 1 || rollbacks != 0 || refreshes != 1 || trim(fs.readfile(inventory)) != new_ver)
			return fail(`${label}: unexpected side effects installs=${installs} rollbacks=${rollbacks} refreshes=${refreshes}`);
		if (index(codes, 'UPDATE_INSTALLED') < 0 || index(codes, 'BRIDGE_INCOMPLETE') >= 0)
			return fail(`${label}: unexpected events ${join(',', codes)}`);
	}
	else if (scenario == 'failure-after-expiry') {
		let want_detail = `verification failed; rolled back to ${old_ver}`;
		if (result.ok || result.exit != 1 || result.code != 'UPDATE_VERIFY_FAILED' || result.detail != want_detail)
			return fail(`${label}: expected UPDATE_VERIFY_FAILED with rollback detail, got code=${result.code} detail=${result.detail}`);
		if (result.value?.ok != false || result.value.code != 'UPDATE_VERIFY_FAILED' || result.value.rolled_back != true
			|| result.value.from != old_ver || result.value.to != new_ver)
			return fail(`${label}: lost rollback metadata: ${sprintf('%.J', result.value)}`);
		if (installs != 1 || rollbacks != 1 || activates != 1 || refreshes != 1 || trim(fs.readfile(inventory)) != old_ver)
			return fail(`${label}: unexpected rollback side effects installs=${installs} rollbacks=${rollbacks} activates=${activates} refreshes=${refreshes}`);
		if (index(codes, 'UPDATE_VERIFY_FAILED') < 0 || index(codes, 'UPDATE_ROLLED_BACK') < 0 || index(codes, 'BRIDGE_INCOMPLETE') >= 0)
			return fail(`${label}: unexpected events ${join(',', codes)}`);
	}
	else if (scenario == 'expired-entry') {
		if (result.ok || result.exit != 1 || result.code != 'BRIDGE_INCOMPLETE' || result.value?.code != 'BRIDGE_INCOMPLETE')
			return fail(`${label}: expected BRIDGE_INCOMPLETE at entry, got code=${result.code}`);
		if (fetches != 0 || downloads != 0 || installs != 0 || rollbacks != 0 || refreshes != 0 || trim(fs.readfile(inventory)) != old_ver)
			return fail(`${label}: expired entry caused side effects fetches=${fetches} downloads=${downloads} installs=${installs}`);
		if (index(codes, 'BRIDGE_INCOMPLETE') < 0 || index(codes, 'UPDATE_STARTED') >= 0)
			return fail(`${label}: unexpected events ${join(',', codes)}`);
	}
	print(`PASS  ${label}\n`);
}

for (let pm in [ 'opkg', 'apk' ]) {
	run_case(pm, 'success-after-expiry');
	run_case(pm, 'failure-after-expiry');
	run_case(pm, 'expired-entry');
}
if (failures > 0)
	die(`T16.76 outcome regressions failed: ${failures}`);
