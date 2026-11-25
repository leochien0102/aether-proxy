'use strict';

// T16.83: per-invocation private temporary capture directory for sys.run.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const PREFIX = ROOT + '/tests/host/prefix';
const UCODE_BIN = PREFIX + '/bin/ucode';
const UCODE_LIB = PREFIX + '/lib';
const LIB_DIR = ROOT + '/aether-proxy/src/lib';

export const cases = [
	{
		name: 'loose umask keeps private dir inaccessible to others and preserves child umask (no timeout)',
		expect: 'PASS',
		kind: 'inflight',
		with_timeout: false
	},
	{
		name: 'loose umask keeps private dir and timer handshake files private (with timeout)',
		expect: 'PASS',
		kind: 'inflight',
		with_timeout: true
	},
	{
		name: 'concurrent calls use distinct private dirs without stdout/stderr crosstalk',
		expect: 'PASS',
		kind: 'concurrent'
	},
	{
		name: 'return contract unchanged for success, nonzero, real timeout, and exit 124',
		expect: 'PASS',
		kind: 'contracts'
	},
	{
		name: 'directory creation failure does not start target or fall back to old paths',
		expect: 'PASS',
		kind: 'mkdir_fail'
	},
	{
		name: 'cleanup removes only owned files and preserves sibling sentinels',
		expect: 'PASS',
		kind: 'sentinels'
	}
];

function failed(detail) {
	return 'FAIL: ' + detail;
}

function with_sandbox(tag, fn) {
	let pid = fs.readlink('/proc/self') ?? 'x';
	let base = `/tmp/aether-proxy-t1683-${tag}-${pid}`;
	sys.run([ 'rm', '-rf', base ], { quiet: true });
	if (!fs.mkdir(base, 0700))
		die(`cannot create sandbox ${base}: ${fs.error() ?? 'unknown error'}`);
	let tmp_root = `${base}/tmp`;
	if (!fs.mkdir(tmp_root, 0700))
		die(`cannot create tmp_root ${tmp_root}: ${fs.error() ?? 'unknown error'}`);

	let res = null;
	let err = null;
	try {
		res = fn({ base, tmp_root });
	}
	catch (e) {
		err = e;
	}
	let ro = `${base}/ro-tmp`;
	if (fs.lstat(ro) != null)
		fs.chmod(ro, 0700);
	sys.run([ 'rm', '-rf', base ], { quiet: true });
	if (err != null)
		die(`${err}`);
	return res;
}

function build_modules(base, tmp_dir) {
	let mod_root = `${base}/modules`;
	let pkg_dir = `${mod_root}/aetherproxy`;
	if (!fs.mkdir(mod_root, 0700) || !fs.mkdir(pkg_dir, 0700))
		die(`cannot create module dir ${pkg_dir}: ${fs.error() ?? 'unknown error'}`);

	for (let entry in fs.lsdir(LIB_DIR) ?? []) {
		if (entry == 'const.uc')
			continue;
		let src = `${LIB_DIR}/${entry}`;
		let dst = `${pkg_dir}/${entry}`;
		if (!fs.symlink(src, dst))
			die(`cannot symlink ${src} -> ${dst}: ${fs.error() ?? 'unknown error'}`);
	}

	let const_src = fs.readfile(`${LIB_DIR}/const.uc`);
	if (const_src == null)
		die('cannot read const.uc');
	let patched = replace(const_src, /export const TMP_DIR = '[^']+';/, `export const TMP_DIR = '${tmp_dir}';`);
	if (patched == const_src)
		die('failed to patch TMP_DIR in const.uc');
	if (fs.writefile(`${pkg_dir}/const.uc`, patched) == null)
		die('cannot write patched const.uc');

	return mod_root;
}

function plant_sentinels(tmp_root) {
	let sentinels = {
		'sentinel.txt': 'keep-plain\n',
		'aether-proxy-run.sentinel': 'keep-run\n',
		'aether-proxy-sys.sentinel': 'keep-sys\n',
		'aether-proxy-run.999999.1': 'keep-legacy-shape\n'
	};
	for (let name in keys(sentinels)) {
		if (fs.writefile(`${tmp_root}/${name}`, sentinels[name]) == null)
			die(`cannot write sentinel ${name}`);
	}
	let other_dir = `${tmp_root}/aether-proxy-run.otherdir`;
	if (!fs.mkdir(other_dir, 0700) || fs.writefile(`${other_dir}/keep.txt`, 'keep-nested\n') == null)
		die('cannot create nested sentinel');
	return sentinels;
}

