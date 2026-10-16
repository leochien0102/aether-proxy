'use strict';

/* Scenario tests 1-7 for the shared LuCI module (docs/tasks/m8.md T8.3).
 *
 * common.js is loaded the way LuCI loads class modules (tests/luci/loader.js)
 * with doubles for rpc and baseclass. Time is controlled with node:test's
 * mock timers, so the tests run against the real ap.TIMEOUTS values without
 * waiting and without network access. */

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const { createDocument, createRpc, loadModule } = require('./loader.js');

const APP = path.join(__dirname, '..', '..', 'luci-app-aether-proxy');
const COMMON = path.join(APP, 'htdocs', 'luci-static', 'resources', 'aether-proxy', 'common.js');

/* Let promise chains (rpc reply bookkeeping, on_update callbacks) drain. */
function flush() {
	return new Promise((resolve) => setImmediate(() => setImmediate(resolve)));
}

function deferred() {
	let resolve, reject;
	const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
	return { promise, resolve, reject };
}

function setup(t) {
	t.mock.timers.enable({ apis: [ 'setTimeout', 'setInterval', 'Date' ] });

	const rpc = createRpc();
	const document = createDocument();
	const ap = loadModule(COMMON, { rpc, baseclass: { extend: (o) => o } }, { window: {}, document });

	return { ap, rpc, document };
}

test('scenario 1: ap.call resolves with the rpc reply; rpc failure becomes RPC_FAILED without rejecting', async (t) => {
	const { ap, rpc } = setup(t);

	/* success: the rpc result is passed through as-is */
	rpc.setHandler((method, params) => {
		assert.equal(method, 'version');
		return { ok: true, version: '0.1.0-r2' };
	});

	const p = ap.call('version');
	const outcome = await p.then(
		(v) => ({ resolved: v }),
		(e) => ({ rejected: e })
	);

	assert.ok(!('rejected' in outcome), 'ap.call must never reject');
	assert.deepEqual(outcome.resolved, { ok: true, version: '0.1.0-r2' });

	/* the declared method reaches the aetherproxy object */
	assert.deepEqual(rpc.calls, [ { object: 'aetherproxy', method: 'version', params: {} } ]);

	/* rpc rejection: RPC_FAILED with the error message in detail, still no rejection */
	rpc.setHandler(async () => {
		throw new Error('Permission denied');
	});

	const res = await ap.call('status');
	assert.deepEqual(res, { ok: false, code: 'RPC_FAILED', detail: 'Permission denied' });

	/* non-Error rejections (numeric ubus codes) also reach the detail field */
	rpc.setHandler(async () => {
		throw 7;
	});

	const res2 = await ap.call('status');
	assert.deepEqual(res2, { ok: false, code: 'RPC_FAILED', detail: '7' });
});

test('scenario 2: settle-once — hard timeout wins over a late reply; check uses the 35s tier, status the 15s tier', async (t) => {
	const { ap, rpc } = setup(t);

	/* the documented defaults live under these keys */
	assert.equal(ap.TIMEOUTS.call, 15);
	assert.equal(ap.TIMEOUTS.long, 35);
	assert.equal(ap.TIMEOUTS.job, 620);

	rpc.setHandler(() => new Promise(() => {}));

	/* check: the long tier — still pending after 34s, timed out at 35s */
	{
		const seen = [];
		ap.call('check').then((v) => seen.push(v));

		t.mock.timers.tick(34000);
		await flush();
		assert.deepEqual(seen, [], 'check must still be pending after 34s');

		t.mock.timers.tick(1000);
		await flush();
		assert.deepEqual(seen, [ { ok: false, code: 'TIMEOUT', detail: 'check did not answer in 35s' } ]);
	}

	/* status: the call tier — still pending after 14s, timed out at 15s */
	{
		const seen = [];
		ap.call('status').then((v) => seen.push(v));

		t.mock.timers.tick(14000);
		await flush();
		assert.deepEqual(seen, [], 'status must still be pending after 14s');

		t.mock.timers.tick(1000);
		await flush();
		assert.deepEqual(seen, [ { ok: false, code: 'TIMEOUT', detail: 'status did not answer in 15s' } ]);
	}

	/* a reply after the hard timeout changes nothing and fires no callback */
	{
		const d = deferred();
		rpc.setHandler(() => d.promise);

		const seen = [];
		ap.call('status').then((v) => seen.push(v));

		t.mock.timers.tick(15000);
		await flush();
		assert.equal(seen.length, 1);

		d.resolve({ ok: true, state: 'running' });
		await flush();

		assert.equal(seen.length, 1, 'a late reply must not fire callbacks again');
		assert.deepEqual(seen[0], { ok: false, code: 'TIMEOUT', detail: 'status did not answer in 15s' });
	}
});

