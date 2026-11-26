'use strict';
'require view';
'require form';
'require aether-proxy.common as ap';
'require aether-proxy.form-defaults as form_defaults';
'require uci';
'require tools.widgets as widgets';
'require aether-proxy.model.advanced as model';

/*
 * Advanced page (docs/10 「高级页」, docs/tasks/m8.md T8.11b).
 *
 * The fields come from four UCI sections: `main` (interception, logging, boot
 * wait), `probe` (health checks), `dns` (dnsmasq_instance) and `stats` (B25
 * usage heatmap). The tabs
 * are declared on one NamedSection for `main`; options that belong to another
 * section set LuCI's per-option `ucisection` override (form.js: load/write/
 * remove all honour it), so they still read and save the right section.
 *
 * Every option validates through the pure model, which mirrors schema.uc and
 * config.uc. The page prechecks because unapplied LuCI changes live in the
 * rpcd session and are invisible to the command line (docs/10 访问控制页
 * 「保存前校验」); the CLI stays authoritative after saving.
 */

/* Add one tab option, point it at its UCI section, give it the shared model
   validator and the schema default (docs/05). `target` is only needed when
   the field lives outside the page's `main` section. */
function option(section, tab, type, field, title, target) {
	const o = section.taboption(tab, type, field, title, model.description(field));

	if (target)
		o.ucisection = target;

	const fallback = model.default(field);

	if (fallback != null) {
		// A Value default would be saved even without input; a hint stays display-only.
		if (type == form.Value)
			o.placeholder = fallback;
		else
			o.default = fallback;
	}

	o.validate = function(section_id, value) {
		return model.validate(field, value);
	};

	return o;
}

