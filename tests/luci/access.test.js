'use strict';

/* Scenario tests for the access control page (docs/tasks/m8.md T8.7).
 *
 * 1-4 exercise the rules 1-4 of docs/10 「访问控制页」 (docs/05 校验规则 2)
 * on the pure model module, loaded the LuCI way with a baseclass double;
 * _() resolves from the real po file. 5 runs every fixture through both the
 * model and the authoritative command line (`aether-proxy check --json
 * --no-precheck` on a temporary confdir) and requires both to agree on
 * whether the configuration has host-related errors. 6 covers the overlap
 * hints, 7 the MAC candidates from getHostHints, 8 the policy wording. 9
 * holds the static source checks on the view and the ACL.
 *
 * All fixtures use made-up IPs, MACs and names; nothing outside temporary
 * directories is touched and no network access happens.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { loadModule, parsePo } = require('./loader.js');

const ROOT = path.join(__dirname, '..', '..');
const APP = path.join(ROOT, 'luci-app-aether-proxy');
const RES = path.join(APP, 'htdocs', 'luci-static', 'resources');
const MODEL = path.join(RES, 'aether-proxy', 'model', 'access.js');
const VIEW = path.join(RES, 'view', 'aether-proxy', 'access.js');
const ACL = path.join(APP, 'root', 'usr', 'share', 'rpcd', 'acl.d', 'luci-app-aether-proxy.json');
const PO = path.join(APP, 'po', 'zh_Hans', 'aether-proxy.po');

const UCODE = path.join(ROOT, 'tests', 'host', 'ucode');
const ENTRY = path.join(ROOT, 'aether-proxy', 'src', 'aether-proxy');

const po = parsePo(fs.readFileSync(PO, 'utf8'));

/* The model goes through the browser-global _(); resolve it from the real po
   so the tests also fail when a translation goes missing. */
globalThis._ = (s) => po[s] ?? s;

function model() {
	return loadModule(MODEL, { baseclass: { extend: (o) => o } }, {
		window: {},
		document: { addEventListener() {}, removeEventListener() {} }
	});
}

function validate(sections) {
	return model().validate(sections);
}

/* A raw uci.sections('aetherproxy', 'host') entry: list options arrive as
   arrays, scalar options as strings, everything optional. */
function host(dotname, opts) {
	return Object.assign({ '.name': dotname, '.type': 'host', '.anonymous': true }, opts);
}

/* --- scenario 1: rule 1 ------------------------------------------------------ */

test('scenario 1: rule 1 — ip and mac both empty is an error named by name or ordinal; only one filled is fine', () => {
	let r = validate([ host('cfg1', { name: 'tv' }) ]);

	assert.equal(r.errors.length, 1);
	assert.equal(r.errors[0].code, 'required');
	assert.equal(r.errors[0].field, 'ip');
	assert.equal(r.errors[0].host, 'tv');
	assert.match(r.errors[0].text, /tv/);

	/* without a name the 1-based position names the host */
	r = validate([ host('cfg1', {}) ]);

	assert.equal(r.errors.length, 1);
	assert.equal(r.errors[0].host, '#1');
	assert.match(r.errors[0].text, /#1/);

	/* the ordinal counts positions: the second host is #2 even with an empty
	   name option in between */
	r = validate([ host('cfg1', { ip: [ '10.0.0.1' ] }), host('cfg2', { name: '' }), host('cfg3', {}) ]);
	assert.deepEqual(r.errors.map((e) => e.host), [ '#2', '#3' ]);

	/* either value alone passes */
	assert.equal(validate([ host('cfg1', { name: 'pc', ip: [ '10.0.0.1' ] }) ]).errors.length, 0);
	assert.equal(validate([ host('cfg1', { name: 'pc', mac: [ 'aa:bb:cc:dd:ee:01' ] }) ]).errors.length, 0);

	/* empty lists and empty strings count as unset, like lib/config.uc unset();
	   an empty string inside a list is additionally an invalid entry — the
	   command line produces both errors for `option ip ''` too */
	assert.equal(validate([ host('cfg1', { ip: [], mac: [] }) ]).errors.length, 1);

	r = validate([ host('cfg1', { ip: '', mac: null }) ]);

	assert.deepEqual(r.errors.map((e) => e.code).sort(), [ 'invalid_cidr', 'required' ]);
});

/* --- scenario 2: rule 2 ------------------------------------------------------ */

test('scenario 2: rule 2 — direct + udp=1 is an error; follow and proxy with udp=1 are fine', () => {
	const r = validate([ host('cfg1', { name: 'tv', ip: [ '10.0.0.1' ], policy: 'direct', udp: '1' }) ]);

	assert.equal(r.errors.length, 1);
	assert.equal(r.errors[0].code, 'conflict');
	assert.equal(r.errors[0].field, 'udp');
	assert.equal(r.errors[0].host, 'tv');

	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], policy: 'direct', udp: '0' }) ]).errors.length, 0);
	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], policy: 'proxy', udp: '1' }) ]).errors.length, 0);
	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], policy: 'follow', udp: '1' }) ]).errors.length, 0);
	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], policy: 'bypass_cn', udp: '1' }) ]).errors.length, 0);
	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], policy: 'gfw', udp: '1' }) ]).errors.length, 0);

	/* a missing policy is a follow host (docs/05 default) */
	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], udp: '1' }) ]).errors.length, 0);
	assert.equal(validate([ host('cfg1', { ip: [ '10.0.0.1' ], policy: 'direct' }) ]).errors.length, 0);
});

