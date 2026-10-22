'use strict';
// rpcd plugin scenarios for docs/tasks/m8.md T8.1 and T8.2, numbered like the cards.
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

	for (let key in [ 'exit', 'stdout', 'stderr', 'sleep', 'real_probe' ])
		text += `${key}\t${values[key] ?? ''}\n`;

	if (!fs.writefile(CTRL, text))
		die(`cannot write ${CTRL}: ${fs.error() ?? 'unknown error'}`);
}

// Drops the CLI stub log; the returned function yields the argv of the stub's
// next invocation, or null while the stub has not been called at all. Arguments
// are logged base64-encoded (ARG64=) so multi-line content stays one argument.
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
			if (substr(line, 0, 6) == 'ARG64=')
				push(argv, b64dec(substr(line, 6)));
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

// ucode strings have no .repeat(); used for the size-limit cases below.
function repeat_str(s, n) {
	let out = '';
	for (let i = 0; i < n; i++)
		out += s;
	return out;
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

	expect_eq('10. ACL read methods match the read-only whitelist including stats',
		show([ 'components', 'data_status', 'events', 'job_status', 'list_file', 'log', 'node_parse',
			'probe_results', 'probe_sites', 'stats', 'status', 'sub_status', 'version' ]),
		show(sort(app?.read?.ubus?.aetherproxy ?? [])));
	expect_eq('10. ACL write methods are exactly service/check/job_start/node_import/save_file/probe_now',
		show([ 'check', 'job_start', 'mode_use', 'node_import', 'node_use', 'probe_now', 'probe_url', 'save_file', 'service' ]),
		show(sort(app?.write?.ubus?.aetherproxy ?? [])));
	check('10. ACL read keeps the aetherproxy UCI grant',
		deep_eq(app?.read?.uci, [ 'aetherproxy' ]), show(app?.read?.uci));
	check('10. ACL write keeps the aetherproxy UCI grant',
		deep_eq(app?.write?.uci, [ 'aetherproxy' ]), show(app?.write?.uci));

	let names = sort(keys(methods));
	expect_eq('10. plugin exposes exactly the current methods',
		show([ 'check', 'components', 'data_status', 'events', 'job_start', 'job_status', 'list_file', 'log', 'mode_use',
			'node_import', 'node_parse', 'node_use', 'probe_now', 'probe_results', 'probe_sites', 'probe_url',
			'save_file', 'service', 'stats', 'status', 'sub_status', 'version' ]),
		names != null ? show(names) : null);

	check('T10.4 components declares empty args', deep_eq(methods.components.args, {}), show(methods.components.args));
	check('10. version declares empty args', deep_eq(methods.version.args, {}), show(methods.version.args));
	check('10. status declares empty args', deep_eq(methods.status.args, {}), show(methods.status.args));
	check('10. check declares empty args', deep_eq(methods.check.args, {}), show(methods.check.args));
	check('10. probe_results declares empty args (T8.5)', deep_eq(methods.probe_results.args, {}), show(methods.probe_results.args));
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
	check('10. log policy: source string, lines int32',
		deep_eq(rpcd_policy(methods.log.args), { source: 'string', lines: 'int32' }), show(methods.log.args));
	check('10. node_import policy: uri string',
		deep_eq(rpcd_policy(methods.node_import.args), { uri: 'string' }), show(methods.node_import.args));
	check('10. list_file policy: name string',
		deep_eq(rpcd_policy(methods.list_file.args), { name: 'string' }), show(methods.list_file.args));
	check('10. save_file policy: name string, content string',
		deep_eq(rpcd_policy(methods.save_file.args), { name: 'string', content: 'string' }), show(methods.save_file.args));

	let side_of = {
		version: 'read', status: 'read', events: 'read', job_status: 'read',
		log: 'read', list_file: 'read', probe_results: 'read', sub_status: 'read',
		data_status: 'read', stats: 'read', components: 'read', probe_sites: 'read', node_parse: 'read',
		service: 'write', check: 'write', job_start: 'write', mode_use: 'write',
		node_import: 'write', save_file: 'write', probe_now: 'write', node_use: 'write', probe_url: 'write'
	};

	for (let name in names) {
		let in_read = index(app?.read?.ubus?.aetherproxy ?? [], name) >= 0;
		let in_write = index(app?.write?.ubus?.aetherproxy ?? [], name) >= 0;
		check(`10. ${name}: listed exactly once in the ACL, under ${side_of[name]}`,
			side_of[name] == 'read' ? (in_read && !in_write) : (!in_read && in_write),
			`read=${in_read}, write=${in_write}`);
	}
}

