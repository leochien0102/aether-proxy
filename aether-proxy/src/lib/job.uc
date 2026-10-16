'use strict';

// Long-running commands are detached as job workers; all job-file I/O lives here.

import * as fs from 'fs';
import * as C from 'aetherproxy.const';
import * as log from 'aetherproxy.log';
import * as sys from 'aetherproxy.sys';

const ENV_RUN_DIR = 'AETHER_PROXY_JOB_RUN_DIR';
const ENV_SYS_ROOT = 'AETHER_PROXY_JOB_SYS_ROOT';
const ENV_BIN_DIR = 'AETHER_PROXY_JOB_BIN_DIR';

function fs_error() {
	return fs.error() ?? 'unknown error';
}

function system_path(root, path) {
	return root == '' ? path : replace(root, /\/$/, '') + path;
}

function context(opts) {
	opts ??= {};
	let root = opts.sys_root ?? '';
	let bin_dir = opts.bin_dir ?? null;
	if (bin_dir == '')
		bin_dir = null;
	return {
		root,
		run_dir: opts.run_dir ?? system_path(root, C.RUN_DIR),
		bin_dir
	};
}

function jobs_dir(ctx) {
	return `${ctx.run_dir}/${C.JOBS_SUBDIR}`;
}

function job_path(ctx, id) {
	return `${jobs_dir(ctx)}/${id}${C.JOB_FILE_SUFFIX}`;
}

function report_fs(op, path, detail) {
	log.event('error', 'FS_FAILED', { op, path, detail });
}

function write_job(ctx, job) {
	let path = job_path(ctx, job.id);
	if (!sys.write_atomic(path, sprintf('%.J', job) + '\n')) {
		let detail = sys.error() ?? 'unknown error';
		report_fs('write', path, detail);
		return { ok: false, detail: `write ${path}: ${detail}` };
	}
	return { ok: true };
}

function read_job_file(path) {
	let text = fs.readfile(path);
	if (text == null) {
		let detail = fs_error();
		return { ok: false, missing: detail == 'No such file or directory', detail: `read ${path}: ${detail}` };
	}
	let job = null;
	try {
		job = json(text);
	}
	catch (e) {
		job = null;	// json() throws on bad input
	}
	if (type(job) != 'object')
		return { ok: false, corrupt: true, detail: `parse ${path}: expected a JSON object` };
	return { ok: true, job };
}

function valid_job_id(id) {
	return type(id) == 'string' && match(id, C.JOB_ID_RE) != null;
}

function current_pid() {
	let value = fs.readlink(`${C.PROC_DIR}/self`);
	return match(value ?? '', /^[0-9]+$/) == null ? null : +value;
}

// Process liveness uses the host procfs, not --sys-root's fixture tree.
function worker_alive(job) {
	let pid = job.pid;
	if (type(pid) == 'string' && match(pid, /^[0-9]+$/) != null)
		pid = +pid;
	if (type(pid) != 'int' || pid <= 0)
		return false;

	let cmdline_path = `${C.PROC_DIR}/${pid}/cmdline`;
	if (fs.stat(cmdline_path) == null) {
		let detail = fs_error();
		if (detail != 'No such file or directory')
			log.event('error', 'FS_FAILED', { op: 'stat', path: cmdline_path, detail });
		return false;
	}
	let fp = fs.open(cmdline_path, 'r');
	if (fp == null) {
		let detail = fs_error();
		if (detail != 'No such file or directory')
			log.event('error', 'FS_FAILED', { op: 'open', path: cmdline_path, detail });
		return false;
	}
	let cmdline = fp.read('all');
	let read_error = fs.error();
	let closed = fp.close();
	if (cmdline == null || !closed) {
		let detail = read_error ?? fs_error();
		log.event('error', 'FS_FAILED', { op: 'read', path: cmdline_path, detail });
		return false;
	}
	let argv = split(cmdline, '\x00');
	for (let i = 0; i + 1 < length(argv); i++)
		if (argv[i] == 'job' && argv[i + 1] == 'run')
			return true;
	return false;
};

function fail(code, detail, exit, extra) {
	return { ok: false, code, detail, exit, ...(extra ?? {}) };
}