/* --- scenario 3: rule 3 ------------------------------------------------------ */

test('scenario 3: rule 3 — same ip, x vs x/32, same CIDR, MAC case/separator; disabled sections take part; same-section repeats do not', () => {
	let r = validate([ host('cfg1', { ip: [ '10.0.0.1' ] }), host('cfg2', { ip: [ '10.0.0.1' ] }) ]);

	assert.equal(r.errors.length, 1);
	assert.equal(r.errors[0].code, 'duplicate');
	assert.equal(r.errors[0].host, '#2');
	assert.equal(r.errors[0].other, '#1');
	assert.equal(r.errors[0].value, '10.0.0.1');
	assert.match(r.errors[0].text, /重复/);

	/* x and x/32 select the same host (lib/net.uc ip_key) */
	assert.equal(validate([
		host('cfg1', { ip: [ '1.2.3.4' ] }), host('cfg2', { ip: [ '1.2.3.4/32' ] })
	]).errors.length, 1);

	/* the same CIDR in two sections */
	assert.equal(validate([
		host('cfg1', { ip: [ '10.0.0.0/8' ] }), host('cfg2', { ip: [ '10.0.0.0/8' ] })
	]).errors.length, 1);

	/* MAC case and the -/: separators do not matter (lib/config.uc mac) */
	assert.equal(validate([
		host('cfg1', { mac: [ 'AA:BB:CC:DD:EE:01' ] }), host('cfg2', { mac: [ 'aa:bb:cc:dd:ee:01' ] })
	]).errors.length, 1);
	assert.equal(validate([
		host('cfg1', { mac: [ 'aa-bb-cc-dd-ee-02' ] }), host('cfg2', { mac: [ 'aa:bb:cc:dd:ee:02' ] })
	]).errors.length, 1);

	/* a disabled section takes part like any other (docs/02 冲突校验) */
	r = validate([
		host('cfg1', { enabled: '0', ip: [ '10.0.0.5' ] }),
		host('cfg2', { enabled: '1', ip: [ '10.0.0.5' ] })
	]);

	assert.equal(r.errors.length, 1);
	assert.equal(r.errors[0].code, 'duplicate');

	/* repeats inside one section are not cross-section conflicts, matching
	   check_hosts: the first claim of a value wins and j == i never reports */
	assert.equal(validate([
		host('cfg1', { ip: [ '10.0.0.1', '10.0.0.1/32' ], mac: [ 'aa:bb:cc:dd:ee:01', 'AA-BB-CC-DD-EE-01' ] })
	]).errors.length, 0);

	/* three sections sharing a value: each later section reports once */
	r = validate([
		host('cfg1', { ip: [ '10.0.0.9' ] }),
		host('cfg2', { ip: [ '10.0.0.9' ] }),
		host('cfg3', { ip: [ '10.0.0.9' ] })
	]);

	assert.equal(r.errors.length, 2);
	assert.deepEqual(r.errors.map((e) => e.host), [ '#2', '#3' ]);
});

