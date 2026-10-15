'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as state_file from 'aetherproxy.state';
import * as pipeline from 'aetherproxy.pipeline';
import * as check from 'aetherproxy.cmd.check';
import * as apply from 'aetherproxy.apply';
import * as supervise from 'aetherproxy.supervise';

// Pure plan over renderer hashes, never over UCI input values.
function plan(old, fresh) {
	if (old.enabled == true && fresh.enabled == false)
		return [ 'stop' ];

	let actions = [];
	if (old.hashes?.nft != fresh.hashes?.nft)
		push(actions, 'nft_replace');
	if (old.hashes?.xray != fresh.hashes?.xray)
		push(actions, 'restart_xray');
	if (old.hashes?.chinadns != fresh.hashes?.chinadns)
		push(actions, 'restart_chinadns');
	if (old.hashes?.dnsmasq != fresh.hashes?.dnsmasq)
		push(actions, 'dnsmasq_restart');
	return actions;
};

function run_dir(daemon) {
	let root = daemon.ctx.root ?? '';
	let dir = daemon.ctx.run_dir ?? C.RUN_DIR;
	return root == '' ? dir : replace(root, /\/$/, '') + dir;
};

function setup_log(daemon) {
	log.set_run_dir(run_dir(daemon));
};

function log_failure(daemon, step, detail) {
	setup_log(daemon);
	log.event('error', 'START_FAILED', { step: `reload:${step}`, detail });
};

function failure(daemon, step, detail, code) {
	setup_log(daemon);
	if (code == 'CONFIG_INVALID') {
		log.event('error', code, { field: detail.field ?? '-', reason: detail.reason ?? detail.message ?? 'invalid configuration' });
		return { ok: false, code, detail: detail.message ?? detail.reason ?? 'configuration invalid', errors: detail.errors };
	}
	if (code == 'PRECHECK_FAILED')
		log.event('error', code, { missing: detail.missing ?? [] });
	else if (code == 'RENDER_INVALID')
		log.event('error', code, { artifact: detail.artifact ?? 'reload', detail: detail.detail ?? detail.message ?? `${detail}` });
	else
		log.event('error', 'START_FAILED', { step: `reload:${step}`, detail: detail.message ?? detail });
	return { ok: false, code: code ?? 'START_FAILED', detail: detail.message ?? detail };
};

function write_artifacts(dir, artifacts) {
	for (let name, file in C.ARTIFACT_FILES)
		if (!sys.write_atomic(`${dir}/${file}`, artifacts[name]))
			return { ok: false, detail: `cannot write ${dir}/${file}: ${sys.error()}`, artifact: name };
	return { ok: true };
};

function hash_artifacts(dir) {
	let hashes = {};
	for (let name, file in C.ARTIFACT_FILES) {
		let result = sys.run([ 'sha256sum', `${dir}/${file}` ], { timeout: 10 });
		if (result.code != 0)
			return { ok: false, detail: `sha256sum ${file} failed (${result.code}): ${result.stderr}` };
		let m = match(trim(result.stdout), /^([0-9a-fA-F]{64})\s/);
		if (m == null)
			return { ok: false, detail: `cannot parse sha256sum output for ${file}` };
		hashes[name] = lc(m[1]);
	}
	return { ok: true, hashes };
};

function write_stage(dir, artifacts) {
	let rm = sys.run([ 'rm', '-rf', dir ], { timeout: 10 });
	if (rm.code != 0)
		return { ok: false, detail: `rm -rf ${dir} failed (${rm.code}): ${rm.stderr}` };
	if (!sys.mkdir_p(dir))
		return { ok: false, detail: `cannot create ${dir}: ${sys.error()}` };
	return write_artifacts(dir, artifacts);
};

function discard_stage(daemon, stage) {
	let removed = sys.run([ 'rm', '-rf', stage ], { timeout: 10 });
	if (removed.code != 0) {
		log_failure(daemon, 'discard_staging', `rm -rf ${stage} failed (${removed.code}): ${removed.stderr}`);
		return false;
	}
	return true;
};

