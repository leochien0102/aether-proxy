'use strict';
// Adapt job start/status and the internal worker command to the background-job implementation.
// Design: docs/10「作业机制」; long work stays outside the rpcd request lifetime.

import * as job from 'aetherproxy.job';
import * as pipeline from 'aetherproxy.pipeline';

const USAGE = 'Usage: aether-proxy job start <probe nodes|sub update> [options]\n       aether-proxy job status <id> [--json] [--run-dir <dir>] [--sys-root <dir>]';
const CONTEXT_OPTIONS = {
	'--confdir': 'confdir', '--run-dir': 'run_dir', '--sys-root': 'sys_root', '--bin-dir': 'bin_dir'
};

function usage(detail, json) {
	return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail }, 2, `${detail}\n${USAGE}`);
}

function start_options(argv) {
	let opts = {};
	for (let i = 0; i < length(argv); i++) {
		let key = CONTEXT_OPTIONS[argv[i]];
		if (key == null)
			continue;
		if (i + 1 >= length(argv))
			return { error: `option ${argv[i]} needs a value` };
		opts[key] = argv[++i];
	}
	return { opts };
}

function status_args(args) {
	let opts = {}, positional = [];
	for (let i = 0; i < length(args); i++) {
		let arg = args[i];
		if (arg == '--json') {
			opts.json = true;
			continue;
		}
		let key = CONTEXT_OPTIONS[arg];
		if (key != null) {
			if (i + 1 >= length(args))
				return { error: `option ${arg} needs a value` };
			opts[key] = args[++i];
			continue;
		}
		if (substr(arg, 0, 1) == '-')
			return { error: `unknown option ${arg}` };
		push(positional, arg);
	}
	return { opts, positional };
}

function job_failure(result, json) {
	let value = result.code == 'BUSY'
		? { ok: false, code: result.code, job: result.job }
		: { ok: false, code: result.code, detail: result.detail };
	return pipeline.finish({ json }, value, result.exit, `${result.code}: ${result.detail}`);
}

function job_summary(value) {
	return `Job ${value.id}: ${value.state}${value.error ? ` (${value.error})` : ''}`;
}

export function run(args) {
	let action = args[0];
	if (action == 'run') {
		if (length(args) != 2)
			return 2;
		return job.run_worker(args[1]);
	}

	if (action == 'start') {
		let argv = slice(args, 1);
		let parsed = start_options(argv);
		if (parsed.error)
			return job_failure({ ok: false, code: 'USAGE', detail: parsed.error, exit: 2 }, true);
		let result = job.start(argv, parsed.opts);
		if (result.ok) {
			print(sprintf('%.J', { job: result.job }), '\n');
			return 0;
		}
		return job_failure(result, true);
	}

	if (action == 'status') {
		let parsed = status_args(slice(args, 1));
		if (parsed.error)
			return usage(parsed.error, index(args, '--json') >= 0);
		if (length(parsed.positional) != 1)
			return usage('expected exactly one job ID', !!parsed.opts.json);
		let result = job.status(parsed.positional[0], parsed.opts);
		if (!result.ok)
			return job_failure(result, !!parsed.opts.json);
		if (parsed.opts.json)
			print(sprintf('%.J', result.job), '\n');
		else
			print(job_summary(result.job), '\n');
		return 0;
	}

	return usage('expected `job start` or `job status`', index(args, '--json') >= 0);
};