/* --- scenario 4: rule 4 ------------------------------------------------------ */

test('scenario 4: rule 4 — invalid IPv4/CIDR and MAC entries are errors; valid ones pass; no spurious required error', () => {
	const bad_ips = [ '1.2.3.256', '1.2.3.4/33', '192.168.1.5/24', '192.168.01.5', '1.2.3', '1.2.3.4/' ];

	for (const ip of bad_ips) {
		const r = validate([ host('cfg1', { ip: [ ip ] }) ]);

		assert.equal(r.errors.length, 1, `invalid ip ${ip}: exactly one error`);
		assert.equal(r.errors[0].code, 'invalid_cidr');
		assert.equal(r.errors[0].value, ip);

		/* the raw value counts as set, so no spurious required error appears
		   (lib/config.uc consults raw_hosts for rule 1) */
		assert.notEqual(r.errors[0].code, 'required');
	}

	const good_ips = [ '1.2.3.4', '10.0.0.0/8', '0.0.0.0/0', '1.2.3.4/32', '192.168.1.0/24' ];

	for (const ip of good_ips)
		assert.equal(validate([ host('cfg1', { ip: [ ip ] }) ]).errors.length, 0, `valid ip ${ip}`);

	const bad_macs = [ 'aa:bb:cc:dd:ee', 'zz:bb:cc:dd:ee:ff', 'aa:bb:cc:dd:ee:ff:00', 'aa bb cc dd ee ff' ];

	for (const mac of bad_macs) {
		const r = validate([ host('cfg1', { mac: [ mac ] }) ]);

		assert.equal(r.errors.length, 1, `invalid mac ${mac}: exactly one error`);
		assert.equal(r.errors[0].code, 'invalid_mac');
		assert.equal(r.errors[0].value, mac);
	}

	const good_macs = [ 'aa:bb:cc:dd:ee:ff', 'AA-BB-CC-DD-EE-FE', 'aa:bb-cc:dd-ee:ff' ];

	for (const mac of good_macs)
		assert.equal(validate([ host('cfg1', { mac: [ mac ] }) ]).errors.length, 0, `valid mac ${mac}`);
});

/* --- scenario 5: the model agrees with the command line ----------------------- */

/* The fixtures are described once as uci.sections entries and rendered to the
   UCI file from the same objects, so the two sides really see the same input. */
function uci_host(h) {
	let out = 'config host\n';

	if (h.enabled != null)
		out += `\toption enabled '${h.enabled}'\n`;

	if (h.name != null)
		out += `\toption name '${h.name}'\n`;

	for (const ip of (h.ip ?? []))
		out += `\tlist ip '${ip}'\n`;

	for (const mac of (h.mac ?? []))
		out += `\tlist mac '${mac}'\n`;

	if (h.policy != null)
		out += `\toption policy '${h.policy}'\n`;

	if (h.udp != null)
		out += `\toption udp '${h.udp}'\n`;

	return out;
}

/* T10.51 values follow tests/unit/host_range.uc. Only identical normalized
   entries conflict; other intersections are non-blocking precedence hints. */
function range_fixture(name, ips, codes = [], warnings = 0) {
	return {
		name: name, codes: codes, warnings: warnings,
		sections: ips.map((ip, i) => host('cfg' + i, { ip: [ ip ], policy: i == 0 ? 'direct' : 'proxy' }))
	};
}

