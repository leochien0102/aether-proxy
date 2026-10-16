'use strict';

/* T8.11b advanced-page contracts (docs/tasks/m8.md 「T8.11b 高级页」).
 *
 * Scenarios 1-2 exercise the pure model, scenario 3 cross-checks every fixture
 * against the real command line (`check --json --no-precheck`, per field),
 * scenario 4 covers the required wording and scenario 5 inspects the form the
 * view builds. The CLI fixtures run in throwaway directories; nothing touches
 * the host configuration or the network.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadModule, parsePo } = require('./loader');

const ROOT = path.resolve(__dirname, '../..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const MODEL = path.join(RES, 'aether-proxy/model/advanced.js');
const VIEW = path.join(RES, 'view/aether-proxy/advanced.js');
const PO = parsePo(fs.readFileSync(path.join(APP, 'po/zh_Hans/aether-proxy.po'), 'utf8'));

/* The model is loaded with the real translations so wording assertions cover
   what the user actually sees. */
globalThis._ = (s) => PO[s] ?? s;

function load_model() {
	return loadModule(MODEL, { baseclass: { extend: (o) => o } }, { window: {}, document: {} });
}

/* --- fixtures shared by scenarios 1-3 ------------------------------------- */

/* section is the UCI stanza the option belongs to, which is also the prefix of
   the CLI's error field (`main.…`, `probe.…`, `dns.…`). */
function fixture(section, field, value, ok) {
	return { section, field, value, ok };
}

const int_fixtures = [
	fixture('main', 'boot_wait_timeout', '0', true),
	fixture('main', 'boot_wait_timeout', '600', true),
	fixture('main', 'boot_wait_timeout', '601', false),
	fixture('main', 'boot_wait_timeout', '-1', false),
	fixture('probe', 'expect_code', '99', false),
	fixture('probe', 'expect_code', '100', true),
	fixture('probe', 'expect_code', '599', true),
	fixture('probe', 'expect_code', '600', false),
	/* The five ">= 1" fields have no upper bound, so a very large value stays valid. */
	fixture('probe', 'timeout', '0', false),
	fixture('probe', 'timeout', '1', true),
	fixture('probe', 'timeout', '999999999', true),
	fixture('probe', 'fail_threshold', '0', false),
	fixture('probe', 'fail_threshold', '1', true),
	fixture('probe', 'fail_threshold', '999999999', true),
	fixture('probe', 'recover_threshold', '0', false),
	fixture('probe', 'recover_threshold', '1', true),
	fixture('probe', 'recover_threshold', '999999999', true),
	fixture('probe', 'node_timeout', '0', false),
	fixture('probe', 'node_timeout', '1', true),
	fixture('probe', 'node_timeout', '999999999', true),
	fixture('probe', 'node_concurrency', '0', false),
	fixture('probe', 'node_concurrency', '1', true),
	fixture('probe', 'node_concurrency', '999999999', true),
	/* Non-integer spellings must match the command line: no trim, no sign, no
	   decimal point, but leading zeros are accepted. */
	fixture('main', 'boot_wait_timeout', '1.5', false),
	fixture('main', 'boot_wait_timeout', ' 5', false),
	fixture('main', 'boot_wait_timeout', '5 ', false),
	fixture('main', 'boot_wait_timeout', 'abc', false),
	fixture('main', 'boot_wait_timeout', '+5', false),
	fixture('main', 'boot_wait_timeout', '0005', true)
];

const other_fixtures = [
	fixture('main', 'boot_check_targets', [ '1.2.3.4:53' ], true),
	fixture('main', 'boot_check_targets', [ '1.2.3.4' ], false),
	fixture('main', 'boot_check_targets', [ '1.2.3.4:0' ], false),
	fixture('main', 'boot_check_targets', [ '1.2.3.4:65536' ], false),
	fixture('main', 'boot_check_targets', [ 'example.com:53' ], false),
	fixture('main', 'boot_check_targets', [ '1.2.3.4:53', '5.6.7.8:5353' ], true),
	fixture('main', 'xray_bin', '/usr/bin/xray', true),
	fixture('main', 'xray_bin', 'usr/bin/xray', false),
	fixture('main', 'xray_bin', '/usr/bin/x ray', false),
	fixture('main', 'chinadns_bin', '/usr/bin/chinadns-ng', true),
	fixture('main', 'chinadns_bin', 'bin/chinadns-ng', false),
	fixture('main', 'chinadns_bin', '/usr/bin/chinadns ng', false),
	fixture('dns', 'dnsmasq_instance', 'dnsmasq', true),
	fixture('dns', 'dnsmasq_instance', '', true),
	fixture('probe', 'url', 'http://host', true),
	fixture('probe', 'url', 'https://host', true),
	fixture('probe', 'url', 'https://host:8443/path?q=x', true),
	fixture('probe', 'url', 'ftp://host', false),
	fixture('probe', 'url', 'https:///path', false),
	fixture('probe', 'url', 'http://a b', false),
	fixture('probe', 'url', '', true)
];