function check_sentinels_and_clean(tmp_root, sentinels) {
	let expected = sort([ ...keys(sentinels), 'aether-proxy-run.otherdir' ]);
	let actual = sort(fs.lsdir(tmp_root) ?? []);
	if (sprintf('%.J', actual) != sprintf('%.J', expected))
		return `tmp_root entries mismatch: expected ${sprintf('%.J', expected)}, got ${sprintf('%.J', actual)}`;
	for (let name in keys(sentinels)) {
		let got = fs.readfile(`${tmp_root}/${name}`);
		if (got != sentinels[name])
			return `sentinel ${name} modified: ${sprintf('%.J', got)}`;
	}
	let nested = fs.readfile(`${tmp_root}/aether-proxy-run.otherdir/keep.txt`);
	if (nested != 'keep-nested\n')
		return `nested sentinel modified: ${sprintf('%.J', nested)}`;
	return null;
}

function run_isolated_ucode(mod_root, code, umask_val) {
	let script = `umask ${umask_val}; LD_LIBRARY_PATH="$1" exec "$2" -L "$3/*.uc" -L "$3/*/*.uc" -L "$4/ucode/*.so" -e "$5"`;
	return sys.run([ 'sh', '-c', script, 'sh', UCODE_LIB, UCODE_BIN, mod_root, UCODE_LIB, code ], { quiet: true, timeout: 15 });
}

function inflight_case(with_timeout) {
	return with_sandbox(with_timeout ? 'inflight-to' : 'inflight-no', sb => {
		let sentinels = plant_sentinels(sb.tmp_root);
		let mod_root = build_modules(sb.base, sb.tmp_root);
		let obs_path = `${sb.base}/obs.txt`;

		// Target command runs under loose umask 0000 and inspects its own umask,
		// stdout/stderr targets, and the isolated tmp_root while sys.run is active.
		let probe_sh = join('\n', [
			'obs="$1"; root="$2"',
			'u=$(umask)',
			'fd1=$(readlink -f /proc/$$/fd/1)',
			'fd2=$(readlink -f /proc/$$/fd/2)',
			'dir1=$(dirname "$fd1")',
			'dir2=$(dirname "$fd2")',
			'mode1=$(stat -c "%a" "$dir1" 2>/dev/null || echo ERR)',
			'f1mode=$(stat -c "%a" "$fd1" 2>/dev/null || echo ERR)',
			'entries=$(ls -1A "$root" | sort | tr "\\n" ",")',
			'inner=$(ls -1A "$dir1" 2>/dev/null | sort | tr "\\n" ",")',
			'printf "%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n%s\\n" "$u" "$fd1" "$fd2" "$dir1" "$dir2" "$mode1" "$f1mode" "$entries" "$inner" >"$obs"',
			'printf "hello-out\\n"',
			'printf "hello-err\\n" >&2'
		]);

		let opts_lit = with_timeout ? '{ timeout: 5, quiet: true }' : '{ quiet: true }';
		let uc = "import * as sys from 'aetherproxy.sys'; " +
			`let r = sys.run([ 'sh', '-c', ${sprintf('%.J', probe_sh)}, 'sh', ${sprintf('%.J', obs_path)}, ${sprintf('%.J', sb.tmp_root)} ], ${opts_lit}); ` +
			"print(sprintf('%.J', r));";

		let child = run_isolated_ucode(mod_root, uc, '0000');
		if (child.code != 0)
			return failed(`isolated ucode failed: ${sprintf('%.J', child)}`);

		let r = json(child.stdout);
		if (r.code != 0 || r.timed_out || r.stdout != 'hello-out\n' || r.stderr != 'hello-err\n')
			return failed(`unexpected sys.run result: ${sprintf('%.J', r)}`);

		let raw = fs.readfile(obs_path);
		if (raw == null)
			return failed('missing in-flight observation file');
		let lines = split(raw, '\n');
		let child_umask = lines[0], fd1 = lines[1], fd2 = lines[2], dir1 = lines[3], dir2 = lines[4],
			mode1 = lines[5], f1mode = lines[6], entries = lines[7], inner = lines[8];

		if (child_umask != '0000')
			return failed(`target inherited umask changed: got ${child_umask}, want 0000`);
		if (dir1 != dir2)
			return failed(`stdout and stderr not in same dir: ${fd1} vs ${fd2}`);
		if (dir1 == sb.tmp_root || index(dir1, sb.tmp_root + '/') != 0)
			return failed(`capture files not in private subdir of tmp_root: fd1=${fd1} (mode ${f1mode}), fd2=${fd2}, entries=${entries}`);
		if (mode1 != '700')
			return failed(`private dir mode is ${mode1}, want 700 (dir=${dir1})`);

		let base_name = fs.basename(dir1);
		let expected_entries = join(',', sort([ ...keys(sentinels), 'aether-proxy-run.otherdir', base_name ])) + ',';
		if (entries != expected_entries)
			return failed(`loose files in tmp_root during run: got ${entries}, want ${expected_entries}`);

		let inner_list = filter(split(inner, ','), x => x != '');
		let required = with_timeout ? [ 'stdout', 'stderr', 'wrapper', 'sleep', 'grace' ] : [ 'stdout', 'stderr', 'wrapper' ];
		for (let req in required) {
			if (index(inner_list, req) < 0)
				return failed(`expected ${req} inside private dir ${dir1}, got ${inner}`);
		}

		let clean_err = check_sentinels_and_clean(sb.tmp_root, sentinels);
		if (clean_err)
			return failed(clean_err);

		return 'PASS';
	});
}

