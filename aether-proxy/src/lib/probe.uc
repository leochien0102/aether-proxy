'use strict';

// Synchronous TCP reachability probes for subscription nodes (docs/07).
// Successful DNS answers seed the per-address LKG cache once per job (docs/03 bootstrap step 3).

import * as socket from 'socket';
import * as C from 'aetherproxy.const';
import { ipv4 } from 'aetherproxy.net';
import * as sys from 'aetherproxy.sys';
import * as apply from 'aetherproxy.apply';
import * as log from 'aetherproxy.log';

// Linux errno values from the target socket ABI; socket 2025.07.18 exposes errors numerically.
const EINTR = 4;
const EADDRNOTAVAIL = 99;
const ENETDOWN = 100;
const ENETUNREACH = 101;
const EHOSTDOWN = 112;
const EHOSTUNREACH = 113;
const EALREADY = 114;
const EINPROGRESS = 115;
const ECONNREFUSED = 111;
const ETIMEDOUT = 110;

function monotonic_ms() {
	let now = clock(true);
	return now == null ? null : now[0] * 1000 + now[1] / 1000000;
}

function elapsed_ms(start, end) {
	return int(end - start + 0.5);
}

function error_kind(code, text) {
	if (code == ECONNREFUSED || index(lc(text ?? ''), 'connection refused') >= 0)
		return 'refused';
	if (code == ETIMEDOUT || index(lc(text ?? ''), 'timed out') >= 0)
		return 'timeout';
	if (index([ EADDRNOTAVAIL, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH ], code) >= 0
		|| index(lc(text ?? ''), 'unreachable') >= 0 || index(lc(text ?? ''), 'no route') >= 0)
		return 'unreachable';

	return 'other';
}

function summarize_node(record) {
	let samples = [];
	let ok = 0;
	let error = null;

	for (let attempt in record.attempts) {
		if (attempt?.ok) {
			ok++;
			push(samples, attempt.ms);
		}
		else if (attempt?.error != null) {
			error = attempt.error;
		}
	}

	samples = sort(samples, (a, b) => a - b);
	let min_ms = length(samples) ? samples[0] : null;
	let median_ms = null;
	if (length(samples)) {
		let middle = length(samples) >> 1;
		median_ms = (length(samples) % 2)
			? samples[middle]
			: int((samples[middle - 1] + samples[middle]) / 2 + 0.5);
	}

	return { ip: record.ip, ok, fail: 3 - ok, min_ms, median_ms, error };
}

// T8.5 (docs/07 「实现细节」): one callback per finished node, fired as soon as all
// three attempts of the node have a result (or the resolution failed). The probe
// itself is unchanged; reporting the result incrementally is up to the caller.
function complete_if_done(results, node_id, on_done) {
	if (on_done == null)
		return;

	let record = results[node_id];

	for (let attempt in record.attempts)
		if (attempt == null)
			return;

	on_done(node_id, summarize_node(record));
}

function resolve_node(node, timeout, bin_dir) {
	if (ipv4(node.address) != null)
		return { ip: node.address };

	let resolveip = bin_dir ? `${bin_dir}/resolveip` : 'resolveip';
	let result = sys.run([ resolveip, '-4', '-t', `${timeout}`, node.address ], { timeout, quiet: true });
	if (result.code != 0)
		return { error: 'resolve_failed' };

	// Several A records: the first valid one, as for the bootstrap resolution (03).
	for (let candidate in split(trim(result.stdout ?? ''), /[[:space:]]+/))
		if (ipv4(candidate) != null)
			return { ip: candidate };

	return { error: 'resolve_failed' };
}

function record_success(results, job, start, end, on_done) {
	results[job.node_id].attempts[job.attempt] = {
		ok: true,
		ms: elapsed_ms(start, end)
	};
	complete_if_done(results, job.node_id, on_done);
}

function record_failure(results, job, reason, on_done) {
	results[job.node_id].attempts[job.attempt] = { ok: false, error: reason };
	complete_if_done(results, job.node_id, on_done);
}

function start_attempt(results, job, timeout, on_done) {
	let start = monotonic_ms();
	if (start == null) {
		record_failure(results, job, 'other', on_done);
		return null;
	}

	let sock = socket.create(socket.AF_INET, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);
	if (sock == null) {
		record_failure(results, job, error_kind(socket.error(true), socket.error()), on_done);
		return null;
	}

	let connected = sock.connect(job.ip, job.port);
	if (connected) {
		let end = monotonic_ms();
		sock.close();
		if (end == null)
			record_failure(results, job, 'other', on_done);
		else
			record_success(results, job, start, end, on_done);
		return null;
	}

	let code = socket.error(true);
	let message = socket.error();
	if (code != EINPROGRESS && code != EALREADY && index(lc(message ?? ''), 'progress') < 0) {
		sock.close();
		record_failure(results, job, error_kind(code, message), on_done);
		return null;
	}

	return {
		key: job.key,
		node_id: job.node_id,
		attempt: job.attempt,
		sock,
		started: start,
		deadline: start + timeout * 1000
	};
}