const RANGE_FIXTURES = [
	range_fixture('range passes', [ '192.168.8.250-192.168.8.254' ]),
	range_fixture('x-x normalises to x', [ '192.168.8.7-192.168.8.7' ]),
	range_fixture('range with reversed ends is rejected', [ '192.168.8.254-192.168.8.250' ], [ 'invalid_cidr' ]),
	range_fixture('range with missing end is rejected', [ '192.168.8.250-' ], [ 'invalid_cidr' ]),
	range_fixture('range with missing start is rejected', [ '-192.168.8.250' ], [ 'invalid_cidr' ]),
	range_fixture('non-address range is rejected', [ 'a-b' ], [ 'invalid_cidr' ]),
	range_fixture('range with spaces is rejected', [ '192.168.8.250 - 192.168.8.254' ], [ 'invalid_cidr' ]),
	range_fixture('range with CIDR end is rejected', [ '192.168.8.250-192.168.8.0/24' ], [ 'invalid_cidr' ]),
	range_fixture('range with three parts is rejected', [ '192.168.8.1-192.168.8.2-192.168.8.3' ], [ 'invalid_cidr' ]),
	range_fixture('same range in two hosts is duplicate',
		[ '192.168.8.250-192.168.8.254', '192.168.8.250-192.168.8.254' ], [ 'duplicate' ], 1),
	range_fixture('x-x duplicates the single address in another host',
		[ '192.168.8.7', '192.168.8.7-192.168.8.7' ], [ 'duplicate' ], 1),
	range_fixture('x-x duplicates a /32 in another host',
		[ '192.168.8.7-192.168.8.7', '192.168.8.7/32' ], [ 'duplicate' ], 1),
	range_fixture('range and an address inside it coexist',
		[ '192.168.8.250-192.168.8.254', '192.168.8.252' ], [], 1),
	range_fixture('partially overlapping ranges coexist',
		[ '192.168.8.250-192.168.8.254', '192.168.8.252-192.168.8.253' ], [], 1),
	range_fixture('range and containing subnet coexist',
		[ '192.168.8.250-192.168.8.254', '192.168.8.0/24' ], [], 1),
	range_fixture('range spelling a CIDR block is not a duplicate',
		[ '10.0.0.0/24', '10.0.0.0-10.0.0.255' ], [], 1),
	range_fixture('range partially intersects subnet', [ '10.0.0.0/30', '10.0.0.2-10.0.0.9' ], [], 1),
	range_fixture('ranges intersect at one endpoint',
		[ '192.168.8.250-192.168.8.252', '192.168.8.252-192.168.8.254' ], [], 1),
	range_fixture('range and adjacent address do not overlap',
		[ '192.168.8.250-192.168.8.254', '192.168.8.255' ]),
	range_fixture('range and adjacent subnet do not overlap', [ '10.0.0.0/30', '10.0.0.4-10.0.0.9' ]),
	range_fixture('adjacent ranges do not overlap',
		[ '192.168.8.250-192.168.8.251', '192.168.8.252-192.168.8.254' ]),
	range_fixture('range crosses signed integer boundary', [ '127.255.255.255-128.0.0.1', '128.0.0.0' ], [], 1),
	range_fixture('reversed range across signed boundary is rejected',
		[ '128.0.0.1-127.255.255.255' ], [ 'invalid_cidr' ]),
	range_fixture('whole IPv4 space overlaps last address', [ '0.0.0.0/0', '255.255.255.255-255.255.255.255' ], [], 1),
	range_fixture('range with invalid octet is rejected', [ '192.168.8.250-192.168.8.256' ], [ 'invalid_cidr' ]),
	range_fixture('range with leading zero is rejected', [ '192.168.08.250-192.168.8.254' ], [ 'invalid_cidr' ]),
	range_fixture('range with trailing newline is rejected', [ '192.168.8.250-192.168.8.254\n' ], [ 'invalid_cidr' ]),
	range_fixture('single address with trailing newline is rejected', [ '192.168.8.250\n' ], [ 'invalid_cidr' ]),
	range_fixture('CIDR with trailing newline is rejected', [ '192.168.8.0/24\n' ], [ 'invalid_cidr' ])
];

test('T10.53 single-item IP validator shares all range parser cases and permits only the empty add box', () => {
	const m = model();
	assert.equal(m.validate_ip(''), true);
	for (const fixture of RANGE_FIXTURES) {
		for (const section of fixture.sections) {
			for (const ip of section.ip) {
				const invalid = fixture.codes.includes('invalid_cidr');
				assert.equal(m.validate_ip(ip) === true, !invalid, fixture.name);
				if (invalid)
					assert.match(m.validate_ip(ip), /不是合法的 IPv4 地址、范围或 CIDR/);
			}
		}
	}
	for (const value of [ '192.168.1.5/24', '1.2.3.4/33', '1.2.3.4/01', ' ', null, undefined ])
		assert.notEqual(m.validate_ip(value), true, 'invalid item: ' + value);
});

