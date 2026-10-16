'use strict';

// Device-side update discovery. Downloaded metadata is never trusted before usign succeeds.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as log from 'aetherproxy.log';
import * as net from 'aetherproxy.net';
import * as sys from 'aetherproxy.sys';

function fs_error() {
	return fs.error() ?? 'unknown error';
}

function system_path(root, path) {
	return root == '' ? path : replace(root, /\/$/, '') + path;
}

function read_object(path) {
	let text = fs.readfile(path);
	if (text == null)
		return null;
	try {
		let value = json(text);
		return type(value) == 'object' ? value : null;
	}
	catch (e) {
		return null;
	}
}

function proxy_running(ctx) {
	let state = read_object(`${ctx.run_dir}/${C.STATE_FILE}`);
	if (state == null || index([ 'running', 'degraded' ], state.state) < 0)
		return false;
	for (let file in [ C.PROC_NET_TCP, C.PROC_NET_TCP6 ])
		if (net.tcp_listening(fs.readfile(system_path(ctx.root, file)), C.HTTP_PORT))
			return true;
	return false;
}

function curl(ctx, url, output, max_size, via_proxy) {
	let bin = 'curl';
	let argv = [ bin, '--fail', '--silent', '--show-error', '--max-time', `${C.UPDATE_DOWNLOAD_MAX_SECS}`,
		'--max-filesize', `${max_size}` ];
	if (via_proxy)
		push(argv, '-x', `http://${C.HTTP_LISTEN}:${C.HTTP_PORT}`);
	push(argv, '-o', output, url);
	let result = sys.run(argv, { timeout: C.UPDATE_COMMAND_TIMEOUT_SECS, quiet: true });
	if (result.code != 0)
		log.event('error', 'CMD_FAILED', { cmd: join(' ', argv), rc: result.code, stderr: trim(result.stderr) });
	return result;
}

function unlink_file(path) {
	if (fs.stat(path) == null) {
		let detail = fs_error();
		return detail == 'No such file or directory' ? true : null;
	}
	return fs.unlink(path) ? true : null;
}

function fetch_file(ctx, url, path, max_size, proxied_first) {
	if (!sys.mkdir_p(ctx.download_dir))
		return false;
	if (unlink_file(path) == null)
		return false;
	let routes = proxied_first ? [ true, false ] : [ false ];
	for (let via_proxy in routes) {
		let result = curl(ctx, url, path, max_size, via_proxy);
		if (result.code == 0) {
			let stat = fs.stat(path);
			if (stat != null && stat.size <= max_size)
				return true;
		}
		if (unlink_file(path) == null)
			return false;
	}
	return false;
}

function channel_url(base, file) {
	return `${replace(base, /\/$/, '')}/${file}`;
}

function download_manifest(ctx, base, proxied_first, index) {
	let manifest_path = `${ctx.download_dir}/manifest-${index}.json`;
	let sig_path = `${ctx.download_dir}/manifest-${index}.json.sig`;
	if (!fetch_file(ctx, channel_url(base, 'manifest.json'), manifest_path, C.UPDATE_MANIFEST_MAX, proxied_first) ||
		!fetch_file(ctx, channel_url(base, 'manifest.json.sig'), sig_path, C.UPDATE_MANIFEST_MAX, proxied_first))
		return { reached: false };
	// Verify before parsing: nothing from an unverified file is interpreted.
	let usign = ctx.bin_dir ? `${ctx.bin_dir}/usign` : 'usign';
	let verified = sys.run([ usign, '-V', '-q', '-m', manifest_path, '-P', ctx.keys_dir ], { timeout: 10, quiet: true });
	let manifest = verified.code == 0 ? read_object(manifest_path) : null;
	if (manifest == null || manifest.schema != 2) {
		log.event('error', 'MANIFEST_BAD_SIGNATURE', { url: base });
		return { reached: true };
	}
	return { manifest, path: manifest_path };
}

function load_channel_urls(confdir) {
	let cursor = uci.cursor(confdir);
	let loaded = config.load(cursor);
	if (!loaded.ok) {
		let first = loaded.errors?.[0] ?? {};
		log.event('error', 'CONFIG_INVALID', { field: first.field ?? '-', reason: first.code ?? first.detail ?? 'invalid configuration' });
		return { ok: false, detail: 'configuration is invalid' };
	}
	return { ok: true, urls: loaded.snapshot.update.channel_urls };
}