// --- 11: log maps source/lines to CLI options and validates them ---
function scenario_11() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"source":"all","lines":[]}' });

	let cases = [
		{ name: 'no arguments', args: {}, want: [ 'log', '--json' ] },
		{ name: 'source only', args: { source: 'xray' }, want: [ 'log', '--source', 'xray', '--json' ] },
		{ name: 'source aether-proxy', args: { source: 'aether-proxy' },
		  want: [ 'log', '--source', 'aether-proxy', '--json' ] },
		{ name: 'source dns', args: { source: 'dns' }, want: [ 'log', '--source', 'dns', '--json' ] },
		{ name: 'source all', args: { source: 'all' }, want: [ 'log', '--source', 'all', '--json' ] },
		{ name: 'lines only', args: { lines: 50 }, want: [ 'log', '--lines', '50', '--json' ] },
		{ name: 'lines lower bound', args: { lines: 1 }, want: [ 'log', '--lines', '1', '--json' ] },
		{ name: 'lines upper bound', args: { lines: 2000 }, want: [ 'log', '--lines', '2000', '--json' ] },
		{ name: 'source and lines', args: { source: 'dns', lines: 2 },
		  want: [ 'log', '--source', 'dns', '--lines', '2', '--json' ] }
	];

	for (let c in cases) {
		let argv_of = watch_cli();
		let r = methods.log.call({ args: c.args });
		check(`11. log ${c.name}: stub received exactly the mapped options`,
			deep_eq(argv_of(), c.want), show(argv_of()));
		check(`11. log ${c.name}: reply is the CLI JSON object`,
			deep_eq(r, { ok: true, source: 'all', lines: [] }), show(r));
	}

	let rejects = [
		{ name: 'unknown source', args: { source: 'dnsmasq' } },
		{ name: 'source not a string', args: { source: 7 } },
		{ name: 'lines 0', args: { lines: 0 } },
		{ name: 'lines above the bound', args: { lines: 2001 } },
		{ name: 'negative lines', args: { lines: -1 } },
		{ name: 'lines as string', args: { lines: '50' } },
		{ name: 'fractional lines', args: { lines: 1.5 } }
	];

	for (let c in rejects) {
		let argv_of = watch_cli();
		let r = methods.log.call({ args: c.args });
		check(`11. log ${c.name}: USAGE`, r?.ok === false && r?.code == 'USAGE', show(r));
		check(`11. log ${c.name}: stub not called`, argv_of() == null, show(argv_of()));
	}
}

// --- 12: node_import forwards the URI as one argument and rejects malformed values ---
function scenario_12() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"node":"n_a","duplicate":false}' });

	let ok_cases = [
		{ name: 'vless uri', uri: 'vless://uuid@h.example:443?security=tls#Edge' },
		{ name: 'ss uri', uri: 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@h.example:8388' },
		// A URI carrying shell metacharacters must arrive as one argv element (sys.run,
		// no shell), never interpreted by a shell.
		{ name: 'uri with shell metacharacters', uri: 'trojan://pw@h.example:443?sni=x#n;reboot $(id) `id`' }
	];

	for (let c in ok_cases) {
		let argv_of = watch_cli();
		let r = methods.node_import.call({ args: { uri: c.uri } });
		check(`12. node_import ${c.name}: forwarded as [node, import, <uri>, --json]`,
			deep_eq(argv_of(), [ 'node', 'import', c.uri, '--json' ]), show(argv_of()));
		check(`12. node_import ${c.name}: reply is the CLI JSON object`,
			deep_eq(r, { ok: true, node: 'n_a', duplicate: false }), show(r));
	}

	let rejects = [
		{ name: 'uri missing', args: {} },
		{ name: 'uri not a string', args: { uri: 17 } },
		{ name: 'uri without scheme', args: { uri: 'foo' } },
		{ name: 'uri starting with a dash', args: { uri: '-vless://x@h:1' } },
		{ name: 'uri too long', args: { uri: 'vless://' + repeat_str('a', 4096) + '@h:1' } },
		{ name: 'bare scheme without //', args: { uri: 'vless:' } }
	];

	for (let c in rejects) {
		let argv_of = watch_cli();
		let r = methods.node_import.call({ args: c.args });
		check(`12. node_import ${c.name}: USAGE`, r?.ok === false && r?.code == 'USAGE', show(r));
		check(`12. node_import ${c.name}: stub not called`, argv_of() == null, show(argv_of()));
	}
}

