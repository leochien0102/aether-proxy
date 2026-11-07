'use strict';
// Restrict both compiler and runtime paths. Explicit negative controls prove an
// optional module cannot leak in from the host's default installation.
let paths = json(ARGV[1]);
splice(REQUIRE_SEARCH_PATH, 0, length(REQUIRE_SEARCH_PATH), ...paths);
let options = { raw_mode: true, module_search_path: paths };
let runtime_missing = false, compiler_missing = false;
try { require('struct'); }
catch (e) { runtime_missing = index('' + e, 'struct') >= 0; }
try { loadstring("import * as s from 'struct'; return s;", options)(); }
catch (e) { compiler_missing = index('' + e, 'struct') >= 0; }
if (!runtime_missing || !compiler_missing)
	die('struct negative control failed');
let loaded = [];
for (let name in [ 'net', 'config', 'render.xray', 'render.chinadns', 'xray_ready',
	'daemon', 'reload', 'monitor', 'bootstrap_dns', 'apply' ]) {
	loadstring("import * as m from 'aetherproxy." + name + "'; return m;", options)();
	push(loaded, name);
}
print(sprintf('%.J', { runtime_missing, compiler_missing, loaded }), '\n');
// Execute the real test driver and repaired readiness path, not an import-only
// approximation. ARGV[0] remains the driver's spec; it initializes signal dispatch.
loadfile(ARGV[2], options)();
if (getenv('XRAY_READY_FS_FAULT') != null) {
	let fs_test = loadstring("import * as f from 'testfs'; return f;", options)();
	print(sprintf('%.J', fs_test.stats), '\n');
}
