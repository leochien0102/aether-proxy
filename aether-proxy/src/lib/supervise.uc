'use strict';
// Supervise child lifetimes, crash backoff and shutdown; clean up matching stale children.
// Design: docs/04「进程模型（已定）」 and docs/09「子进程日志（S1 已定，2026-10-15）」.

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as C from 'aetherproxy.const';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';

function pid_path(run_dir, name) {
	return `${run_dir}/${name}.pid`;
};

function unlink_pid(path) {
	if (fs.stat(path) != null && !fs.unlink(path))
		log.event('error', 'START_FAILED', { step: 'supervise', detail: `cannot remove ${path}: ${fs.error() ?? 'unknown error'}` });
};

function fifo_path(run_dir, name) {
	return `${run_dir}/${name}${C.CHILD_LOG_FIFO_SUFFIX}`;
};

function remove_fifo(path) {
	if (fs.lstat(path) != null && !fs.unlink(path)) {
		let detail = fs.error() ?? 'unknown error';
		log.event('error', 'FS_FAILED', { op: 'unlink', path, detail });
		return { ok: false, detail };
	}
	return { ok: true };
};

function filtered_argv(opts, path) {
	// Never interpolate names, paths or child arguments into shell source. exec keeps
	// uloop's pid and exit status attached to the actual service, not a shell wrapper.
	let removed = remove_fifo(path);
	let made = removed.ok ? sys.run([ 'mkfifo', '-m', '0600', path ], { quiet: true }) : null;
	if (made == null || made.code != 0) {
		log.event('error', 'FS_FAILED', {
			op: 'mkfifo', path, detail: removed.ok ? `mkfifo failed (${made.code}): ${made.stderr}` : removed.detail
		});
		return opts.argv;
	}
	// Host suites run uninstalled sources; production always uses the packaged path.
	let filter = getenv(C.CHILD_LOG_FILTER_TEST_ENV) ?? C.CHILD_LOG_FILTER;
	return [ '/bin/sh', '-c',
		'fifo=$3; awk -v name="$1" -f "$2" <"$fifo" & shift 3; exec "$@" >"$fifo" 2>&1',
		'aether-proxy-logfilter', opts.name, filter, path, ...opts.argv ];
};

function process_exists(pid) {
	return pid != null && fs.stat(`${C.PROC_DIR}/${pid}`) != null;
};

function emit(callback, kind, info) {
	if (callback)
		callback(kind, info);
};

function kill_process(pid, signal) {
	return sys.run([ 'kill', `-${signal}`, `${pid}` ]);
};