// --- 13: list_file forwards get, save_file forwards set with the full content ---
function scenario_13() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"name":"direct_domain","content":""}' });

	for (let name in [ 'direct_domain', 'proxy_domain', 'direct_ip', 'proxy_ip' ]) {
		let argv_of = watch_cli();
		let r = methods.list_file.call({ args: { name: name } });
		check(`13. list_file ${name}: stub received [custom, get, <name>, --json]`,
			deep_eq(argv_of(), [ 'custom', 'get', name, '--json' ]), show(argv_of()));
		check(`13. list_file ${name}: reply is the CLI JSON object`,
			deep_eq(r, { ok: true, name: 'direct_domain', content: '' }), show(r));
	}

	// Multi-line content must reach the CLI byte for byte (it is passed as one argv
	// element, never through a shell or a temp file).
	let content = '# custom list\nexample.com\n\n1.2.3.4/24\nlast line without newline';
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"name":"proxy_domain","changed":true,"reload":false}' });
	let argv_of = watch_cli();
	let r = methods.save_file.call({ args: { name: 'proxy_domain', content: content } });
	check('13. save_file: stub received [custom, set, <name>, --content, <content>, --json]',
		deep_eq(argv_of(), [ 'custom', 'set', 'proxy_domain', '--content', content, '--json' ]), show(argv_of()));
	check('13. save_file: reply is the CLI JSON object',
		deep_eq(r, { ok: true, name: 'proxy_domain', changed: true, reload: false }), show(r));

	// save_file has a 30s budget (a save may reload the service): an 11s CLI is answered,
	// not killed at the 10s default.
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"name":"proxy_ip","changed":true,"reload":true}', sleep: 11 });
	let t0 = clock();
	r = methods.save_file.call({ args: { name: 'proxy_ip', content: '10.0.0.0/8' } });
	let dt = elapsed(t0);
	check('13. save_file sleeping 11s: answered by the 30s budget',
		deep_eq(r, { ok: true, name: 'proxy_ip', changed: true, reload: true }), show(r));
	check('13. save_file sleeping 11s: the call took over 10s (10 < t < 29)', dt > 10 && dt < 29, sprintf('%.1fs', dt));

	let rejects = [
		{ name: 'list_file unknown name', call: 'list_file', args: { name: 'hosts' } },
		{ name: 'list_file name not a string', call: 'list_file', args: { name: 3 } },
		{ name: 'list_file name missing', call: 'list_file', args: {} },
		{ name: 'save_file unknown name', call: 'save_file', args: { name: 'gfwlist', content: 'x' } },
		{ name: 'save_file name missing', call: 'save_file', args: { content: 'x' } },
		{ name: 'save_file content missing', call: 'save_file', args: { name: 'direct_ip' } },
		{ name: 'save_file content not a string', call: 'save_file', args: { name: 'direct_ip', content: [] } },
		{ name: 'save_file content too long', call: 'save_file',
		  args: { name: 'direct_ip', content: repeat_str('x', 65537) } }
	];

	for (let c in rejects) {
		let argv_of2 = watch_cli();
		let r2 = methods[c.call].call({ args: c.args });
		check(`13. ${c.name}: USAGE`, r2?.ok === false && r2?.code == 'USAGE', show(r2));
		check(`13. ${c.name}: stub not called`, argv_of2() == null, show(argv_of2()));
	}

	// Exactly at the size limit is still accepted.
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"name":"direct_ip","changed":false,"reload":false}' });
	let argv_of3 = watch_cli();
	let r3 = methods.save_file.call({ args: { name: 'direct_ip', content: repeat_str('y', 65536) } });
	check('13. save_file 65536 bytes: forwarded', deep_eq(r3, { ok: true, name: 'direct_ip', changed: false, reload: false }), show(r3));
	check('13. save_file 65536 bytes: stub called with the full content',
		deep_eq(argv_of3(), [ 'custom', 'set', 'direct_ip', '--content', repeat_str('y', 65536), '--json' ]), 'argv mismatch');
}

