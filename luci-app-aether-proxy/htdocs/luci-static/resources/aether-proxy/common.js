'use strict';
'require baseclass';
'require rpc';

/*
 * Shared helpers for the aether-proxy LuCI pages (docs/10 「公共模块与菜单」).
 *
 * Pages load this module with 'require aether-proxy.common as ap' and never
 * call rpc.declare themselves. Every rpcd access goes through ap.call(), which
 * settles exactly once — rpc reply, rpc failure or hard timeout, whichever
 * comes first — and never rejects. At most 2 calls are in flight at any time;
 * further calls wait in a FIFO queue (docs/10 「UI 规则」: 为 uhttpd 的
 * max_requests 3 留出余量).
 */

/* docs/10 「rpcd 插件」: all 12 ubus methods of the aetherproxy object with
   their named parameters, in declaration order. */
var METHODS = {
	version: [],
	status: [],
	service: [ 'action' ],
	check: [],
	job_start: [ 'kind', 'args' ],
	job_status: [ 'id' ],
	events: [ 'since', 'level' ],
	probe_results: [],
	log: [ 'source', 'lines' ],
	node_import: [ 'uri' ],
	list_file: [ 'name' ],
	save_file: [ 'name', 'content' ]
};

/* docs/10 「公共模块与菜单」: check and save_file get the long hard-timeout
   tier, every other method the normal one (35s/15s vs the plugin's 30s/10s). */
var LONG_CALLS = [ 'check', 'save_file' ];

/* docs/10 「公共模块与菜单」: ap.poll() intervals below 2000ms count as 2000ms. */
var MIN_POLL_INTERVAL_MS = 2000;

var decls = {};

for (var method in METHODS)
	decls[method] = rpc.declare({
		object: 'aetherproxy',
		method: method,
		params: METHODS[method]
	});

/* In-flight counter and FIFO queue for the ≤2 concurrent calls rule. Module
   scope on purpose: LuCI keeps one instance per module name, so the limit
   covers ap.call and the job polling of every page alike. */
var inflight = 0;
var queue = [];

function error_text(e) {
	if (e instanceof Error)
		return e.message;

	return (e === null || e === undefined) ? 'unknown error' : String(e);
}

/* Send queued calls while fewer than 2 are in flight. */
function pump() {
	while (inflight < 2 && queue.length > 0) {
		var entry = queue.shift();

		inflight++;
		invoke(entry);
	}
}

function invoke(entry) {
	var fn = decls[entry.method];
	var settled = false;
	var timer = null;

	/* settle-once: only the first of reply, failure and hard timeout wins;
	   later ones are ignored and free the queue slot exactly once. */
	var finish = function(res) {
		if (settled)
			return;

		settled = true;

		if (timer != null)
			clearTimeout(timer);

		inflight--;
		entry.resolve(res);
		pump();
	};

	if (!fn) {
		/* Unreachable through the public API (ap.call only accepts the methods
		   declared above); fail the call instead of issuing an rpc.
		   TODO(design): docs/10 does not describe a reply shape for programming
		   errors, so the generic RPC_FAILED object is used. */
		finish({ ok: false, code: 'RPC_FAILED', detail: 'unknown method: ' + entry.method });
		return;
	}

	var timeout_s = (LONG_CALLS.indexOf(entry.method) != -1) ? ap.TIMEOUTS.long : ap.TIMEOUTS.call;

	timer = setTimeout(function() {
		finish({
			ok: false,
			code: 'TIMEOUT',
			detail: entry.method + ' did not answer in ' + timeout_s + 's'
		});
	}, timeout_s * 1000);

	try {
		Promise.resolve(fn.apply(null, entry.args)).then(finish, function(e) {
			finish({ ok: false, code: 'RPC_FAILED', detail: error_text(e) });
		});
	}
	catch (e) {
		finish({ ok: false, code: 'RPC_FAILED', detail: error_text(e) });
	}
}

