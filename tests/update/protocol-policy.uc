'use strict';
// T16.77: verify update.uc's common curl() argv policy across manifest, signature, and asset downloads.
// Direct and proxied-first/fallback routes must restrict initial + redirect protocols to HTTP(S)
// and pass the URL as the final positional argument after standalone `--`.
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

function exported_helper(start_name, end_name) {
	let start = index(source, `export function ${start_name}(`);
	let end = index(source, `\nfunction ${end_name}(`, start);
	if (start < 0 || end < start)
		die(`production exported helper missing: ${start_name}`);
	return replace(substr(source, start, end - start), /^export /, '') + '\n';
}

let dependencies = [ 'C', 'fs', 'sys', 'log', 'run', 'read_object', 'proxy_running', 'free_bytes', 'file_sha256' ];

let factory = loadstring('(function(' + join(', ', dependencies) + ') { '
	+ helper('fs_error', 'system_path')
	+ helper('system_path', 'read_object')
	+ helper('curl', 'load_channel_urls')
	+ exported_helper('download_asset', 'fetch_manifest')
	+ '\nreturn { curl, fetch_file, download_manifest, download_asset }; })')();

let failures = 0;
function fail(message) {
	failures++;
	print(`FAIL  ${message}\n`);
}
function pass(message) {
	print(`PASS  ${message}\n`);
}

function has_pair(argv, flag, value) {
	for (let i = 0; i + 1 < length(argv); i++)
		if (argv[i] == flag && argv[i + 1] == value)
			return i;
	return -1;
}

function check_curl_argv(label, argv, expected_url, expected_out, expected_max, via_proxy) {
	let n = length(argv);
	if (argv[0] != 'curl') {
		fail(`${label}: expected argv[0]='curl', got '${argv[0]}'`);
		return false;
	}
	for (let flag in [ '--fail', '--silent', '--show-error', '--location' ]) {
		if (index(argv, flag) < 0) {
			fail(`${label}: missing flag ${flag} in ${join(' ', argv)}`);
			return false;
		}
	}
	if (has_pair(argv, '--max-redirs', '5') < 0) {
		fail(`${label}: missing --max-redirs 5`);
		return false;
	}
	if (has_pair(argv, '--proto', '=http,https') < 0) {
		fail(`${label}: missing --proto =http,https in ${join(' ', argv)}`);
		return false;
	}
	if (has_pair(argv, '--proto-redir', '=http,https') < 0) {
		fail(`${label}: missing --proto-redir =http,https in ${join(' ', argv)}`);
		return false;
	}
	if (has_pair(argv, '--max-time', `${C.UPDATE_DOWNLOAD_MAX_SECS}`) < 0) {
		fail(`${label}: missing --max-time ${C.UPDATE_DOWNLOAD_MAX_SECS}`);
		return false;
	}
	if (has_pair(argv, '--max-filesize', `${expected_max}`) < 0) {
		fail(`${label}: missing --max-filesize ${expected_max}`);
		return false;
	}
	let proxy_idx = has_pair(argv, '-x', `http://${C.HTTP_LISTEN}:${C.HTTP_PORT}`);
	if (via_proxy && proxy_idx < 0) {
		fail(`${label}: expected -x http://${C.HTTP_LISTEN}:${C.HTTP_PORT}`);
		return false;
	}
	if (!via_proxy && index(argv, '-x') >= 0) {
		fail(`${label}: unexpected -x on direct route`);
		return false;
	}
	if (n < 4 || argv[n - 4] != '-o' || argv[n - 3] != expected_out || argv[n - 2] != '--' || argv[n - 1] != expected_url) {
		fail(`${label}: expected trailing [-o, ${expected_out}, --, ${expected_url}], got ${join(' ', slice(argv, max(0, n - 4)))}`);
		return false;
	}
	if (via_proxy && proxy_idx >= n - 4) {
		fail(`${label}: -x must precede -o <path> -- <url>`);
		return false;
	}
	return true;
}