function validate(daemon, snapshot, stage, components, validate_xray) {
	let pre = check.precheck(snapshot, stage, { sys_root: daemon.ctx.root, bin_dir: daemon.ctx.bin_dir });
	let missing = map(filter(pre.items, item => !item.ok), item => item.item);
	for (let name in [ C.XRAY_COMPONENT, C.CHINADNS_COMPONENT ])
		if (!pre.components[name]?.found)
			push(missing, `component:${name}`);
	if (length(missing))
		return { ok: false, code: 'PRECHECK_FAILED', missing };
	components ??= pre.components;

	let nft = sys.run([ daemon.ctx.bin_dir ? `${daemon.ctx.bin_dir}/nft` : 'nft', '-c', '-f', `${stage}/${C.ARTIFACT_FILES.nft}` ], { timeout: 10, quiet: true });
	if (nft.code != 0)
		return { ok: false, code: 'RENDER_INVALID', detail: `nft -c -f failed (${nft.code}): ${nft.stderr}`, artifact: 'nft' };
	if (validate_xray) {
		let xray = sys.run([ components[C.XRAY_COMPONENT].path, 'run', '-test', '-c', `${stage}/${C.ARTIFACT_FILES.xray}` ], { timeout: 10, quiet: true });
		if (xray.code != 0)
			return { ok: false, code: 'RENDER_INVALID', detail: `xray run -test failed (${xray.code}): ${xray.stderr}`, artifact: 'xray' };
	}
	return { ok: true, components: pre.components };
};

function wait_stopped(child) {
	let stopped = false;
	child.stop(() => { stopped = true; uloop.end(); });
	while (!stopped)
		uloop.run();
};

function start_child(daemon, key, name, argv) {
	let child = supervise.create({ name, argv, run_dir: run_dir(daemon), backoff: [ 5, 10, 30, 60 ], stable_secs: 300 });
	daemon.children[key] = child;
	child.start();
	return child.pid() != null ? null : `cannot start ${name}`;
};

function execute_action(daemon, action, artifacts, components) {
	let current = `${run_dir(daemon)}/${C.DAEMON_CURRENT_DIR}`;
	if (action == 'nft_replace') {
		return apply.nft_load(daemon.ctx, `${current}/${C.ARTIFACT_FILES.nft}`);
	}
	if (action == 'restart_xray') {
		if (daemon.children.xray != null)
			wait_stopped(daemon.children.xray);
		let bin = components[C.XRAY_COMPONENT].path;
		let error = start_child(daemon, 'xray', C.XRAY_COMPONENT,
			[ bin, 'run', '-c', `${current}/${C.ARTIFACT_FILES.xray}` ]);
		return error == null ? { ok: true } : { ok: false, detail: error };
	}
	if (action == 'restart_chinadns') {
		if (daemon.children.dns != null)
			wait_stopped(daemon.children.dns);
		let bin = components[C.CHINADNS_COMPONENT].path;
		let error = start_child(daemon, 'dns', C.CHINADNS_COMPONENT,
			[ bin, '-C', `${current}/${C.ARTIFACT_FILES.chinadns}` ]);
		if (error != null)
			return { ok: false, detail: error };
		return apply.dnsmasq_hup(daemon.ctx);
	}
	if (action == 'dnsmasq_restart')
		return apply.dnsmasq_install(daemon.ctx, artifacts.dnsmasq);
	return { ok: false, detail: `unknown reload action ${action}` };
};

function restore_current(daemon, previous, current, had_current) {
	let remove = sys.run([ 'rm', '-rf', current ], { timeout: 10 });
	if (remove.code != 0)
		return `cannot remove failed current (${remove.code}): ${remove.stderr}`;
	if (had_current && !fs.rename(previous, current))
		return `cannot restore ${previous}: ${fs.error() ?? 'unknown error'}`;
	return null;
};

