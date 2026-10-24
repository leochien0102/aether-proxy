'use strict';
// Shared, event-free detection for docs/04「与其他代理插件的冲突」 and docs/10 notices.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';

// Names and configuration predicates verified in docs/04 (2026-10-24).
export const PLUGINS = [
	{ name: 'ssr-plus', init: 'shadowsocksr', tables: [ 'inet ss_spec', 'ip ss_spec_mangle' ], chains: [], processes: [],
	  configured: [ { package: 'shadowsocksr', type: 'global', option: 'global_server', test: 'not-nil' } ] },
	{ name: 'passwall', init: 'passwall', tables: [ 'inet passwall' ], chains: [], processes: [],
	  configured: [ { package: 'passwall', type: 'global', option: 'enabled', test: 'one' } ] },
	{ name: 'passwall2', init: 'passwall2', tables: [ 'inet passwall2' ], chains: [], processes: [],
	  configured: [ { package: 'passwall2', type: 'global', option: 'enabled', test: 'one' } ] },
	{ name: 'homeproxy', init: 'homeproxy', tables: [], chains: [ 'homeproxy_' ], processes: [],
	  configured: [ { package: 'homeproxy', section: 'config', option: 'main_node', test: 'not-nil' },
	                { package: 'homeproxy', section: 'server', option: 'enabled', test: 'one' } ] },
	{ name: 'openclash', init: 'openclash', tables: [], chains: [ 'openclash' ], processes: [ 'clash' ],
	  configured: [ { package: 'openclash', section: 'config', option: 'enable', test: 'one' } ] },
	{ name: 'nikki', init: 'nikki', tables: [ 'inet nikki' ], chains: [], processes: [ 'mihomo' ],
	  configured: [ { package: 'nikki', section: 'config', option: 'enabled', test: 'one' } ] },
	{ name: 'clash', init: null, tables: [], chains: [], processes: [ 'clash' ], configured: [] },
	{ name: 'mihomo', init: null, tables: [], chains: [], processes: [ 'mihomo' ], configured: [] }
];

function init_path(ctx, plugin) {
	return replace(ctx.root ?? '', /\/$/, '') + '/etc/init.d/' + plugin.init;
};

function run(ctx, name, args) {
	return sys.run([ ctx.bin_dir ? `${ctx.bin_dir}/${name}` : name, ...args ], { timeout: 10, quiet: true });
};

export function inspect(ctx) {
	let tables = run(ctx, 'nft', [ 'list', 'tables' ]);
	if (tables.code != 0)
		return { ok: false, conflicts: [], detail: `nft list tables failed (${tables.code}): ${tables.stderr}` };
	let names = [];
	for (let line in split(tables.stdout, '\n')) {
		let m = match(trim(line), /^table\s+(\S+)\s+(\S+)$/);
		if (m != null)
			push(names, `${m[1]} ${m[2]}`);
	}
	let chains = run(ctx, 'nft', [ 'list', 'chains', 'inet', 'fw4' ]);
	let chain_names = [];
	// Per T9.34, failure (including an absent fw4 table) means no chains.
	if (chains.code == 0)
		for (let line in split(chains.stdout, '\n')) {
			let m = match(trim(line), /^chain\s+(\S+)\s*\{/);
			if (m != null)
				push(chain_names, m[1]);
		}
	let processes = {};
	for (let plugin in PLUGINS)
		for (let process in plugin.processes)
			if (processes[process] == null)
				// Busybox killall -0: 0 = exists, 1 = absent (original check).
				processes[process] = run(ctx, 'killall', [ '-0', process ]).code == 0;
	let active = [], owned = {};
	for (let plugin in PLUGINS) {
		let found = false;
		for (let table in plugin.tables)
			found ||= index(names, table) >= 0;
		for (let prefix in plugin.chains)
			for (let chain in chain_names)
				found ||= substr(chain, 0, length(prefix)) == prefix;
		for (let process in plugin.processes) {
			if (plugin.init != null) {
				// An installed init script or plugin nft evidence attributes the core to that
				// plugin; otherwise keep the independent clash/mihomo name (docs/04).
				if (found || fs.stat(init_path(ctx, plugin)) != null) {
					owned[process] = true;
					found ||= processes[process];
				}
			}
			else
				found ||= processes[process] && !owned[process];
		}
		if (found)
			push(active, plugin.name);
	}
	return { ok: true, conflicts: sort(active), detail: 'conflicting services inspected' };
};

function configured(cursor, plugin) {
	for (let rule in plugin.configured) {
		let value = null;
		if (rule.type != null)
			cursor.foreach(rule.package, rule.type, section => {
				value = section[rule.option];
				return false; // @global[0], not any later global section
			});
		else
			value = cursor.get(rule.package, rule.section, rule.option);
		if (rule.test == 'one' ? value == '1' : (type(value) == 'string' && value != 'nil'))
			return true;
	}
	return false; // Missing/unreadable foreign packages are not configured.
};

export function notices(ctx, cursor) {
	let candidates = filter(PLUGINS, plugin => plugin.init != null && fs.stat(init_path(ctx, plugin)) != null);
	if (!length(candidates))
		return [];
	let running = inspect(ctx), notices = [];
	// A failed inspection gives no enabled notices rather than call a possibly running plugin stopped (docs/04).
	if (!running.ok)
		return notices;
	for (let plugin in candidates) {
		if (index(running.conflicts, plugin.name) >= 0)
			continue;
		let path = init_path(ctx, plugin);
		let boot = sys.run([ path, 'enabled' ], { timeout: 10, quiet: true }).code == 0;
		let enabled = configured(cursor, plugin);
		if (boot || enabled)
			push(notices, { code: 'CONFLICT_ENABLED', args: { plugin: plugin.name, boot, configured: enabled } });
	}
	return notices;
};