test('scenario 3: at most 2 calls in flight; FIFO order; the queued next call goes out when the head settles', async (t) => {
	const { ap, rpc } = setup(t);

	/* five different methods (the queue is shared by all of them); none of
	   them carries params, so the calls are told apart by the method name */
	const methods = [ 'version', 'status', 'check', 'events', 'log' ];
	const pending = {};

	for (const m of methods)
		pending[m] = deferred();

	const order = [];
	rpc.setHandler((method) => {
		order.push(method);
		return pending[method].promise;
	});

	const promises = methods.map((m) => ap.call(m));

	await flush();

	/* only the first two go out; the rest wait in the queue */
	assert.deepEqual(order, [ 'version', 'status' ], 'only 2 calls may be in flight');

	t.mock.timers.tick(14999);
	await flush();
	assert.deepEqual(order, [ 'version', 'status' ], 'no queued call goes out before a slot frees');

	/* calls 1 and 2 hit their hard timeout at 15s; the two queue heads follow */
	t.mock.timers.tick(1);
	await flush();
	assert.deepEqual(order, [ 'version', 'status', 'check', 'events' ],
		'queue heads go out once calls 1 and 2 settle');

	/* in flight right now: check and events (version/status timed out, log queued) */
	assert.deepEqual(order.filter((m) => m != 'version' && m != 'status').length, 2);

	/* settling the events call by reply frees the slot for the last queue head */
	pending['events'].resolve({ ok: true, events: [] });
	await flush();
	assert.deepEqual(order, [ 'version', 'status', 'check', 'events', 'log' ],
		'calls are issued in the order they were made');
	assert.deepEqual(order.filter((m) => m != 'version' && m != 'status').length, 3, 'still at most 2 in flight');

	/* all five calls resolve */
	pending['check'].resolve({ ok: true });
	pending['log'].resolve({ ok: true, lines: [] });

	const results = await Promise.all(promises);
	assert.equal(results[0].code, 'TIMEOUT');
	assert.equal(results[1].code, 'TIMEOUT');
	assert.deepEqual(results.slice(2), [ { ok: true }, { ok: true, events: [] }, { ok: true, lines: [] } ]);
});

test('settle-once frees a request slot only once: a reply arriving after the hard timeout', async (t) => {
	const { ap, rpc } = setup(t);
	const late = deferred();
	const order = [];
	const pending = {};

	rpc.setHandler((method) => {
		order.push(method);
		if (method == 'version')
			return late.promise;
		pending[method] = deferred();
		return pending[method].promise;
	});

	const first = ap.call('version');
	await flush();
	t.mock.timers.tick(15000);
	assert.equal((await first).code, 'TIMEOUT');

	/* the late reply must not release the slot a second time */
	late.resolve({ ok: true, version: 'late' });
	await flush();

	ap.call('status'); ap.call('check'); ap.call('events');
	await flush();
	assert.deepEqual(order, [ 'version', 'status', 'check' ],
		'a double release would let a third call out (in flight count driven below zero)');
});

test('run_job polls one job_status at a time: the next poll waits for the previous reply', async (t) => {
	const { ap, rpc } = setup(t);
	let statusCalls = 0;
	const slow = deferred();

	rpc.setHandler((method) => {
		if (method == 'job_start')
			return { job: 'j_3_3' };
		statusCalls++;
		return statusCalls == 1 ? slow.promise : { id: 'j_3_3', state: 'ok' };
	});

	const updates = [];
	const p = ap.run_job('update_check', [], (job) => updates.push(job.state));
	await flush();
	assert.equal(statusCalls, 1);

	/* the first reply is slow: 6 seconds pass, no second poll may go out */
	t.mock.timers.tick(6000);
	await flush();
	assert.equal(statusCalls, 1, 'polls must not stack while a job_status is unanswered');

	slow.resolve({ id: 'j_3_3', state: 'running' });
	await flush();
	t.mock.timers.tick(2000);
	await flush();
	assert.equal(statusCalls, 2, 'next poll 2 seconds after the reply');
	assert.deepEqual((await p).state, 'ok');
	assert.deepEqual(updates, [ 'running', 'ok' ]);
});