for (const fixture of RANGE_FIXTURES) {
	test('T10.51 ranges: ' + fixture.name, () => {
		for (const sections of [ fixture.sections, fixture.sections.slice().reverse() ]) {
			const result = validate(sections);
			assert.deepEqual(result.errors.map((e) => e.code), fixture.codes);
			assert.equal(result.warnings.length, fixture.warnings);
			if (fixture.codes.includes('invalid_cidr'))
				assert.match(result.errors[0].text, /IPv4 地址、范围或 CIDR/);
		}
	});
}

test('T10.51 ranges: disabled duplicates still fail; same-section repeats and non-effective overlaps do not', () => {
	const range = '192.168.8.250-192.168.8.254';
	const inside = '192.168.8.252';
	const disabled = validate([
		host('a', { ip: [ range ], policy: 'direct', enabled: '0' }),
		host('b', { ip: [ range ], policy: 'proxy' })
	]);
	assert.deepEqual(disabled.errors.map((e) => e.code), [ 'duplicate' ]);
	assert.equal(disabled.warnings.length, 0);
	assert.deepEqual(validate([ host('a', { ip: [ range, range ] }) ]).errors, []);
	for (const options of [ { policy: 'direct' }, { policy: 'proxy', enabled: '0' } ]) {
		const result = validate([
			host('a', { ip: [ range ], policy: 'direct' }), host('b', { ip: [ inside ], ...options })
		]);
		assert.deepEqual(result.errors, []);
		assert.deepEqual(result.warnings, []);
	}
});

const AGREEMENT_FIXTURES = [
	...RANGE_FIXTURES,
	{ name: 'rule 1: no ip and no mac', sections: [ host('cfg1', { name: 'tv' }) ] },
	{ name: 'rule 1: only ip', sections: [ host('cfg1', { name: 'tv', ip: [ '192.168.1.10' ] }) ] },
	{ name: 'rule 1: only mac', sections: [ host('cfg1', { name: 'tv', mac: [ 'aa:bb:cc:dd:ee:01' ] }) ] },
	{ name: 'rule 2: direct with udp',
		sections: [ host('cfg1', { ip: [ '192.168.1.10' ], policy: 'direct', udp: '1' }) ] },
	{ name: 'rule 2: proxy with udp', sections: [ host('cfg1', { ip: [ '192.168.1.10' ], policy: 'proxy', udp: '1' }) ] },
	{ name: 'rule 2: bypass_cn with udp',
		sections: [ host('cfg1', { ip: [ '192.168.1.10' ], policy: 'bypass_cn', udp: '1' }) ] },
	{ name: 'rule 2: gfw with udp',
		sections: [ host('cfg1', { ip: [ '192.168.1.10' ], policy: 'gfw', udp: '1' }) ] },
	{ name: 'rule 3: same ip', sections: [ host('cfg1', { ip: [ '10.0.0.1' ] }), host('cfg2', { ip: [ '10.0.0.1' ] }) ] },
	{ name: 'rule 3: x vs x/32',
		sections: [ host('cfg1', { ip: [ '1.2.3.4' ] }), host('cfg2', { ip: [ '1.2.3.4/32' ] }) ] },
	{ name: 'rule 3: same cidr',
		sections: [ host('cfg1', { ip: [ '10.0.0.0/8' ] }), host('cfg2', { ip: [ '10.0.0.0/8' ] }) ] },
	{ name: 'rule 3: mac case',
		sections: [ host('cfg1', { mac: [ 'AA:BB:CC:DD:EE:01' ] }), host('cfg2', { mac: [ 'aa:bb:cc:dd:ee:01' ] }) ] },
	{ name: 'rule 3: mac dash vs colon',
		sections: [ host('cfg1', { mac: [ 'aa-bb-cc-dd-ee-02' ] }), host('cfg2', { mac: [ 'aa:bb:cc:dd:ee:02' ] }) ] },
	{
		name: 'rule 3: disabled section participates',
		sections: [
			host('cfg1', { enabled: '0', ip: [ '10.0.0.5' ] }),
			host('cfg2', { enabled: '1', ip: [ '10.0.0.5' ] })
		]
	},
	{ name: 'rule 3: repeat inside one section', sections: [ host('cfg1', { ip: [ '10.0.0.1', '10.0.0.1/32' ] }) ] },
	{ name: 'rule 4: bad ip', sections: [ host('cfg1', { ip: [ '1.2.3.256' ] }) ] },
	{ name: 'rule 4: prefix 33', sections: [ host('cfg1', { ip: [ '10.0.0.0/33' ] }) ] },
	{ name: 'rule 4: host bits set', sections: [ host('cfg1', { ip: [ '192.168.1.5/24' ] }) ] },
	{ name: 'rule 4: leading zero', sections: [ host('cfg1', { ip: [ '192.168.01.5' ] }) ] },
	{ name: 'rule 4: mac with 5 groups', sections: [ host('cfg1', { mac: [ 'aa:bb:cc:dd:ee' ] }) ] },
	{ name: 'rule 4: mac not hex', sections: [ host('cfg1', { mac: [ 'zz:bb:cc:dd:ee:ff' ] }) ] },
	{
		name: 'valid combination',
		sections: [
			host('cfg1', { name: 'tv', ip: [ '192.168.1.10' ], mac: [ 'aa:bb:cc:dd:ee:01' ], policy: 'proxy', udp: '1' }),
			host('cfg2', { enabled: '0', name: 'phone', mac: [ 'aa-bb-cc-dd-ee-02' ], policy: 'direct' })
		]
	},
	{
		name: 'nested cidrs are legal',
		sections: [
			host('cfg1', { ip: [ '192.168.1.0/24' ], policy: 'direct' }),
			host('cfg2', { ip: [ '192.168.1.10' ], policy: 'proxy' })
		]
	}
];

