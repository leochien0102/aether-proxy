'use strict';
// rpcd plugin scenarios for docs/tasks/m8.md T8.1, numbered like the card.
//
// The plugin file is loaded exactly the way rpcd loads it: compile the source
// and take the returned object (the file has no exports, so `import` would see
// an empty namespace). The aether-proxy CLI and the init script are replaced by
// tests/rpcd/stub-cli.sh and tests/rpcd/stub-init.sh; their behavior is set per
// scenario through the control file, and their invocations are recorded in log
// files, all exported by tests/rpcd/run.sh. The real binaries are never run.

import * as fs from 'fs';

const ROOT = fs.realpath(sourcepath(0, true) + '/../..');
const PLUGIN_PATH = ROOT + '/luci-app-aether-proxy/root/usr/share/rpcd/ucode/aetherproxy.uc';
const ACL_PATH = ROOT + '/luci-app-aether-proxy/root/usr/share/rpcd/acl.d/luci-app-aether-proxy.json';

const CTRL = getenv('RPCD_TEST_CTRL');
const CLI_LOG = getenv('RPCD_TEST_CLI_LOG');
const INIT_LOG = getenv('RPCD_TEST_INIT_LOG');

if (CTRL == null || CLI_LOG == null || INIT_LOG == null) {
	warn('rpcd tests: RPCD_TEST_CTRL, RPCD_TEST_CLI_LOG and RPCD_TEST_INIT_LOG must be set\n');
	exit(2);
}

// ---------------------------------------------------------------- helpers

let pass = 0, fail = 0;

function ok(name) {
	pass++;
	print(`PASS  ${name}\n`);
}

function bad(name, detail) {
	fail++;
	print(`FAIL  ${name}${detail != null ? `: ${detail}` : ''}\n`);
}

function check(name, cond, detail) {
	cond ? ok(name) : bad(name, detail);
}

function show(v) {
	return sprintf('%J', v ?? null);
}

function expect_eq(name, want, got) {
	check(name, want == got, `expected ${show(want)}, got ${show(got)}`);
}

// Structural equality over JSON-shaped values; types must match exactly.
function deep_eq(a, b) {
	let ta = type(a);

	if (ta != type(b))
		return false;

	if (ta == 'array') {
		if (length(a) != length(b))
			return false;
		for (let i = 0; i < length(a); i++)
			if (!deep_eq(a[i], b[i]))
				return false;
		return true;
	}

	if (ta == 'object') {
		let ka = sort(keys(a));
		let kb = sort(keys(b));

		if (join('|', ka) != join('|', kb))
			return false;

		for (let k in ka)
			if (!deep_eq(a[k], b[k]))
				return false;

		return true;
	}

	return a === b;
}

// Rewrites the stub control file (tab-separated, reread by the stub on every
// invocation).
function stub_ctrl(values) {
	let text = '';

	for (let key in [ 'exit', 'stdout', 'stderr', 'sleep' ])
		text += `${key}\t${values[key] ?? ''}\n`;

	if (!fs.writefile(CTRL, text))
		die(`cannot write ${CTRL}: ${fs.error() ?? 'unknown error'}`);
}

// Drops the CLI stub log; the returned function yields the argv of the stub's
// next invocation, or null while the stub has not been called at all.
function watch_cli() {
	fs.unlink(CLI_LOG);
	return function() {
		let text = fs.readfile(CLI_LOG);
		if (text == null)
			return null;

		let argv = [];
		for (let line in split(text, '\n')) {
			if (line == '---')
				break;
			if (substr(line, 0, 4) == 'ARG=')
				push(argv, substr(line, 4));
		}
		return argv;
	};
}

// Same for the init stub's recorded action.
function watch_init() {
	fs.unlink(INIT_LOG);
	return function() {
		let text = fs.readfile(INIT_LOG);
		if (text == null)
			return null;

		for (let line in split(text, '\n'))
			if (substr(line, 0, 7) == 'ACTION=')
				return substr(line, 7);

		return null;
	};
}

function elapsed(t0) {
	let t = clock();
	return (t[0] - t0[0]) + (t[1] - t0[1]) / 1e9;
}