test('scenario 4: poll — 2000ms floor, skip while unsettled, pause while hidden with immediate resume, stop()', async (t) => {
	const { ap, document } = setup(t);

	/* (a) an interval below 2000 counts as 2000; stop() ends the ticks */
	{
		let calls = 0;
		const handle = ap.poll(() => {
			calls++;
			return Promise.resolve();
		}, 50);

		t.mock.timers.tick(1999);
		await flush();
		assert.equal(calls, 0, 'interval below 2000 must not fire earlier than 2000ms');

		t.mock.timers.tick(1);
		await flush();
		assert.equal(calls, 1);

		t.mock.timers.tick(1999);
		await flush();
		assert.equal(calls, 1, 'the next tick comes only after another 2000ms');

		t.mock.timers.tick(1);
		await flush();
		assert.equal(calls, 2);

		handle.stop();
		t.mock.timers.tick(10000);
		await flush();
		assert.equal(calls, 2, 'stop() must end the ticks');
	}

	/* (b) a tick is skipped while the previous run has not settled */
	{
		const d = deferred();
		let calls = 0;

		ap.poll(() => {
			calls++;
			return d.promise;
		}, 2000);

		t.mock.timers.tick(2000);
		await flush();
		assert.equal(calls, 1);

		t.mock.timers.tick(2000);
		await flush();
		assert.equal(calls, 1, 'tick skipped while fn is unsettled');

		d.resolve(true);
		await flush();

		t.mock.timers.tick(2000);
		await flush();
		assert.equal(calls, 2, 'the loop continues after fn settles');
	}

	/* (c) hidden: no ticks; becoming visible: one immediate call, cadence continues */
	{
		let calls = 0;

		ap.poll(() => {
			calls++;
			return Promise.resolve();
		}, 2000);

		document.hidden = true;
		t.mock.timers.tick(6000);
		await flush();
		assert.equal(calls, 0, 'no ticks while document.hidden is true');

		document.hidden = false;
		document.emit('visibilitychange');
		await flush();
		assert.equal(calls, 1, 'one immediate call on becoming visible');

		t.mock.timers.tick(2000);
		await flush();
		assert.equal(calls, 2, 'the interval continues after the resume');
	}
});

test('scenario 5: run_job — job_start, then job_status until ok/failed; on_update sees every state', async (t) => {
	const { ap, rpc } = setup(t);

	const statusReplies = [
		{ id: 'j_1_1', state: 'running' },
		{ id: 'j_1_1', state: 'running' },
		{ id: 'j_1_1', state: 'ok', result: { nodes: 3 } }
	];
	let statusCalls = 0;

	rpc.setHandler((method, params) => {
		if (method == 'job_start') {
			assert.deepEqual(params, { kind: 'probe_nodes', args: [] });
			return { job: 'j_1_1' };
		}

		assert.equal(method, 'job_status');
		assert.deepEqual(params, { id: 'j_1_1' });
		return statusReplies[Math.min(statusCalls++, statusReplies.length - 1)];
	});

	const updates = [];
	const p = ap.run_job('probe_nodes', [], (job) => updates.push(job));

	await flush();
	assert.equal(statusCalls, 1, 'the first job_status goes out right after job_start');

	t.mock.timers.tick(2000);
	await flush();
	assert.equal(statusCalls, 2, 'job_status is polled every 2 seconds');

	t.mock.timers.tick(2000);
	await flush();
	assert.equal(statusCalls, 3);

	const final = await p;
	assert.deepEqual(updates.map((j) => j.state), [ 'running', 'running', 'ok' ], 'on_update saw every status');
	assert.deepEqual(final, { id: 'j_1_1', state: 'ok', result: { nodes: 3 } }, 'resolves the final job object');
	assert.deepEqual(updates[2], final);

	/* a failed job ends the loop the same way and resolves */
	{
		let calls = 0;
		rpc.setHandler((method) => {
			if (method == 'job_start')
				return { job: 'j_2_2' };
			calls++;
			return calls >= 2
				? { id: 'j_2_2', state: 'failed', error: 'CMD_FAILED' }
				: { id: 'j_2_2', state: 'running' };
		});

		const seen = [];
		const p2 = ap.run_job('sub_update', [], (job) => seen.push(job));

		await flush();
		t.mock.timers.tick(2000);
		await flush();

		const final2 = await p2;
		assert.equal(final2.state, 'failed');
		assert.deepEqual(seen.map((j) => j.state), [ 'running', 'failed' ]);
	}
});