function concurrent_case() {
	return with_sandbox('concurrent', sb => {
		let sentinels = plant_sentinels(sb.tmp_root);
		let mod_root = build_modules(sb.base, sb.tmp_root);
		let n = 4;
		let ready_dir = `${sb.base}/ready`;
		let go_file = `${sb.base}/go`;
		fs.mkdir(ready_dir, 0700);

		let target_sh = join('\n', [
			'id="$1"; ready_dir="$2"; go_file="$3"; meta="$4"',
			'fd1=$(readlink -f /proc/$$/fd/1)',
			'fd2=$(readlink -f /proc/$$/fd/2)',
			'dir1=$(dirname "$fd1")',
			'dir2=$(dirname "$fd2")',
			'mode1=$(stat -c "%a" "$dir1" 2>/dev/null || echo ERR)',
			'printf "%s\\n%s\\n%s\\n" "$dir1" "$dir2" "$mode1" >"$meta"',
			': >"$ready_dir/$id"',
			'i=0; while [ ! -f "$go_file" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done',
			'printf "OUT-%s-LINE1\\nOUT-%s-LINE2\\n" "$id" "$id"',
			'printf "ERR-%s-LINE1\\nERR-%s-LINE2\\n" "$id" "$id" >&2'
		]);

		let driver_lines = [
			'umask 0000',
			`LD_LIBRARY_PATH=${sprintf("'%s'", UCODE_LIB)}`,
			'export LD_LIBRARY_PATH',
			'pids=""'
		];
		for (let i = 0; i < n; i++) {
			let res_file = `${sb.base}/res.${i}.json`;
			let meta_file = `${sb.base}/meta.${i}.txt`;
			let opts_lit = (i % 2 == 1) ? '{ timeout: 10, quiet: true }' : '{ quiet: true }';
			let uc = "import * as sys from 'aetherproxy.sys'; import * as fs from 'fs'; " +
				`let r = sys.run([ 'sh', '-c', ${sprintf('%.J', target_sh)}, 'sh', '${i}', ${sprintf('%.J', ready_dir)}, ${sprintf('%.J', go_file)}, ${sprintf('%.J', meta_file)} ], ${opts_lit}); ` +
				`fs.writefile(${sprintf('%.J', res_file)}, sprintf('%.J', r));`;
			let uc_file = `${sb.base}/worker.${i}.uc`;
			fs.writefile(uc_file, uc);
			push(driver_lines, `"$1" -L "$2/*.uc" -L "$2/*/*.uc" -L "$3/ucode/*.so" "${uc_file}" & pids="$pids $!"`);
		}
		push(driver_lines,
			`w=0; while [ "$(ls -1A ${sprintf("'%s'", ready_dir)} | wc -l)" -lt ${n} ] && [ "$w" -lt 100 ]; do sleep 0.05; w=$((w + 1)); done`,
			`: >${sprintf("'%s'", go_file)}`,
			'rc=0; for p in $pids; do wait "$p" || rc=1; done; exit $rc'
		);

		let drv = sys.run([ 'sh', '-c', join('\n', driver_lines), 'sh', UCODE_BIN, mod_root, UCODE_LIB ], { quiet: true, timeout: 20 });
		if (drv.code != 0)
			return failed(`concurrent driver failed: ${sprintf('%.J', drv)}`);

		let seen_dirs = {};
		for (let i = 0; i < n; i++) {
			let r_raw = fs.readfile(`${sb.base}/res.${i}.json`);
			let m_raw = fs.readfile(`${sb.base}/meta.${i}.txt`);
			if (r_raw == null || m_raw == null)
				return failed(`missing output for worker ${i}`);
			let r = json(r_raw);
			let m = split(m_raw, '\n');
			let dir1 = m[0], dir2 = m[1], mode1 = m[2];
			if (dir1 != dir2 || dir1 == sb.tmp_root || index(dir1, sb.tmp_root + '/') != 0)
				return failed(`worker ${i} not in private subdir: ${dir1} / ${dir2}`);
			if (mode1 != '700')
				return failed(`worker ${i} private dir mode ${mode1}, want 700`);
			if (seen_dirs[dir1])
				return failed(`concurrent workers shared dir ${dir1}`);
			seen_dirs[dir1] = true;

			let want_out = `OUT-${i}-LINE1\nOUT-${i}-LINE2\n`;
			let want_err = `ERR-${i}-LINE1\nERR-${i}-LINE2\n`;
			if (r.code != 0 || r.timed_out || r.stdout != want_out || r.stderr != want_err)
				return failed(`worker ${i} crosstalk or bad result: ${sprintf('%.J', r)}`);
		}

		let clean_err = check_sentinels_and_clean(sb.tmp_root, sentinels);
		if (clean_err)
			return failed(clean_err);

		return 'PASS';
	});
}