const fixtures = [ ...int_fixtures, ...other_fixtures ];

/* Options that must be accepted by both sides when the user removes them. */
const empty_fixtures = [
	[ 'main', 'boot_wait_timeout' ], [ 'main', 'boot_check_targets' ],
	[ 'main', 'xray_bin' ], [ 'main', 'chinadns_bin' ], [ 'main', 'log_level' ],
	[ 'probe', 'expect_code' ], [ 'probe', 'url' ], [ 'dns', 'dnsmasq_instance' ]
];

/* --- CLI sandbox ---------------------------------------------------------- */

const DATA_NAMES = [ 'gfwlist', 'chnlist', 'apple', 'chnroute4', 'gfw_static4' ];

function sandbox(fn) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ap-advanced-'));
	try {
		for (const name of [ 'conf', 'data', 'custom', 'run', 'base' ])
			fs.mkdirSync(path.join(dir, name));

		for (const name of DATA_NAMES)
			fs.writeFileSync(path.join(dir, 'base', name + '.txt'), '');

		return fn(dir);
	}
	finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

/* The main stanza is always present; a `dns`/`probe` option gets its own
   stanza. `value` is undefined for the "leave empty" fixtures. */
function config_text(section, field, value) {
	let text = "config global 'main'\n option enabled '0'\n";

	if (section != 'main')
		text += `config ${section} '${section}'\n`;

	if (value === undefined)
		return text;

	if (Array.isArray(value))
		text += value.map((v) => ` list ${field} '${v}'\n`).join('');
	else
		text += ` option ${field} '${value}'\n`;

	return text;
}

function check_dir(dir, text) {
	fs.writeFileSync(path.join(dir, 'conf/aetherproxy'), text);

	const args = [ '-S', path.join(ROOT, 'aether-proxy/src/aether-proxy'), '--',
		'check', '--json', '--no-precheck' ];

	for (const [ opt, name ] of [ [ 'confdir', 'conf' ], [ 'data-dir', 'data' ],
		[ 'baseline-dir', 'base' ], [ 'custom-dir', 'custom' ], [ 'run-dir', 'run' ] ])
		args.push('--' + opt, path.join(dir, name));

	const r = spawnSync(path.join(ROOT, 'tests/host/ucode'), args, { encoding: 'utf8' });

	assert.equal(r.error, undefined);
	assert.equal(r.stderr, '');
	assert.ok([ 0, 2 ].includes(r.status), 'unexpected exit code ' + r.status);

	return JSON.parse(r.stdout).errors ?? [];
}

/* Exactly this field, not merely "some error in this section" (docs/tasks/m8.md
   T8.11b scenario 3 requires the conclusion per field name). */
function field_has_error(errors, section, field) {
	return errors.some((e) => e.field === section + '.' + field);
}

/* --- scenarios ------------------------------------------------------------ */

test('T8.11b scenario 1: integer fields follow the command-line syntax and bounds', () => {
	const model = load_model();

	for (const f of int_fixtures)
		assert.equal(model.validate(f.field, f.value) === true, f.ok,
			`${f.field}=${JSON.stringify(f.value)}`);
});

test('T8.11b scenario 2: list, path, string and URL fields follow the command line', () => {
	const model = load_model();

	for (const f of other_fixtures)
		assert.equal(model.validate(f.field, f.value) === true, f.ok,
			`${f.field}=${JSON.stringify(f.value)}`);

	/* An empty DeviceSelect list still fails: docs/10 requires at least one
	   interface. Absence is handled by the "leave empty" fixtures below. */
	assert.equal(model.validate('lan_ifaces', []), '请至少选择一个接口。');
	assert.equal(model.validate('lan_ifaces', [ 'br-lan' ]), true);
	assert.equal(model.validate('lan_ifaces', [ '' ]), '请至少选择一个接口。');
});

