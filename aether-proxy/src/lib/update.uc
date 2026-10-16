'use strict';

// Device-side update discovery. Downloaded metadata is never trusted before usign succeeds.

import * as fs from 'fs';
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as config from 'aetherproxy.config';
import * as data from 'aetherproxy.data';
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

function read_signed_manifest(opts) {
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
		return { ok: false, detail: loaded.detail };
	if (!length(loaded.urls))
		return { ok: false, detail: 'no update channel URLs are configured' };
	if (!sys.mkdir_p(ctx.download_dir))
		return { ok: false, detail: `cannot create ${ctx.download_dir}: ${sys.error() ?? 'unknown error'}` };
	let proxied = proxy_running(ctx), selected = null, reached = false;
	for (let i = 0; i < length(loaded.urls); i++) {
		let candidate = download_manifest(ctx, loaded.urls[i], proxied, i);
		if (candidate.manifest != null) {
			selected = { manifest: candidate.manifest, base: loaded.urls[i] };
			break;
		}
		reached ||= candidate.reached;
	}
	let names = fs.lsdir(ctx.download_dir);
	if (names == null)
		return { ok: false, detail: `cannot list ${ctx.download_dir}: ${fs_error()}` };
	for (let name in names)
		if (match(name, /^manifest-[0-9]+\.json(\.sig)?$/) != null && unlink_file(`${ctx.download_dir}/${name}`) == null)
			return { ok: false, detail: `cannot remove ${ctx.download_dir}/${name}: ${fs_error()}` };
	if (selected == null)
		return { ok: false, detail: reached ? 'no channel provided a valid signed schema 2 manifest' : 'no update channel could be reached' };
	return { ok: true, ...selected, bases: loaded.urls, ctx };
}

function path_sha256(path) {
	return file_sha256(path);
}

function line_count(text) {
	let count = 0;
	for (let line in split(text, '\n')) {
		let value = trim(line);
		if (value != '' && substr(value, 0, 1) != '#')
			count++;
	}
	return count;
}

function data_parser(name, text) {
	if (C.DATA_DOMAIN_FILES[name] != null)
		return data.parse_domains(text);
	if (C.DATA_IP_FILES[name] != null)
		return data.parse_cidrs(text);
	return null;
}

function set_data_failure(result, name, detail) {
	result.failed[name] = detail;
	log.event('error', 'UPDATE_VERIFY_FAILED', { item: name });
}

function file_sha256_from_text(text, dir, name) {
	let path = `${dir}/data-${name}.plain`;
	if (!sys.write_atomic(path, text))
		return null;
	let hash = file_sha256(path);
	if (!fs.unlink(path)) {
		let detail = fs_error();
		log.event('error', 'FS_FAILED', { op: 'unlink', path, detail });
	}
	return hash;
}