function contracts_case() {
	return with_sandbox('contracts', sb => {
		let sentinels = plant_sentinels(sb.tmp_root);
		let mod_root = build_modules(sb.base, sb.tmp_root);

		let uc = join('\n', [
			"import * as sys from 'aetherproxy.sys';",
			'let results = {',
			"  ok: sys.run([ 'sh', '-c', 'printf out-ok; printf err-ok >&2; exit 0' ], { quiet: true }),",
			"  nz: sys.run([ 'sh', '-c', 'printf out-nz; printf err-nz >&2; exit 7' ], { quiet: true }),",
			"  to: sys.run([ 'sh', '-c', 'printf out-to; printf err-to >&2; sleep 5' ], { timeout: 1, quiet: true }),",
			"  e124: sys.run([ 'sh', '-c', 'printf out-124; printf err-124 >&2; exit 124' ], { timeout: 5, quiet: true })",
			'};',
			"print(sprintf('%.J', results));"
		]);

		let child = run_isolated_ucode(mod_root, uc, '0000');
		if (child.code != 0)
			return failed(`contracts runner failed: ${sprintf('%.J', child)}`);

		let res = json(child.stdout);
		if (res.ok.code != 0 || res.ok.timed_out || res.ok.stdout != 'out-ok' || res.ok.stderr != 'err-ok')
			return failed(`success contract broken: ${sprintf('%.J', res.ok)}`);
		if (res.nz.code != 7 || res.nz.timed_out || res.nz.stdout != 'out-nz' || res.nz.stderr != 'err-nz')
			return failed(`nonzero contract broken: ${sprintf('%.J', res.nz)}`);
		if (res.to.code != 124 || !res.to.timed_out || res.to.stdout != 'out-to' || index(res.to.stderr, 'err-to') < 0)
			return failed(`timeout contract broken: ${sprintf('%.J', res.to)}`);
		if (res.e124.code != 124 || res.e124.timed_out || res.e124.stdout != 'out-124' || res.e124.stderr != 'err-124')
			return failed(`exit 124 contract broken: ${sprintf('%.J', res.e124)}`);

		let clean_err = check_sentinels_and_clean(sb.tmp_root, sentinels);
		if (clean_err)
			return failed(clean_err);

		return 'PASS';
	});
}