function run_scenario(name, proxied) {
	let folder = `${directory}/proto-${name}`;
	let dl_dir = `${folder}/tmp/aether-proxy-dl`;
	if (!sys.mkdir_p(dl_dir))
		die(`cannot create test folder: ${dl_dir}`);

	let calls = [];
	let payload = 'verified payload\n';
	let fake_sha = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
	let observed_log = { event: () => {} };
	let fake_run = (argv, opts) => {
		push(calls, argv);
		if (argv[0] == 'curl') {
			if (index(argv, '-x') >= 0)
				return { code: 7, stdout: '', stderr: 'proxy connect refused' };
			let o_idx = index(argv, '-o');
			if (o_idx >= 0 && o_idx + 1 < length(argv))
				sys.write_atomic(argv[o_idx + 1], payload);
			return { code: 0, stdout: '', stderr: '' };
		}
		if (argv[0] == 'usign')
			return { code: 0, stdout: '', stderr: '' };
		return { code: 1, stdout: '', stderr: 'unexpected command' };
	};
	let mod = factory(
		C,
		fs,
		sys,
		observed_log,
		fake_run,
		() => ({ schema: 2 }),
		() => proxied,
		() => 10000000,
		() => fake_sha
	);

	// 1. Manifest + signature via download_manifest()
	let ctx = { root: folder, bin_dir: null, run_dir: folder, tmp_dir: `${folder}/tmp`, download_dir: dl_dir, keys_dir: `${folder}/keys` };
	let base = 'https://releases.example.test/channel';
	let mres = mod.download_manifest(ctx, base, proxied, 0);
	if (mres.manifest?.schema != 2) {
		fail(`T16.77 ${name} manifest download failed`);
		return;
	}
	let curl_calls = filter(calls, a => a[0] == 'curl');
	let expected_manifest_calls = proxied ? [
		[ `${base}/manifest.json`, `${dl_dir}/manifest-0.json`, true ],
		[ `${base}/manifest.json`, `${dl_dir}/manifest-0.json`, false ],
		[ `${base}/manifest.json.sig`, `${dl_dir}/manifest-0.json.sig`, true ],
		[ `${base}/manifest.json.sig`, `${dl_dir}/manifest-0.json.sig`, false ]
	] : [
		[ `${base}/manifest.json`, `${dl_dir}/manifest-0.json`, false ],
		[ `${base}/manifest.json.sig`, `${dl_dir}/manifest-0.json.sig`, false ]
	];
	if (length(curl_calls) != length(expected_manifest_calls)) {
		fail(`T16.77 ${name} manifest curl count: expected ${length(expected_manifest_calls)}, got ${length(curl_calls)}`);
		return;
	}
	let ok = true;
	for (let i = 0; i < length(expected_manifest_calls); i++) {
		let spec = expected_manifest_calls[i];
		if (!check_curl_argv(`T16.77 ${name} manifest[${i}]`, curl_calls[i], spec[0], spec[1], C.UPDATE_MANIFEST_MAX, spec[2]))
			ok = false;
	}
	if (ok)
		pass(`T16.77 ${name} manifest and signature argv`);

	// 2. Asset via download_asset()
	calls = [];
	let asset = { url: 'aether-proxy_1.0.0_aarch64_generic.ipk', size: length(payload), sha256: fake_sha };
	let ares = mod.download_asset({ sys_root: folder }, base, asset, asset.url);
	if (!ares.ok) {
		fail(`T16.77 ${name} asset download failed: ${ares.detail ?? ares.code}`);
		return;
	}
	curl_calls = filter(calls, a => a[0] == 'curl');
	let expected_temp = `${dl_dir}/${asset.url}.part`;
	let expected_url = `${base}/${asset.url}`;
	let expected_asset_calls = proxied ? [
		[ expected_url, expected_temp, true ],
		[ expected_url, expected_temp, false ]
	] : [
		[ expected_url, expected_temp, false ]
	];
	if (length(curl_calls) != length(expected_asset_calls)) {
		fail(`T16.77 ${name} asset curl count: expected ${length(expected_asset_calls)}, got ${length(curl_calls)}`);
		return;
	}
	ok = true;
	for (let i = 0; i < length(expected_asset_calls); i++) {
		let spec = expected_asset_calls[i];
		if (!check_curl_argv(`T16.77 ${name} asset[${i}]`, curl_calls[i], spec[0], spec[1], asset.size, spec[2]))
			ok = false;
	}
	if (ok)
		pass(`T16.77 ${name} asset argv`);
}

run_scenario('direct', false);
run_scenario('proxy-fallback', true);

if (failures > 0)
	die(`T16.77 protocol policy regressions failed: ${failures}`);