// --- 14: probe_results forwards `probe results --json` and takes no arguments (T8.5) ---
function scenario_14() {
	let data = { ok: true, at: 1760400000, nodes: {}, done: 1, total: 1, finished: true, pending: [] };
	data.nodes[node_id(1)] = { ip: '203.0.113.10', ok: 3, fail: 0, min_ms: 41, median_ms: 44, error: null };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', data) });

	let argv_of = watch_cli();
	let r = methods.probe_results.call({ args: {} });
	expect_eq('14. probe_results: stub received exactly [probe, results, --json]',
		show([ 'probe', 'results', '--json' ]), show(argv_of()));
	check('14. probe_results: reply deep-equals the CLI object (file content as-is)', deep_eq(r, data), show(r));

	// The default object for a missing or damaged probe.json is produced by the CLI;
	// the plugin returns it unchanged like any other reply.
	let empty = { ok: true, at: null, nodes: {}, done: 0, total: 0, finished: true, pending: [] };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', empty) });
	argv_of = watch_cli();
	r = methods.probe_results.call({ args: {} });
	check('14. probe_results: CLI default object returned unchanged', deep_eq(r, empty), show(r));
	expect_eq('14. probe_results: stub still received exactly [probe, results, --json]',
		show([ 'probe', 'results', '--json' ]), show(argv_of()));
}

function scenario_15() {
	let data = { ok: true, subs: { s_00000001: { nodes: 2, error: null } } };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', data) });
	let argv_of = watch_cli();
	let r = methods.sub_status.call({ args: {} });
	expect_eq('15. sub_status forwards exactly sub status --json', show([ 'sub', 'status', '--json' ]), show(argv_of()));
	check('15. sub_status preserves records and declares empty args', deep_eq(r, data) && deep_eq(methods.sub_status.args, {}), show(r));
}

function scenario_16() {
	let data = { ok: true, checked: 123, items: { gfwlist: { changed: false } } };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', data) });
	let argv_of = watch_cli();
	let r = methods.data_status.call({ args: {} });
	expect_eq('16. data_status forwards exactly data status --json',
		show([ 'data', 'status', '--json' ]), show(argv_of()));
	check('16. data_status preserves inventory and declares empty args',
		deep_eq(r, data) && deep_eq(methods.data_status.args, {}), show(r));
	check('16. data_status uses default 10-second timeout',
		match(plugin_src, /call_cli\(\[ 'data', 'status' \], DEFAULT_TIMEOUT_SECS\)/) != null &&
		match(plugin_src, /const DEFAULT_TIMEOUT_SECS = 10;/) != null, 'timeout policy');
}

// T8.12a: stats is a parameterless read, forwarding the complete snapshot unchanged.
function scenario_17() {
	let data = { ok: true, at_ms: 123, proxy: null, wan: null, connections: { proxy: 2, total: 5 } };
	stub_ctrl({ exit: 0, stdout: sprintf('%J', data) });
	let argv_of = watch_cli();
	let r = methods.stats.call({ args: {} });
	expect_eq('17. stats forwards exactly stats --json', show([ 'stats', '--json' ]), show(argv_of()));
	check('17. stats preserves snapshot and declares empty args',
		deep_eq(r, data) && deep_eq(methods.stats.args, {}), show(r));
	check('17. stats uses default 10-second timeout',
		match(plugin_src, /call_cli\(\[ 'stats' \], DEFAULT_TIMEOUT_SECS\)/) != null &&
		match(plugin_src, /const DEFAULT_TIMEOUT_SECS = 10;/) != null, 'timeout policy');
}

// T8.12b (docs/10 Dashboard part 2): forwarding is immediate and uses the ordinary timeout.
function scenario_18() {
	let data = { ok: true, requested_at: 123456 };
	stub_ctrl({ stdout: show(data), exit: 0 });
	let argv_of = watch_cli();
	let result = methods.probe_now.call({ args: {} });
	expect_eq('18. probe_now forwards exactly probe now --json',
		show([ 'probe', 'now', '--json' ]), show(argv_of()));
	check('18. probe_now preserves response and declares empty args',
		deep_eq(result, data) && deep_eq(methods.probe_now.args, {}), show(result));
	check('18. probe_now uses default 10-second timeout',
		match(plugin_src, /call_cli\(\[ 'probe', 'now' \], DEFAULT_TIMEOUT_SECS\)/) != null &&
		match(plugin_src, /const DEFAULT_TIMEOUT_SECS = 10;/) != null, 'timeout policy');
}