function clean_old_jobs(ctx) {
	let dir = jobs_dir(ctx);
	if (!sys.mkdir_p(dir)) {
		let detail = sys.error() ?? 'unknown error';
		report_fs('mkdir', dir, detail);
		return { ok: false, detail: `cannot create ${dir}: ${detail}` };
	}
	let names = fs.lsdir(dir);
	if (names == null) {
		let detail = fs_error();
		report_fs('list', dir, detail);
		return { ok: false, detail: `cannot list ${dir}: ${detail}` };
	}
	let cutoff = time() - C.JOB_RETENTION_SECS;
	let retained = [];
	for (let name in sort(names)) {
		if (match(name, /\.json$/) == null)
			continue;
		let path = `${dir}/${name}`;
		let loaded = read_job_file(path);
		if (!loaded.ok && loaded.missing)
			continue;	// removed between lsdir and read (another start's cleanup)
		if (!loaded.ok && loaded.corrupt) {
			// Job files are written atomically, so a corrupt one is damage from outside and
			// carries no usable state: log and remove it instead of blocking every new job.
			report_fs('parse', path, loaded.detail);
			if (!fs.unlink(path))
				report_fs('unlink', path, fs_error());
			continue;
		}
		if (!loaded.ok) {
			report_fs('read', path, loaded.detail);
			return { ok: false, detail: loaded.detail };
		}
		if (type(loaded.job.finished) == 'int' && loaded.job.finished < cutoff && !fs.unlink(path)) {
			let detail = fs_error();
			report_fs('unlink', path, detail);
			return { ok: false, detail: `unlink ${path}: ${detail}` };
		}
		if (type(loaded.job.finished) != 'int' || loaded.job.finished >= cutoff)
			push(retained, name);
	}
	return { ok: true, names: retained };
}

function lock_kind(kind) {
	return substr(kind, 0, 7) == 'update_' ? 'update' : kind;
}

function find_busy(ctx, names, kind) {
	for (let name in names) {
		if (match(name, /\.json$/) == null)
			continue;
		let path = `${jobs_dir(ctx)}/${name}`;
		let loaded = read_job_file(path);
		if (!loaded.ok && (loaded.missing || loaded.corrupt))
			continue;	// gone, or already reported and removed by the cleanup scan
		if (!loaded.ok)
			return { error: loaded.detail, path };
		let job = loaded.job;
		if (lock_kind(job.kind) == kind && job.state == 'running' && worker_alive(job))
			return { job: job.id };
	}
	return null;
}

function kind_for(argv) {
	if (length(argv) >= 2 && argv[0] == 'probe' && argv[1] == 'nodes')
		return 'probe_nodes';
	if (length(argv) >= 2 && argv[0] == 'sub' && argv[1] == 'update')
		return 'sub_update';
	if (length(argv) >= 2 && argv[0] == 'update' && argv[1] == 'check')
		return 'update_check';
	if (length(argv) >= 2 && argv[0] == 'update' && argv[1] == 'data')
		return 'update_data';
	if (length(argv) >= 3 && argv[0] == 'update' && argv[1] == 'package')
		return 'update_package';
	return null;
}

function process_self(ctx) {
	return ctx.bin_dir == null ? C.PROG_EXEC : `${ctx.bin_dir}/${C.PROG}`;
}

function set_terminal(ctx, job, state, exit, error, result, detail) {
	job.state = state;
	job.finished = time();
	job.exit = exit;
	job.error = error;
	job.result = result;
	job.detail = detail;
	return write_job(ctx, job);
}