// Polls until read() yields a value or the timeout passes. The init stub logs
// before it sleeps, so a short poll is enough; sleeping stubs left behind exit
// on their own and are not waited for.
function wait_for(read, timeout_s) {
	let t0 = clock();

	for (;;) {
		let v = read();
		if (v != null)
			return v;
		if (elapsed(t0) > timeout_s)
			return null;
		system([ 'sleep', '0.05' ]);
	}
}

function node_id(i) {
	return 'n_' + sprintf('%032x', i);
}

function sub_id(i) {
	return 's_' + sprintf('%08x', i);
}

function n_ids(count) {
	let ids = [];
	for (let i = 1; i <= count; i++)
		push(ids, node_id(i));
	return ids;
}

// Load the plugin the way rpcd does: compile the file and take its return value.
const plugin_src = fs.readfile(PLUGIN_PATH);

if (plugin_src == null) {
	bad('rpcd plugin file is readable', `${PLUGIN_PATH}: ${fs.error() ?? 'unknown error'}`);
	print(`\n${pass} passed, ${fail} failed\n`);
	exit(1);
}

const methods = loadstring(plugin_src)()?.aetherproxy;

if (methods == null) {
	bad('plugin file returns { aetherproxy: methods }', PLUGIN_PATH);
	print(`\n${pass} passed, ${fail} failed\n`);
	exit(1);
}

// --- 1: version / status forward verbatim and return the CLI object as-is ---
function scenario_1() {
	let out = { ok: true, version: '0.1.0-r1', meta: { a: [ 1, 2 ], b: null, c: false } };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', out) });

	let argv_of = watch_cli();
	let r = methods.version.call({ args: {} });
	expect_eq('1. version: stub received exactly [version, --json]',
		show([ 'version', '--json' ]), show(argv_of()));
	check('1. version: reply deep-equals the stub output object', deep_eq(r, out), show(r));

	let out2 = { ok: true, state: 'running', probe: { at: 1760400000, total: 3, reachable: 3 }, updates_available: null };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', out2) });

	argv_of = watch_cli();
	r = methods.status.call({ args: {} });
	expect_eq('1. status: stub received exactly [status, --json]',
		show([ 'status', '--json' ]), show(argv_of()));
	check('1. status: reply deep-equals the stub output object', deep_eq(r, out2), show(r));
}

// --- 2: a non-zero exit with a JSON object on stdout is returned unchanged ---
function scenario_2() {
	// `job start` busy: exit 3 and {"ok":false,"code":"BUSY","job":...}
	let busy = { ok: false, code: 'BUSY', job: 'j_1_2' };
	stub_ctrl({ exit: 3, stdout: sprintf('%J', busy) });

	let argv_of = watch_cli();
	let r = methods.job_start.call({ args: { kind: 'probe_nodes', args: [] } });
	check('2. job_start busy (exit 3): JSON object returned unchanged', deep_eq(r, busy), show(r));
	expect_eq('2. job_start busy: stub received the job start command',
		show([ 'job', 'start', 'probe', 'nodes', '--json' ]), show(argv_of()));

	// The rule holds for every method: exit 1 with a JSON object is not CMD_FAILED.
	let failobj = { ok: false, code: 'CONFIG_INVALID', detail: 'main.enabled is set but no node exists' };
	stub_ctrl({ exit: 1, stdout: sprintf('%J', failobj) });

	r = methods.version.call({ args: {} });
	check('2. version exit 1: JSON object returned unchanged', deep_eq(r, failobj), show(r));
}