function package_manager(bin_dir) {
	let apk = bin_dir ? `${bin_dir}/apk` : 'apk';
	if (fs.access(apk, 'x'))
		return 'apk';
	let opkg = bin_dir ? `${bin_dir}/opkg` : 'opkg';
	if (fs.access(opkg, 'x'))
		return 'opkg';
	return null;
}

function installed_version(ctx, pm, name) {
	let bin = ctx.bin_dir ? `${ctx.bin_dir}/${pm}` : pm;
	let argv = pm == 'opkg' ? [ bin, 'status', name ] : [ bin, 'list', '-I', name ];
	let result = sys.run(argv, { timeout: 10, quiet: true });
	if (result.code != 0) {
		log.event('error', 'CMD_FAILED', { cmd: join(' ', argv), rc: result.code, stderr: trim(result.stderr) });
		return { ok: false, detail: `${pm} exited ${result.code}: ${trim(result.stderr)}` };
	}
	if (pm == 'opkg') {
		let match_version = match(result.stdout, /(^|\n)Version:[ \t]*([^\r\n]+)/);
		return { ok: true, version: match_version ? trim(match_version[2]) : null };
	}
	let token = split(trim(split(trim(result.stdout), '\n')[0] ?? ''), /[[:space:]]+/)[0] ?? '';
	let prefix = `${name}-`;
	return { ok: true, version: substr(token, 0, length(prefix)) == prefix ? substr(token, length(prefix)) : null };
}

function version_parts(version) {
	let m = match(version, /^(.*)-r([0-9]+)$/);
	let upstream = m ? m[1] : version;
	let release = m ? +m[2] : 0;
	let parts = [];
	for (let part in split(upstream, '.')) {
		let n = match(part, /^([0-9]+)/);
		push(parts, n ? +n[1] : 0);
	}
	return { parts, release };
}

function version_newer(available, installed) {
	if (installed == null)
		return false;
	let a = version_parts(available), b = version_parts(installed);
	for (let i = 0; i < max(length(a.parts), length(b.parts)); i++) {
		let av = a.parts[i] ?? 0, bv = b.parts[i] ?? 0;
		if (av != bv)
			return av > bv;
	}
	return a.release > b.release;
}

function file_sha256(path) {
	let argv = [ 'sha256sum', path ];
	let hash = sys.run(argv, { timeout: 10, quiet: true });
	if (hash.code != 0) {
		log.event('error', 'CMD_FAILED', { cmd: join(' ', argv), rc: hash.code, stderr: trim(hash.stderr) });
		return null;
	}
	let m = match(hash.stdout, /^([0-9a-fA-F]{64})[ \t]/);
	return m ? lc(m[1]) : null;
}

function data_status(ctx, manifest) {
	let result = {};
	for (let name in sort(keys(manifest.data ?? {}))) {
		let local_path = system_path(ctx.root, `${C.DATA_DIR}/${name}.sha256`);
		let local = fs.readfile(local_path);
		if (local == null) {
			let detail = fs_error();
			if (detail != 'No such file or directory')
				log.event('error', 'FS_FAILED', { op: 'read', path: local_path, detail });
		}
		// .sha256 holds the plain list's hash, so compare content_sha256, not the .gz sha256 (08).
		result[name] = { changed: local == null || trim(local) != manifest.data[name].content_sha256 };
	}
	return result;
}