function create(opts) {
	if (type(opts) != 'object' || !opts.name || type(opts.argv) != 'array' || !length(opts.argv) ||
	    !opts.run_dir || type(opts.backoff) != 'array' || !length(opts.backoff))
		die('supervise.create: name, argv, run_dir and non-empty backoff are required');

	let cb = opts.on_event;
	let pidfile = pid_path(opts.run_dir, opts.name);
	let fifo = fifo_path(opts.run_dir, opts.name);
	let delays = map(opts.backoff, d => max(+d, 0));
	let stable_secs = max(+(opts.stable_secs ?? 300), 0);
	let proc = null, pid = null, stopping = false, restart_index = 0, done_cb = null;
	let restart_timer = null, stop_timer = null, stable_timer = null;
	let on_exit = null, force_stop = null;

	function start_child() {
		if (proc != null || stopping)
			return;

		if (!sys.mkdir_p(opts.run_dir)) {
			log.event('error', 'START_FAILED', { step: 'supervise', detail: `cannot create ${opts.run_dir}: ${sys.error()}` });
			return;
		}

		// A separate reader avoids the stdio buffering trap of popen + uloop.handle (09).
		let argv = filtered_argv(opts, fifo);
		proc = uloop.process(argv[0], slice(argv, 1), null, on_exit);
		if (proc == null) {
			remove_fifo(fifo);
			log.event('error', 'START_FAILED', { step: 'supervise', detail: `cannot start ${opts.name}` });
			return;
		}

		pid = proc.pid();
		if (!sys.write_atomic(pidfile, `${pid}\n`)) {
			log.event('error', 'START_FAILED', { step: 'supervise', detail: `cannot write ${pidfile}: ${sys.error()}` });
			stopping = true;
			kill_process(pid, 'TERM');
			stop_timer = uloop.timer(C.SUPERVISE_TERM_GRACE_MS, force_stop);
			return;
		}

		log.event('info', 'CHILD_STARTED', { name: opts.name, pid });
		emit(cb, 'started', { name: opts.name, pid });
		if (stable_timer != null)
			stable_timer.cancel();
		stable_timer = uloop.timer(stable_secs * 1000, () => { restart_index = 0; stable_timer = null; });
	};

	function finish_stop(exited_pid) {
		stopping = false;
		let done = done_cb;
		done_cb = null;
		emit(cb, 'exited', { name: opts.name, pid: exited_pid });
		if (done)
			done();
	};

	force_stop = () => {
		stop_timer = null;
		if (proc != null && process_exists(pid))
			kill_process(pid, 'KILL');
	};

	on_exit = code => {
		let exited_pid = pid;
		proc = null;
		pid = null;
		if (stop_timer != null)
			stop_timer.cancel();
		stop_timer = null;
		if (stable_timer != null)
			stable_timer.cancel();
		stable_timer = null;
		unlink_pid(pidfile);
		remove_fifo(fifo);

		// A signal-terminated child can report exit code zero, so code alone cannot distinguish
		// intentional shutdown from a crash (docs/09「子进程日志（S1 已定，2026-10-15）」).
		if (stopping) {
			finish_stop(exited_pid);
			return;
		}

		let delay = delays[min(restart_index, length(delays) - 1)];
		restart_index = min(restart_index + 1, length(delays) - 1);
		let info = { name: opts.name, pid: exited_pid, code, restart_in: delay };
		log.event('warn', 'CHILD_CRASHED', info);
		restart_timer = uloop.timer(delay * 1000, () => {
			restart_timer = null;
			emit(cb, 'restarting', { name: opts.name, restart_in: delay });
			start_child();
		});
		emit(cb, 'crashed', info);
	};

	function start() {
		if (proc != null || restart_timer != null || stopping)
			return;
		stopping = false;
		start_child();
	};

	function stop(done) {
		// Cancel a pending crash restart before stopping, or shutdown could spawn a new child.
		if (restart_timer != null)
			restart_timer.cancel();
		restart_timer = null;
		if (stable_timer != null)
			stable_timer.cancel();
		stable_timer = null;
		stopping = true;
		done_cb = done;
		if (proc == null) {
			unlink_pid(pidfile);
			remove_fifo(fifo);
			finish_stop(pid);
			return;
		}
		kill_process(pid, 'TERM');
		stop_timer = uloop.timer(C.SUPERVISE_TERM_GRACE_MS, force_stop);
	};

	return {
		start,
		stop,
		running: () => proc != null && process_exists(pid),
		pid: () => pid
	};
};

function kill_stale(run_dir, name, command_match) {
	// cleanup must remove even a FIFO whose child died before writing its pid file.
	let removed = remove_fifo(fifo_path(run_dir, name));
	if (!removed.ok)
		return removed;
	let path = pid_path(run_dir, name);
	if (type(command_match) != 'string' || command_match == '')
		return { ok: false, detail: 'command match must be non-empty' };

	let value = fs.readfile(path);
	if (value == null && fs.stat(path) == null)
		return { ok: true, detail: 'pid file absent' };
	if (value == null)
		return { ok: false, detail: `cannot read ${path}: ${fs.error() ?? 'unknown error'}` };

	let text = trim(value);
	if (match(text, /^[0-9]+$/) == null)
		return { ok: false, detail: `invalid pid in ${path}` };

	let pid = +text;
	let proc_path = `${C.PROC_DIR}/${pid}`;
	let cmdline = fs.readfile(`${proc_path}/cmdline`);
	// Gone, or the pid now belongs to someone else: not ours to kill (04), and the pid file
	// is stale either way. Treating this as a failure blocked every later cleanup and start.
	if (cmdline == null || index(cmdline, command_match) < 0) {
		unlink_pid(path);
		return { ok: true, detail: `stale pid file removed (pid ${pid} is not ${command_match})` };
	}

	let term = kill_process(pid, 'TERM');
	if (term.code != 0)
		return { ok: false, detail: `kill -TERM failed (${term.code})` };

	let wait = sys.run([ 'sleep', '1' ], { quiet: true });
	if (wait.code != 0)
		return { ok: false, detail: `sleep failed (${wait.code})` };

	if (process_exists(pid)) {
		cmdline = fs.readfile(`${proc_path}/cmdline`);
		if (cmdline != null && index(cmdline, command_match) >= 0) {
			let force = kill_process(pid, 'KILL');
			if (force.code != 0) {
				cmdline = fs.readfile(`${proc_path}/cmdline`);
				if (cmdline != null && index(cmdline, command_match) >= 0)
					return { ok: false, detail: `kill -KILL failed (${force.code})` };
			}
		}
	}

	unlink_pid(path);
	return { ok: true, detail: 'stale process stopped' };
};

export { create, kill_stale };
