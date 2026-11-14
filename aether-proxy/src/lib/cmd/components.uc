'use strict';

// Live installed-component inventory (docs/10 "概览页真机修正" step 5).
// Read-only and event-free: missing config or failed version commands are information,
// not service failures. This must work even before the daemon has ever started.
import * as uci from 'uci';
import * as C from 'aetherproxy.const';
import * as component_id from 'aetherproxy.component_id';
import * as sys from 'aetherproxy.sys';
import * as check from 'aetherproxy.cmd.check';
import * as component_version from 'aetherproxy.component_version';
import * as package_db from 'aetherproxy.package_db';
import * as pipeline from 'aetherproxy.pipeline';

function usage(args, detail) {
	return pipeline.finish({ json: index(args, '--json') >= 0 },
		{ ok: false, code: 'USAGE', detail }, 2, detail);
};

// Shared with the daemon (docs/04 "components" versions). Informational failures must not emit
// CMD_FAILED or block startup. Keep the daemon's original timeout by default; the live
// inventory uses its own shorter budget.
export function read_component_version(binary, arg, timeout) {
	let result = sys.run([ binary, arg ], { timeout: timeout ?? C.COMPONENT_VERSION_TIMEOUT_SECS, quiet: true });
	return result.code == 0 ? component_version.parse_version(result.stdout) : null;
};

export function run(args) {
	let parsed = pipeline.parse_args(args);
	if (parsed.error)
		return usage(args, parsed.error);
	if (length(parsed.positional))
		return usage(args, 'components takes no arguments');
	for (let key in keys(parsed.opts))
		if (key != 'json' && key != 'confdir' && key != 'bin_dir')
			return usage(args, `option --${replace(key, /_/g, '-')} is not supported by components`);

	// Read only the overrides: unrelated invalid settings must not hide installed binaries.
	// A missing/unreadable UCI package yields null, i.e. automatic discovery by design.
	let cursor = uci.cursor(parsed.opts.confdir);
	let components = {}, lines = [];
	for (let name, key in { [C.XRAY_COMPONENT]: 'xray_bin', [C.CHINADNS_COMPONENT]: 'chinadns_bin' }) {
		let found = check.find_component(name, cursor.get(C.UCI_PACKAGE, 'main', key), parsed.opts);
		let version = found == null ? null : read_component_version(found.path,
			name == C.XRAY_COMPONENT ? 'version' : '-V', C.COMPONENTS_TIMEOUT_SECS);
		components[name] = { found: found != null, path: found?.path ?? null, version };
	}
	// M4-19: enrich before aliasing so the legacy DNS alias is a faithful copy.
	let installed = package_db.read();
	for (let name in [ C.XRAY_COMPONENT, C.CHINADNS_COMPONENT ]) {
		let entry = components[name];
		if (type(entry) != 'object')
			continue;
		let engine = component_id.engine(entry.path ?? null);
		let pkg = name == C.XRAY_COMPONENT ? 'aether-xray'
			: engine == 'aether-dns' ? 'aether-dns'
			: engine == 'chinadns-ng' ? 'chinadns-ng' : null;
		let package_version = pkg == null ? null : component_version.normalize_release(installed[pkg]);
		let banner = entry.version ?? null;
		entry.package = pkg;
		entry.installed = package_version;
		entry.banner = banner;
		entry.version = package_version ?? component_version.normalize_release(banner);
		entry.mismatch = component_version.version_mismatch(package_version, banner);
	}
	components = component_id.with_aliases(components);
	// Render logical components only; the legacy alias is a JSON compatibility detail.
	for (let name in [ C.XRAY_COMPONENT, C.DNS_COMPONENT ]) {
		let entry = components[name];
		let engine = entry.engine == null ? '' : `, engine ${entry.engine}`;
		push(lines, `${name}: ${entry.found ? `${entry.version ?? '–'} (${entry.path}${engine})` : 'not found'}`);
	}
	cursor.unload(C.UCI_PACKAGE);
	return pipeline.finish(parsed.opts, { ok: true, components }, 0, join('\n', lines));
};
