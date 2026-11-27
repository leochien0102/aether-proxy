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
	load: function() {
		return Promise.all([
			uci.load('aetherproxy'),
			ap.call('status').then(reply => {
				// CONFIG_INVALID may still carry live candidates so other fields can be repaired.
				this.explicitLan = reply?.explicit_lan;
			}).catch(() => { this.explicitLan = null; })
		]);
	},
	render: function() {
		const m = new form.Map('aetherproxy', _('Advanced', 'aether-proxy'));
		const s = m.section(form.NamedSection, 'main', 'global');
		ap.form_section(s, {
			description: _('Interception, logging, boot and health-check settings.', 'aether-proxy')
		});

		s.tab('intercept', _('Interception', 'aether-proxy'));
		s.tab('explicit', _('LAN explicit proxy', 'aether-proxy'),
			_('Clients must explicitly configure the router LAN IPv4 address and port. HTTP supports CONNECT to HTTPS destinations, not TLS to the proxy. Use only on controlled networks; reachability is determined by the existing firewall.', 'aether-proxy')
			+ ' ' + _('Authentication is shared by both proxies. When disabled, any client that can reach the port can use the proxy. Clearing credentials does not disable authentication.', 'aether-proxy')
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

		// Candidates are already filtered by the backend's logical LAN lookup.
		const addresses = this.explicitLan?.addresses || [];
		const main = () => uci.get('aetherproxy', 'main') || {};
		const inputs = {};
		const values = () => Object.fromEntries(Object.entries(inputs).map(([key, child]) => [key, child.formvalue('main')]));
		const enabled = () => values().socks_enabled === '1' || values().http_enabled === '1';
		let credentialsCleared = false;
		// Map.reset() only calls renderContents(), not load(). Discard local intent
		// at the native reset boundary as well as after a successful save reload.
		for (const method of ['reset', 'load']) {
			const original = m[method];
			if (typeof original === 'function')
				m[method] = function() {
					credentialsCleared = false;
					return original.apply(this, arguments);
				};
		}
		const resolved = () => {
			const v = values();
			// Clear resets the source widget; a later explicit source choice wins.
			if (v._proxy_credential_source === 'socks' || v._proxy_credential_source === 'http')
				return ['username', 'password'].map(key => main()[v._proxy_credential_source + '_' + key] || '');
			if (credentialsCleared)
				return [v.proxy_username || '', v.proxy_password || ''];
			if (model.credentials(main()).conflict && !(v.proxy_username && v.proxy_password))
				return null;
			return [v.proxy_username || '', v.proxy_password || ''];
		};
		const addressError = () => !enabled() ||
			(addresses.length === 1 || (addresses.length > 1 && addresses.includes(values().proxy_address))) ? true :
			addresses.length ? _('Select one of the current LAN IPv4 addresses.', 'aether-proxy') :
				_('No usable IPv4 address is available on logical LAN. Disable both proxies or restore LAN connectivity.', 'aether-proxy');
		const credentialError = () => !resolved() && (values().proxy_auth_enabled === '1' || values().proxy_username || values().proxy_password) ?
			_('Legacy proxy credentials differ. Choose a source or enter both shared credentials.', 'aether-proxy') : true;

		o = s.taboption('explicit', form.DummyValue, '_proxy_lan', _('LAN address source', 'aether-proxy'));
		o.cfgvalue = () => _('Logical interface: %s', 'aether-proxy').format(this.explicitLan?.interface || 'lan')
			+ ' — ' + (addresses.length ? addresses.join(', ') : _('No usable LAN IPv4 address', 'aether-proxy'));
		if (addresses.length > 1) {
			o = inputs.proxy_address = s.taboption('explicit', form.ListValue, 'proxy_address', _('LAN IPv4 address', 'aether-proxy'),
				_('Both proxies use this address. Only current backend LAN candidates can be selected.', 'aether-proxy'));
			o.value('', _('Select a LAN address', 'aether-proxy'));
			addresses.forEach(address => o.value(address));
			o.validate = addressError;
			o.write = o.remove = function() {};
		}
		for (const protocol of [ 'socks', 'http' ]) {
			const label = protocol == 'socks' ? 'SOCKS5' : 'HTTP';
			o = inputs[protocol + '_enabled'] = option(s, 'explicit', form.Flag, protocol + '_enabled',
				_('Enable %s proxy', 'aether-proxy').format(label));
			o.default = '0';
			o.rmempty = false;
			o.validate = (section_id, value) => model.validate(protocol + '_enabled', value) !== true ?
				model.validate(protocol + '_enabled', value) : addressError();
			o = inputs[protocol + '_port'] = option(s, 'explicit', form.Value, protocol + '_port', label + ' — ' + _('Port', 'aether-proxy'));
			o.default = protocol == 'socks' ? '1080' : '8080';
			o.depends(protocol + '_enabled', '1');
			o.rmempty = false;
			o.validate = (section_id, value) => model.validate(protocol + '_port', value, values());
		}
		o = inputs.proxy_auth_enabled = s.taboption('explicit', form.Flag, 'proxy_auth_enabled', _('Require authentication', 'aether-proxy'));
		o.cfgvalue = () => model.authentication(main());
		o.rmempty = false;
		o.validate = (section_id, value) => model.validate('proxy_auth_enabled', value);
		// Persist even 0 explicitly, after whole-page validation, to suppress legacy inference.
		o.write = o.remove = function() {};
		if (model.credentials(main()).conflict) {
			o = inputs._proxy_credential_source = s.taboption('explicit', form.ListValue, '_proxy_credential_source', _('Resolve legacy credentials', 'aether-proxy'),
				_('The old credential pairs differ and are not displayed. Select an old source or enter both shared credentials. To remove all credentials, use Clear credentials and disable authentication before saving. Nothing is migrated until a valid save.', 'aether-proxy'));
			o.value('', _('Enter new shared credentials or disable authentication', 'aether-proxy'));
			o.value('socks', _('Use the old SOCKS5 credentials', 'aether-proxy'));
			o.value('http', _('Use the old HTTP credentials', 'aether-proxy'));
			o.validate = credentialError;
			o.parse = () => Promise.resolve();
		}
		for (const [index, key, title] of [[0, 'username', _('Shared username', 'aether-proxy')], [1, 'password', _('Shared password', 'aether-proxy')]]) {
			const field = 'proxy_' + key;
			o = inputs[field] = s.taboption('explicit', form.Value, field, title,
				_('Stored once and used by both SOCKS5 and HTTP. Turning a proxy off does not erase these credentials.', 'aether-proxy'));
			o.password = key == 'password';
			const renderField = o.renderWidget;
			o.renderWidget = function() {
				const node = renderField.apply(this, arguments);
				const input = node.querySelector('input');
				if (this.password) {
					input.nextElementSibling.remove(); // Replace SDK's external reveal button.
					input.type = 'password';
					const show = _('Show password', 'aether-proxy'), hide = _('Hide password', 'aether-proxy');
					const eye = ap.input_action(input, 'hidden', show, () => {
						const reveal = input.type === 'password';
						input.type = reveal ? 'text' : 'password';
						eye.setIcon(reveal ? 'eye' : 'hidden', reveal ? hide : show);
					});
				}
				const clear = ap.input_action(input, 'clear', this.password ? _('Clear password', 'aether-proxy') : _('Clear username', 'aether-proxy'), () => {
					input.value = ''; input.dispatchEvent(new Event('input', { bubbles:true }));
					input.dispatchEvent(new Event('change', { bubbles:true }));
					this.triggerValidation('main'); input.focus();
				}, this.password ? 1.75 : 0);
				const host = input.parentElement;
				const sync = (focus = document.activeElement) => {
					const visible = !!input.value && !input.readOnly && !input.disabled && host.contains(focus);
					clear.hidden = !visible;
					clear.disabled = !visible;
					clear.tabIndex = visible ? 0 : -1;
					// Author theme display rules can override the browser's default [hidden] rule.
					clear.style.setProperty('display', visible ? 'inline-flex' : 'none', 'important');
				};
				input.addEventListener('input', () => sync());
				input.addEventListener('change', () => sync());
				host.addEventListener('focusin', () => sync());
				host.addEventListener('focusout', event => sync(event.relatedTarget));
				new MutationObserver(() => sync()).observe(input, { attributes:true, attributeFilter:['disabled', 'readonly'] });
				sync();
				return node;
			};
			o.cfgvalue = () => model.credentials(main()).pair[index];
			o.validate = () => {
				if (credentialError() !== true) return credentialError();
				const pair = resolved();
				return model.validate(field, pair?.[index], {
					proxy_username: pair?.[0], proxy_password: pair?.[1],
					proxy_auth_enabled: values().proxy_auth_enabled
				});
			};
			// Commit the pair and remove legacy fields only after every tab parses.
			o.write = o.remove = function() {};
		}

		o = s.taboption('explicit', form.DummyValue, '_proxy_clear_credentials', _('Clear credentials', 'aether-proxy'));
		o.renderWidget = () => E('button', {
			type: 'button', class: 'cbi-button cbi-button-neutral',
			click: () => {
				credentialsCleared = true;
				for (const key of ['proxy_username', 'proxy_password', '_proxy_credential_source']) {
					const widget = inputs[key]?.getUIElement('main');
					if (widget) {
						widget.setValue('');
						widget.node?.querySelector('input')?.dispatchEvent(new Event('input', { bubbles:true }));
					}
				}
				for (const key of ['proxy_username', 'proxy_password'])
					inputs[key].triggerValidation('main');
			}
		}, _('Clear credentials', 'aether-proxy'));

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
		const parse = m.parse;
		m.parse = function() {
			// Recheck cross-field state, including optional empty inputs, at save time.
			for (const child of Object.values(inputs)) {
				if (child.isActive('main')) {
					const result = child.validate('main', child.formvalue('main'));
					if (result !== true)
						return Promise.reject(new TypeError(result));
				}
			}
			return Promise.resolve(parse.call(this)).then(() => {
				const auth = values().proxy_auth_enabled;
				const pair = resolved();
				// Saving new credentials while off must not enable legacy inference on reload.
				if (main().proxy_auth_enabled !== auth
					&& (auth === '1' || model.authentication(main()) === '1'
						|| main().proxy_auth_enabled != null || pair?.some(Boolean)))
					uci.set('aetherproxy', 'main', 'proxy_auth_enabled', auth);
				if (pair) {
					for (const [index, key] of [[0, 'username'], [1, 'password']]) {
						if (!pair[index]) {
							if (main()['proxy_' + key] != null)
								uci.unset('aetherproxy', 'main', 'proxy_' + key);
						}
						else if (main()['proxy_' + key] !== pair[index])
							uci.set('aetherproxy', 'main', 'proxy_' + key, pair[index]);
					}
					for (const protocol of ['socks', 'http'])
						for (const key of ['username', 'password', 'listen'])
							if (main()[protocol + '_' + key] != null)
								uci.unset('aetherproxy', 'main', protocol + '_' + key);
				}
				if (addresses.length) {
					const address = addresses.length > 1 ? values().proxy_address : '';
					if (address && addresses.includes(address) && address !== main().proxy_address)
						uci.set('aetherproxy', 'main', 'proxy_address', address);
					else if (!address && main().proxy_address != null)
						uci.unset('aetherproxy', 'main', 'proxy_address');
				}
			});
		};
		return m.render();
	}
});
