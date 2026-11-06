'use strict';

/* T14.3: run only in the task worktree, with no concurrent view edits/tests.
 * Each mutant removes one local fix; always restore the exact original bytes.
 * These are structural CSS-declaration checks, not browser layout assertions. */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const views = 'luci-app-aether-proxy/htdocs/luci-static/resources/view/aether-proxy/';
const cases = [
	['node progress', 'nodes.js', "'class': 'cbi-map-descr', style: 'margin:0'", "'class': 'cbi-map-descr'"],
	['import summary', 'nodes.js',
		"E('p', { style: 'margin:' + (items.length ? '0 0 1rem' : '0') }, [ sum.text ])",
		"E('p', {}, [ sum.text ])"],
	['import failure list', 'nodes.js', "E('ul', { style: 'margin-top:0;margin-bottom:0' }, items)",
		"E('ul', {}, items)"],
	['list feedback', 'rules.js',
		"target.replaceChildren(...[vm.text, ...vm.errors].map((text, i) =>\n\t\t\tE('p', { style: 'margin:' + (i ? '1rem 0 0' : '0') }, [ text ])))",
		"target.replaceChildren(...[vm.text, ...vm.errors].map(text => E('p', {}, [ text ])))"],
	['rule update summary', 'rules.js',
		"summary.replaceChildren(...model.job_result(job).map((text, i) =>\n\t\t\t\t\t\tE('p', { style: 'margin:' + (i ? '1rem 0 0' : '0') }, [ text ])))",
		"summary.replaceChildren(...model.job_result(job).map(text => E('p', {}, [ text ])))"],
	['no-node fallback', 'overview.js', "this.nodeControl ?? E('p', { style: 'margin:0' }, [ vm.node_text ])",
		"this.nodeControl ?? E('p', {}, [ vm.node_text ])"]
];
const args = ['--test', '--test-reporter=tap', '--test-name-pattern=T14.3',
	'tests/luci/nodes-add.test.js', 'tests/luci/rules.test.js', 'tests/luci/overview.test.js'];
for (const [name, view, before, after] of cases) {
	const file = path.join(root, views, view);
	const original = fs.readFileSync(file, 'utf8');
	assert.equal(original.split(before).length, 2, name + ': unique mutation anchor');
	let result;
	try {
		fs.writeFileSync(file, original.replace(before, after));
		result = spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8' });
	}
	finally {
		fs.writeFileSync(file, original);
	}
	assert.equal(result.error, undefined);
	assert.equal(result.status, 1, name + ': mutant must fail');
	const failures = result.stdout.split('\n').filter(line => line.startsWith('not ok '));
	assert.equal(failures.length, 1, name + ': exactly its regression fails\n' + result.stdout);
	console.log('KILLED ' + name + ': ' + failures[0]);
}
const clean = spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8' });
assert.equal(clean.status, 0, clean.stdout + clean.stderr);
console.log('RESTORED: 5 passed, 0 failed');
console.log('6/6 mutants killed');