// --- 3: stdout that is not a JSON object becomes CMD_FAILED, stderr head ---
function scenario_3() {
	let big_err = '';
	for (let i = 0; i < 200; i++)
		big_err += '0123456789';

	stub_ctrl({ exit: 1, stdout: 'terminate called after throwing an instance', stderr: big_err });
	let r = methods.status.call({ args: {} });

	check('3. status non-JSON stdout: ok false', r?.ok === false, show(r));
	expect_eq('3. status non-JSON stdout: code CMD_FAILED', 'CMD_FAILED', r?.code);
	check('3. status non-JSON stdout: detail starts with "exit 1: "',
		substr(r?.detail ?? '', 0, 8) == 'exit 1: ', show(r?.detail));
	expect_eq('3. status non-JSON stdout: detail carries exactly 512 bytes of stderr',
		8 + 512, length(r?.detail));
	check('3. status non-JSON stdout: detail carries the first 512 stderr bytes',
		substr(r?.detail ?? '', 8) == substr(big_err, 0, 512), show(r?.detail));

	// A JSON array is not a JSON object either (empty stderr: "exit 1: " + '').
	stub_ctrl({ exit: 1, stdout: '[1,2]' });
	r = methods.events.call({ args: {} });
	check('3. events JSON-array stdout: CMD_FAILED, not the array',
		deep_eq(r, { ok: false, code: 'CMD_FAILED', detail: 'exit 1: ' }), show(r));
}

// --- 4: a CLI sleeping past the timeout yields "timeout after Ns" ---
function scenario_4() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true}', sleep: 11 });
	let t0 = clock();
	let r = methods.status.call({ args: {} });
	let dt = elapsed(t0);

	expect_eq('4. status sleeping 11s: code CMD_FAILED (10s timeout)', 'CMD_FAILED', r?.code);
	expect_eq('4. status sleeping 11s: detail is exactly "timeout after 10s"',
		'timeout after 10s', r?.detail);
	check('4. status sleeping 11s: reply returned within 15s', dt < 15, sprintf('%.1fs', dt));

	// check has its own 30s budget: an 11s stub is answered, not killed.
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"staging":"/var/run/aether-proxy/staging"}', sleep: 11 });
	let argv_of = watch_cli();
	t0 = clock();
	r = methods.check.call({ args: {} });
	dt = elapsed(t0);

	check('4. check sleeping 11s: answered by the 30s budget',
		deep_eq(r, { ok: true, staging: '/var/run/aether-proxy/staging' }), show(r));
	check('4. check sleeping 11s: the call took over 10s (10 < t < 29)', dt > 10 && dt < 29, sprintf('%.1fs', dt));
	expect_eq('4. check: stub received exactly [check, --json]',
		show([ 'check', '--json' ]), show(argv_of()));
}

// --- 5: service backgrounds the init script and reports immediately ---
function scenario_5() {
	for (let action in [ 'start', 'stop', 'restart' ]) {
		let action_of = watch_init();
		let t0 = clock();
		let r = methods.service.call({ args: { action: action } });
		let dt = elapsed(t0);

		check(`5. service ${action}: reply is {"ok":true,"action":"${action}"}`,
			deep_eq(r, { ok: true, action: action }), show(r));
		check(`5. service ${action}: returned within 1s while the init stub sleeps 5s`,
			dt < 1, sprintf('%.2fs', dt));
		expect_eq(`5. service ${action}: init stub recorded the action`, action, wait_for(action_of, 3));
	}

	// Invalid, mistyped and missing actions never reach the init script.
	let rejects = [
		{ name: 'unknown action reload', args: { action: 'reload' } },
		{ name: 'action with shell metacharacters', args: { action: 'start;reboot' } },
		{ name: 'action not a string', args: { action: 7 } },
		{ name: 'action missing', args: {} }
	];

	for (let c in rejects) {
		let action_of = watch_init();
		let r = methods.service.call({ args: c.args });
		check(`5. service ${c.name}: USAGE`, r?.ok === false && r?.code == 'USAGE', show(r));
		check(`5. service ${c.name}: init stub not called`, action_of() == null, 'the init stub was invoked');
	}
}

