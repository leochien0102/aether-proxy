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
	'daemon', 'reload', 'monitor', 'bootstrap_dns', 'bootstrap', 'apply' ]) {
	loadstring("import * as m from 'aetherproxy." + name + "'; return m;", options)();
	push(loaded, name);
}
let bootstrap = loadstring("import * as m from 'aetherproxy.bootstrap'; return m;", options)();
if (!bootstrap.stop(null).ok || !bootstrap.recover({ run_dir: '/proc/nonexistent-aether-bootstrap-test' }).ok)
	die('minimal bootstrap cleanup execution failed');
let text = bootstrap.render({ dns: { china_dns: [ '127.0.0.1#40001' ] } },
	{ address: '127.0.0.1', port: 40002 });
if (index(text, 'trust-dns 127.0.0.1#40001\n') < 0 || index(text, 'group ') >= 0)
	die('minimal private bootstrap render failed');
print(sprintf('%.J', { runtime_missing, compiler_missing, loaded }), '\n');
// Execute the real test driver and repaired readiness path, not an import-only
// approximation. ARGV[0] remains the driver's spec; it initializes signal dispatch.
loadfile(ARGV[2], options)();
if (getenv('XRAY_READY_FS_FAULT') != null) {
	let fs_test = loadstring("import * as f from 'testfs'; return f;", options)();
	print(sprintf('%.J', fs_test.stats), '\n');
}