test('T8.11b scenario 3: every fixture agrees with the real CLI, field by field', () => sandbox((dir) => {
	const model = load_model();

	for (const f of fixtures) {
		const errors = check_dir(dir, config_text(f.section, f.field, f.value));
		const cli_bad = field_has_error(errors, f.section, f.field);
		const model_ok = model.validate(f.field, f.value) === true;

		assert.equal(model_ok, f.ok, `model: ${f.field}=${JSON.stringify(f.value)}`);
		assert.equal(cli_bad, !f.ok, `cli: ${f.field}=${JSON.stringify(f.value)}`);
		assert.equal(cli_bad, !model_ok,
			`CLI and model disagree on ${f.section}.${f.field}=${JSON.stringify(f.value)}`);
	}

	/* Removing an option means "use the default": neither side reports it. */
	for (const [ section, field ] of empty_fixtures) {
		const errors = check_dir(dir, config_text(section, field, undefined));

		assert.equal(model.validate(field, undefined), true, `model empty: ${field}`);
		assert.equal(field_has_error(errors, section, field), false, `cli empty: ${field}`);
	}
}));

test('T8.11b scenario 4: switch descriptions and the debug hint carry the required meaning', () => {
	const model = load_model();

	assert.match(model.description('fail_open'), /中断/);
	assert.match(model.description('fail_open'), /直连/);
	assert.match(model.description('dns_hijack'), /绕过分流/);
	assert.match(model.description('dns_hijack'), /DNS/);
	assert.match(model.description('ipv6_filter'), /AAAA/);
	assert.match(model.description('ipv6_filter'), /IPv4/);
	assert.match(model.description('quic_block'), /UDP 443/);
	assert.match(model.description('filter_https_rr'), /HTTPS RR/);
	assert.match(model.description('sniffing'), /嗅探/);
	assert.match(model.description('lan_ifaces'), /br-lan/);
	assert.match(model.description('xray_bin'), /留空/);
	assert.match(model.description('dnsmasq_instance'), /留空/);

	const levels = model.log_level_choices();
	assert.deepEqual(levels.map((c) => c.value), [ 'error', 'warn', 'notice', 'info', 'debug' ]);

	for (const c of levels) {
		if (c.value == 'debug') {
			assert.match(c.description, /logd/);
			assert.match(c.description, /缓冲区/);
			assert.match(c.description, /notice/);
		}
		else
			assert.ok(c.description == null, 'only debug carries the logd hint');
	}

	assert.deepEqual(model.xray_log_level_choices().map((c) => c.value),
		[ 'error', 'warning', 'info', 'debug' ]);
});

/* The view is loaded with doubles so the exact form tree can be inspected
   without a browser (docs/10 「页面卡的写法」). */
function build_form() {
	const created = [];
	const state = { map: null };

	class Option {
		constructor(tab, type, field, title, description) {
			this.tab = tab;
			this.type = type;
			this.field = field;
			this.title = title;
			this.description = description;
			this.ucisection = null;
			this.validate = null;
			this.value = () => this;
			created.push(this);
		}
	}

	class Section {
		constructor(kind, section, type, title) {
			this.kind = kind;
			this.section = section;
			this.type = type;
			this.title = title;
			this.tabs = [];
		}

		tab(name, title) {
			this.tabs.push(name);
			return this;
		}

		taboption(tab, type, field, title, description) {
			return new Option(tab, type, field, title, description);
		}
	}

	class Map {
		constructor(config, title, description) {
			this.config = config;
			this.title = title;
			this.description = description;
			this.sections = [];
			state.map = this;
		}

		section(kind, section, type, title) {
			const s = new Section(kind, section, type, title);
			this.sections.push(s);
			return s;
		}

		render() {
			return Promise.resolve({});
		}
	}

	const form = {
		Map, NamedSection: 'NamedSection', Flag: 'Flag', Value: 'Value', ListValue: 'ListValue',
		RichListValue: 'RichListValue', DynamicList: 'DynamicList'
	};

	return { form, state, created };
}

