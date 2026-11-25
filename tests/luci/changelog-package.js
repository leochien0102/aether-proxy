'use strict';
// Verify decoded data from an actual unpacked package against a fresh extraction.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { loadModule } = require('./loader');
const root = path.resolve(__dirname, '../..');
const [resources, docs, ipk] = process.argv.slice(2);
if (!ipk) throw new Error('expected unpacked resources, source release directory, ipk');
const pkg = path.join(root, 'luci-app-aether-proxy');
const relative = 'aether-proxy/changelog.js';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 't16105-package-'));
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const load = file => loadModule(file, { baseclass: { extend: o => o } }, { window: {}, document: {} });
try {
	const expected = path.join(tmp, 'changelog.js');
	fs.copyFileSync(path.join(pkg, 'htdocs/luci-static/resources', relative), expected);
	execFileSync('python3', [path.join(pkg, 'tools/build-changelog.py'), docs, expected]);
	const actual = load(path.join(resources, relative)).releases;
	assert.deepEqual(actual, load(expected).releases);
	assert.ok(actual.length <= 8);
	assert.ok(!fs.readFileSync(path.join(resources, relative), 'utf8').includes('@RELEASES@'));
	console.log(JSON.stringify({ verified: true, ipk, ipk_sha256: hash(ipk),
		generator_sha256: hash(path.join(pkg, 'tools/build-changelog.py')),
		makefile_sha256: hash(path.join(pkg, 'Makefile')),
		resource_sha256: hash(path.join(resources, relative)),
		source_files: Object.fromEntries(fs.readdirSync(docs).filter(f => f.endsWith('.md')).sort()
			.map(f => [f, hash(path.join(docs, f))])),
		entries: actual }, null, 2));
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