function publish_stage(daemon, stage, current, previous) {
	let cleared = sys.run([ 'rm', '-rf', previous ], { timeout: 10 });
	if (cleared.code != 0)
		return { ok: false, detail: `rm -rf ${previous} failed (${cleared.code}): ${cleared.stderr}` };
	let had_current = fs.stat(current) != null;
	if (had_current && !fs.rename(current, previous))
		return { ok: false, detail: `cannot move current to previous: ${fs.error() ?? 'unknown error'}` };
	if (!fs.rename(stage, current)) {
		let detail = `cannot publish staging: ${fs.error() ?? 'unknown error'}`;
		if (had_current && !fs.rename(previous, current))
			detail += `; restore current failed: ${fs.error() ?? 'unknown error'}`;
		return { ok: false, detail };
	}
	return { ok: true, had_current };
};

function rollback_actions(daemon, done_actions, previous, current, had_current, old_artifacts, old_components) {
	let restore_error = restore_current(daemon, previous, current, had_current);
	if (restore_error != null)
		log_failure(daemon, 'rollback_current', restore_error);
	for (let i = length(done_actions) - 1; i >= 0; i--) {
		let action = done_actions[i];
		if (action == 'nft_replace') {
			let r = apply.nft_load(daemon.ctx, `${current}/${C.ARTIFACT_FILES.nft}`);
			if (!r.ok) log_failure(daemon, 'rollback_nft', r.detail);
		}
		else if (action == 'restart_xray') {
			if (daemon.children.xray != null) wait_stopped(daemon.children.xray);
			let err = start_child(daemon, 'xray', C.XRAY_COMPONENT,
				[ old_components[C.XRAY_COMPONENT].path, 'run', '-c', `${current}/${C.ARTIFACT_FILES.xray}` ]);
			if (err != null) log_failure(daemon, 'rollback_xray', err);
		}
		else if (action == 'restart_chinadns') {
			if (daemon.children.dns != null) wait_stopped(daemon.children.dns);
			let err = start_child(daemon, 'dns', C.CHINADNS_COMPONENT,
				[ old_components[C.CHINADNS_COMPONENT].path, '-C', `${current}/${C.ARTIFACT_FILES.chinadns}` ]);
			if (err != null) log_failure(daemon, 'rollback_chinadns', err);
			else {
				let hup = apply.dnsmasq_hup(daemon.ctx);
				if (!hup.ok) log_failure(daemon, 'rollback_dnsmasq_hup', hup.detail);
			}
		}
		else if (action == 'dnsmasq_restart') {
			let r = apply.dnsmasq_install(daemon.ctx, old_artifacts.dnsmasq);
			if (!r.ok) log_failure(daemon, 'rollback_dnsmasq', r.detail);
		}
	}
};

function apply_plan(daemon, actions, artifacts, components, stage_hashes, old_artifacts, old_components, old_lan_ifaces, new_lan_ifaces, new_node_id) {
	let current = `${run_dir(daemon)}/${C.DAEMON_CURRENT_DIR}`;
	let stage = `${run_dir(daemon)}/${C.STAGING_SUBDIR}`;
	let previous = `${run_dir(daemon)}/${C.DAEMON_PREVIOUS_DIR}`;
	// Publish before the actions (04, reload): supervised children keep a stable current/<config>
	// argv. A failed action restores previous/ and reverses the completed actions.
	let publication = publish_stage(daemon, stage, current, previous);
	if (!publication.ok)
		return publication;
	daemon.ctx.lan_ifaces = new_lan_ifaces;
	let done = [];
	for (let action in actions) {
		push(done, action);
		let result = execute_action(daemon, action, artifacts, components);
		if (!result.ok) {
			daemon.ctx.lan_ifaces = old_lan_ifaces;
			rollback_actions(daemon, done, previous, current, publication.had_current, old_artifacts, old_components);
			return { ok: false, detail: `${action}: ${result.detail}` };
		}
	}
	let updated = {
		...daemon.state,
		node_id: new_node_id,
		components: {
			[C.XRAY_COMPONENT]: { path: components[C.XRAY_COMPONENT].path },
			[C.CHINADNS_COMPONENT]: { path: components[C.CHINADNS_COMPONENT].path }
		},
		render_hash: stage_hashes
	};
	if (!state_file.write(run_dir(daemon), updated)) {
		daemon.ctx.lan_ifaces = old_lan_ifaces;
		rollback_actions(daemon, done, previous, current, publication.had_current, old_artifacts, daemon.state.components ?? components);
		return { ok: false, detail: `cannot update state render_hash: ${state_file.error()}` };
	}
	daemon.state = updated;
	let removed = sys.run([ 'rm', '-rf', previous ], { timeout: 10 });
	if (removed.code != 0)
		log_failure(daemon, 'remove_previous', `rm -rf ${previous} failed (${removed.code}): ${removed.stderr}`);
	return { ok: true, state: updated };
};