test('scenario 5: the model agrees with `aether-proxy check` on every fixture having host errors or not', () => {
	assert.ok(fs.existsSync(UCODE), 'tests/host/ucode is built (tests/host/bootstrap.sh)');

	const T = fs.mkdtempSync(path.join(os.tmpdir(), 'aether-proxy-t8-7-'));

	try {
		const dirs = {
			conf: path.join(T, 'conf'),
			data: path.join(T, 'data'),
			base: path.join(T, 'base'),
			custom: path.join(T, 'custom'),
			run: path.join(T, 'run')
		};

		for (const d of Object.values(dirs))
			fs.mkdirSync(d);

		/* Baseline rule data so the renderer has something to work with; the
		   confdir holds only the sections under test over a minimal valid
		   base config. */
		for (const f of [ 'gfwlist', 'chnlist', 'apple' ])
			fs.writeFileSync(path.join(dirs.base, `${f}.txt`), 'example.com\n');

		fs.writeFileSync(path.join(dirs.base, 'chnroute4.txt'), '1.0.0.0/8\n');
		fs.writeFileSync(path.join(dirs.base, 'gfw_static4.txt'), '91.108.4.0/22\n');

		for (const fixture of AGREEMENT_FIXTURES) {
			const confdir = fs.mkdtempSync(path.join(dirs.conf, 'f-'));

			/* enabled=0 keeps the rest of the config valid without any node,
			   so the only possible differences come from the host sections. */
			fs.writeFileSync(path.join(confdir, 'aetherproxy'),
				"config global 'main'\n\toption enabled '0'\n" +
				fixture.sections.map(uci_host).join(''));

			const r = spawnSync(UCODE, [
				'-S', ENTRY, '--', 'check', '--json', '--no-precheck',
				'--confdir', confdir,
				'--data-dir', dirs.data, '--baseline-dir', dirs.base,
				'--custom-dir', dirs.custom, '--run-dir', dirs.run
			], { encoding: 'utf8' });

			assert.equal(r.error, undefined, `${fixture.name}: the command line ran`);
			assert.equal(r.stderr, '', `${fixture.name}: --json keeps stderr empty`);

			const reply = JSON.parse(r.stdout);
			const cli_host_errors = (reply.errors ?? []).filter((e) => /^host\[[0-9]+\]/.test(e.field ?? ''));
			const model_errors = validate(fixture.sections).errors;

			if (fixture.codes)
				assert.deepEqual(cli_host_errors.map((e) => e.code), fixture.codes, fixture.name + ': backend codes');

			assert.equal(
				cli_host_errors.length > 0,
				model_errors.length > 0,
				`${fixture.name}: cli ${cli_host_errors.length}, model ${model_errors.length} — both sides must agree on host errors`
			);

			fs.rmSync(confdir, { recursive: true, force: true });
		}
	}
	finally {
		fs.rmSync(T, { recursive: true, force: true });
	}
});