function update_data_item(opts, ctx, base_urls, name, item) {
	if (index(C.DATA_UPDATE_ITEMS, name) < 0 || type(item) != 'object' ||
		type(item.url) != 'string' || match(item.url, /^[A-Za-z0-9._-]+\.txt\.gz$/) == null ||
		type(item.sha256) != 'string' || match(item.sha256, /^[0-9a-fA-F]{64}$/) == null ||
		type(item.content_sha256) != 'string' || match(item.content_sha256, /^[0-9a-fA-F]{64}$/) == null ||
		type(item.size) != 'int' || item.size < 0 || type(item.lines) != 'int' || item.lines < 0)
		return { ok: false, detail: 'invalid data manifest entry' };
	let filename = C.DATA_DOMAIN_FILES[name] ?? C.DATA_IP_FILES[name];
	let current_path = system_path(ctx.root, `${C.DATA_DIR}/${filename}`);
	let hash_path = system_path(ctx.root, `${C.DATA_DIR}/${name}.sha256`);
	let local_hash = fs.readfile(hash_path);
	if (local_hash != null) {
		local_hash = trim(local_hash);
		if (match(local_hash, /^[0-9a-fA-F]{64}$/) == null)
			return { ok: false, detail: 'invalid local content hash' };
	}
	else {
		let err = fs_error();
		if (err != 'No such file or directory')
			return { ok: false, detail: `cannot read ${hash_path}: ${err}` };
		let baseline = system_path(ctx.root, `${C.BASELINE_DATA_DIR}/${filename}`);
		local_hash = path_sha256(baseline);
		if (local_hash == null)
			return { ok: false, detail: `cannot hash baseline ${baseline}` };
	}
	if (lc(local_hash) == lc(item.content_sha256))
		return { ok: true, unchanged: true };

	let downloaded = download_asset(opts, base_urls, item, `data-${name}.txt.gz`);
	if (!downloaded.ok)
		return { ok: false, detail: downloaded.detail ?? downloaded.code ?? 'asset download failed' };
	let gunzip = sys.run([ 'gunzip', '-c', downloaded.path ], { timeout: C.UPDATE_COMMAND_TIMEOUT_SECS });
	if (gunzip.code != 0) {
		if (unlink_file(downloaded.path) == null)
			log.event('error', 'FS_FAILED', { op: 'unlink', path: downloaded.path, detail: fs_error() });
		return { ok: false, detail: `gunzip exited ${gunzip.code}: ${trim(gunzip.stderr)}` };
	}
	if (unlink_file(downloaded.path) == null)
		return { ok: false, detail: `cannot remove downloaded data asset ${downloaded.path}: ${fs_error()}` };
	let content = gunzip.stdout;
	let actual_hash = file_sha256_from_text(content, ctx.download_dir, name);
	if (actual_hash == null || actual_hash != lc(item.content_sha256))
		return { ok: false, detail: 'decompressed content sha256 mismatch' };
	let count = line_count(content);
	if (count * 100 < item.lines * C.UPDATE_DATA_MIN_PERCENT)
		return { ok: false, detail: `line count ${count} is below ${C.UPDATE_DATA_MIN_PERCENT}% of ${item.lines}` };
	let parsed = data_parser(name, content);
	if (parsed == null || length(parsed.errors))
		return { ok: false, detail: parsed == null ? 'unknown data item' : `invalid list line ${parsed.errors[0].line}` };
	let data_dir = system_path(ctx.root, C.DATA_DIR);
	if (!sys.mkdir_p(data_dir))
		return { ok: false, detail: `cannot create ${data_dir}: ${sys.error() ?? 'unknown error'}` };
	let temp_path = `${current_path}.tmp`;
	let previous = fs.readfile(current_path);
	let previous_missing = previous == null && fs_error() == 'No such file or directory';
	if (previous == null && !previous_missing)
		return { ok: false, detail: `cannot read ${current_path}: ${fs_error()}` };
	if (!sys.write_atomic(temp_path, content))
		return { ok: false, detail: `cannot stage ${temp_path}: ${sys.error() ?? 'unknown error'}` };
	let moved = sys.run([ 'mv', temp_path, current_path ]);
	if (moved.code != 0) {
		unlink_file(temp_path);
		return { ok: false, detail: `mv ${temp_path} exited ${moved.code}: ${trim(moved.stderr)}` };
	}
	if (!sys.write_atomic(hash_path, `${lc(item.content_sha256)}\n`)) {
		let detail = sys.error() ?? 'unknown error';
		if (previous_missing) {
			if (!fs.unlink(current_path))
				log.event('error', 'FS_FAILED', { op: 'unlink', path: current_path, detail: fs_error() });
		}
		else if (!sys.write_atomic(current_path, previous))
			log.event('error', 'FS_FAILED', { op: 'restore', path: current_path, detail: sys.error() ?? 'unknown error' });
		return { ok: false, detail: `cannot write ${hash_path}: ${detail}` };
	}
	return { ok: true, updated: true };
}

export function data_update(opts) {
	opts ??= {};
	let loaded = read_signed_manifest(opts);
	let result = { ok: false, updated: [], unchanged: [], failed: {} };
	if (!loaded.ok) {
		result.failed.manifest = loaded.detail;
		log.event('error', 'UPDATE_VERIFY_FAILED', { item: 'manifest' });
		return { ...result, detail: loaded.detail, exit: 1 };
	}
	let entries = loaded.manifest.data;
	if (type(entries) != 'object') {
		set_data_failure(result, 'manifest', 'manifest data section is missing');
		return { ...result, exit: 1 };
	}
	for (let name in sort(keys(entries))) {
		let outcome = update_data_item(opts, loaded.ctx, loaded.bases, name, entries[name]);
		if (!outcome.ok)
			set_data_failure(result, name, outcome.detail);
		else if (outcome.unchanged)
			push(result.unchanged, name);
		else
			push(result.updated, name);
	}
	if (length(result.updated)) {
		let state = read_object(`${loaded.ctx.run_dir}/${C.STATE_FILE}`);
		if (state != null && index([ 'starting', 'running', 'degraded' ], state.state) >= 0) {
			let init = system_path(loaded.ctx.root, C.UPDATE_INIT);
			let reload = sys.run([ init, 'reload' ], { timeout: 120 });
			if (reload.code != 0) {
				// TODO(design): 08 specifies reload after a successful data write, but not rollback
				// semantics when init reload itself fails. Keep the verified data and report failure.
				result.failed.reload = `init reload exited ${reload.code}: ${trim(reload.stderr)}`;
				log.event('error', 'UPDATE_VERIFY_FAILED', { item: 'reload' });
			}
		}
		log.event('notice', 'DATA_UPDATED', { items: result.updated });
	}
	result.ok = !length(keys(result.failed));
	return { ...result, exit: result.ok ? 0 : 1 };
};