// --- 6: job_start forwards exactly the parameter-table command ---
function scenario_6() {
	let job_ok = { ok: true, job: 'j_1760400000_1234' };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', job_ok) });

	let cases = [
		{ name: 'probe_nodes with 0 ids', args: { kind: 'probe_nodes', args: [] },
		  want: [ 'job', 'start', 'probe', 'nodes', '--json' ] },
		{ name: 'probe_nodes with 2 ids', args: { kind: 'probe_nodes', args: n_ids(2) },
		  want: [ 'job', 'start', 'probe', 'nodes', node_id(1), node_id(2), '--json' ] },
		{ name: 'probe_nodes with 256 ids (upper bound)', args: { kind: 'probe_nodes', args: n_ids(256) },
		  want: [ 'job', 'start', 'probe', 'nodes', ...n_ids(256), '--json' ] },
		{ name: 'sub_update without id', args: { kind: 'sub_update', args: [] },
		  want: [ 'job', 'start', 'sub', 'update', '--json' ] },
		{ name: 'sub_update with 1 id', args: { kind: 'sub_update', args: [ sub_id(0x9a) ] },
		  want: [ 'job', 'start', 'sub', 'update', sub_id(0x9a), '--json' ] },
		{ name: 'update_check without args', args: { kind: 'update_check' },
		  want: [ 'job', 'start', 'update', 'check', '--json' ] },
		{ name: 'update_data with empty args', args: { kind: 'update_data', args: [] },
		  want: [ 'job', 'start', 'update', 'data', '--json' ] },
		{ name: 'update_package with a package', args: { kind: 'update_package', args: [ 'xray-core' ] },
		  want: [ 'job', 'start', 'update', 'package', 'xray-core', '--json' ] },
		{ name: 'update_package with --previous',
		  args: { kind: 'update_package', args: [ 'luci-app-aether-proxy', '--previous' ] },
		  want: [ 'job', 'start', 'update', 'package', 'luci-app-aether-proxy', '--previous', '--json' ] }
	];

	for (let c in cases) {
		let argv_of = watch_cli();
		let r = methods.job_start.call({ args: c.args });
		check(`6. ${c.name}: stub received exactly the parameter-table command`,
			deep_eq(argv_of(), c.want), show(argv_of()));
		check(`6. ${c.name}: reply is the CLI JSON object`, deep_eq(r, job_ok), show(r));
	}
}

// --- 7: invalid job_start arguments are rejected without calling the stub ---
function scenario_7() {
	let cases = [
		{ name: 'unknown kind probe', args: { kind: 'probe' } },
		{ name: 'unknown kind Probe_Nodes', args: { kind: 'Probe_Nodes' } },
		{ name: 'kind missing', args: {} },
		{ name: 'kind not a string', args: { kind: 7 } },
		{ name: 'args not an array (string)', args: { kind: 'probe_nodes', args: 'n_x' } },
		{ name: 'args not an array (object)', args: { kind: 'update_check', args: {} } },
		{ name: 'args element not a string', args: { kind: 'probe_nodes', args: [ 17 ] } },
		{ name: 'node id wrong prefix', args: { kind: 'probe_nodes', args: [ 'x_00000000000000000000000000000001' ] } },
		{ name: 'node id too short', args: { kind: 'probe_nodes', args: [ 'n_123' ] } },
		{ name: 'node id with injected shell command', args: { kind: 'probe_nodes', args: [ node_id(9) + ';reboot' ] } },
		{ name: 'node id uppercase hex', args: { kind: 'probe_nodes', args: [ 'n_ABCDEF0123456789ABCDEF0123456789' ] } },
		{ name: '257 node ids', args: { kind: 'probe_nodes', args: n_ids(257) } },
		{ name: 'duplicate node ids', args: { kind: 'probe_nodes', args: [ node_id(1), node_id(1) ] } },
		{ name: 'sub_update with 2 ids', args: { kind: 'sub_update', args: [ sub_id(1), sub_id(2) ] } },
		{ name: 'sub_update id wrong format', args: { kind: 'sub_update', args: [ 'sub_12345678' ] } },
		{ name: 'sub_update id too long', args: { kind: 'sub_update', args: [ sub_id(1) + 'f' ] } },
		{ name: 'update_check with args', args: { kind: 'update_check', args: [ '--json' ] } },
		{ name: 'update_data with args', args: { kind: 'update_data', args: [ 'force' ] } },
		{ name: 'update_package unknown package', args: { kind: 'update_package', args: [ 'nginx' ] } },
		{ name: 'update_package wrong spelling', args: { kind: 'update_package', args: [ 'aether_proxy' ] } },
		{ name: 'update_package missing package', args: { kind: 'update_package', args: [] } },
		{ name: 'update_package --previous without package', args: { kind: 'update_package', args: [ '--previous' ] } },
		{ name: 'update_package --previous before package', args: { kind: 'update_package', args: [ '--previous', 'xray-core' ] } },
		{ name: 'update_package extra argument', args: { kind: 'update_package', args: [ 'xray-core', '--previous', 'x' ] } },
		{ name: 'update_package wrong second argument', args: { kind: 'update_package', args: [ 'xray-core', '--first' ] } }
	];

	for (let c in cases) {
		let argv_of = watch_cli();
		let r = methods.job_start.call({ args: c.args });
		check(`7. ${c.name}: USAGE`, r?.ok === false && r?.code == 'USAGE', show(r));
		check(`7. ${c.name}: stub not called`, argv_of() == null, show(argv_of()));
	}
}