/* --- scenario 6: overlap hints ------------------------------------------------- */

test('scenario 6: overlap hints — nesting CIDRs with different policies warn once and are not errors; otherwise silent', () => {
	let r = validate([
		host('cfg1', { name: 'tv', ip: [ '192.168.1.0/24' ], policy: 'direct' }),
		host('cfg2', { name: 'pc', ip: [ '192.168.1.10' ], policy: 'proxy' })
	]);

	assert.equal(r.errors.length, 0, 'an overlap is not an error');
	assert.equal(r.warnings.length, 1);
	assert.equal(r.warnings[0].a, 'tv');
	assert.equal(r.warnings[0].b, 'pc');
	assert.match(r.warnings[0].text, /tv 与 pc 重叠/);
	assert.match(r.warnings[0].text, /直连 → 全局 → 绕过大陆 → 仅被墙 → 跟随/);

	/* the pair is reported once even though both directions nest */
	r = validate([
		host('cfg1', { ip: [ '10.0.0.0/8' ], policy: 'direct' }),
		host('cfg2', { ip: [ '10.1.2.3' ], policy: 'proxy' })
	]);

	assert.equal(r.warnings.length, 1);

	/* the same effective policy has no precedence question to answer */
	r = validate([
		host('cfg1', { ip: [ '192.168.1.0/24' ], policy: 'proxy' }),
		host('cfg2', { ip: [ '192.168.1.10' ], policy: 'proxy' })
	]);

	assert.equal(r.warnings.length, 0);

	/* disjoint ranges never warn */
	r = validate([
		host('cfg1', { ip: [ '10.0.0.0/8' ], policy: 'direct' }),
		host('cfg2', { ip: [ '192.168.1.10' ], policy: 'proxy' })
	]);

	assert.equal(r.warnings.length, 0);

	/* disabled sections are not rendered into nft, so there is no runtime
	   overlap to warn about (TODO(design) in the model) */
	r = validate([
		host('cfg1', { enabled: '0', ip: [ '192.168.1.0/24' ], policy: 'direct' }),
		host('cfg2', { ip: [ '192.168.1.10' ], policy: 'proxy' })
	]);

	assert.equal(r.warnings.length, 0);
});

/* --- scenario 7: MAC candidates ------------------------------------------------ */

test('scenario 7: MAC candidates — normalized, deduplicated, labelled name (IP, MAC) with missing parts left out, sorted', () => {
	const hints = { hosts: {
		'AA-BB-CC-DD-EE-01': { name: 'tv', ipaddrs: [ '192.168.1.10' ] },
		'aa:bb:cc:dd:ee:01': { ipaddrs: [ '192.168.1.11' ] },
		'cc-dd-ee-ff-00-11': { name: 'printer' },
		'ab:cd:ef:12:34:56': { ipaddrs: [ '192.168.1.12' ] },
		'ff:ee:dd:cc:bb:aa': {},
		'not-a-mac': { name: 'junk' }
	} };

	const cands = model().mac_candidates(hints);

	assert.deepEqual(cands.map((c) => c.mac),
		[ 'aa:bb:cc:dd:ee:01', 'ab:cd:ef:12:34:56', 'cc:dd:ee:ff:00:11', 'ff:ee:dd:cc:bb:aa' ],
		'normalized to the lowercase colon form, deduplicated, sorted by MAC');

	assert.equal(cands[0].label, 'tv（192.168.1.10，aa:bb:cc:dd:ee:01）');
	assert.equal(cands[1].label, '192.168.1.12，ab:cd:ef:12:34:56');
	assert.equal(cands[2].label, 'printer（cc:dd:ee:ff:00:11）');
	assert.equal(cands[3].label, 'ff:ee:dd:cc:bb:aa', 'a candidate without name and IP shows the bare MAC');

	/* the legacy ipv4 field the LuCI Hosts class also accepts */
	const legacy = model().mac_candidates({ hosts: { '11:22:33:44:55:66': { name: 'legacy', ipv4: '192.168.1.9' } } });

	assert.equal(legacy.length, 1);
	assert.equal(legacy[0].label, 'legacy（192.168.1.9，11:22:33:44:55:66）');

	/* no hints at all: an empty list instead of an error */
	assert.deepEqual(model().mac_candidates(null), []);
	assert.deepEqual(model().mac_candidates({}), []);
});