// T10.4: live discovery is read-only, no arguments, with a dedicated timeout.
function scenario_components() {
	let data = { ok: true, components: {
		xray: { found: true, path: '/usr/bin/xray', version: '26.9.30' },
		'chinadns-ng': { found: false, path: null, version: null }
	} };
	stub_ctrl({ stdout: show(data), exit: 0 });
	let argv_of = watch_cli();
	let result = methods.components.call({ args: {} });
	expect_eq('T10.4 components forwards exactly components --json',
		show([ 'components', '--json' ]), show(argv_of()));
	check('T10.4 components preserves the CLI object', deep_eq(result, data), show(result));
	for (let args in [ { unexpected: 'x' }, { confdir: '/tmp' }, { args: [] } ]) {
		let unused = watch_cli();
		let r = methods.components.call({ args });
		check('T10.4 components rejects parameters with USAGE and no execution',
			r.code == 'USAGE' && unused() == null, show(r));
	}
	check('T10.4 components uses 15-second plugin timeout',
		match(plugin_src, /call_cli\(\[ 'components' \], COMPONENTS_TIMEOUT_SECS\)/) != null &&
		match(plugin_src, /const COMPONENTS_TIMEOUT_SECS = 15;/) != null, 'timeout policy');
}

// T9.10: session metadata must not become a business argument. Exercise every
// method and compare actual argv (service is checked separately against init).
function scenario_sessions() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"session_test":true}' });
	let cases = {
		version: { argv: [ 'version' ] },
		status: { argv: [ 'status' ] },
		components: { argv: [ 'components' ] },
		check: { argv: [ 'check' ] },
		job_start: { args: { kind: 'probe_nodes' }, argv: [ 'job', 'start', 'probe', 'nodes' ] },
		job_status: { args: { id: 'j_1_2' }, argv: [ 'job', 'status', 'j_1_2' ] },
		events: { args: { since: 0, level: 'warn' }, argv: [ 'events', '--since', '0', '--level', 'warn' ] },
		stats: { argv: [ 'stats' ] },
		data_status: { argv: [ 'data', 'status' ] },
		sub_status: { argv: [ 'sub', 'status' ] },
		probe_now: { argv: [ 'probe', 'now' ] },
		probe_results: { argv: [ 'probe', 'results' ] },
		probe_sites: { argv: [ 'probe', 'sites' ] },
		probe_url: { args: { site: 'google' }, argv: [ 'probe', 'url', 'google' ] },
		node_use: { args: { id: node_id(1), mode: 'global' }, argv: [ 'node', 'use', node_id(1), '--mode', 'global' ] },
		mode_use: { args: { mode: 'gfw' }, argv: [ 'mode', 'use', 'gfw' ] },
		log: { args: { source: 'dns', lines: 1 }, argv: [ 'log', '--source', 'dns', '--lines', '1' ] },
		node_import: { args: { uri: 'vless://uuid@host:443' }, argv: [ 'node', 'import', 'vless://uuid@host:443' ] },
		node_parse: { args: { uri: 'trojan://pw@host:443' }, argv: [ 'node', 'parse', 'trojan://pw@host:443' ] },
		list_file: { args: { name: 'direct_ip' }, argv: [ 'custom', 'get', 'direct_ip' ] },
		save_file: { args: { name: 'direct_ip', content: '1.2.3.4' },
			argv: [ 'custom', 'set', 'direct_ip', '--content', '1.2.3.4' ] }
	};
	for (let name, c in cases) {
		let argv_of = watch_cli();
		let r = methods[name].call({ args: { ...(c.args ?? {}), ubus_rpc_session: 'session-token' } });
		check(`T9.10 ${name} with ubus_rpc_session: success and exact business argv`,
			r.ok === true && deep_eq(argv_of(), [ ...c.argv, '--json' ]), show(r));
	}
	let action_of = watch_init();
	let r = methods.service.call({ args: { action: 'start', ubus_rpc_session: 'session-token' } });
	check('T9.10 service with ubus_rpc_session: success and correct init action',
		r.ok === true && wait_for(action_of, 3) == 'start', show(r));
	check('T9.10 session scenarios cover every exposed method',
		deep_eq(sort([ ...keys(cases), 'service' ]), sort(keys(methods))), show(keys(methods)));
}

