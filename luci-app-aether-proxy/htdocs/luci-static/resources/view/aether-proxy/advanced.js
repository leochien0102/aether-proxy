'use strict';
'require view';
'require form';
'require aether-proxy.form-defaults as form_defaults';
'require uci';
'require tools.widgets as widgets';
'require aether-proxy.model.advanced as model';

/*
 * Advanced page (docs/10 「高级页」, docs/tasks/m8.md T8.11b).
 *
 * The fields come from three UCI sections: `main` (interception, logging, boot
 * wait), `probe` (health checks) and `dns` (dnsmasq_instance). The four tabs
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
	render: function() {
		const m = new form.Map('aetherproxy', _('Advanced', 'aether-proxy'), _('Interception, logging, boot and health-check settings.', 'aether-proxy'));
		const s = m.section(form.NamedSection, 'main', 'global', _('Advanced', 'aether-proxy'));

		s.tab('intercept', _('Interception', 'aether-proxy'));
		s.tab('log', _('Logging', 'aether-proxy'));
		s.tab('boot', _('Boot and health checks', 'aether-proxy'));
		s.tab('components', _('Components and DNS instance', 'aether-proxy'));

		let o;

		o = option(s, 'intercept', widgets.DeviceSelect, 'lan_ifaces', _('Interfaces', 'aether-proxy'));
		o.multiple = true;
		o.rmempty = false;

		option(s, 'intercept', form.Flag, 'quic_block', _('Block QUIC', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'dns_hijack', _('Hijack DNS', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'ipv6_filter', _('Filter IPv6', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'filter_https_rr', _('Filter HTTPS RR', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'fail_open', _('Fail open', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'degrade_gfw',
			_('Proxy only blocked sites when the node is unavailable', 'aether-proxy'));
		option(s, 'intercept', form.Flag, 'sniffing', _('Sniffing', 'aether-proxy'));

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

		form_defaults.section(s, Object.fromEntries(s.children.map(o => [o.option, model.default(o.option)])));
		return m.render();
	}
});