/* --- scenario 8: policy wording ------------------------------------------------- */

test('scenario 8: policy and unlisted_policy wording; unknown values are shown verbatim', () => {
	const m = model();

	assert.equal(m.policy_text('follow'), '跟随默认模式');
	assert.equal(m.policy_text('direct'), '直连');
	assert.equal(m.policy_text('proxy'), '全局（所有流量走代理）');
	assert.equal(m.policy_text('bogus'), 'bogus');

	assert.equal(m.unlisted_text('follow'), '跟随默认模式');
	assert.equal(m.unlisted_text('direct'), '直连');
	assert.equal(m.unlisted_text('bogus'), 'bogus');
});

/* --- scenario 9: static checks -------------------------------------------------- */

test('scenario 9: static checks — Map + GridSection(host), precheck before uci.save, getHostHints, no rpc.declare, ACL', () => {
	const src = fs.readFileSync(VIEW, 'utf8');

	assert.match(src, /new form\.Map\('aetherproxy'/, 'the page is a form.Map');
	assert.match(src, /Hosts = form\.GridSection\.extend/, 'the host table extends GridSection');
	assert.match(src, /m\.section\(Hosts, 'host'/, 'the host table uses the extended GridSection');
	assert.match(src, /'require aether-proxy\.model\.access as model'/, 'the view goes through the model');
	assert.match(src, /network\.getHostHints\(\)/, 'MAC candidates come from network.getHostHints');
	assert.ok(!/rpc\s*\.\s*declare/.test(src), 'no rpc.declare in the view');
	assert.ok(!src.includes('cbi-button-reset'), 'no cbi-button-reset');

	/* both footer buttons route through the precheck helper … */
	assert.match(src, /handleSave: function\(ev\) \{\s*return this\.saveChecked\(false\);/,
		'保存 runs the precheck');
	assert.match(src, /handleSaveApply: function\(ev\) \{\s*return this\.saveChecked\(true\);/,
		'保存并应用 runs the precheck');

	/* … which validates the staged sections, aborts on errors and only then
	   calls uci.save (source order proves the abort happens first) */
	const at_validate = src.indexOf("model.validate(uci.sections('aetherproxy', 'host'))");
	const at_notify = src.indexOf('showErrors(errors)');

	/* the first uci.save() occurrence after the notify is the real save call;
	   the header comment mentioning uci.save sits before all of them */
	const at_save = src.indexOf('uci.save()', at_notify);

	assert.ok(at_validate >= 0, 'the precheck validates uci.sections aetherproxy/host');
	assert.ok(at_notify > at_validate, 'errors are listed before anything is saved');
	assert.ok(at_save > at_notify, 'uci.save is only reached after the precheck passed');

	/* the ACL grants getHostHints on luci-rpc for reading */
	const acl = JSON.parse(fs.readFileSync(ACL, 'utf8'))['luci-app-aether-proxy'];

	assert.deepEqual(acl.read.ubus['luci-rpc'], [ 'getHostHints' ], 'read grants luci-rpc getHostHints');
	assert.ok(!('luci-rpc' in (acl.write.ubus ?? {})), 'write grants nothing on luci-rpc');
});