function scenario_node_probe() {
	stub_ctrl({ exit: 0, stdout: '{"ok":true,"preserved":[1,2]}' });
	let cases = [
		{ method: 'node_use', args: { id: node_id(1) }, argv: [ 'node', 'use', node_id(1), '--json' ] },
		{ method: 'probe_url', args: { site: 'cloudflare' }, argv: [ 'probe', 'url', 'cloudflare', '--json' ] },
		{ method: 'probe_sites', args: {}, argv: [ 'probe', 'sites', '--json' ] }
	];
	for (let c in cases) {
		let argv_of = watch_cli();
		let r = methods[c.method].call({ args: c.args });
		check(`T9.10 ${c.method}: valid args forwarded and CLI object preserved`,
			deep_eq(argv_of(), c.argv) && deep_eq(r, { ok: true, preserved: [ 1, 2 ] }), show(r));
		let expected_args = { node_use: { id: '', mode: '' }, probe_url: { site: '' }, probe_sites: {} };
		check(`T9.10 ${c.method}: declared args policy matches examples`,
			deep_eq(methods[c.method].args, expected_args[c.method]), show(methods[c.method].args));
	}
	let rejects = [
		{ method: 'node_use', args: {} },
		{ method: 'node_use', args: { id: 1 } },
		{ method: 'node_use', args: { id: 'n_short' } },
		{ method: 'node_use', args: { id: 'n_' + repeat_str('A', 32) } },
		{ method: 'node_use', args: { id: node_id(1) + ';reboot' } },
		{ method: 'probe_url', args: {} },
		{ method: 'probe_url', args: { site: 1 } },
		{ method: 'probe_url', args: { site: 'Google' } },
		{ method: 'probe_url', args: { site: 'google;id' } },
		{ method: 'probe_url', args: { site: repeat_str('a', 17) } },
		{ method: 'probe_sites', args: { unexpected: true } }
	];
	for (let c in rejects) {
		let argv_of = watch_cli();
		let r = methods[c.method].call({ args: { ...c.args, ubus_rpc_session: 'token' } });
		check(`T9.10 ${c.method} rejects ${show(c.args)}: USAGE without execution`,
			r.code == 'USAGE' && argv_of() == null, show(r));
	}
	// Unknown names pass the syntax gate but must reach real CLI membership validation.
	stub_ctrl({ real_probe: 1 });
	let argv_of = watch_cli();
	let r = methods.probe_url.call({ args: { site: 'unknown', ubus_rpc_session: 'token' } });
	check('T9.10 probe_url unknown site: real CLI USAGE forwarded unchanged',
		r.code == 'USAGE' && deep_eq(argv_of(), [ 'probe', 'url', 'unknown', '--json' ]), show(r));

	// Isolate only UCI and execution for deadline inspection; production method stays unchanged.
	for (let raw in [ '13', '1', null, 'bad', '0' ]) {
		let src = replace(plugin_src, "import * as uci from 'uci';",
			`const uci = { cursor: () => ({ get: () => ${show(raw)} }) };`);
		src = replace(src, "import * as sys from 'aetherproxy.sys';",
			"const sys = { run: (argv, opts) => ({ stdout: sprintf('%J', { argv, timeout: opts.timeout }) }) };");
		let instrumented = loadstring(src)().aetherproxy;
		let reply = instrumented.probe_url.call({ args: { site: 'google' } });
		let expected = (raw == '13' ? 13 : raw == '1' ? 1 : 5) + 5;
		expect_eq(`T9.10 probe_url timeout ${show(raw)}: configured/default timeout plus 5`, expected, reply.timeout);
	}
}