function build_result(ctx, manifest, base, arch, pm) {
	let packages = {};
	let prior = read_object(`${ctx.run_dir}/${C.UPDATE_FILE}`);
	for (let name in C.UPDATE_PACKAGES) {
		let entry = manifest.packages?.[name];
		if (type(entry) != 'object' || type(entry.current) != 'object')
			continue;
		let current = entry.current;
		let asset_set = current.assets?.[arch] ?? current.assets?.all;
		let asset = asset_set?.[pm] ?? null;
		let installed = installed_version(ctx, pm, name);
		if (!installed.ok)
			return { ok: false, detail: installed.detail };
	let newer = asset != null && version_newer(current.version, installed.version);
		if (asset == null)
			log.event('error', 'ARCH_UNSUPPORTED', { arch });
		let was_reported = prior?.packages?.[name]?.available == current.version && prior?.packages?.[name]?.newer == true;
		if (newer && !was_reported)
			log.event('notice', 'UPDATE_AVAILABLE', { package: name, current: installed.version, latest: current.version });
		packages[name] = {
			installed: installed.version,
			available: current.version,
			newer,
			asset: asset == null ? null : asset.url	// file name for this arch and pm (08 "检查")
		};
	}
	return {
		ok: true,
		value: {
			checked: time(), url: base, arch, pm,
			packages,
			data: data_status(ctx, manifest)
		}
	};
}

function free_bytes(ctx) {
	let override = getenv('AETHER_PROXY_TEST_TMP_FREE');
	if (override != null && match(override, /^[0-9]+$/) != null)
		return +override;
	let argv = [ 'df', '-Pk', ctx.tmp_dir ];
	let result = sys.run(argv, { timeout: 5, quiet: true });
	if (result.code != 0) {
		log.event('error', 'CMD_FAILED', { cmd: join(' ', argv), rc: result.code, stderr: trim(result.stderr) });
		return null;
	}
	let lines = split(trim(result.stdout), '\n');
	let fields = split(trim(lines[length(lines) - 1] ?? ''), /[[:space:]]+/);
	if (length(fields) < 4 || match(fields[3], /^[0-9]+$/) == null)
		return null;
	return +fields[3] * 1024;
}

// Fetch one signed asset for T7.4/T7.5. Failure never leaves a partial file.
export function download_asset(opts, base, asset, name) {
	opts ??= {};
	let root = opts.sys_root ?? '';
	let ctx = {
		root,
		bin_dir: opts.bin_dir ?? null,
		run_dir: opts.run_dir ?? system_path(root, C.RUN_DIR),
		tmp_dir: system_path(root, C.TMP_DIR),
		download_dir: system_path(root, C.DOWNLOAD_DIR)
	};
	let path = `${ctx.download_dir}/${name}`;
	let free = free_bytes(ctx);
	if (free == null || free < asset.size + C.UPDATE_SPACE_RESERVE) {
		log.event('error', 'NO_SPACE', { need: asset.size + C.UPDATE_SPACE_RESERVE, free: free ?? 0 });
		return { ok: false, code: 'NO_SPACE' };
	}
	let proxied = proxy_running(ctx);
	let bases = type(base) == 'array' ? base : [ base ];
	for (let channel in bases) {
		let routes = proxied ? [ true, false ] : [ false ];
		for (let via_proxy in routes) {
			if (!fetch_file(ctx, channel_url(channel, asset.url), path, asset.size, via_proxy))
				continue;
			let stat = fs.stat(path), hash = file_sha256(path);
			if (stat != null && stat.size == asset.size && hash == lc(asset.sha256))
				return { ok: true, path };
			if (unlink_file(path) == null)
				return { ok: false, code: 'FS_FAILED', detail: `cannot remove invalid asset ${path}: ${fs_error()}` };
		}
	}
	return { ok: false, code: 'UPDATE_VERIFY_FAILED', detail: 'asset size or sha256 mismatch, or download failed' };
};