function run(daemon) {
	setup_log(daemon);
	let built = pipeline.build({ ...daemon.opts, runtime: {
		node_ip: daemon.state.node_ip ?? null,
		dns_tier: daemon.state.dns_tier ?? 'T2',
		restored: {}
	} });
	if (!built.ok)
		return failure(daemon, 'config', {
			message: built.detail, errors: built.errors,
			field: built.errors?.[0]?.field ?? built.errors?.[0]?.file ?? '-',
			reason: built.errors?.[0]?.code ?? built.detail
		}, 'CONFIG_INVALID');
	let snapshot = built.snapshot;
	// A different node (or a new address for the same node) needs its own bootstrap IP: the
	// running one belongs to the old node and also feeds node_ip4 in the nft table.
	let node_ip = daemon.state.node_ip ?? null;
	let old_node = daemon.snapshot.nodes?.[daemon.snapshot.main.node];
	let new_node = snapshot.nodes?.[snapshot.main.node];
	if (snapshot.main.enabled == true && new_node != null &&
	    (snapshot.main.node != daemon.snapshot.main.node || new_node.address != old_node?.address)) {
		let resolved = apply.resolve_node(daemon.ctx, new_node.address);
		if (!resolved.ok)
			return failure(daemon, 'resolve_node', resolved.detail);
		node_ip = resolved.ip;
		built = pipeline.build({ ...daemon.opts, runtime: { node_ip, dns_tier: daemon.state.dns_tier ?? 'T2', restored: {} } });
		if (!built.ok)
			return failure(daemon, 'render', built.detail);
		snapshot = built.snapshot;
	}
	let stage = `${run_dir(daemon)}/${C.STAGING_SUBDIR}`;
	let clean = sys.run([ 'rm', '-rf', stage ], { timeout: 10 });
	if (clean.code != 0)
		return failure(daemon, 'staging', `rm -rf ${stage} failed (${clean.code}): ${clean.stderr}`);
	if (!sys.mkdir_p(stage))
		return failure(daemon, 'staging', `cannot create ${stage}: ${sys.error()}`);
	let written = write_artifacts(stage, built.artifacts);
	if (!written.ok) {
		discard_stage(daemon, stage);
		return failure(daemon, 'staging', written.detail);
	}
	let rough_hashes = hash_artifacts(stage);
	if (!rough_hashes.ok) {
		discard_stage(daemon, stage);
		return failure(daemon, 'hash', rough_hashes.detail);
	}
	let rough_plan = plan(
		{ hashes: daemon.state.render_hash ?? {}, enabled: daemon.snapshot.main.enabled == true },
		{ hashes: rough_hashes.hashes, enabled: snapshot.main.enabled == true }
	);
	if (length(rough_plan) == 1 && rough_plan[0] == 'stop') {
		if (!discard_stage(daemon, stage))
			return failure(daemon, 'staging_cleanup', `cannot discard ${stage}`);
		return { ok: true, stop: true, snapshot };
	}
	let validated = validate(daemon, snapshot, stage, null, true);
	if (!validated.ok) {
		discard_stage(daemon, stage);
		return failure(daemon, 'validation', validated, validated.code);
	}
	if (!length(rough_plan)) {
		if (!discard_stage(daemon, stage))
			return failure(daemon, 'staging_cleanup', `cannot discard ${stage}`);
		return { ok: true, actions: [], snapshot, state: daemon.state };
	}
	let hashes = rough_hashes.hashes;
	let actions = rough_plan;
	let artifacts = built.artifacts;
	let old_hashes = daemon.state.render_hash ?? {};
	let old_plan = { hashes: old_hashes, enabled: daemon.snapshot.main.enabled == true };
	let fresh_plan = { hashes, enabled: snapshot.main.enabled == true };
	let old_components = daemon.state.components ?? validated.components;
	let components = validated.components;
	let old_lan_ifaces = daemon.ctx.lan_ifaces;
	let old_artifacts = {};
	for (let name, file in C.ARTIFACT_FILES) {
		let text = fs.readfile(`${run_dir(daemon)}/${C.DAEMON_CURRENT_DIR}/${file}`);
		if (text == null) {
			discard_stage(daemon, stage);
			return failure(daemon, 'read_current', `cannot read ${file}: ${fs.error() ?? 'unknown error'}`);
		}
		old_artifacts[name] = text;
	}

	if (index(rough_plan, 'nft_replace') >= 0) {
		// A candidate nft diff may be only the live dynamic elements; export and re-render before
		// final planning so identical config does not flush/recreate those sets.
		let table = apply.nft_table_exists(daemon.ctx);
		if (!table.ok) {
			discard_stage(daemon, stage);
			return failure(daemon, 'sets_export', table.detail);
		}
		let restored = table.exists ? apply.sets_export(daemon.ctx) : { ok: true, sets: { gfw4: [], udirect4: [], uproxy4: [] } };
		if (!restored.ok) {
			discard_stage(daemon, stage);
			return failure(daemon, 'sets_export', restored.detail);
		}
		let with_sets = pipeline.build({ ...daemon.opts, runtime: {
			node_ip,
			dns_tier: daemon.state.dns_tier ?? 'T2',
			restored: restored.sets
		} });
		if (!with_sets.ok) {
			discard_stage(daemon, stage);
			return failure(daemon, 'render', with_sets.detail);
		}
		artifacts = with_sets.artifacts;
		if (!sys.write_atomic(`${stage}/${C.ARTIFACT_FILES.nft}`, artifacts.nft)) {
			discard_stage(daemon, stage);
			return failure(daemon, 'nft_stage', sys.error());
		}
		let checked = validate(daemon, snapshot, stage, components, true);
		if (!checked.ok) {
			discard_stage(daemon, stage);
			return failure(daemon, 'validation', checked, checked.code);
		}
		let h = hash_artifacts(stage);
		if (!h.ok) {
			discard_stage(daemon, stage);
			return failure(daemon, 'hash', h.detail);
		}
		hashes = h.hashes;
		fresh_plan = { hashes, enabled: snapshot.main.enabled == true };
		actions = plan(old_plan, fresh_plan);
		if (length(actions) == 1 && actions[0] == 'stop') {
			discard_stage(daemon, stage);
			return { ok: true, stop: true, snapshot };
		}
	}

	if (!length(actions)) {
		discard_stage(daemon, stage);
		daemon.ctx.lan_ifaces = snapshot.main.lan_ifaces ?? [];
		daemon.snapshot = snapshot;
		return { ok: true, actions: [], snapshot, state: daemon.state };
	}
	let old_state = daemon.state;
	daemon.state = { ...daemon.state, node_ip };
	let applied = apply_plan(daemon, actions, artifacts, components, hashes, old_artifacts, old_components,
		old_lan_ifaces, snapshot.main.lan_ifaces ?? [], snapshot.main.node);
	if (!applied.ok) {
		daemon.state = old_state;
		return failure(daemon, 'actions', applied.detail);
	}
	daemon.snapshot = snapshot;
	return { ok: true, actions, snapshot, state: applied.state };
};

export { plan, run };
