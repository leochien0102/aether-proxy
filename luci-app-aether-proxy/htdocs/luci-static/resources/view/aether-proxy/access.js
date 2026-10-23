'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require network';
'require aether-proxy.model.access as model';

/*
 * Access control (docs/10 「访问控制页定案」 and 「r13 修正：访问控制页」).
 * Action sizing follows docs/10 「r13 修正：块内行与表格操作列」.
 * The model owns wording, summaries and validation. Staged LuCI changes are
 * invisible to the command line, so both save buttons precheck them here;
 * the backend remains authoritative. Display sorting must not reorder UCI.
 */
return view.extend({
	load: function() {
		return Promise.all([
			uci.load('aetherproxy'),
			/* Hints are optional: manual MAC input works after lookup failure. */
			L.resolveDefault(network.getHostHints(), null)
		]);
	},

	render: function(data) {
		this.candidates = model.mac_candidates(data[1]);
		this.map = this.buildMap();
		return this.map.render();
	},

	unlistedPolicy: function() {
		return this.unlistedOption.formvalue('main') || uci.get('aetherproxy', 'main', 'unlisted_policy') || 'follow';
	},

	updateNotice: function() {
		if (this.notice)
			this.notice.textContent = model.unlisted_notice(this.unlistedPolicy(),
				uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn');
	},

	/* Read unsaved inline edits too; moving existing DOM rows preserves widgets.
	   No uci.move() or whole-map rerender is allowed for presentation sorting. */
	updateRows: function() {
		if (!this.tableNode)
			return;

		const self = this;
		const rows = Array.from(this.tableNode.querySelectorAll('tr[data-sid]'));
		const hosts = uci.sections('aetherproxy', 'host').map(function(host) {
			const current = Object.assign({}, host);
			for (const key of [ 'enabled', 'policy', 'udp' ]) {
				const option = self.hostSection.children.find((o) => o.option == key);
				current[key] = option.formvalue(host['.name']) ?? host[key];
			}
			return current;
		});

		for (const host of model.sort_hosts(hosts)) {
			const row = rows.find((r) => r.getAttribute('data-sid') == host['.name']);
			if (!row)
				continue;

			const inactive = model.ineffective(host, this.unlistedPolicy());
			row.style.opacity = inactive ? '0.6' : '';
			row.style.whiteSpace = 'nowrap';
			const cell = row.querySelector('[data-name="policy"]');
			let note = cell.querySelector('[data-access-note]');
			if (!note) {
				note = E('span', { 'data-access-note': '1' });
				cell.appendChild(note);
			}
			/* The space stays outside the msgid: po2lmo keeps it but _() trims it (X3). */
			note.textContent = inactive
				? ' ' + _('(same as unlisted devices; has no effect)', 'aether-proxy') : '';
			row.parentNode.appendChild(row);
		}
	},

	buildMap: function() {
		const self = this;
		const m = new form.Map('aetherproxy', _('Access Control', 'aether-proxy'),
			_('Set the policy for each LAN device and for devices that are not listed.', 'aether-proxy'));
		const renderContents = m.renderContents.bind(m);
		/* Section rendering builds detached nodes; formvalue() still searches
		   the old Map root then. Wait for replacement so modal saves and resets
		   read the new widgets, not the previous inline policy/game-mode values. */
		m.renderContents = function() {
			return renderContents().then(function(node) {
				self.updateRows();
				return node;
			});
		};
		this.addMainOptions(m);
		this.addHostOptions(m);
		return m;
	},

	addMainOptions: function(m) {
		const self = this;
		const s = m.section(form.NamedSection, 'main', 'global');
		let o;
		s.description = [
			_('To proxy all devices, set Unlisted devices to Follow default mode, then set exceptions below to Direct.',
				'aether-proxy'),
			_('To proxy only some devices, set Unlisted devices to Direct, then list the devices to proxy below.',
				'aether-proxy')
		].join(' ');
		o = s.option(form.DummyValue, '_mode', _('Default mode', 'aether-proxy'));
		o.cfgvalue = function() {
			return model.mode_text(uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn');
		};

		o = this.unlistedOption = s.option(form.ListValue, 'unlisted_policy', _('Unlisted devices', 'aether-proxy'));
		o.value('follow', model.unlisted_text('follow'));
		o.value('direct', model.unlisted_text('direct'));
		o.default = 'follow';
		o.onchange = function() {
			self.updateNotice();
			self.updateRows();
		};
		o = s.option(form.DummyValue, '_notice');
		o.renderWidget = function() {
			self.notice = E('span', {}, model.unlisted_notice(
				uci.get('aetherproxy', 'main', 'unlisted_policy') || 'follow',
				uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn'));
			return self.notice;
		};

	},

	addHostOptions: function(m) {
		const self = this;
		let o;
		const Hosts = form.GridSection.extend({
			cfgsections: function() {
				return model.sort_hosts(uci.sections('aetherproxy', 'host')).map((h) => h['.name']);
			},
			renderSectionAdd: function() { return E([]); },
			renderRowActions: function(id) {
				const td = form.GridSection.prototype.renderRowActions.call(this, id);
				const actions = td.lastChild;
				// Keep intrinsic button widths without changing the theme's narrow-screen card layout.
				for (const button of actions.childNodes)
					button.style = (button.style?.cssText ?? '') + ';white-space:nowrap';
				actions.style = 'display:flex; flex-wrap:nowrap; gap:0.25em; align-items:center';
				return td;
			},
			renderContents: function(ids, nodes) {
				const node = form.GridSection.prototype.renderContents.call(this, ids, nodes);
				node.insertBefore(E('div', {
					style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
						+ 'flex-wrap:wrap; margin:0.5em 0 1em'
				}, E('button', {
					'class': 'cbi-button cbi-button-add',
					'click': ui.createHandlerFn(this, 'handleAdd'),
					'disabled': this.map.readonly || null
				}, _('Add', 'aether-proxy'))), node.querySelector('table'));
				self.tableNode = node;
				return node;
			}
		});
		const s = this.hostSection = m.section(Hosts, 'host');
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', _('Enabled', 'aether-proxy'));
		o.editable = true;
		o.default = '1';
		o.onchange = function() { self.updateRows(); };

		o = s.option(form.Value, 'name', _('Name', 'aether-proxy'));
		o.rmempty = true;
		/* GridSection modals save independently of the page footer. Fill the
		   name in both write/remove paths, including an empty optional field. */
		o.write = function(sid, value) {
			const mac = this.map.lookupOption('mac', sid)?.[0].formvalue(sid);
			const name = value || model.default_name(mac, self.candidates);
			if (name)
				uci.set('aetherproxy', sid, 'name', name);
			else
				uci.unset('aetherproxy', sid, 'name');
		};
		o.remove = function(sid) { return this.write(sid, ''); };

		/* Keep both match inputs together in the modal, absent from the table.
		   DynamicList allows manual/multiple MACs; never copy DHCP IPs to ip. */
		o = s.option(form.DynamicList, 'mac', _('Device', 'aether-proxy'));
		o.modalonly = true;
		o.rmempty = true;
		for (const c of self.candidates)
			o.value(c.mac, c.label);

		o = s.option(form.DummyValue, '_devices', _('Device', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(sid) {
			const summary = model.device_summary(uci.get('aetherproxy', sid), self.candidates);
			return E('span', { title: summary.title, style: 'white-space:nowrap' }, summary.text);
		};

		o = s.option(form.DynamicList, 'ip', _('IP / subnet (optional)', 'aether-proxy'));
		o.modalonly = true;
		o.rmempty = true;
		o.description = _(
			'Match MAC or IP (either suffices). Use IP for fixed addresses, subnets or devices behind a router.',
			'aether-proxy');

		o = s.option(form.ListValue, 'policy', _('Policy', 'aether-proxy'));
		o.editable = true;
		o.default = 'follow';
		for (const policy of [ 'follow', 'direct', 'bypass_cn', 'gfw', 'proxy' ])
			o.value(policy, model.policy_text(policy));
		o.description = _(
			'DNS uses the default mode. Web pages and most apps connect by domain name through the node.',
			'aether-proxy');
		o.onchange = function() { self.updateRows(); };

		o = s.option(form.Flag, 'udp', _('Game mode', 'aether-proxy'));
		o.editable = true;
		o.default = '0';
		for (const policy of [ 'follow', 'proxy', 'bypass_cn', 'gfw' ])
			o.depends({ policy: policy });
		o.onchange = function() { self.updateRows(); };

	},

	handleSave: function(ev) {
		return this.saveChecked(false);
	},

	handleSaveApply: function(ev) {
		return this.saveChecked(true);
	},

	saveChecked: function(apply_after_save) {
		const self = this;
		return this.map.parse().then(function() {
			const result = model.validate(uci.sections('aetherproxy', 'host'));
			const errors = result.errors;
			if (errors.length > 0) {
				self.showErrors(errors);
				return;
			}

			const warnings = result.warnings;
			if (warnings.length)
				ui.addNotification(null, E('ul', {}, warnings.map((w) => E('li', {}, w.text))), 'warning');

			return uci.save().then(function() {
				if (apply_after_save)
					return ui.changes.apply(true);
				return self.map.reset();
			});
		}).catch(function(e) {
			/* Widget validation failures must remain visible, like stock save. */
			ui.addNotification(null, E('p', {}, e?.message || String(e)), 'error');
		});
	},

	showErrors: function(errors) {
		ui.addNotification(null, E('div', {}, [
			E('p', {}, _('The host configuration has %s error(s); nothing was saved.', 'aether-proxy')
				.replace('%s', errors.length)),
			E('ul', {}, errors.map((e) => E('li', {}, e.text)))
		]), 'error');
	}
});
