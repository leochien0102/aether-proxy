'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require network';
'require aether-proxy.model.access as model';

/*
 * Access control page (docs/10 「访问控制页」, docs/tasks/m8.md T8.7).
 *
 * The view only fetches data (uci and network.getHostHints()), hands it to the
 * pure model and renders what the model returns: the MAC combobox choices, the
 * policy wording and the pre-save error texts are all decided there. The
 * command line stays the authoritative validator — because unapplied LuCI
 * changes live in the rpcd session where no command line can see them, the
 * page mirrors the rules of lib/config.uc check_hosts as a precheck on
 * 保存/保存并应用 and aborts the save when they fail (docs/10 访问控制页).
 */

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('aetherproxy'),
			/* The MAC candidates are a convenience; a failed lookup leaves the
			   page without combobox entries instead of breaking it. */
			L.resolveDefault(network.getHostHints(), null)
		]);
	},

	render: function(data) {
		this.candidates = model.mac_candidates(data[1]);
		this.map = this.buildMap();

		return this.map.render();
	},

	buildMap: function() {
		const self = this;
		let m, s, o;

		m = new form.Map('aetherproxy', _('Access Control'),
			_('Set the policy for each LAN host and for hosts that are not listed.'));

		/* docs/02 主机策略模型: the three helloworld approaches map onto
		   unlisted_policy plus per-host policies; the mapping is shown so the
		   choices make sense without reading the design. */
		s = m.section(form.NamedSection, 'main', 'global', _('Policy for unlisted hosts'));
		s.description = E('div', {}, [
			E('p', {}, _('This corresponds to the three helloworld approaches as follows:')),
			E('ul', {}, [
				E('li', {}, _('Disabled: unlisted_policy=follow, no host sections.')),
				E('li', {}, _('Only allow listed hosts: unlisted_policy=direct, listed hosts use policy=follow.')),
				E('li', {}, _('Also allow unlisted hosts: unlisted_policy=follow, listed hosts use policy=direct.'))
			])
		]);

		o = s.option(form.ListValue, 'unlisted_policy', _('Policy for unlisted hosts'));
		o.value('follow', model.unlisted_text('follow'));
		o.value('direct', model.unlisted_text('direct'));
		o.default = 'follow';

		s = m.section(form.GridSection, 'host');
		s.addremove = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.editable = true;
		o.default = '1';

		o = s.option(form.Value, 'name', _('Name'));
		o.editable = true;
		o.rmempty = true;

		o = s.option(form.DynamicList, 'ip', _('IP'));
		o.editable = true;
		o.rmempty = true;

		/* docs/10 访问控制页: the MAC input offers the DHCP leases and
		   neighbor table entries computed by the model as combobox choices;
		   free input stays possible (DynamicList). */
		o = s.option(form.DynamicList, 'mac', _('MAC'));
		o.editable = true;
		o.rmempty = true;

		for (const c of self.candidates)
			o.value(c.mac, c.label);

		o = s.option(form.ListValue, 'policy', _('Policy'));
		o.editable = true;
		o.default = 'follow';
		o.value('follow', model.policy_text('follow'));
		o.value('direct', model.policy_text('direct'));
		o.value('proxy', model.policy_text('proxy'));

		/* docs/02: game mode is only valid when the policy is not direct, so
		   the flag is hidden for direct hosts. Two depends() entries are
		   OR-combined by LuCI; a direct host has the staged udp option removed
		   on save because inactive options are dropped by parse(). */
		o = s.option(form.Flag, 'udp', _('Game mode'));
		o.editable = true;
		o.default = '0';
		o.depends({ policy: 'follow' });
		o.depends({ policy: 'proxy' });

		return m;
	},

	/* 保存 / 保存并应用 (docs/10 访问控制页): parse the form first, then run
	   the host sections through the model precheck; on errors the changes are
	   listed and uci.save() is never called. */
	handleSave: function(ev) {
		return this.saveChecked(false);
	},

	handleSaveApply: function(ev) {
		return this.saveChecked(true);
	},

	saveChecked: function(apply_after_save) {
		const self = this;

		return this.map.parse().then(function() {
			const errors = model.validate(uci.sections('aetherproxy', 'host')).errors;

			if (errors.length > 0) {
				self.showErrors(errors);
				return;
			}

			return uci.save().then(function() {
				if (apply_after_save)
					return ui.changes.apply(true);

				return self.map.reset();
			});
		}).catch(function(e) {
			/* Widget-level failures (datatype, empty mandatory field) reject
			   the parse; report them like the stock save flow does instead of
			   leaving an unhandled rejection. */
			ui.addNotification(null, E('p', {}, (e && e.message) ? e.message : String(e)), 'error');
		});
	},

	showErrors: function(errors) {
		ui.addNotification(null, E('div', {}, [
			E('p', {}, _('The host configuration has %s error(s); nothing was saved.').replace('%s', errors.length)),
			E('ul', {}, errors.map((e) => E('li', {}, e.text)))
		]), 'error');
	}
});