// --- 8: job_status forwards valid ids and rejects malformed ones ---
function scenario_8() {
	let job = { ok: true, job: { id: 'j_1760400000_1234', kind: 'probe_nodes', state: 'running' } };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', job) });

	let argv_of = watch_cli();
	let r = methods.job_status.call({ args: { id: 'j_1760400000_1234' } });
	expect_eq('8. job_status valid id: stub received [job, status, <id>, --json]',
		show([ 'job', 'status', 'j_1760400000_1234', '--json' ]), show(argv_of()));
	check('8. job_status valid id: reply is the CLI JSON object', deep_eq(r, job), show(r));

	let rejects = [
		{ name: 'id without pid part (j_1)', args: { id: 'j_1' } },
		{ name: 'id with injected shell command', args: { id: 'j_1_2;x' } },
		{ name: 'id missing', args: {} },
		{ name: 'id not a string', args: { id: 12 } },
		{ name: 'id empty', args: { id: '' } }
	];

	for (let c in rejects) {
		let argv_of2 = watch_cli();
		let r2 = methods.job_status.call({ args: c.args });
		check(`8. job_status ${c.name}: USAGE`, r2?.ok === false && r2?.code == 'USAGE', show(r2));
		check(`8. job_status ${c.name}: stub not called`, argv_of2() == null, show(argv_of2()));
	}
}

// --- 9: events maps since/level to CLI options and validates them ---
function scenario_9() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"events":[]}' });

	let cases = [
		{ name: 'no arguments', args: {}, want: [ 'events', '--json' ] },
		{ name: 'since only', args: { since: 1000 }, want: [ 'events', '--since', '1000', '--json' ] },
		{ name: 'level only', args: { level: 'debug' }, want: [ 'events', '--level', 'debug', '--json' ] },
		{ name: 'since and level', args: { since: 1000, level: 'warn' },
		  want: [ 'events', '--since', '1000', '--level', 'warn', '--json' ] },
		{ name: 'since 0 stays a valid timestamp', args: { since: 0 }, want: [ 'events', '--since', '0', '--json' ] }
	];

	for (let c in cases) {
		let argv_of = watch_cli();
		let r = methods.events.call({ args: c.args });
		check(`9. events ${c.name}: stub received exactly the mapped options`,
			deep_eq(argv_of(), c.want), show(argv_of()));
		check(`9. events ${c.name}: reply is the CLI JSON object`,
			deep_eq(r, { ok: true, events: [] }), show(r));
	}

	let rejects = [
		{ name: 'negative since', args: { since: -1 } },
		{ name: 'fractional since', args: { since: 1.5 } },
		{ name: 'string since', args: { since: '1000' } },
		{ name: 'boolean since', args: { since: true } },
		{ name: 'level outside the enum', args: { level: 'verbose' } },
		{ name: 'level uppercase', args: { level: 'ERROR' } },
		{ name: 'level not a string', args: { level: 3 } }
	];

	for (let c in rejects) {
		let argv_of = watch_cli();
		let r = methods.events.call({ args: c.args });
		check(`9. events ${c.name}: USAGE`, r?.ok === false && r?.code == 'USAGE', show(r));
		check(`9. events ${c.name}: stub not called`, argv_of() == null, show(argv_of()));
	}
}

