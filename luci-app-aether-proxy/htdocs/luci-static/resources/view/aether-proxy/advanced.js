'use strict';
'require view';
'require form';
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

	if (fallback != null)
		o.default = fallback;

	o.validate = function(section_id, value) {
		return model.validate(field, value);
	};

	return o;
}

return view.extend({
	render: function() {
		const m = new form.Map('aetherproxy', _('Advanced'), _('Interception, logging, boot and health-check settings.'));
		const s = m.section(form.NamedSection, 'main', 'global', _('Advanced'));

		s.tab('intercept', _('Interception'));
		s.tab('log', _('Logging'));
		s.tab('boot', _('Boot and health checks'));
		s.tab('components', _('Components and DNS instance'));

		let o;

		o = option(s, 'intercept', widgets.DeviceSelect, 'lan_ifaces', _('Interfaces'));
		o.multiple = true;
		o.rmempty = false;

		option(s, 'intercept', form.Flag, 'quic_block', _('Block QUIC'));
		option(s, 'intercept', form.Flag, 'dns_hijack', _('Hijack DNS'));
		option(s, 'intercept', form.Flag, 'ipv6_filter', _('Filter IPv6'));
		option(s, 'intercept', form.Flag, 'filter_https_rr', _('Filter HTTPS RR'));
		option(s, 'intercept', form.Flag, 'fail_open', _('Fail open'));
		option(s, 'intercept', form.Flag, 'sniffing', _('Sniffing'));

		o = option(s, 'log', form.RichListValue, 'log_level', _('Log level'));
		model.log_level_choices().forEach((c) => o.value(c.value, c.label, c.description));

		o = option(s, 'log', form.ListValue, 'xray_log_level', _('Xray log level'));
		model.xray_log_level_choices().forEach((c) => o.value(c.value, c.label));

		option(s, 'boot', form.Value, 'boot_wait_timeout', _('Boot wait timeout'));
		option(s, 'boot', form.DynamicList, 'boot_check_targets', _('Boot check targets'));
		option(s, 'boot', form.Value, 'url', _('Health check URL'), 'probe');
		option(s, 'boot', form.Value, 'expect_code', _('Expected status code'), 'probe');
		option(s, 'boot', form.Value, 'timeout', _('Health check timeout'), 'probe');
		option(s, 'boot', form.Value, 'fail_threshold', _('Fail threshold'), 'probe');
		option(s, 'boot', form.Value, 'recover_threshold', _('Recover threshold'), 'probe');
		option(s, 'boot', form.Value, 'node_timeout', _('Node probe timeout'), 'probe');
		option(s, 'boot', form.Value, 'node_concurrency', _('Node probe concurrency'), 'probe');

		option(s, 'components', form.Value, 'xray_bin', _('Xray binary'));
		option(s, 'components', form.Value, 'chinadns_bin', _('chinadns-ng binary'));
		option(s, 'components', form.Value, 'dnsmasq_instance', _('dnsmasq instance'), 'dns');

		return m.render();
	}
});