export function check(opts) {
	opts ??= {};
	let root = opts.sys_root ?? '';
	let run_dir = opts.run_dir ?? system_path(root, C.RUN_DIR);
	let ctx = {
		root,
		bin_dir: opts.bin_dir ?? null,
		run_dir,
		tmp_dir: system_path(root, C.TMP_DIR),
		download_dir: system_path(root, C.DOWNLOAD_DIR),
		keys_dir: system_path(root, C.KEYS_DIR)
	};
	log.set_run_dir(run_dir);
	let loaded = load_channel_urls(opts.confdir ?? system_path(root, C.CONFIG_DIR));
	if (!loaded.ok)
		return { ok: false, code: 'CONFIG_INVALID', exit: 2, detail: loaded.detail };
	// An empty channel list is a configuration problem (08 "检查"), not a usage error.
	if (!length(loaded.urls)) {
		log.event('error', 'CONFIG_INVALID', { field: 'update.channel_urls', reason: 'empty' });
		return { ok: false, code: 'CONFIG_INVALID', exit: 2, detail: 'no update channel URLs are configured' };
	}
	if (!sys.mkdir_p(ctx.download_dir)) {
		let detail = sys.error() ?? 'unknown error';
		log.event('error', 'FS_FAILED', { op: 'mkdir', path: ctx.download_dir, detail });
		return { ok: false, code: 'FS_FAILED', exit: 1, detail: `cannot create ${ctx.download_dir}: ${sys.error()}` };
	}
	let proxied = proxy_running(ctx), selected = null, reached = false;
	for (let i = 0; i < length(loaded.urls); i++) {
		let base = loaded.urls[i];
		let candidate = download_manifest(ctx, base, proxied, i);
		if (candidate.manifest != null) {
			selected = { ...candidate, base };
			break;
		}
		reached ||= candidate.reached;
	}
	let download_names = fs.lsdir(ctx.download_dir);
	if (download_names == null) {
		let detail = fs_error();
		log.event('error', 'FS_FAILED', { op: 'list', path: ctx.download_dir, detail });
		return { ok: false, code: 'FS_FAILED', exit: 1, detail };
	}
	for (let name in download_names)
		if (match(name, /^manifest-[0-9]+\.json(\.sig)?$/) != null && unlink_file(`${ctx.download_dir}/${name}`) == null) {
			let detail = `cannot remove ${ctx.download_dir}/${name}: ${fs_error()}`;
			log.event('error', 'FS_FAILED', { op: 'unlink', path: `${ctx.download_dir}/${name}`, detail });
			return { ok: false, code: 'FS_FAILED', exit: 1, detail };
		}
	// 08: some address served a manifest that failed verification -> 4; none answered at all
	// -> 1 with UPDATE_FETCH_FAILED (LuCI tells "cannot reach the channel" from "bad signature").
	if (selected == null && reached)
		return { ok: false, code: 'MANIFEST_BAD_SIGNATURE', exit: 4, detail: 'no channel provided a valid signed schema 2 manifest' };
	if (selected == null) {
		log.event('error', 'UPDATE_FETCH_FAILED', { urls: loaded.urls });
		return { ok: false, code: 'UPDATE_FETCH_FAILED', exit: 1, detail: 'no update channel could be reached' };
	}
	let release_path = system_path(root, C.UPDATE_RELEASE_FILE);
	let release = fs.readfile(release_path);
	if (release == null) {
		let detail = fs_error();
		log.event('error', 'FS_FAILED', { op: 'read', path: release_path, detail });
		return { ok: false, code: 'FS_FAILED', exit: 1, detail: `cannot read ${release_path}: ${detail}` };
	}
	let architecture = match(release, /(^|\n)DISTRIB_ARCH=['"]?([^'"\r\n]+)['"]?/);
	if (!architecture)
		return { ok: false, code: 'CONFIG_INVALID', exit: 1, detail: 'DISTRIB_ARCH is missing from /etc/openwrt_release' };
	let pm = package_manager(ctx.bin_dir);
	if (pm == null)
		return { ok: false, code: 'CMD_FAILED', exit: 1, detail: 'neither apk nor opkg is available' };
	let built = build_result(ctx, selected.manifest, selected.base, architecture[2], pm);
	if (!built.ok)
		return { ok: false, code: 'CMD_FAILED', exit: 1, detail: built.detail };
	let update_path = `${run_dir}/${C.UPDATE_FILE}`;
	if (!sys.write_atomic(update_path, sprintf('%.J', built.value) + '\n')) {
		let detail = sys.error() ?? 'unknown write error';
		log.event('error', 'FS_FAILED', { op: 'write', path: update_path, detail });
		return { ok: false, code: 'FS_FAILED', exit: 1, detail };
	}
	return { ok: true, value: built.value, exit: 0 };
};

function wait_seconds() {
	let value = getenv(C.UPDATE_TEST_WAIT_ENV);
	return match(value ?? '', /^[0-9]+$/) ? +value : null;
}