function finish_pending(results, job, reason, now, on_done) {
	if (reason == null)
		record_success(results, job, job.started, now, on_done);
	else
		record_failure(results, job, reason, on_done);
	job.sock.close();
}

function run_attempts(results, jobs, timeout, concurrency, on_done) {
	let pending = [];
	let next_job = 0;

	while (next_job < length(jobs) || length(pending)) {
		while (next_job < length(jobs) && length(pending) < concurrency) {
			let job = jobs[next_job++];
			let active = start_attempt(results, job, timeout, on_done);
			if (active != null)
				push(pending, active);
		}

		if (!length(pending))
			continue;

		let now = monotonic_ms();
		if (now == null) {
			for (let job in pending)
				finish_pending(results, job, 'other', job.started, on_done);
			pending = [];
			continue;
		}

		let nearest = pending[0].deadline;
		for (let job in pending)
			if (job.deadline < nearest)
				nearest = job.deadline;

		let remaining = nearest - now;
		let wait_ms = 0;
		if (remaining > 0) {
			wait_ms = int(remaining);
			if (wait_ms < remaining)
				wait_ms++;
		}
		if (wait_ms > 1000)
			wait_ms = 1000;

		let poll_args = map(pending, job => [
			job.sock,
			socket.POLLOUT | socket.POLLERR | socket.POLLHUP | socket.POLLNVAL,
			job.key
		]);
		let ready = {};
		let polled = socket.poll(wait_ms, ...poll_args);
		if (polled == null) {
			if (socket.error(true) == EINTR)
				continue;
			for (let job in pending)
				finish_pending(results, job, error_kind(socket.error(true), socket.error()), now, on_done);
			pending = [];
			continue;
		}

		for (let item in polled)
			if (item[1] != 0)
				ready[item[2]] = true;

		now = monotonic_ms();
		let remaining_jobs = [];
		for (let job in pending) {
			if (now == null) {
				finish_pending(results, job, 'other', job.started, on_done);
				continue;
			}

			// Check readiness before the deadline: a connect that completed in this poll round
			// must not be recorded as a timeout just because the clock passed the deadline too.
			if (ready[job.key]) {
				let so_error = job.sock.getopt(socket.SOL_SOCKET, socket.SO_ERROR);
				if (so_error == 0)
					finish_pending(results, job, null, now, on_done);
				else
					finish_pending(results, job, error_kind(so_error, socket.error()), now, on_done);
				continue;
			}

			if (now >= job.deadline) {
				finish_pending(results, job, 'timeout', now, on_done);
				continue;
			}

			push(remaining_jobs, job);
		}
		pending = remaining_jobs;
	}
}

// nodes is a normalized config snapshot map; ids is its sorted selected subset.
// on_done (T8.5) is called once per finished node as (node_id, summarized_result);
// pass null to keep the pre-T8.5 behavior of returning everything at the end.
export function probe_nodes(nodes, ids, timeout, concurrency, bin_dir, on_done, ctx) {
	let results = {};
	let jobs = [];
	let resolved_addresses = {};

	for (let id in ids) {
		let resolved = resolve_node(nodes[id], timeout, bin_dir);
		if (resolved.error != null) {
			// TODO(design): docs/07 does not define whether DNS failure increments the TCP fail count.
			// Count the three planned checks as failed while preserving the specific resolve_failed code.
			results[id] = { ip: null, attempts: [
				{ ok: false, error: 'resolve_failed' },
				{ ok: false, error: 'resolve_failed' },
				{ ok: false, error: 'resolve_failed' }
			] };
			// A resolution failure is a finished node for docs/07 「实现细节」.
			complete_if_done(results, id, on_done);
			continue;
		}

		// Do not reuse LKG or retry here: this probe measures DNS reachability right now.
		if (ipv4(nodes[id].address) == null)
			resolved_addresses[nodes[id].address] = resolved.ip;
		results[id] = { ip: resolved.ip, attempts: [ null, null, null ] };
		for (let attempt = 0; attempt < 3; attempt++)
			push(jobs, { key: id + '|' + attempt, node_id: id, attempt, ip: resolved.ip, port: nodes[id].port });
	}

	run_attempts(results, jobs, timeout, concurrency, on_done);

	if (length(resolved_addresses)) {
		let saved = apply.update_lkg(ctx ?? {}, resolved_addresses);
		if (!saved.ok) {
			// docs/03 bootstrap step 3: a failed cache write keeps the measured results.
			log.event('error', 'FS_FAILED', { op: 'update_lkg', path: saved.path, detail: saved.detail });
		}
	}
	let output = {};
	for (let id in ids)
		output[id] = summarize_node(results[id]);

	return { at: time(), nodes: output };
};
