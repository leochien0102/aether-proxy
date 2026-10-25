'use strict';

/* Frozen LuCI clients -> frozen rpcd plugin -> current CLI and real job workers.
 * Per docs/08 "更新接口（固定）", only the network/package-manager boundary is
 * substituted. No CLI result is synthesized on the successful update path.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { execFile, execFileSync } = require('node:child_process');
const { promisify } = require('node:util');
const { loadModule, createRpc, element } = require('../luci/loader');
const exec = promisify(execFile);
const ROOT = path.resolve(__dirname, '../..');
const FROZEN = path.join(__dirname, 'fixtures/0.3.0-r1');
const RES = path.join(FROZEN, 'htdocs/luci-static/resources');
const PLUGIN = path.join(FROZEN, 'root/usr/share/rpcd/ucode/aetherproxy.uc');
const UCODE = path.join(ROOT, 'tests/host/ucode');
const ENTRY = path.join(ROOT, 'aether-proxy/src/aether-proxy');
const USIGN = path.join(ROOT, 'tests/host/prefix/bin/usign');
const NAMES = ['xray-core', 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn'];
const CURRENT = { 'xray-core': '26.10.10-r1', 'aether-proxy': '0.3.1-r1',
	'luci-app-aether-proxy': '0.3.1-r1', 'luci-i18n-aether-proxy-zh-cn': '26.299.00000~abcdef0' };
// The backend is already new: the previous release's page must update itself.
const INSTALLED = { 'xray-core': '26.9.30-r1', 'aether-proxy': CURRENT['aether-proxy'],
	'luci-app-aether-proxy': '0.3.0-r1', 'luci-i18n-aether-proxy-zh-cn': '26.298.00000~abcdef0' };

globalThis._ = text => text;
globalThis.E = element;
// LuCI supplies this formatter; keep the frozen source byte-for-byte intact.
String.prototype.format = function(...args) {
	let i = 0;
	return this.replace(/%s/g, () => String(args[i++]));
};

function shell_quote(value) {
	return "'" + value.replace(/'/g, "'\\''") + "'";
}

function write(file, text, executable = false) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, text, { mode: executable ? 0o755 : 0o644 });
}

async function fixture() {
	const dir = fs.mkdtempSync(path.join(__dirname, 'tmp.'));
	const files = new Map();
	const requests = [];
	const server = http.createServer((req, res) => {
		requests.push(req.url);
		const body = files.get(req.url);
		res.writeHead(body ? 200 : 404);
		res.end(body ?? 'fixture not found');
	});
	const env = { ...process.env, UPDATE_PACKAGE_STATE_DIR: path.join(dir, 'installed'),
		UPDATE_PACKAGE_CALLS: path.join(dir, 'package-calls'),
		AETHER_PROXY_TEST_TMP_FREE: '999999999' };
	// All descendants, including detached job workers, inherit the same sandbox.
	for (const key of ['UPDATE_PACKAGE_STATE_FILE', 'UPDATE_STATUS_VERSION', 'UPDATE_INSTALL_EXIT',
		'UPDATE_INSTALL_FAIL_PACKAGE', 'UPDATE_PACKAGE_DB_FILE', 'UPDATE_INSTALLED_SLEEP'])
		delete env[key];
	const options = ['--confdir', path.join(dir, 'conf'), '--run-dir', path.join(dir, 'run'),
		'--sys-root', path.join(dir, 'root'), '--bin-dir', path.join(dir, 'bin')];
	async function cli(...args) {
		const result = await exec(UCODE, ['-S', ENTRY, '--', ...args, ...options, '--json'], { env });
		assert.equal(result.stderr, '');
		return JSON.parse(result.stdout);
	}
	async function close() {
		await new Promise(resolve => server.close(resolve));
		fs.rmSync(dir, { recursive: true, force: true });
	}
	try {
		await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
		const url = `http://127.0.0.1:${server.address().port}/`;
		write(path.join(dir, 'conf/aetherproxy'), "config update 'update'\n list channel_urls '" + url + "'\n");
		write(path.join(dir, 'root/etc/openwrt_release'), "DISTRIB_ARCH='aarch64_generic'\n");
		write(path.join(dir, 'run/state.json'), JSON.stringify({ state: 'stopped', components: {
			xray: { version: '26.9.30', path: '/fixture/xray' },
			'chinadns-ng': { version: 'fixture-dns', path: '/fixture/chinadns-ng' }
		} }));
		for (const [name, version] of Object.entries(INSTALLED))
			write(path.join(dir, 'installed', name), version + '\n');
		write(env.UPDATE_PACKAGE_CALLS, '');
		fs.mkdirSync(path.join(dir, 'root/tmp'), { recursive: true });
		fs.mkdirSync(path.join(dir, 'bin'), { recursive: true });
		fs.copyFileSync(path.join(ROOT, 'tests/stubs/update-bin/opkg'), path.join(dir, 'bin/opkg'));
		fs.symlinkSync(USIGN, path.join(dir, 'bin/usign'));
		// This wrapper redirects paths only. Every command, including job run and
		// the worker's update subprocess, executes the real current entry point.
		write(path.join(dir, 'bin/aether-proxy'), '#!/bin/sh\n' +
			'printf "%s\\n" "$*" >> ' + shell_quote(path.join(dir, 'cli-calls')) + '\n' +
			'if [ "$1" = job ] && [ "$2" = run ]; then\n' +
			' exec ' + [UCODE, '-S', ENTRY, '--'].map(shell_quote).join(' ') + ' "$@"\nfi\n' +
			'exec ' + [UCODE, '-S', ENTRY, '--'].map(shell_quote).join(' ') +
			' "$@" ' + options.map(shell_quote).join(' ') + '\n', true);
		env.AETHER_PROXY_TEST_RPCD_CLI = path.join(dir, 'bin/aether-proxy');
		execFileSync(USIGN, ['-G', '-p', path.join(dir, 'pub'), '-s', path.join(dir, 'sec')]);
		const fp = execFileSync(USIGN, ['-F', '-p', path.join(dir, 'pub')], { encoding: 'utf8' }).trim();
		write(path.join(dir, 'root/etc/aether-proxy/keys', fp), fs.readFileSync(path.join(dir, 'pub')));
		const manifest = { schema: 2, generated: '2026-10-25T00:00:00Z', packages: {}, data: {} };
		for (const name of NAMES) {
			const releases = [CURRENT[name], INSTALLED[name]].map(version => {
				const filename = `${name}_${version}_all.ipk`;
				const body = Buffer.from(`compat package ${name} ${version}\n`);
				files.set('/' + filename, body);
				return { version, assets: { all: { ipk: { url: filename, size: body.length,
					sha256: crypto.createHash('sha256').update(body).digest('hex') } } } };
			});
			manifest.packages[name] = { current: releases[0], previous: releases[1] };
		}
		write(path.join(dir, 'manifest.json'), JSON.stringify(manifest));
		execFileSync(USIGN, ['-S', '-m', path.join(dir, 'manifest.json'), '-s', path.join(dir, 'sec')]);
		files.set('/manifest.json', fs.readFileSync(path.join(dir, 'manifest.json')));
		files.set('/manifest.json.sig', fs.readFileSync(path.join(dir, 'manifest.json.sig')));
		// Seed a genuine cache so the initial status exercises all inventory fields,
		// not just the model's permissive "not checked" fallback.
		await cli('update', 'check');
		return { dir, env, requests, close, cli, async rpc(method, args) {
			const r = await exec(UCODE, [path.join(__dirname, 'rpc.uc'), '--',
				PLUGIN, method, JSON.stringify(args)], { env, timeout: 15000 });
			assert.equal(r.stderr, '');
			return JSON.parse(r.stdout);
		} };
	}
	catch (error) {
		await close();
		throw error;
	}
}

function old_clients(transport) {
	const env = { window: {}, document: {} };
	const model = loadModule(path.join(RES, 'aether-proxy/model/updates.js'),
		{ baseclass: { extend: object => object } }, env);
	const rpc = createRpc();
	rpc.setHandler(transport);
	const common = loadModule(path.join(RES, 'aether-proxy/common.js'),
		{ baseclass: { extend: object => object }, rpc, ui: {} }, env);
	// Only polling cadence changes; use the actual old run_job implementation.
	common.TIMEOUTS.job_poll = 0.02;
	common.TIMEOUTS.job = 30;
	const page = loadModule(path.join(RES, 'view/aether-proxy/updates.js'), {
		view: { extend: object => object }, form: {}, uci: {}, ui: {
			createHandlerFn: (self, fn) => fn.bind(self)
		}, 'aether-proxy.common': common, 'aether-proxy.model.updates': model,
		// The test calls the real inventory and job controls, not the policy form.
		'aether-proxy.form-defaults': {}
	}, env);
	page.inventory = element('div');
	page.summary = element('div');
	page.progress = element('span');
	return { model, common, page };
}

function assert_inventory(model, status, installed) {
	// TODO(design): successful status/job start omit ok in both released and
	// current CLIs; preserve the frozen client's `ok !== false` interpretation.
	assert.notEqual(status.ok, false);
	const table = model.table(status, false, status.updates_available.checked + 10);
	assert.equal(table.error, null);
	assert.equal(table.checked, '10 seconds ago');
	assert.deepEqual(table.rows.map(row => row.name), NAMES);
	for (const row of table.rows) {
		assert.equal(row.installed, installed[row.name]);
		assert.equal(row.available, CURRENT[row.name]);
		assert.equal(row.previous, INSTALLED[row.name]);
		assert.equal(row.update, installed[row.name] !== CURRENT[row.name]);
	}
	assert.deepEqual(model.components(status).map(row => [row.version, row.path]),
		[['26.9.30', '/fixture/xray'], ['fixture-dns', '/fixture/chinadns-ng']]);
	assert.ok(model.components(status)[1].note.includes('(device architecture aarch64_generic)'));
}

function assert_package_text(model, job) {
	assert.equal(job.state, 'ok');
	assert.equal(job.error, null);
	const r = job.result;
	assert.equal(r.ok, true);
	assert.ok(['aether-proxy', 'luci-app-aether-proxy'].includes(r.package));
	assert.equal(r.from, INSTALLED[r.package]);
	assert.equal(r.to, CURRENT[r.package]);
	assert.equal(r.rolled_back, false);
	assert.equal(r.code, null);
	const text = model.job_result('update_package', 'luci-app-aether-proxy', job);
	assert.equal(text, `luci-app-aether-proxy updated from ${r.from} to ${CURRENT[r.package]} ` +
		'Page files may have changed; please refresh your browser.');
	assert.doesNotMatch(text, /Operation failed|Unknown|undefined|failed/i);
	return text;
}

test('T9.39 frozen 0.3.0-r1 clients can update themselves through current CLI', { timeout: 90000 }, async t => {
	const f = await fixture();
	t.after(() => f.close());
	const replies = [];
	const { model, common, page } = old_clients(async (method, args) => {
		const reply = await f.rpc(method, args);
		replies.push({ method, args, reply });
		return reply;
	});
	await t.test('1a status: frozen plugin calls current CLI and old model lists all four packages', async () => {
		page.status = await common.call('status');
		assert_inventory(model, page.status, INSTALLED);
		page.show_inventory();
		assert.ok(page.inventory.textContent.includes('luci-app-aether-proxy'));
		const acl = JSON.parse(fs.readFileSync(path.join(FROZEN,
			'root/usr/share/rpcd/acl.d/luci-app-aether-proxy.json')))['luci-app-aether-proxy'];
		assert.ok(acl.read.ubus.aetherproxy.includes('status'));
		assert.ok(acl.read.ubus.aetherproxy.includes('job_status'));
		assert.ok(acl.write.ubus.aetherproxy.includes('job_start'));
	});
	let check_job;
	await t.test('1b job_start update_check: old page starts a real current background job', async () => {
		await page.run('update_check');
		const start = replies.find(r => r.method === 'job_start');
		assert.deepEqual(start.args, { kind: 'update_check', args: [] });
		assert.match(start.reply.job, /^j_[0-9]+_[0-9]+$/);
		assert.notEqual(start.reply.ok, false);
		check_job = start.reply.job;
	});
	await t.test('1c job_status check: old run_job polls to ok and old model reads packages', () => {
		const polls = replies.filter(r => r.method === 'job_status' && r.args.id === check_job);
		assert.ok(polls.length > 0);
		assert.ok(polls.every(r => ['running', 'ok'].includes(r.reply.state)));
		const job = polls.at(-1).reply;
		assert.equal(job.state, 'ok');
		assert.equal(job.error, null);
		assert.deepEqual(Object.keys(job.result.packages).sort(), [...NAMES].sort());
		assert.equal(model.job_result('update_check', null, job), 'Check complete: 3 packages have updates');
		assert.equal(page.summary.textContent, 'Check complete: 3 packages have updates');
		assert_inventory(model, page.status, INSTALLED);
		assert.equal(page.busy, false);
	});
	let package_job;
	await t.test('1d job_start update_package: old Update now button dispatches luci-app', async () => {
		const row = model.table(page.status, false, Date.now() / 1000).rows
			.find(row => row.name === 'luci-app-aether-proxy');
		assert.equal(row.update, true);
		await page.package_button(row, 'Update now', false).click();
		const start = replies.find(r => r.method === 'job_start' && r.args.kind === 'update_package');
		assert.deepEqual(start.args.args, ['luci-app-aether-proxy']);
		assert.match(start.reply.job, /^j_[0-9]+_[0-9]+$/);
		assert.notEqual(start.reply.ok, false);
		package_job = start.reply.job;
	});
	let completed;
	await t.test('1e job_status package: real worker reaches ok and installs signed local asset', () => {
		const polls = replies.filter(r => r.method === 'job_status' && r.args.id === package_job);
		assert.ok(polls.length > 0);
		assert.ok(polls.every(r => ['running', 'ok'].includes(r.reply.state)));
		completed = polls.at(-1).reply;
		assert.equal(completed.state, 'ok');
		assert.equal(fs.readFileSync(path.join(f.dir, 'installed/luci-app-aether-proxy'), 'utf8').trim(),
			CURRENT['luci-app-aether-proxy']);
		const calls = fs.readFileSync(f.env.UPDATE_PACKAGE_CALLS, 'utf8').trim().split('\n');
		assert.equal(calls.filter(line => line.includes('luci-app-aether-proxy_')).length, 1);
		assert.ok(f.requests.includes('/manifest.json.sig'));
		assert.ok(f.requests.includes('/luci-app-aether-proxy_0.3.1-r1_all.ipk'));
		const cli_calls = fs.readFileSync(path.join(f.dir, 'cli-calls'), 'utf8');
		assert.ok(cli_calls.includes(`job run ${package_job}`));
		assert.ok(cli_calls.includes('update package luci-app-aether-proxy'));
	});
	await t.test('2 install result: frozen model and actual page show successful version text', () => {
		assert.equal(page.summary.textContent, assert_package_text(model, completed));
		assert.equal(page.busy, false);
		const row = model.table(page.status, false, Date.now() / 1000).rows
			.find(row => row.name === 'luci-app-aether-proxy');
		assert.equal(row.installed, CURRENT['luci-app-aether-proxy']);
		assert.equal(row.update, false);
		assert.ok(page.jobButtons.every(button => !button.disabled));
	});
	await t.test('3a negative control: renamed job id makes frozen run_job fail', async () => {
		const broken = structuredClone(replies.find(r => r.method === 'job_start').reply);
		broken.renamed_job = broken.job;
		delete broken.job;
		const old = old_clients(async method => {
			assert.equal(method, 'job_start', 'must not poll an absent job id');
			return broken;
		});
		const result = await old.common.run_job('update_check', []);
		assert.equal(result.ok, false);
		assert.equal(result.code, 'RPC_FAILED');
		assert.equal(result.detail, 'job_start did not return a job id');
	});
	await t.test('3b negative control: renamed packages changes old check result and fails assertion', () => {
		const job = structuredClone(replies.filter(r => r.method === 'job_status' &&
			r.args.id === check_job).at(-1).reply);
		job.result.renamed_packages = job.result.packages;
		delete job.result.packages;
		assert.equal(model.job_result('update_check', null, job), 'Check complete: 0 packages have updates');
		assert.throws(() => assert.equal(model.job_result('update_check', null, job),
			'Check complete: 3 packages have updates'), assert.AssertionError);
	});
	await t.test('3c negative control: renamed to breaks frozen install success text', () => {
		const job = structuredClone(completed);
		job.result.renamed_to = job.result.to;
		delete job.result.to;
		const text = model.job_result('update_package', 'luci-app-aether-proxy', job);
		assert.ok(text.includes('undefined'));
		assert.notEqual(text, page.summary.textContent);
		assert.throws(() => assert.equal(text, page.summary.textContent), assert.AssertionError);
	});
});