return view.extend({
	load: function() { return uci.load('aetherproxy'); },
	render: function() {
		const m = new form.Map('aetherproxy', _('Advanced', 'aether-proxy'));
		const s = m.section(form.NamedSection, 'main', 'global');
		ap.form_section(s, {
			description: _('Interception, logging, boot and health-check settings.', 'aether-proxy')
		});

		s.tab('intercept', _('Interception', 'aether-proxy'));
		s.tab('explicit', _('LAN explicit proxy', 'aether-proxy'),
			_('Clients must explicitly configure the router LAN IPv4 address and port. HTTP supports CONNECT to HTTPS destinations, not TLS to the proxy. Use only on controlled networks; reachability is determined by the existing firewall.', 'aether-proxy')
			+ ' ' + _('After clicking Save, anyone authorized to view LuCI Pending Changes may see modified proxy usernames and passwords until you apply or revert the changes.', 'aether-proxy'));
		s.tab('log', _('Logging', 'aether-proxy'));
		s.tab('boot', _('Boot and health checks', 'aether-proxy'));
		s.tab('components', _('Components and DNS instance', 'aether-proxy'));
		s.tab('experimental', _('Experimental features', 'aether-proxy'),
			_('These features are still being validated and may change or be removed in future versions. '
				+ 'All are disabled by default; when disabled, the interface matches the stable version.', 'aether-proxy'));

		let o;

		o = option(s, 'intercept', widgets.DeviceSelect, 'lan_ifaces', _('Interfaces', 'aether-proxy'));
		o.multiple = true;
		o.rmempty = false;

		// Scope is edited on Overview; readonly disables the widget without hiding saved values.
		o = s.taboption('intercept', form.Value, 'extra_ports', _('Extra ports', 'aether-proxy'),
			_('Comma-separated ports or ranges within 1–65535, up to 64 unique entries.', 'aether-proxy'));
		const scope = uci.get('aetherproxy', 'main', 'port_scope') || 'all';
		o.readonly = scope !== 'common_extra';
		if (o.readonly) {
			const current = scope === 'common' ? _('Common ports', 'aether-proxy') : _('All ports', 'aether-proxy');
			o.description += ' ' + _('Current port scope is “%s”; switch to “%s” to take effect.', 'aether-proxy')
				.format(current, _('Common and extra ports', 'aether-proxy'));
		}
		o.placeholder = o.readonly ? '' : '8080, 5000-5002';
		o.validate = function(section_id, value) {
			if (this.readonly || !value || !value.trim())
				return true;
			const entries = new Set();
			for (const part of value.split(',')) {
				const m = part.trim().match(/^([0-9]{1,5})(?:-([0-9]{1,5}))?$/);
				const a = m ? Number(m[1]) : 0;
				const b = m ? Number(m[2] ?? m[1]) : 0;
				if (a < 1 || b > 65535 || a > b)
					return _('Use ports or ascending ranges within 1–65535 (at most 64 unique entries).', 'aether-proxy');
				entries.add(a === b ? String(a) : a + '-' + b);
			}
			return entries.size <= 64 ? true
				: _('Use ports or ascending ranges within 1–65535 (at most 64 unique entries).', 'aether-proxy');
		};

		option(s, 'intercept', form.Flag, 'quic_block', _('Block QUIC', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'dns_hijack', _('Hijack DNS', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'ipv6_filter', _('Filter IPv6', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'filter_https_rr', _('Filter HTTPS RR', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'fail_open', _('Fail open', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'degrade_gfw',
			_('Proxy only blocked sites when the node is unavailable', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'sniffing', _('Sniffing', 'aether-proxy'));

		for (const protocol of [ 'socks', 'http' ]) {
			const label = protocol == 'socks' ? 'SOCKS5' : 'HTTP';
			o = option(s, 'explicit', form.Flag, protocol + '_enabled',
				_('Enable %s proxy', 'aether-proxy').format(label));
			o.default = '0';
			o.rmempty = false;
			for (const [suffix, title] of [
				[ 'listen', _('LAN IPv4 address', 'aether-proxy') ],
				[ 'port', _('Port', 'aether-proxy') ],
				[ 'username', _('Username', 'aether-proxy') ],
				[ 'password', _('Password', 'aether-proxy') ]
			]) {
				const field = protocol + '_' + suffix;
				o = option(s, 'explicit', form.Value, field, label + ' — ' + title);
				o.depends(protocol + '_enabled', '1');
				o.rmempty = false;
				o.password = suffix == 'password';
				o.validate = function(section_id, value) {
					const values = Object.fromEntries(s.children
						.filter(child => /^(socks|http)_/.test(child.option))
						.map(child => [child.option, child.formvalue(section_id)]));
					return model.validate(field, value, values);
				};
			}
		}

		o = option(s, 'log', form.RichListValue, 'log_level', _('Log level', 'aether-proxy'));
		model.log_level_choices().forEach((c) => o.value(c.value, c.label, c.description));

		o = option(s, 'log', form.ListValue, 'xray_log_level', _('Xray log level', 'aether-proxy'));
		model.xray_log_level_choices().forEach((c) => o.value(c.value, c.label));

		option(s, 'boot', form.Value, 'boot_wait_timeout', _('Boot wait timeout', 'aether-proxy'));
		option(s, 'boot', form.DynamicList, 'boot_check_targets', _('Boot check targets', 'aether-proxy'));
		option(s, 'boot', form.Value, 'url', _('Health check URL', 'aether-proxy'), 'probe');
		option(s, 'boot', form.Value, 'expect_code', _('Expected status code', 'aether-proxy'), 'probe');
		option(s, 'boot', form.Value, 'timeout', _('Health check timeout', 'aether-proxy'), 'probe');
		option(s, 'boot', form.Value, 'fail_threshold', _('Fail threshold', 'aether-proxy'), 'probe');
		option(s, 'boot', form.Value, 'recover_threshold', _('Recover threshold', 'aether-proxy'), 'probe');
		option(s, 'boot', form.Value, 'node_timeout', _('Node probe timeout', 'aether-proxy'), 'probe');
		option(s, 'boot', form.Value, 'node_concurrency', _('Node probe concurrency', 'aether-proxy'), 'probe');

		option(s, 'components', form.Value, 'xray_bin', _('Xray binary', 'aether-proxy'));
		option(s, 'components', form.Value, 'chinadns_bin', _('chinadns-ng binary', 'aether-proxy'));
		option(s, 'components', form.Value, 'dnsmasq_instance', _('dnsmasq instance', 'aether-proxy'), 'dns');

		const features = model.experimental_features();
		for (const feature of features) {
			o = option(s, 'experimental', form.Flag, feature.option, feature.title, feature.section);
			o.description = feature.description;
			o.default = feature.default;
			o.rmempty = false;
			// Upgraded installs may lack stats; uci.set silently ignores absent sections.
			o.write = function(section_id, value) {
				if (uci.get('aetherproxy', feature.section) == null)
					uci.add('aetherproxy', feature.section, feature.section);
				return form.Flag.prototype.write.call(this, section_id, value);
			};
		}

		const fallbacks = Object.fromEntries(s.children.map(o => [o.option, model.default(o.option)]));
		// Keep change-aware parsing, but persist an explicit 0 when a feature is switched off.
		// An untouched absent option still saves nothing; no default is backfilled.
		for (const feature of features)
			fallbacks[feature.option] = null;
		form_defaults.section(s, fallbacks);
		return m.render();
	}
});