// T9.13 docs/10: node_parse is a read-only, ten-second forward with the import gate.
function scenario_node_parse() {
	let data = { ok: true, node: { protocol: 'trojan', port: '443', alpn: [ 'h2', 'http/1.1' ] } };
	stub_ctrl({ exit: 0, stdout: show(data) });
	for (let uri in [ 'trojan://pw@host:443', 'ss://encoded@host:443#x;$(id)',
		'trojan://' + repeat_str('a', 4087) ]) {
		let argv_of = watch_cli();
		let r = methods.node_parse.call({ args: { uri, ubus_rpc_session: 'token' } });
		check('T9.13 node_parse valid/session/boundary: exact argv and unchanged JSON',
			deep_eq(argv_of(), [ 'node', 'parse', uri, '--json' ]) && deep_eq(r, data), show(r));
	}
	let rejects = [ {}, { uri: '' }, { uri: 1 }, { uri: [] }, { uri: null },
		{ uri: 'foo' }, { uri: '-vless://host' }, { uri: '1bad://host' },
		{ uri: 'trojan://' + repeat_str('a', 4088) },
		{ uri: 'trojan://' + repeat_str('中', 1400) } ];
	for (let args in rejects) {
		let argv_of = watch_cli();
		let r = methods.node_parse.call({ args: { ...args, ubus_rpc_session: 'token' } });
		check('T9.13 node_parse invalid value: USAGE without CLI execution',
			r.ok === false && r.code == 'USAGE' && argv_of() == null, show(r));
	}
	check('T9.13 node_parse declares uri string', deep_eq(methods.node_parse.args, { uri: '' }));
	let failure = { ok: false, code: 'CONFIG_INVALID', detail: 'unsupported_scheme' };
	stub_ctrl({ exit: 2, stdout: show(failure) });
	check('T9.13 node_parse failure: CLI JSON forwarded unchanged',
		deep_eq(methods.node_parse.call({ args: { uri: 'unknown://host' } }), failure));

	// Inspect the actual execution options without waiting another ten seconds.
	let src = replace(plugin_src, "import * as sys from 'aetherproxy.sys';",
		"const sys = { run: (argv, opts) => ({ stdout: sprintf('%J', { timeout: opts.timeout }) }) };");
	let instrumented = loadstring(src)().aetherproxy;
	expect_eq('T9.13 node_parse forwarding timeout is 10 seconds', 10,
		instrumented.node_parse.call({ args: { uri: 'trojan://pw@host:443' } }).timeout);
}

// T9.20: both mode entry points remain validated, ten-second thin forwards.
function scenario_mode_use() {
	let data = { ok: true, mode: 'gfw', previous: 'bypass_cn', reload: true };
	stub_ctrl({ exit: 0, stdout: show(data) });
	for (let mode in [ 'gfw', 'bypass_cn', 'global' ]) {
		for (let method in [ 'mode_use', 'node_use' ]) {
			let args = { mode, ubus_rpc_session: 'token' };
			let argv = [ 'mode', 'use', mode, '--json' ];
			if (method == 'node_use') {
				args.id = node_id(1);
				argv = [ 'node', 'use', node_id(1), '--mode', mode, '--json' ];
			}
			let argv_of = watch_cli();
			let r = methods[method].call({ args });
			check(`T9.20 ${method} ${mode} with session: exact argv and unchanged JSON`,
				deep_eq(argv_of(), argv) && deep_eq(r, data), show(r));
		}
	}
	for (let mode in [ 'foo', 'GFW', '', '--json', 'gfw;reboot', 1, true, [], {} ]) {
		for (let method in [ 'mode_use', 'node_use' ]) {
			let argv_of = watch_cli();
			let r = methods[method].call({ args: { id: node_id(1), mode, ubus_rpc_session: 'token' } });
			check(`T9.20 ${method} invalid mode ${show(mode)}: USAGE without execution`,
				r.ok === false && r.code == 'USAGE' && argv_of() == null, show(r));
		}
	}
	let argv_of = watch_cli();
	let r = methods.mode_use.call({ args: { ubus_rpc_session: 'token' } });
	check('T9.20 mode_use missing mode: USAGE without execution',
		r.code == 'USAGE' && argv_of() == null, show(r));
	check('T9.20 mode_use declares mode string', deep_eq(methods.mode_use.args, { mode: '' }));
	let src = replace(plugin_src, "import * as sys from 'aetherproxy.sys';",
		"const sys = { run: (argv, opts) => ({ stdout: sprintf('%J', { timeout: opts.timeout }) }) };");
	let instrumented = loadstring(src)().aetherproxy;
	for (let method in [ 'mode_use', 'node_use' ])
		expect_eq(`T9.20 ${method} forwarding timeout is 10 seconds`, 10,
			instrumented[method].call({ args: { id: node_id(1), mode: 'gfw' } }).timeout);
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
scenario_11();
scenario_12();
scenario_13();
scenario_14();
scenario_15();
scenario_16();
scenario_17();
scenario_18();
scenario_components();
scenario_sessions();
scenario_node_probe();
scenario_node_parse();
scenario_mode_use();

print(`\n${pass} passed, ${fail} failed\n`);
exit(fail == 0 ? 0 : 1);