// --- 10: ACL grants exactly the plugin's methods, each exactly once ---
function scenario_10() {
	let acl = json(fs.readfile(ACL_PATH));
	let app = acl?.['luci-app-aether-proxy'];

	expect_eq('10. ACL read methods are exactly version/status/events/job_status',
		show([ 'events', 'job_status', 'status', 'version' ]),
		show(sort(app?.read?.ubus?.aetherproxy ?? [])));
	expect_eq('10. ACL write methods are exactly service/check/job_start',
		show([ 'check', 'job_start', 'service' ]),
		show(sort(app?.write?.ubus?.aetherproxy ?? [])));
	check('10. ACL read keeps the aetherproxy UCI grant',
		deep_eq(app?.read?.uci, [ 'aetherproxy' ]), show(app?.read?.uci));
	check('10. ACL write keeps the aetherproxy UCI grant',
		deep_eq(app?.write?.uci, [ 'aetherproxy' ]), show(app?.write?.uci));

	let names = sort(keys(methods));
	expect_eq('10. plugin exposes exactly the T8.1 methods',
		show([ 'check', 'events', 'job_start', 'job_status', 'service', 'status', 'version' ]),
		show(names));

	check('10. version declares empty args', deep_eq(methods.version.args, {}), show(methods.version.args));
	check('10. status declares empty args', deep_eq(methods.status.args, {}), show(methods.status.args));
	check('10. check declares empty args', deep_eq(methods.check.args, {}), show(methods.check.args));
	// rpcd builds the ubus policy from the *type* of each example value (rpcd ucode.c: boolean ->
	// int8, integer -> int32 (8/16/64 select other widths), double, array, object -> table,
	// anything else -> string) and rejects a call whose argument has another type. So
	// `since: 'int'` would declare a string and every integer `since` sent by LuCI would fail.
	let rpcd_policy = (args) => {
		let out = {};
		for (let k, v in args) {
			let t = type(v);
			out[k] = t == 'bool' ? 'int8' : t == 'int' ? (v == 8 ? 'int8' : v == 16 ? 'int16' : v == 64 ? 'int64' : 'int32')
				: t == 'double' ? 'double' : t == 'array' ? 'array' : t == 'object' ? 'table' : 'string';
		}
		return out;
	};
	check('10. service policy: action string', deep_eq(rpcd_policy(methods.service.args), { action: 'string' }), show(methods.service.args));
	check('10. job_start policy: kind string, args array',
		deep_eq(rpcd_policy(methods.job_start.args), { kind: 'string', args: 'array' }), show(methods.job_start.args));
	check('10. job_status policy: id string', deep_eq(rpcd_policy(methods.job_status.args), { id: 'string' }), show(methods.job_status.args));
	check('10. events policy: since int32, level string',
		deep_eq(rpcd_policy(methods.events.args), { since: 'int32', level: 'string' }), show(methods.events.args));

	let side_of = {
		version: 'read', status: 'read', events: 'read', job_status: 'read',
		service: 'write', check: 'write', job_start: 'write'
	};

	for (let name in names) {
		let in_read = index(app?.read?.ubus?.aetherproxy ?? [], name) >= 0;
		let in_write = index(app?.write?.ubus?.aetherproxy ?? [], name) >= 0;
		check(`10. ${name}: listed exactly once in the ACL, under ${side_of[name]}`,
			side_of[name] == 'read' ? (in_read && !in_write) : (!in_read && in_write),
			`read=${in_read}, write=${in_write}`);
	}

	for (let name in [ 'log', 'node_import', 'list_file', 'save_file' ])
		check(`10. ${name}: not offered before the CLI exists (T8.2)`, methods[name] == null, 'the method exists');
}

// ---------------------------------------------------------------- scenarios

scenario_1();
scenario_2();
scenario_3();
scenario_4();
scenario_5();
scenario_6();
scenario_7();
scenario_8();
scenario_9();
scenario_10();

print(`\n${pass} passed, ${fail} failed\n`);
exit(fail == 0 ? 0 : 1);
