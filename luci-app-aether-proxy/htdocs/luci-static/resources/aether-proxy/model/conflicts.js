'use strict';
'require baseclass';

/* Shared proxy-plugin conflict presentation (docs/10 「r15：启动失败时写明冲突的插件、
 * `CONFLICT_ENABLED` 提示」). Product names live here so overview notices,
 * startup diagnostics and log events cannot drift apart. T10.60 also recognizes
 * pre-T9.34 nft table names in stored events (docs/10 r17). M4-02b2 shares
 * logical component names across notices and logs, including historical ids.
 */
const DISPLAY_NAMES = {
	'ssr-plus': 'ShadowSocksR Plus+',
	ss_spec: 'ShadowSocksR Plus+',
	ss_spec_mangle: 'ShadowSocksR Plus+',
	passwall: 'PassWall',
	passwall2: 'PassWall 2',
	homeproxy: 'HomeProxy',
	openclash: 'OpenClash',
	nikki: 'Nikki'
};

function display_name(name) {
	return DISPLAY_NAMES[name] ?? String(name);
}

function component_name(name) {
	// Old records are read-only: normalize the label, never the stored id.
	return name === 'dns' || name === 'chinadns-ng' ? _('DNS engine', 'aether-proxy') : String(name);
}

function item(value) {
	if (typeof value != 'string')
		return { kind: 'other', value };
	if (value.startsWith('conflict-check:') && value.length > 'conflict-check:'.length)
		return { kind: 'check', value: value.slice('conflict-check:'.length) };
	if (value.startsWith('conflict:') && value.length > 'conflict:'.length)
		return { kind: 'conflict', value: value.slice('conflict:'.length) };
	if (value.startsWith('component:') && value.length > 'component:'.length)
		return { kind: 'component', value: value.slice('component:'.length) };
	return { kind: 'other', value };
}

function groups(missing) {
	const result = { conflicts: [], checks: [], other: [] };
	for (const value of Array.isArray(missing) ? missing : []) {
		const parsed = item(value);
		const target = parsed.kind === 'conflict' ? result.conflicts
			: (parsed.kind === 'check' ? result.checks : result.other);
		const text = parsed.kind === 'component' ? component_name(parsed.value) : parsed.value;
		if (!target.some(existing => existing === text))
			target.push(text);
	}
	return result;
}

function format_log_item(value) {
	const parsed = item(value);
	if (parsed.kind === 'conflict')
		return _('Conflict with %s', 'aether-proxy').replace('%s', () => display_name(parsed.value));
	if (parsed.kind === 'check')
		return _('Could not check other proxy plugins (%s)', 'aether-proxy').replace('%s', () => parsed.value);
	if (parsed.kind === 'component')
		return component_name(parsed.value);
	return null;
}

return baseclass.extend({
	display_name: display_name,
	component_name: component_name,
	parse_item: item,
	groups: groups,
	format_log_item: format_log_item
});