test('T8.11b scenario 5: form shape, field set, DeviceSelect, validators and wiring', async () => {
	const real = load_model();
	const calls = [];
	const spy = {
		validate: (field, value) => { calls.push([ field, value ]); return true; },
		description: (field) => real.description(field),
		default: (field) => real.default(field),
		log_level_choices: () => real.log_level_choices(),
		xray_log_level_choices: () => real.xray_log_level_choices()
	};

	const { form, state, created } = build_form();
	const view = loadModule(VIEW, {
		view: { extend: (o) => o }, form, uci: {},
		'tools.widgets': { DeviceSelect: 'DeviceSelect' },
		'aether-proxy.model.advanced': spy, 'aether-proxy.common': {}
	}, { window: {}, document: {} });

	await view.render();

	assert.equal(state.map.config, 'aetherproxy');
	assert.equal(state.map.sections.length, 1);

	const section = state.map.sections[0];
	assert.equal(section.kind, 'NamedSection');
	assert.equal(section.section, 'main');
	assert.deepEqual(section.tabs, [ 'intercept', 'log', 'boot', 'components' ]);

	const expected = {
		intercept: [ 'lan_ifaces', 'quic_block', 'dns_hijack', 'ipv6_filter', 'filter_https_rr',
			'fail_open', 'sniffing' ],
		log: [ 'log_level', 'xray_log_level' ],
		boot: [ 'boot_wait_timeout', 'boot_check_targets', 'url', 'expect_code', 'timeout',
			'fail_threshold', 'recover_threshold', 'node_timeout', 'node_concurrency' ],
		components: [ 'xray_bin', 'chinadns_bin', 'dnsmasq_instance' ]
	};

	assert.deepEqual(created.map((o) => o.field).sort(),
		Object.values(expected).flat().sort(), 'exactly the docs/10 fields, no more, no less');

	for (const [ tab, fields ] of Object.entries(expected))
		assert.deepEqual(created.filter((o) => o.tab == tab).map((o) => o.field), fields, tab);

	/* probe and dns fields render in this page's main section but must load
	   and save their own UCI section. */
	const target = (field) => created.find((o) => o.field == field).ucisection;
	for (const field of expected.boot.slice(2))
		assert.equal(target(field), 'probe', field);
	assert.equal(target('dnsmasq_instance'), 'dns');
	for (const field of [ ...expected.intercept, ...expected.log, 'boot_wait_timeout',
		'boot_check_targets', 'xray_bin', 'chinadns_bin' ])
		assert.equal(target(field), null, field);

	const lan = created.find((o) => o.field == 'lan_ifaces');
	assert.equal(lan.type, 'DeviceSelect');
	assert.equal(lan.multiple, true);
	assert.equal(lan.rmempty, false);

	/* docs/05 defaults: the form must show what the CLI uses when the option is
	   absent, otherwise a checked-by-default switch would look disabled. */
	assert.deepEqual(lan.default, [ 'br-lan' ]);
	for (const o of created)
		assert.deepEqual(o.default ?? null, real.default(o.field) ?? null, o.field + ': default');

	for (const field of [ 'quic_block', 'dns_hijack', 'ipv6_filter', 'filter_https_rr',
		'fail_open', 'sniffing' ])
		assert.equal(created.find((o) => o.field == field).default, '1', field + ': defaults on');

	assert.equal(created.find((o) => o.field == 'log_level').default, 'notice');
	assert.equal(created.find((o) => o.field == 'xray_log_level').default, 'warning');
	assert.equal(created.find((o) => o.field == 'boot_wait_timeout').default, '120');

	/* Every option routes its validator through the model with its own field
	   name — a wrong field name here would silently validate the wrong rule. */
	for (const o of created) {
		assert.equal(typeof o.validate, 'function', o.field + ': has a validator');
		calls.length = 0;
		assert.equal(o.validate('main', 'SAMPLE'), true);
		assert.deepEqual(calls, [ [ o.field, 'SAMPLE' ] ], o.field + ': validator calls the model');
	}

	const source = fs.readFileSync(VIEW, 'utf8');
	assert.match(source, /new form\.Map\('aetherproxy'/);
	assert.equal((source.match(/s\.tab\(/g) ?? []).length, 4, 'four tabs');
	assert.doesNotMatch(source, /rpc\.declare|cbi-button-reset|innerHTML/);
	assert.doesNotMatch(source, /\.depends\s*=/);

	/* po: every literal of the view and the model has a Chinese translation. */
	for (const file of [ VIEW, MODEL ]) {
		const text = fs.readFileSync(file, 'utf8');
		for (const match of text.matchAll(/_\('([^']*)'\)/g))
			assert.ok(PO[match[1]], 'missing translation: ' + match[1]);
	}
});