var ap = baseclass.extend({
	/* Hard timeouts in seconds, kept in an object so tests can shrink them
	   (docs/10 「公共模块与菜单」). call/long are the ap.call tiers; job is the
	   total budget for one background job (the job itself caps at 600s);
	   job_poll is the job_status polling cadence required by docs/10
	   「作业机制」 (frontend polls every 2 seconds). */
	TIMEOUTS: {
		call: 15,
		long: 35,
		job: 620,
		job_poll: 2
	},

	/* Call one of the rpcd plugin methods (docs/10 「rpcd 插件」) and resolve
	   exactly once: with the rpc reply, or { ok: false, code: "RPC_FAILED" }
	   when the rpc layer rejects, or { ok: false, code: "TIMEOUT" } on hard
	   timeout. Never rejects. Calls beyond 2 in flight wait in FIFO order and
	   are sent when a slot frees up (docs/10 「UI 规则」). */
	call: function(method, params) {
		var names = METHODS[method] ?? [];
		var args = [];

		for (var i = 0; i < names.length; i++)
			args.push(params ? params[names[i]] : undefined);

		return new Promise(function(resolve) {
			queue.push({ method: method, args: args, resolve: resolve });
			pump();
		});
	},

	/* Call fn (which returns a promise) every interval_ms, but at most every
	   2000ms. A tick is skipped while the previous run has not settled and
	   while document.hidden is true; on becoming visible fn runs once at once
	   and the cadence continues. Rejections of fn are contained here — the
	   poll loop must survive them, which is exactly what LuCI's own poll does
	   not guarantee (docs/10 「作业机制」). Returns { stop() }. */
	poll: function(fn, interval_ms) {
		var interval = (typeof interval_ms == 'number' && interval_ms >= MIN_POLL_INTERVAL_MS) ? interval_ms : MIN_POLL_INTERVAL_MS;
		var stopped = false;
		var busy = false;

		var run = function() {
			if (stopped || busy || document.hidden)
				return;

			busy = true;

			Promise.resolve().then(fn).catch(function() {}).then(function() {
				busy = false;
			});
		};

		var on_visibility = function() {
			if (!stopped && !document.hidden)
				run();
		};

		document.addEventListener('visibilitychange', on_visibility);

		var timer = setInterval(run, interval);

		return {
			stop: function() {
				stopped = true;
				clearInterval(timer);
				document.removeEventListener('visibilitychange', on_visibility);
			}
		};
	},

	/* Start a background job (docs/10 「作业机制」) and poll it until it reaches
	   state ok or failed; on_update(job) is called for every observed status.
	   Resolves the final job object — with attached: true when job_start
	   reported BUSY and an already running job was attached to — or the
	   failure object of job_start / job_status (USAGE, JOB_NOT_FOUND,
	   RPC_FAILED, TIMEOUT, …), or { ok: false, code: "TIMEOUT" } once the
	   total time exceeds ap.TIMEOUTS.job. Never rejects. */
	run_job: function(kind, args, on_update) {
		var started_at = Date.now();

		/* One job_status at a time: the next poll is scheduled only after the
		   previous reply, so a slow reply (up to the 15s call timeout) never
		   stacks polls, never takes both request slots and never reports a
		   status after the job already resolved. */
		var track = function(id, attached) {
			return new Promise(function(resolve) {
				var poll_once = function() {
					if (Date.now() - started_at > ap.TIMEOUTS.job * 1000) {
						resolve({ ok: false, code: 'TIMEOUT' });
						return;
					}

					ap.call('job_status', { id: id }).then(function(st) {
						if (!st || st.ok === false) {
							resolve(st ?? { ok: false, code: 'RPC_FAILED', detail: 'job_status returned nothing' });
							return;
						}

						var job = attached ? Object.assign({}, st, { attached: true }) : st;

						if (typeof on_update == 'function')
							on_update(job);

						if (st.state == 'ok' || st.state == 'failed') {
							resolve(job);
							return;
						}

						setTimeout(poll_once, ap.TIMEOUTS.job_poll * 1000);
					});
				};

				/* First status right away, then job_poll seconds after each reply. */
				poll_once();
			});
		};

		return ap.call('job_start', { kind: kind, args: args ?? [] }).then(function(started) {
			/* BUSY with a job id: attach to the already running job instead of
			   failing (docs/10 「公共模块与菜单」). */
			if (started && started.code == 'BUSY' && typeof started.job == 'string')
				return track(started.job, true);

			if (started && started.ok === false)
				return started;

			/* TODO(design): docs/10 does not say how to treat a successful
			   job_start that carries no job id; fail the job defensively. */
			if (!started || typeof started.job != 'string')
				return { ok: false, code: 'RPC_FAILED', detail: 'job_start did not return a job id' };

			return track(started.job, false);
		});
	}
});

return ap;