function poll_seconds() {
	let value = getenv(C.UPDATE_TEST_POLL_ENV);
	return match(value ?? '', /^[0-9]+$/) && +value > 0 ? +value : C.UPDATE_PACKAGE_POLL_SECS;
}

function wait_limit(default_value) {
	let value = wait_seconds();
	return value == null ? default_value : value;
}

function read_manifest_for(opts, base) {
	let root = opts.sys_root ?? '';
	let run_dir = opts.run_dir ?? system_path(root, C.RUN_DIR);
	let ctx = {
		root,
		bin_dir: opts.bin_dir ?? null,
		run_dir,
		tmp_dir: system_path(root, C.TMP_DIR),
		download_dir: system_path(root, C.DOWNLOAD_DIR),
		keys_dir: system_path(root, C.KEYS_DIR)
	};
	if (!sys.mkdir_p(ctx.download_dir))
		return { ok: false, code: 'FS_FAILED', detail: `cannot create ${ctx.download_dir}: ${sys.error()}` };
	let manifest = download_manifest(ctx, base, proxy_running(ctx), 999);
	for (let path in [ `${ctx.download_dir}/manifest-999.json`, `${ctx.download_dir}/manifest-999.json.sig` ])
		if (unlink_file(path) == null)
			log.event('error', 'FS_FAILED', { op: 'unlink', path, detail: fs_error() });
	if (manifest.manifest == null)
		return { ok: false, code: 'MANIFEST_BAD_SIGNATURE', detail: 'cannot retrieve a valid signed manifest' };
	return { ok: true, ctx, manifest: manifest.manifest };
}

function package_asset(manifest, name, arch, pm, previous) {
	let entry = manifest.packages?.[name];
	let version = previous ? entry?.previous?.version : entry?.current?.version;
	let release = previous ? entry?.previous : entry?.current;
	if (type(release) != 'object' || type(release.assets) != 'object')
		return null;
	let asset_set = release.assets[arch] ?? release.assets.all;
	let asset = asset_set?.[pm] ?? null;
	return type(asset) == 'object' && type(asset.url) == 'string' && type(version) == 'string'
		? { ...asset, version } : null;
}

function install_package(ctx, pm, path, previous) {
	let bin = ctx.bin_dir ? `${ctx.bin_dir}/${pm}` : pm;
	let argv = pm == 'opkg'
		? [ bin, 'install', ...(previous ? [ '--force-downgrade' ] : []), path ]
		: [ bin, 'add', '--allow-untrusted', path ];
	// TODO(design): package-manager runtime is unspecified; use the background-job ceiling so a
	// slow flash write is not interrupted at the shorter health-check deadline.
	let result = sys.run(argv, { timeout: C.JOB_TIMEOUT_SECS });
	if (result.code == 0)
		return { ok: true };
	let stderr = trim(result.stderr);
	let lower_stderr = lc(stderr);
	if (index(lower_stderr, 'no space') >= 0 || index(lower_stderr, 'not enough space') >= 0 ||
	    index(lower_stderr, 'disk full') >= 0 || index(lower_stderr, 'insufficient space') >= 0)
		log.event('error', 'NO_SPACE', { need: 0, free: 0 });
	return { ok: false, detail: `${pm} install exited ${result.code}: ${stderr}`, code: result.code };
}

function xray_binary(ctx) {
	if (ctx.bin_dir && fs.access(`${ctx.bin_dir}/${C.XRAY_COMPONENT}`, 'x'))
		return `${ctx.bin_dir}/${C.XRAY_COMPONENT}`;
	return C.XRAY_COMPONENT;
}

function port_listening(ctx) {
	for (let file in [ C.PROC_NET_TCP, C.PROC_NET_TCP6 ])
		if (net.tcp_listening(fs.readfile(system_path(ctx.root, file)), C.TPROXY_PORT))
			return true;
	return false;
}

function monotonic_seconds() {
	let value = clock(true);
	return value == null ? null : value[0] + value[1] / 1000000000;
}

