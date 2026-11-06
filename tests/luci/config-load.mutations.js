'use strict';

/* Run explicitly: node tests/luci/config-load.mutations.js
 * Mutate worktree-local temporary copies, never the production source/SDK.
 * All mutants run the unchanged tests and the same cached-Promise UCI double. */
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const source = fs.readFileSync(path.resolve(__dirname,
	'../../luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/common.js'), 'utf8');
const original = `function load_config() {
	return uci.load('aetherproxy').catch(function() {
		uci.unload('aetherproxy');
		return uci.load('aetherproxy');
	});
}`;
if (source.split(original).length !== 2) throw new Error('mutation anchor must match exactly once');
const mutants = [
	[ 'remove-unload', original.replace("\t\tuci.unload('aetherproxy');\n", '') ],
	[ 'remove-retry', `function load_config() { return uci.load('aetherproxy'); }` ],
	[ 'retry-twice', original.replace("return uci.load('aetherproxy');", `return uci.load('aetherproxy').catch(function() {
			uci.unload('aetherproxy');
			return uci.load('aetherproxy');
		});`) ]
];
const dir = fs.mkdtempSync(path.join(__dirname, '.config-mutations-'));
try {
	for (const [ name, body ] of [ [ 'baseline', original ], ...mutants ]) {
		const file = path.join(dir, 'common.js');
		fs.writeFileSync(file, source.replace(original, body));
		const run = spawnSync(process.execPath, [ '--test', '--test-reporter=tap', '--test-timeout=5000',
			path.join(__dirname, 'config-load.test.js') ], {
			env: { ...process.env, AETHER_CONFIG_LOAD_MUTANT: file }, encoding: 'utf8', timeout: 15000
		});
		if (run.error || run.signal || run.status === null) throw run.error || new Error('runner interrupted');
		const output = run.stdout + run.stderr;
		const summary = output.split('\n').filter(line => /^# (tests|pass|fail) /.test(line));
		const killed = run.status !== 0 && /^not ok \d+ - config load:/m.test(output);
		console.log(`${name}: ${name === 'baseline' ? (run.status === 0 ? 'PASS' : 'FAIL') : (killed ? 'KILLED' : 'SURVIVED')} (exit ${run.status})`);
		console.log(summary.join('\n'));
		if (name !== 'baseline') console.log(output.split('\n').filter(line => /^not ok /.test(line)).join('\n'));
		if ((name === 'baseline' && run.status !== 0) || (name !== 'baseline' && !killed)) {
			console.error(output);
			process.exitCode = 1;
		}
	}
} finally {
	fs.rmSync(dir, { recursive: true, force: true });
}