test('scenario 6: run_job on BUSY attaches to the running job and marks the result attached: true', async (t) => {
	const { ap, rpc } = setup(t);

	const statuses = [];
	rpc.setHandler((method, params) => {
		if (method == 'job_start')
			return { ok: false, code: 'BUSY', job: 'j_1_2' };

		statuses.push(params.id);
		return statuses.length >= 2
			? { id: 'j_1_2', state: 'ok', result: {} }
			: { id: 'j_1_2', state: 'running' };
	});

	const updates = [];
	const p = ap.run_job('update_data', [], (job) => updates.push(job));

	await flush();
	assert.deepEqual(statuses, [ 'j_1_2' ], 'the busy job is polled instead of failing');

	t.mock.timers.tick(2000);
	await flush();

	const final = await p;
	assert.equal(final.state, 'ok');
	assert.equal(final.attached, true, 'the result carries attached: true');
	assert.deepEqual(updates.map((j) => j.state), [ 'running', 'ok' ]);
	assert.ok(updates.every((j) => j.attached === true), 'every observed status carries attached: true');
});

test('scenario 7: run_job failures — USAGE resolves at once; JOB_NOT_FOUND stops; over-timeout resolves TIMEOUT', async (t) => {
	const { ap, rpc } = setup(t);

	/* job_start returns USAGE: resolve that object, never call job_status */
	{
		let statusCalls = 0;
		rpc.setHandler((method) => {
			if (method == 'job_start')
				return { ok: false, code: 'USAGE', detail: 'invalid args for kind nope' };
			statusCalls++;
			return {};
		});

		const final = await ap.run_job('nope', []);
		assert.deepEqual(final, { ok: false, code: 'USAGE', detail: 'invalid args for kind nope' });
		assert.equal(statusCalls, 0, 'job_status must not be called');
	}

	/* job_status returns JOB_NOT_FOUND: stop and resolve that object */
	{
		rpc.setHandler((method) => method == 'job_start'
			? { job: 'j_9_9' }
			: { ok: false, code: 'JOB_NOT_FOUND', detail: 'no such job' });

		const p = ap.run_job('probe_nodes', []);
		await flush();

		const final = await p;
		assert.deepEqual(final, { ok: false, code: 'JOB_NOT_FOUND', detail: 'no such job' });

		const before = rpc.calls.filter((c) => c.method == 'job_status').length;
		t.mock.timers.tick(6000);
		await flush();
		assert.equal(rpc.calls.filter((c) => c.method == 'job_status').length, before, 'polling stopped');
	}

	/* total time beyond ap.TIMEOUTS.job: resolve { ok: false, code: "TIMEOUT" } */
	{
		ap.TIMEOUTS.job = 3;
		rpc.setHandler((method) => method == 'job_start'
			? { job: 'j_8_8' }
			: { id: 'j_8_8', state: 'running' });

		const updates = [];
		const p = ap.run_job('probe_nodes', [], (job) => updates.push(job));

		await flush();                   /* poll at t=0, within budget */
		t.mock.timers.tick(2000);
		await flush();                   /* poll at t=2, still within budget */

		t.mock.timers.tick(2000);        /* poll at t=4 exceeds the 3s budget */
		const final = await p;

		assert.deepEqual(final, { ok: false, code: 'TIMEOUT' });
		assert.equal(updates.length, 2, 'no status after the budget ran out');
	}
});