function launch_job(ctx, job) {
	let self = process_self(ctx);
	if (!fs.access(self, 'x')) {
		let detail = `${self} is not executable`;
		let saved = set_terminal(ctx, job, 'failed', 127, 'CMD_FAILED', null, detail);
		return saved.ok ? fail('CMD_FAILED', detail, 1) : fail('FS_FAILED', saved.detail, 1);
	}
	let script = join(' ', [
		`${ENV_RUN_DIR}="$1";`,
		`${ENV_SYS_ROOT}="$2";`,
		`${ENV_BIN_DIR}="$3";`,
		`export ${ENV_RUN_DIR} ${ENV_SYS_ROOT} ${ENV_BIN_DIR};`,
		'shift 3;',
		'"$@" </dev/null >/dev/null 2>&1 &',
		'printf "%s\\n" "$!"'
	]);
	let launched = sys.run([
		'sh', '-c', script, 'sh', ctx.run_dir, ctx.root, ctx.bin_dir ?? '',
		self, 'job', 'run', job.id
	], { timeout: 5 });
	if (launched.code != 0) {
		let detail = `sh background launch exited ${launched.code}: ${trim(launched.stderr)}`;
		let saved = set_terminal(ctx, job, 'failed', launched.code, 'CMD_FAILED', null, detail);
		return saved.ok ? fail('CMD_FAILED', detail, 1) : fail('FS_FAILED', saved.detail, 1);
	}
	let pid_text = trim(launched.stdout);
	if (match(pid_text, /^[0-9]+$/) == null) {
		let detail = `sh background launch returned invalid pid '${pid_text}'`;
		let saved = set_terminal(ctx, job, 'failed', launched.code, 'CMD_FAILED', null, detail);
		return saved.ok ? fail('CMD_FAILED', detail, 1) : fail('FS_FAILED', saved.detail, 1);
	}

	// The worker also records its own pid. Read the latest file to avoid overwriting a fast result.
	let loaded = read_job_file(job_path(ctx, job.id));
	if (!loaded.ok) {
		report_fs('read', job_path(ctx, job.id), loaded.detail);
		return fail('FS_FAILED', loaded.detail, 1);
	}
	if (loaded.job.state == 'running' && loaded.job.pid == null) {
		loaded.job.pid = +pid_text;
		let saved = write_job(ctx, loaded.job);
		if (!saved.ok)
			return fail('FS_FAILED', saved.detail, 1);
	}
	return { ok: true, job: job.id, exit: 0 };
}

// start(argv, opts) accepts only the two long-running command families documented in 10.
export function start(argv, opts) {
	let kind = kind_for(argv);
	if (kind == null)
		return fail('USAGE', 'unsupported job command', 2);
	let ctx = context(opts);
	log.set_run_dir(ctx.run_dir);
	let listed = clean_old_jobs(ctx);
	if (!listed.ok)
		return fail('FS_FAILED', listed.detail, 1);
	let busy = find_busy(ctx, listed.names, lock_kind(kind));
	if (busy?.error != null) {
		report_fs('read', busy.path, busy.error);
		return fail('FS_FAILED', busy.error, 1);
	}
	if (busy?.job != null) {
		log.event('warn', 'BUSY', { holder: `job_${kind}` });
		return fail('BUSY', `job kind ${kind} is already running`, 3, { job: busy.job });
	}

	let pid = current_pid();
	if (pid == null)
		return fail('FS_FAILED', `cannot read numeric pid from ${C.PROC_DIR}/self`, 1);
	let started = time();
	let id = `j_${started}_${pid}`;
	let path = job_path(ctx, id);
	if (fs.stat(path) != null) {
		// One start per process, so seconds+pid cannot repeat in practice; never overwrite.
		return fail('FS_FAILED', `job ID collision at ${path}`, 1);
	}
	let stat_error = fs_error();
	if (stat_error != 'No such file or directory') {
		report_fs('stat', path, stat_error);
		return fail('FS_FAILED', `stat ${path}: ${stat_error}`, 1);
	}
	let job = {
		id,
		kind,
		cmd: join(' ', slice(argv, 0, 2)),
		argv: [ ...argv ],
		state: 'running',
		pid: null,
		started,
		finished: null,
		exit: null,
		result: null,
		error: null,
		detail: null
	};
	let saved = write_job(ctx, job);
	if (!saved.ok)
		return fail('FS_FAILED', saved.detail, 1);
	return launch_job(ctx, job);
};