function mkdir_fail_case() {
	return with_sandbox('mkdir-fail', sb => {
		let not_a_dir = `${sb.base}/not-a-dir`;
		fs.writefile(not_a_dir, 'file\n');
		let missing = `${sb.base}/missing-tmp`;
		let ro_dir = `${sb.base}/ro-tmp`;
		fs.mkdir(ro_dir, 0500);

		let bad_roots = [
			{ label: 'missing', path: missing },
			{ label: 'not-a-dir', path: not_a_dir }
		];
		// Read-only dir fails with EACCES for non-root; root bypasses DAC.
		let id_r = sys.run([ 'id', '-u' ], { quiet: true });
		if (id_r.code == 0 && trim(id_r.stdout) != '0')
			push(bad_roots, { label: 'readonly', path: ro_dir });

		for (let item in bad_roots) {
			let sub = `${sb.base}/case-${item.label}`;
			fs.mkdir(sub, 0700);
			let mod_root = build_modules(sub, item.path);
			let marker = `${sub}/target-ran`;

			let before_tmp = sort(fs.glob('/tmp/aether-proxy-run.*') ?? []);
			let before_sys = sort(fs.glob('/tmp/aether-proxy-sys.*') ?? []);

			let uc = "import * as sys from 'aetherproxy.sys'; " +
				`let r = sys.run([ 'sh', '-c', 'printf ran >"$1"; echo SHOULD_NOT_RUN', 'sh', ${sprintf('%.J', marker)} ], { timeout: 5, quiet: true }); ` +
				"print(sprintf('%.J', r));";

			let child = run_isolated_ucode(mod_root, uc, '0000');
			if (child.code != 0)
				return failed(`${item.label}: runner failed: ${sprintf('%.J', child)}`);

			let r = json(child.stdout);
			if (r.code != -1 || r.timed_out || r.stdout != '' || r.stderr == '')
				return failed(`${item.label}: unexpected result ${sprintf('%.J', r)}`);
			if (fs.lstat(marker) != null)
				return failed(`${item.label}: target command was started despite mkdir failure`);

			let after_tmp = sort(fs.glob('/tmp/aether-proxy-run.*') ?? []);
			let after_sys = sort(fs.glob('/tmp/aether-proxy-sys.*') ?? []);
			if (sprintf('%.J', after_tmp) != sprintf('%.J', before_tmp) || sprintf('%.J', after_sys) != sprintf('%.J', before_sys))
				return failed(`${item.label}: fell back to /tmp public paths`);
		}

		return 'PASS';
	});
}

function sentinels_case() {
	return with_sandbox('sentinels', sb => {
		let sentinels = plant_sentinels(sb.tmp_root);
		let mod_root = build_modules(sb.base, sb.tmp_root);

		let uc = join('\n', [
			"import * as sys from 'aetherproxy.sys';",
			"let a = sys.run([ 'sh', '-c', 'echo a; echo ea >&2' ], { quiet: true });",
			"let b = sys.run([ 'sh', '-c', 'echo b; echo eb >&2; exit 2' ], { timeout: 5, quiet: true });",
			"print(sprintf('%.J', { a, b }));"
		]);

		let child = run_isolated_ucode(mod_root, uc, '0000');
		if (child.code != 0)
			return failed(`sentinels runner failed: ${sprintf('%.J', child)}`);

		let res = json(child.stdout);
		if (res.a.code != 0 || res.b.code != 2)
			return failed(`unexpected sentinel run results: ${sprintf('%.J', res)}`);

		let clean_err = check_sentinels_and_clean(sb.tmp_root, sentinels);
		if (clean_err)
			return failed(clean_err);

		return 'PASS';
	});
}

export function run(c) {
	if (c.kind == 'inflight')
		return inflight_case(c.with_timeout);
	if (c.kind == 'concurrent')
		return concurrent_case();
	if (c.kind == 'contracts')
		return contracts_case();
	if (c.kind == 'mkdir_fail')
		return mkdir_fail_case();
	if (c.kind == 'sentinels')
		return sentinels_case();
	return failed('unknown test kind');
};