function wait_for(ctx, timeout, predicate) {
	let started = monotonic_seconds();
	if (started == null)
		return false;
	let deadline = started + timeout;
	while (true) {
		if (predicate())
			return true;
		let now = monotonic_seconds();
		if (now == null || now >= deadline)
			break;
		let sleep = sys.run([ 'sleep', `${poll_seconds()}` ], { timeout: poll_seconds() + 1, quiet: true });
		if (sleep.code != 0) {
			log.event('error', 'CMD_FAILED', { cmd: 'sleep', rc: sleep.code, stderr: trim(sleep.stderr) });
			return false;
		}
	}
	return predicate();
}

function service_state(ctx) {
	return read_object(`${ctx.run_dir}/${C.STATE_FILE}`);
}

function verify_installed_version(ctx, pm, name, version) {
	let installed = installed_version(ctx, pm, name);
	return installed.ok && installed.version == version;
}

function verify_package(ctx, opts, pm, name, version, before_state, before_probe) {
	if (name == 'luci-app-aether-proxy' || name == 'luci-i18n-aether-proxy-zh-cn')
		return true;
	if (name == 'xray-core') {
		if (before_state?.state == 'running') {
			let signal = sys.run([ 'killall', '-USR2', C.UPDATE_DAEMON_PROCESS ], { timeout: 5 });
			if (signal.code != 0) {
				log.event('error', 'CMD_FAILED', { cmd: 'killall -USR2 aether-proxy', rc: signal.code, stderr: trim(signal.stderr) });
				return false;
			}
			let wait = wait_limit(C.UPDATE_XRAY_WAIT_SECS);
			return wait_for(ctx, wait, () => {
				let state = service_state(ctx);
				return state?.last_probe?.ok == true && type(state.last_probe.at) == 'int' && state.last_probe.at > before_probe;
			});
		}
		if (index([ 'starting', 'degraded', 'failsafe' ], before_state?.state) >= 0)
			return wait_for(ctx, wait_limit(C.UPDATE_PORT_WAIT_SECS), () => port_listening(ctx));
		if (before_state == null || index([ 'stopped', 'error' ], before_state.state) >= 0) {
			let result = sys.run([ xray_binary(ctx), 'version' ], { timeout: 10, quiet: true });
			if (result.code != 0)
				return false;
			let found = split(trim(result.stdout), /[[:space:]]+/)[1] ?? null;
			let expected = split(version, '-r')[0];
			return found == expected;
		}
		// TODO(design): 08 defines xray checks for running, unhealthy, and stopped states, but not failsafe.
		return false;
	}
	if (name == 'aether-proxy') {
		let init = system_path(ctx.root, C.UPDATE_INIT);
		let restarted = sys.run([ init, 'restart' ], { timeout: 35 });
		if (restarted.code != 0) {
			log.event('error', 'CMD_FAILED', { cmd: `${init} restart`, rc: restarted.code, stderr: trim(restarted.stderr) });
			return false;
		}
		if (index([ 'running', 'degraded' ], before_state?.state) >= 0)
			return wait_for(ctx, wait_limit(C.UPDATE_SERVICE_WAIT_SECS), () => {
				let state = service_state(ctx);
				return index([ 'running', 'degraded' ], state?.state) >= 0;
			});
		let check_bin = ctx.bin_dir ? `${ctx.bin_dir}/${C.PROG}` : C.PROG;
		let argv = [ check_bin, 'check', '--json', '--run-dir', ctx.run_dir, '--sys-root', ctx.root ];
		if (opts.confdir != null)
			push(argv, '--confdir', opts.confdir);
		if (ctx.bin_dir != null)
			push(argv, '--bin-dir', ctx.bin_dir);
		return sys.run(argv, { timeout: 35, quiet: true }).code == 0;
	}
	return false;
}

