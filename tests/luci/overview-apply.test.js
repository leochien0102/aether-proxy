'use strict';

/* T16.70 (H7): isolated end-to-end tests for overview Apply across
 * view/overview.js -> model/overview.js -> real rpcd aetherproxy.uc ->
 * real aether-proxy CLI -> real libuci committed & session savedir ->
 * isolated init reload reading committed UCI via real pipeline.read & render/nft.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadModule, element, contentChildren } = require('./loader');

const ROOT = path.resolve(__dirname, '../..');
const RES = path.join(ROOT, 'luci-app-aether-proxy/htdocs/luci-static/resources');
const UCODE = path.join(ROOT, 'tests/host/ucode');
const RPCD_PLUGIN = path.join(ROOT, 'luci-app-aether-proxy/root/usr/share/rpcd/ucode/aetherproxy.uc');
const CLI_ENTRY = path.join(ROOT, 'aether-proxy/src/aether-proxy');

const N1 = 'n_' + '1'.padStart(32, '0');
const N2 = 'n_' + '2'.padStart(32, '0');

globalThis._ = text => text;
globalThis.E = element;
const baseclass = { extend: value => value };
const conflicts = loadModule(path.join(RES, 'aether-proxy/model/conflicts.js'), { baseclass }, {});
const logs = loadModule(path.join(RES, 'aether-proxy/model/logs.js'),
	{ baseclass, 'aether-proxy.model.conflicts': conflicts }, {});
const model = loadModule(path.join(RES, 'aether-proxy/model/overview.js'),
	{ baseclass, 'aether-proxy.model.logs': logs, 'aether-proxy.model.conflicts': conflicts }, {});

function all(node, tag) {
	return !node || typeof node !== 'object' ? []
		: [...(node.tag === tag ? [node] : []), ...(node.children ?? []).flatMap(n => all(n, tag))];
}

function runUcode(script, args = [], env = {}) {
	return execFileSync(UCODE, ['-e', script, '--', ...args], {
		cwd: ROOT,
		encoding: 'utf8',
		env: { ...process.env, ...env }
	});
}

function createFixture(opts = {}) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 't1670-'));
	const confdir = path.join(dir, 'etc/config');
	const rundir = path.join(dir, 'var/run/aether-proxy');
	const sessiondir = path.join(dir, 'session');
	const initdir = path.join(dir, 'etc/init.d');
	const bindir = path.join(dir, 'bin');
	const customdir = path.join(dir, 'custom');
	const datadir = path.join(ROOT, 'aether-proxy/files/data');
	for (const d of [confdir, rundir, sessiondir, initdir, bindir, customdir])
		fs.mkdirSync(d, { recursive: true });

	const enabled = opts.enabled ?? '1';
	const extraPorts = opts.extra_ports ?? '8080';
	const baseConfig = [
		'',
		"config main 'main'",
		`\toption enabled '${enabled}'`,
		"\toption mode 'bypass_cn'",
		`\toption node '${N1}'`,
		`\toption extra_ports '${extraPorts}'`,
		"\tlist lan_ifaces 'br-lan'",
		'',
		`config node '${N1}'`,
		"\toption label 'Alpha'",
		"\toption protocol 'vmess'",
		"\toption address '198.51.100.1'",
		"\toption port '443'",
		"\toption uuid '11111111-1111-1111-1111-111111111111'",
		'',
		`config node '${N2}'`,
		"\toption label 'Beta'",
		"\toption protocol 'vmess'",
		"\toption address '198.51.100.2'",
		"\toption port '443'",
		"\toption uuid '22222222-2222-2222-2222-222222222222'",
		''
	].join('\n');
	const configPath = path.join(confdir, 'aetherproxy');
	fs.writeFileSync(configPath, baseConfig);

	const otherConfigPath = path.join(confdir, 'otherpkg');
	fs.writeFileSync(otherConfigPath, "\nconfig section 'sec'\n\toption opt 'committed_val'\n");

	// Seed real libuci session drafts unrelated to this overview Apply.
	runUcode(`
		import * as uci from 'uci';
		let c = uci.cursor(ARGV[0], ARGV[1]);
		if (!c.set('aetherproxy', 'main', 'log_level', 'debug') || !c.save('aetherproxy')) exit(1);
		if (!c.set('otherpkg', 'sec', 'opt', 'draft_val') || !c.save('otherpkg')) exit(1);
	`, [confdir, sessiondir]);

	const draftAetherBefore = fs.readFileSync(path.join(sessiondir, 'aetherproxy'));
	const draftOtherBefore = fs.readFileSync(path.join(sessiondir, 'otherpkg'));

	const statePath = path.join(rundir, 'state.json');
	const initialState = opts.state ?? 'running';
	fs.writeFileSync(statePath, JSON.stringify({
		state: initialState,
		node_id: opts.running_node ?? N1,
		mode: opts.running_mode ?? 'bypass_cn',
		since: 1000
	}) + '\n');

	const daemonLogPath = path.join(dir, 'daemon-seen.jsonl');
	fs.writeFileSync(daemonLogPath, '');
	const faultFile = path.join(dir, 'fault.json');
	fs.writeFileSync(faultFile, JSON.stringify({ init_rc: 0, daemon_fail_count: 0 }));

	// Isolated init script: simulates daemon reading committed UCI via real pipeline.read + render/nft.
	const initPath = path.join(initdir, 'aether-proxy');
	const initHelper = path.join(bindir, 'daemon-reload.uc');
	fs.writeFileSync(initHelper, `'use strict';
import * as fs from 'fs';
import * as pipeline from 'aetherproxy.pipeline';
import * as nft from 'aetherproxy.render.nft';

let confdir = ARGV[0], rundir = ARGV[1], sysroot = ARGV[2], logpath = ARGV[3], faultpath = ARGV[4];
let fault = json(fs.readfile(faultpath));
let rc = fault.init_rc ?? 0;
if (rc != 0) {
	if (fault.init_rc_once) {
		fault.init_rc = 0;
		fault.init_rc_once = false;
		fs.writefile(faultpath, sprintf('%.J', fault));
	}
	warn('injected init reload failure\\n');
	exit(rc);
}

let loaded = pipeline.read({ confdir, data_dir: ARGV[5], baseline_dir: ARGV[5], custom_dir: ARGV[6], sys_root: sysroot });
let st = json(fs.readfile(rundir + '/state.json'));
let stamp = clock();
let at = stamp[0] + stamp[1] / 1000000000.0 + 1.0;

if (!loaded.ok) {
	st.last_reload = { at, target_node: null, target_mode: null, ok: false, error: sprintf('%.J', loaded.errors) };
	fs.writefile(rundir + '/state.json', sprintf('%.J', st) + '\\n');
	let f = fs.open(logpath, 'a');
	f.write(sprintf('%J', { ok: false, error: st.last_reload.error }) + '\\n');
	f.close();
	exit(0);
}

let main = loaded.snapshot.main;
let rendered_nft = nft.render(loaded.snapshot, { node_ip: '198.51.100.1', dns_tier: 'T1', restored: {} });
let fail_left = fault.daemon_fail_count ?? 0;
let ok = fail_left <= 0;
if (!ok) {
	fault.daemon_fail_count = fail_left - 1;
	fs.writefile(faultpath, sprintf('%.J', fault));
}

st.last_reload = {
	at,
	target_node: main.node,
	target_mode: main.mode,
	ok,
	error: ok ? null : 'injected daemon reload failure'
};
if (ok) {
	st.node_id = main.node;
	st.mode = main.mode;
}
fs.writefile(rundir + '/state.json', sprintf('%.J', st) + '\\n');

let f = fs.open(logpath, 'a');
f.write(sprintf('%J', {
	ok,
	node: main.node,
	mode: main.mode,
	port_scope: main.port_scope,
	nft_has_common_ports: index(rendered_nft, 'tcp dport {') >= 0,
	nft_has_8080: index(rendered_nft, '8080') >= 0
}) + '\\n');
f.close();
`);

	fs.writeFileSync(initPath, `#!/bin/sh
exec "${UCODE}" -S "${initHelper}" -- "${confdir}" "${rundir}" "${dir}" "${daemonLogPath}" "${faultFile}" "${datadir}" "${customdir}"
`, { mode: 0o755 });

	// Wrapper CLI invoked by real rpcd plugin so it targets the isolated sysroot/confdir.
	const cliWrap = path.join(bindir, 'aether-proxy');
	fs.writeFileSync(cliWrap, `#!/bin/sh
exec "${UCODE}" -S "${CLI_ENTRY}" -- "$@" --confdir "${confdir}" --sys-root "${dir}"
`, { mode: 0o755 });

	// Helper to call real rpcd plugin methods.
	const rpcdRunner = path.join(bindir, 'call-rpcd.uc');
	fs.writeFileSync(rpcdRunner, `'use strict';
import * as fs from 'fs';
let pluginPath = ARGV[0], method = ARGV[1], argsJson = ARGV[2];
let methods = loadstring(fs.readfile(pluginPath))().aetherproxy;
let args = json(argsJson);
let reply = methods[method].call({ args });
print(sprintf('%.J', reply), '\\n');
`);

	function callRpcd(method, params = {}) {
		// Mirror LuCI rpc.declare: omit undefined values.
		const clean = {};
		for (const [k, v] of Object.entries(params ?? {})) {
			if (v !== undefined)
				clean[k] = v;
		}
		const out = execFileSync(UCODE, ['-S', rpcdRunner, '--', RPCD_PLUGIN, method, JSON.stringify(clean)], {
			cwd: ROOT,
			encoding: 'utf8',
			env: {
				...process.env,
				AETHER_PROXY_TEST_RPCD_CLI: cliWrap,
				AETHER_PROXY_TEST_RPCD_INIT: initPath
			}
		});
		return JSON.parse(out);
	}

	function readCommitted() {
		return JSON.parse(runUcode(`
			import * as uci from 'uci';
			let c = uci.cursor(ARGV[0]);
			c.load(ARGV[0] + '/aetherproxy');
			let other = uci.cursor(ARGV[0]);
			other.load(ARGV[0] + '/otherpkg');
			print(sprintf('%.J', {
				node: c.get('aetherproxy', 'main', 'node'),
				mode: c.get('aetherproxy', 'main', 'mode'),
				port_scope: c.get('aetherproxy', 'main', 'port_scope'),
				log_level: c.get('aetherproxy', 'main', 'log_level'),
				enabled: c.get('aetherproxy', 'main', 'enabled'),
				other_opt: other.get('otherpkg', 'sec', 'opt')
			}));
		`, [confdir]));
	}

	function readSessionView() {
		return JSON.parse(runUcode(`
			import * as uci from 'uci';
			let c = uci.cursor(ARGV[0], ARGV[1]);
			c.load('aetherproxy');
			print(sprintf('%.J', {
				node: c.get('aetherproxy', 'main', 'node'),
				mode: c.get('aetherproxy', 'main', 'mode'),
				port_scope: c.get('aetherproxy', 'main', 'port_scope'),
				enabled: c.get('aetherproxy', 'main', 'enabled')
			}));
		`, [confdir, sessiondir]));
	}

	function daemonSeen() {
		const text = fs.readFileSync(daemonLogPath, 'utf8').trim();
		return text ? text.split('\n').map(line => JSON.parse(line)) : [];
	}

	function setFault(fault) {
		fs.writeFileSync(faultFile, JSON.stringify({ init_rc: 0, daemon_fail_count: 0, ...fault }));
	}

	function draftsIntact() {
		const aPath = path.join(sessiondir, 'aetherproxy');
		const oPath = path.join(sessiondir, 'otherpkg');
		return fs.existsSync(aPath) && fs.existsSync(oPath)
			&& Buffer.compare(fs.readFileSync(aPath), draftAetherBefore) === 0
			&& Buffer.compare(fs.readFileSync(oPath), draftOtherBefore) === 0;
	}

	return {
		dir, confdir, rundir, sessiondir, configPath, statePath,
		callRpcd, readCommitted, readSessionView, daemonSeen, setFault, draftsIntact,
		cleanup: () => fs.rmSync(dir, { recursive: true, force: true })
	};
}

async function mountOverview(fx, opts = {}) {
	let stagedInMem = [];
	const metrics = { uciSetCalls: [], uciSaveCalls: 0, uiApplyCalls: 0, rpcCalls: [] };
	const timers = [];
	const polls = [];
	let loadedCache = null;

	const uciMock = {
		load: async () => { loadedCache = fx.readSessionView(); },
		unload: () => { loadedCache = null; },
		get: (pkg, sec, opt) => {
			if (!loadedCache)
				loadedCache = fx.readSessionView();
			return loadedCache[opt];
		},
		sections: (pkg, type, fn) => {
			if (type === 'node') {
				fn({ '.name': N1, label: 'Alpha' });
				fn({ '.name': N2, label: 'Beta' });
			}
		},
		set: (pkg, sec, opt, val) => {
			metrics.uciSetCalls.push([pkg, sec, opt, val]);
			stagedInMem.push([pkg, sec, opt, val]);
			if (loadedCache && pkg === 'aetherproxy' && sec === 'main')
				loadedCache[opt] = val;
		},
		save: async () => {
			metrics.uciSaveCalls++;
			if (stagedInMem.length) {
				runUcode(`
					import * as uci from 'uci';
					let c = uci.cursor(ARGV[0], ARGV[1]);
					for (let item in json(ARGV[2])) {
						c.set(item[0], item[1], item[2], item[3]);
						c.save(item[0]);
					}
				`, [fx.confdir, fx.sessiondir, JSON.stringify(stagedInMem)]);
				stagedInMem = [];
			}
		},
		changes: async () => JSON.parse(runUcode(`
			import * as uci from 'uci';
			let c = uci.cursor(ARGV[0], ARGV[1]);
			print(sprintf('%.J', c.changes()));
		`, [fx.confdir, fx.sessiondir]))
	};

	const uiMock = {
		createHandlerFn: (ctx, fn) => (...args) => fn.apply(ctx, args),
		changes: {
			apply: async () => {
				metrics.uiApplyCalls++;
				// Real LuCI ui.changes.apply commits ALL session deltas and reloads.
				runUcode(`
					import * as uci from 'uci';
					let c = uci.cursor(ARGV[0], ARGV[1]);
					c.load('aetherproxy');
					c.commit('aetherproxy');
					c.load('otherpkg');
					c.commit('otherpkg');
				`, [fx.confdir, fx.sessiondir]);
				execFileSync(path.join(fx.dir, 'etc/init.d/aether-proxy'), ['reload'], { cwd: ROOT });
			}
		},
		addNotification() {}
	};

	const page = loadModule(path.join(RES, 'view/aether-proxy/overview.js'), {
		view: baseclass,
		uci: uciMock,
		ui: uiMock,
		dom: { content: contentChildren },
		'aether-proxy.model.overview': model,
		'aether-proxy.common': {
			load_config: () => uciMock.load('aetherproxy'),
			hint_icon: ({ text }) => element('span', {}, [text]),
			confirm: async () => true,
			poll: (fn, ms) => { const p = { fn, ms, stop() { this.stopped = true; } }; polls.push(p); return p; },
			call: async (method, params) => {
				metrics.rpcCalls.push([method, params]);
				if (method === 'status')
					return JSON.parse(fs.readFileSync(fx.statePath, 'utf8'));
				if (method === 'node_use' || method === 'mode_use')
					return fx.callRpcd(method, params);
				if (method === 'probe_sites')
					return { ok: true, sites: [{ name: 'google', label: 'Google' }] };
				if (method === 'events')
					return { ok: true, events: opts.events ?? [] };
				return { ok: true, events: [] };
			}
		}
	}, {
		window: {
			localStorage: { getItem: () => '0', setItem() {} },
			setTimeout: (fn, ms) => { const t = { fn, ms }; timers.push(t); return t; },
			clearTimeout: t => { if (t) t.cleared = true; },
			addEventListener() {},
			removeEventListener() {}
		},
		document: { addEventListener() {}, removeEventListener() {} }
	});

	page.render(await page.load());
	await Promise.all([page.initialRequest, page.sitesRequest, page.componentRequest, page.versionRequest]);
	return { page, metrics, timers, polls };
}

test('T16.70: simultaneous node + port_scope commits both, reloads once, daemon sees new scope, drafts intact', async () => {
	const fx = createFixture();
	try {
		const { page, metrics } = await mountOverview(fx);
		page.nodeSelect.value = N2;
		page.nodeSelect.attrs.change();
		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		const applyBtn = all(page.nodeControl, 'button')[0];
		assert.equal(applyBtn.disabled, false);

		await applyBtn.attrs.click();
		// Poll once if switch is waiting on last_reload.
		if (page.switchSession && page.switchSession.phase === 'switching')
			await page.pollSwitch(page.switchSession);

		const committed = fx.readCommitted();
		assert.equal(committed.node, N2, 'committed node must be N2');
		assert.equal(committed.mode, 'bypass_cn', 'committed mode must stay bypass_cn');
		assert.equal(committed.port_scope, 'common', 'committed port_scope must be common');
		assert.equal(committed.log_level, null, 'unrelated draft log_level must not be committed');
		assert.equal(committed.other_opt, 'committed_val', 'unrelated package draft must not be committed');

		const seen = fx.daemonSeen();
		assert.equal(seen.length, 1, 'daemon must reload exactly once');
		assert.equal(seen[0].node, N2);
		assert.equal(seen[0].mode, 'bypass_cn');
		assert.equal(seen[0].port_scope, 'common', 'daemon must actually read new port_scope');
		assert.equal(seen[0].nft_has_common_ports, true, 'daemon nft render must reflect common port_scope');

		assert.equal(fx.draftsIntact(), true, 'unrelated LuCI session drafts must remain untouched');
		assert.equal(metrics.uciSaveCalls, 0, 'overview Apply must not stage via uci.save');
		assert.equal(metrics.uiApplyCalls, 0, 'overview Apply must not call ui.changes.apply');
		assert.equal(page.switchSession?.phase, 'success');
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: node-only change commits only node, does not write port_scope, reloads once, drafts intact', async () => {
	const fx = createFixture();
	try {
		const { page, metrics } = await mountOverview(fx);
		page.nodeSelect.value = N2;
		page.nodeSelect.attrs.change();
		const applyBtn = all(page.nodeControl, 'button')[0];
		await applyBtn.attrs.click();
		if (page.switchSession && page.switchSession.phase === 'switching')
			await page.pollSwitch(page.switchSession);

		const committed = fx.readCommitted();
		assert.equal(committed.node, N2);
		assert.equal(committed.mode, 'bypass_cn');
		assert.equal(committed.port_scope, null, 'unchanged port_scope must not be additionally written');
		assert.equal(fx.daemonSeen().length, 1);
		assert.equal(fx.daemonSeen()[0].node, N2);
		assert.equal(fx.daemonSeen()[0].port_scope, 'all');
		assert.equal(fx.draftsIntact(), true, 'unrelated LuCI session drafts must remain untouched');
		assert.equal(metrics.uciSaveCalls, 0);
		assert.equal(metrics.uiApplyCalls, 0);
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: scope-only change commits only port_scope, reloads once, does not commit or clear drafts', async () => {
	const fx = createFixture();
	try {
		const { page, metrics } = await mountOverview(fx);
		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		const applyBtn = all(page.nodeControl, 'button')[0];
		assert.equal(applyBtn.disabled, false);

		await applyBtn.attrs.click();
		if (page.switchSession && page.switchSession.phase === 'switching')
			await page.pollSwitch(page.switchSession);

		const committed = fx.readCommitted();
		assert.equal(committed.node, N1);
		assert.equal(committed.mode, 'bypass_cn');
		assert.equal(committed.port_scope, 'common');
		assert.equal(committed.log_level, null, 'unrelated aetherproxy draft must not be committed');
		assert.equal(committed.other_opt, 'committed_val', 'unrelated otherpkg draft must not be committed');

		const seen = fx.daemonSeen();
		assert.equal(seen.length, 1, 'daemon must reload exactly once');
		assert.equal(seen[0].node, N1);
		assert.equal(seen[0].mode, 'bypass_cn');
		assert.equal(seen[0].port_scope, 'common');
		assert.equal(seen[0].nft_has_common_ports, true);

		assert.equal(fx.draftsIntact(), true, 'unrelated LuCI session drafts must remain untouched');
		assert.equal(metrics.uciSaveCalls, 0);
		assert.equal(metrics.uiApplyCalls, 0);
		assert.equal(page.switchSession?.phase, 'success');
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: three-way change (node + mode + port_scope) commits all three atomically, reloads once', async () => {
	const fx = createFixture({ extra_ports: '8080' });
	try {
		const { page, metrics } = await mountOverview(fx);
		page.nodeSelect.value = N2;
		page.nodeSelect.attrs.change();
		page.modeSelect.value = 'gfw';
		page.modeSelect.attrs.change();
		page.portScopeSelect.value = 'common_extra';
		page.portScopeSelect.attrs.change();

		const applyBtn = all(page.nodeControl, 'button')[0];
		await applyBtn.attrs.click();
		if (page.switchSession && page.switchSession.phase === 'switching')
			await page.pollSwitch(page.switchSession);

		const committed = fx.readCommitted();
		assert.equal(committed.node, N2);
		assert.equal(committed.mode, 'gfw');
		assert.equal(committed.port_scope, 'common_extra');

		const seen = fx.daemonSeen();
		assert.equal(seen.length, 1);
		assert.equal(seen[0].node, N2);
		assert.equal(seen[0].mode, 'gfw');
		assert.equal(seen[0].port_scope, 'common_extra');
		assert.equal(seen[0].nft_has_8080, true);
		assert.equal(fx.draftsIntact(), true);
		assert.equal(metrics.uciSaveCalls, 0);
		assert.equal(metrics.uiApplyCalls, 0);
		assert.equal(page.switchSession?.phase, 'success');
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: no-op Apply stays disabled and backend no-op does zero writes and zero reloads', async () => {
	const fx = createFixture();
	try {
		const { page, metrics } = await mountOverview(fx);
		const applyBtn = all(page.nodeControl, 'button')[0];
		assert.equal(applyBtn.disabled, true);
		const beforeBytes = fs.readFileSync(fx.configPath);
		await applyBtn.attrs.click();
		assert.equal(fx.daemonSeen().length, 0);
		assert.equal(Buffer.compare(fs.readFileSync(fx.configPath), beforeBytes), 0);
		assert.equal(metrics.uciSaveCalls, 0);
		assert.equal(metrics.uiApplyCalls, 0);

		// Direct rpcd call with same effective port_scope ('all' when unset) is also a no-op.
		const reply = fx.callRpcd('node_use', { id: N1, port_scope: 'all' });
		assert.equal(reply.ok, true);
		assert.equal(reply.reload, false);
		assert.equal(reply.committed, true);
		assert.equal(fx.daemonSeen().length, 0);
		assert.equal(Buffer.compare(fs.readFileSync(fx.configPath), beforeBytes), 0);
		assert.equal(fx.draftsIntact(), true);
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: invalid port_scope is rejected without writing config, reloading, or touching drafts', async () => {
	const fx = createFixture();
	try {
		const beforeBytes = fs.readFileSync(fx.configPath);
		for (const [method, params] of [
			['node_use', { id: N2, port_scope: 'bogus' }],
			['mode_use', { mode: 'gfw', port_scope: 'bogus' }],
			['node_use', { id: N2, port_scope: 'all;reboot' }]
		]) {
			const reply = fx.callRpcd(method, params);
			assert.equal(reply.ok, false, method + ' must reject invalid port_scope');
			assert.equal(reply.code, 'USAGE');
			assert.equal(Buffer.compare(fs.readFileSync(fx.configPath), beforeBytes), 0);
			assert.equal(fx.daemonSeen().length, 0);
			assert.equal(fx.draftsIntact(), true);
		}
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: invalid extra_ports with common_extra fails preflight (committed:false), no write or reload', async () => {
	const fx = createFixture({ extra_ports: 'not-a-port' });
	try {
		const { page } = await mountOverview(fx);
		const beforeBytes = fs.readFileSync(fx.configPath);
		page.portScopeSelect.value = 'common_extra';
		page.portScopeSelect.attrs.change();
		const applyBtn = all(page.nodeControl, 'button')[0];
		await applyBtn.attrs.click();

		assert.equal(page.switchSession?.phase, 'preflight-failed');
		assert.equal(Buffer.compare(fs.readFileSync(fx.configPath), beforeBytes), 0);
		assert.equal(fx.daemonSeen().length, 0);
		assert.equal(fx.draftsIntact(), true);
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: daemon reload failure rolls back node, mode, and port_scope and restores daemon state', async () => {
	const fx = createFixture();
	try {
		fx.setFault({ daemon_fail_count: 1 });
		const { page } = await mountOverview(fx);
		page.nodeSelect.value = N2;
		page.nodeSelect.attrs.change();
		page.modeSelect.value = 'gfw';
		page.modeSelect.attrs.change();
		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();

		const applyBtn = all(page.nodeControl, 'button')[0];
		await applyBtn.attrs.click();
		// handleNode's initial pollSwitch observes daemon last_reload.ok === false -> triggers rollback.
		assert.equal(page.switchSession?.phase, 'rolling-back');
		// Next poll observes rollback reload succeeded.
		await page.pollSwitch(page.switchSession);
		assert.equal(page.switchSession?.phase, 'rolled-back');

		const committed = fx.readCommitted();
		assert.equal(committed.node, N1);
		assert.equal(committed.mode, 'bypass_cn');
		assert.equal(committed.port_scope, 'all');

		const seen = fx.daemonSeen();
		assert.equal(seen.length, 2, 'forward failed reload + rollback reload');
		assert.equal(seen[0].ok, false);
		assert.equal(seen[0].port_scope, 'common');
		assert.equal(seen[1].ok, true);
		assert.equal(seen[1].node, N1);
		assert.equal(seen[1].mode, 'bypass_cn');
		assert.equal(seen[1].port_scope, 'all');
		assert.equal(fx.draftsIntact(), true);
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: init reload failure after commit triggers rollback and reports rollback failure if restore also fails', async () => {
	const fx = createFixture();
	try {
		// Case A: init fails once (forward), succeeds on rollback.
		fx.setFault({ init_rc: 7, init_rc_once: true });
		const { page } = await mountOverview(fx);
		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		await all(page.nodeControl, 'button')[0].attrs.click();
		assert.equal(page.switchSession?.phase, 'rolling-back');
		await page.pollSwitch(page.switchSession);
		assert.equal(page.switchSession?.phase, 'rolled-back');
		assert.equal(fx.readCommitted().port_scope, 'all');
		assert.equal(fx.daemonSeen().length, 1);
		assert.equal(fx.daemonSeen()[0].port_scope, 'all');
		assert.equal(fx.draftsIntact(), true);

		// Case B: both forward and rollback fail -> explicit rollback-failed, never claims success.
		page.closeSwitch(true);
		fx.setFault({ daemon_fail_count: 2 });
		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		await all(page.nodeControl, 'button')[0].attrs.click();
		assert.equal(page.switchSession?.phase, 'rolling-back');
		await page.pollSwitch(page.switchSession);
		assert.equal(page.switchSession?.phase, 'rollback-failed');
		assert.ok(page.switchBanner, 'rollback failure must persist a warning banner');
		assert.equal(fx.draftsIntact(), true);
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70: disabled/stopped service commits changes without starting or reloading', async () => {
	const fx = createFixture({ enabled: '0', state: 'stopped' });
	try {
		const { page } = await mountOverview(fx);
		page.nodeSelect.value = N2;
		page.nodeSelect.attrs.change();
		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		await all(page.nodeControl, 'button')[0].attrs.click();

		const committed = fx.readCommitted();
		assert.equal(committed.enabled, '0', 'must not alter disabled startup policy');
		assert.equal(committed.node, N2);
		assert.equal(committed.port_scope, 'common');
		assert.equal(fx.daemonSeen().length, 0, 'stopped service must not reload or start');
		assert.equal(fx.draftsIntact(), true);
		assert.equal(page.switchSession?.phase, 'success');
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70 rework: committed N1 vs running N2 blocks Apply while external switch is pending without failure reason', async () => {
	const fx = createFixture({ running_node: N2 });
	try {
		const { page, metrics } = await mountOverview(fx, { events: [] });
		const beforeBytes = fs.readFileSync(fx.configPath);
		assert.equal(page.vm.switch_busy, true, 'mismatch without failure event must keep switch_busy');
		assert.equal(page.portScopeSelect.disabled, true, 'port scope selector must be disabled while busy');
		const applyBtn = all(page.nodeControl, 'button')[0];
		assert.equal(applyBtn.disabled, true, 'Apply button must be blocked while switch_busy');

		await applyBtn.attrs.click();
		assert.equal(metrics.rpcCalls.filter(([m]) => m === 'node_use' || m === 'mode_use').length, 0);
		assert.equal(Buffer.compare(fs.readFileSync(fx.configPath), beforeBytes), 0);
		assert.equal(fx.daemonSeen().length, 0);
		assert.equal(fx.draftsIntact(), true);
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70 rework: committed N1 vs running N2 scope-only via real Apply button keeps committed N1 and mode untouched', async () => {
	const fx = createFixture({ running_node: N2 });
	try {
		const priorFailure = [{ ts: 1005, code: 'START_FAILED', args: { step: 'reload:actions', detail: 'prior reload failed' } }];
		const { page, metrics } = await mountOverview(fx, { events: priorFailure });
		assert.equal(page.vm.switch_busy, false, 'settled failure reason must allow Apply without bypassing UI');
		assert.equal(page.nodeSelect.value, N2, 'UI shows running node N2');

		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		const applyBtn = all(page.nodeControl, 'button')[0];
		assert.equal(applyBtn.disabled, false, 'Apply button must be enabled for scope-only change');

		await applyBtn.attrs.click();
		if (page.switchSession && page.switchSession.phase === 'switching')
			await page.pollSwitch(page.switchSession);

		const switchRpcs = metrics.rpcCalls.filter(([m]) => m === 'node_use' || m === 'mode_use');
		assert.deepEqual(switchRpcs, [['mode_use', { port_scope: 'common' }]],
			'scope-only must not borrow running node or mode');

		const committed = fx.readCommitted();
		assert.equal(committed.node, N1, 'committed node must remain N1');
		assert.equal(committed.mode, 'bypass_cn', 'committed mode must remain unchanged');
		assert.equal(committed.port_scope, 'common', 'committed port_scope must be common');

		const seen = fx.daemonSeen();
		assert.equal(seen.length, 1, 'running daemon must receive exactly one reload');
		assert.equal(seen[0].node, N1);
		assert.equal(seen[0].mode, 'bypass_cn');
		assert.equal(seen[0].port_scope, 'common');
		assert.equal(seen[0].nft_has_common_ports, true);

		assert.equal(fx.draftsIntact(), true, 'unrelated LuCI session drafts must remain untouched');
		assert.equal(metrics.uciSaveCalls, 0);
		assert.equal(metrics.uiApplyCalls, 0);
		assert.equal(page.switchSession?.phase, 'success');
	}
	finally {
		fx.cleanup();
	}
});

test('T16.70 rework: committed N1 vs running N2 scope-only rollback restores only port_scope without writing node or mode', async () => {
	const fx = createFixture({ running_node: N2 });
	try {
		fx.setFault({ daemon_fail_count: 1 });
		const priorFailure = [{ ts: 1005, code: 'START_FAILED', args: { step: 'reload:actions', detail: 'prior reload failed' } }];
		const { page, metrics } = await mountOverview(fx, { events: priorFailure });
		assert.equal(page.vm.switch_busy, false);

		page.portScopeSelect.value = 'common';
		page.portScopeSelect.attrs.change();
		const applyBtn = all(page.nodeControl, 'button')[0];
		assert.equal(applyBtn.disabled, false);

		await applyBtn.attrs.click();
		assert.equal(page.switchSession?.phase, 'rolling-back');
		await page.pollSwitch(page.switchSession);
		assert.equal(page.switchSession?.phase, 'rolled-back');

		const switchRpcs = metrics.rpcCalls.filter(([m]) => m === 'node_use' || m === 'mode_use');
		assert.deepEqual(switchRpcs, [
			['mode_use', { port_scope: 'common' }],
			['mode_use', { port_scope: 'all' }]
		], 'forward and rollback RPCs must only pass port_scope');

		const committed = fx.readCommitted();
		assert.equal(committed.node, N1, 'committed node must remain N1 after rollback');
		assert.equal(committed.mode, 'bypass_cn', 'committed mode must remain unchanged after rollback');
		assert.equal(committed.port_scope, 'all', 'port_scope must be restored to all');

		const seen = fx.daemonSeen();
		assert.equal(seen.length, 2, 'forward failed reload + rollback reload');
		assert.equal(seen[0].ok, false);
		assert.equal(seen[0].node, N1);
		assert.equal(seen[0].port_scope, 'common');
		assert.equal(seen[1].ok, true);
		assert.equal(seen[1].node, N1);
		assert.equal(seen[1].mode, 'bypass_cn');
		assert.equal(seen[1].port_scope, 'all');
		assert.equal(fx.draftsIntact(), true);
	}
	finally {
		fx.cleanup();
	}
});