export function status(id, opts) {
	let ctx = context(opts);
	log.set_run_dir(ctx.run_dir);
	if (!valid_job_id(id))
		return fail('USAGE', 'job ID must match j_<seconds>_<pid>', 2);
	let path = job_path(ctx, id);
	let loaded = read_job_file(path);
	if (!loaded.ok) {
		if (loaded.missing)
			return fail('JOB_NOT_FOUND', `job '${id}' does not exist`, 2);
		report_fs('read', path, loaded.detail);
		return fail('FS_FAILED', loaded.detail, 1);
	}
	let job = loaded.job;
	if (job.state == 'running' && !worker_alive(job)) {
		job.state = 'failed';
		job.finished = time();
		job.exit = null;
		job.error = 'JOB_LOST';
		job.result = null;
		job.detail = null;
		log.event('warn', 'JOB_LOST', { job: id, kind: job.kind ?? '-' });
		let saved = write_job(ctx, job);
		if (!saved.ok)
			return fail('FS_FAILED', saved.detail, 1);
	}
	return { ok: true, job, exit: 0 };
};

function worker_context() {
	return context({
		run_dir: getenv(ENV_RUN_DIR),
		sys_root: getenv(ENV_SYS_ROOT),
		bin_dir: getenv(ENV_BIN_DIR)
	});
};

export function run_worker(id) {
	let ctx = worker_context();
	log.set_run_dir(ctx.run_dir);
	if (!valid_job_id(id))
		return 2;
	let path = job_path(ctx, id);
	let loaded = read_job_file(path);
	if (!loaded.ok) {
		report_fs('read', path, loaded.detail);
		return 1;
	}
	let job = loaded.job;
	if (job.state != 'running' || kind_for(job.argv ?? []) == null || kind_for(job.argv) != job.kind)
		return 1;
	let pid = current_pid();
	if (pid == null)
		return 1;
	job.pid = pid;
	let saved = write_job(ctx, job);
	if (!saved.ok)
		return 1;

	let lock_path = system_path(ctx.root, `${C.JOB_LOCK_PREFIX}${lock_kind(job.kind)}${C.JOB_LOCK_SUFFIX}`);
	let lock = sys.lock(lock_path);
	if (lock == null) {
		let detail = sys.error() ?? 'cannot acquire kind lock';
		log.event('warn', 'BUSY', { holder: `job_${job.kind}` });
		let latest = read_job_file(path);
		if (latest.ok) {
			latest.job.pid = pid;
			let saved = set_terminal(ctx, latest.job, 'failed', 3, 'BUSY', null, detail);
			if (!saved.ok)
				return 1;
		}
		else {
			report_fs('read', path, latest.detail);
			return 1;
		}
		return 0;
	}

	let executable = process_self(ctx);
	let argv = [ executable, ...job.argv ];
	if (index(job.argv, '--json') < 0)
		push(argv, '--json');
	let ran = sys.run(argv, { timeout: C.JOB_TIMEOUT_SECS });
	let parsed = null, parse_error = null;
	try {
		parsed = json(ran.stdout);
	}
	catch (e) {
		parse_error = e.message ?? `${e}`;
	}
	let valid_result = type(parsed) == 'object';
	let state = ran.code == 0 && valid_result ? 'ok' : 'failed';
	let error = null, result = valid_result ? parsed : null, detail = null;
	if (!valid_result) {
		error = 'CMD_FAILED';
		detail = length(ran.stdout) ? substr(ran.stdout, 0, 200) : `child produced no JSON (exit ${ran.code})`;
		log.event('error', 'CMD_FAILED', {
			cmd: join(' ', argv), rc: ran.code,
			stderr: parse_error ?? 'child stdout is not a JSON object'
		});
	}
	else if (ran.code != 0) {
		error = type(parsed.code) == 'string' ? parsed.code : null;
		// sub update reports per subscription; surface the first failing code (by name).
		if (error == null && type(parsed.subs) == 'object')
			for (let name in sort(keys(parsed.subs)))
				if (type(parsed.subs[name]) == 'object' && parsed.subs[name].ok == false && type(parsed.subs[name].code) == 'string') {
					error = parsed.subs[name].code;
					break;
				}
		error ??= 'CMD_FAILED';
	}
	let finished = read_job_file(path);
	if (!finished.ok) {
		report_fs('read', path, finished.detail);
		lock.close();
		return 1;
	}
	finished.job.pid = pid;
	let outcome = set_terminal(ctx, finished.job, state, ran.code, error, result, detail);
	lock.close();
	return outcome.ok ? 0 : 1;
};