// Install one manifest-selected package. All package-manager calls happen only after the
// signed manifest and downloaded asset have both been verified.
export function package_update(opts, name, previous) {
	opts ??= {};
	let root = opts.sys_root ?? '';
	let run_dir = opts.run_dir ?? system_path(root, C.RUN_DIR);
	log.set_run_dir(run_dir);
	if (index(C.UPDATE_PACKAGE_NAMES, name) < 0)
		return { ok: false, code: 'USAGE', exit: 2, detail: `unsupported package '${name}'` };
	let checked = check(opts);
	if (!checked.ok)
		return { ok: false, code: checked.code, exit: checked.exit, detail: checked.detail };
	let selected = read_manifest_for(opts, checked.value.url);
	if (!selected.ok)
		return { ok: false, code: selected.code, exit: 1, detail: selected.detail };
	let ctx = selected.ctx;
	let configured_channels = load_channel_urls(opts.confdir ?? system_path(root, C.CONFIG_DIR));
	if (!configured_channels.ok)
		return { ok: false, code: 'CONFIG_INVALID', exit: 2, detail: configured_channels.detail };
	let arch = checked.value.arch, pm = checked.value.pm;
	let asset = package_asset(selected.manifest, name, arch, pm, previous == true);
	if (asset == null) {
		log.event('error', 'ARCH_UNSUPPORTED', { arch });
		return { ok: false, code: 'ARCH_UNSUPPORTED', exit: 1, detail: `no ${pm} asset for ${name} on ${arch}` };
	}
	let from = installed_version(ctx, pm, name);
	if (!from.ok)
		return { ok: false, code: 'CMD_FAILED', exit: 1, detail: from.detail };
	let before_state = service_state(ctx);
	let before_probe = before_state?.last_probe?.at ?? 0;
	let downloaded = download_asset(opts, configured_channels.urls, asset, asset.url);
	if (!downloaded.ok)
		return { ok: false, code: downloaded.code, exit: 1, detail: downloaded.detail ?? downloaded.code };
	let installed = install_package(ctx, pm, downloaded.path, previous == true);
	if (fs.stat(downloaded.path) != null && !fs.unlink(downloaded.path))
		log.event('error', 'FS_FAILED', { op: 'unlink', path: downloaded.path, detail: fs_error() });
	if (!installed.ok)
		return { ok: false, code: 'CMD_FAILED', exit: 1, detail: installed.detail };
	let verified = verify_package(ctx, opts, pm, name, asset.version, before_state, before_probe);
	if (verified && !verify_installed_version(ctx, pm, name, asset.version))
		verified = false;
	if (verified) {
		log.event('notice', 'UPDATE_INSTALLED', { package: name, version: asset.version });
		return { ok: true, exit: 0, value: { ok: true, package: name, from: from.version, to: asset.version, rolled_back: false, code: null } };
	}
	log.event('error', 'UPDATE_VERIFY_FAILED', { package: name, version: asset.version });
	let prior = package_asset(selected.manifest, name, arch, pm, false);
	let previous_asset = package_asset(selected.manifest, name, arch, pm, true);
	// --previous is an explicit downgrade request, not a failed upgrade; restore current only if
	// its post-install check fails.
	let rollback = previous == true ? prior : previous_asset;
	if (rollback == null)
		return { ok: false, code: 'UPDATE_VERIFY_FAILED', exit: 1, detail: 'no rollback version is available',
			value: { ok: false, package: name, from: from.version, to: asset.version, rolled_back: false, code: 'UPDATE_VERIFY_FAILED', detail: '无可回滚的版本' } };
	let rollback_file = download_asset(opts, configured_channels.urls, rollback, rollback.url);
	if (!rollback_file.ok)
		return { ok: false, code: 'UPDATE_VERIFY_FAILED', exit: 1, detail: `rollback asset unavailable: ${rollback_file.code}` };
	let rolled = install_package(ctx, pm, rollback_file.path, true);
	if (fs.stat(rollback_file.path) != null && !fs.unlink(rollback_file.path))
		log.event('error', 'FS_FAILED', { op: 'unlink', path: rollback_file.path, detail: fs_error() });
	if (!rolled.ok)
		return { ok: false, code: 'UPDATE_VERIFY_FAILED', exit: 1, detail: `rollback failed: ${rolled.detail}` };
	log.event('error', 'UPDATE_ROLLED_BACK', { package: name, version: rollback.version });
	return { ok: false, code: 'UPDATE_VERIFY_FAILED', exit: 1, detail: `verification failed; rolled back to ${rollback.version}`,
		value: { ok: false, package: name, from: from.version, to: asset.version, rolled_back: true, code: 'UPDATE_VERIFY_FAILED' } };
};
