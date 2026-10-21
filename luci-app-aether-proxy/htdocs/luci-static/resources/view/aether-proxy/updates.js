'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require aether-proxy.common as ap';
'require aether-proxy.model.updates as model';

/* Update inventory, job controls and policy form (docs/10 "更新页").
 * Refresh only after jobs, leaving unsaved policy edits intact.
 * Job progress and unconditional recovery follow docs/10 "UI 规则".
 */
return view.extend({
	load: function() {
		return Promise.all([ uci.load('aetherproxy'), ap.call('status') ]);
	},
	run: async function(kind, name, previous) {
		this.busy = true;
		let timer;
		try {
			this.summary.textContent = '';
			this.show_inventory();
			const text = kind == 'update_check' ? _('Checking for updates…', 'aether-proxy') :
				(previous ? _('Rolling back %s…', 'aether-proxy') : _('Installing %s…', 'aether-proxy')).format(name);
			timer = ap.job_progress(this.progress, text);
			const job = kind == 'update_check' ? await ap.run_job('update_check', []) :
				await ap.run_job('update_package', previous ? [ name, '--previous' ] : [ name ]);
			timer.stop();
			this.summary.textContent = model.job_result(kind, name, job);
			this.status = await ap.call('status');
		}
		catch (e) {
			this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
		}
		finally {
			this.busy = false;
			if (timer)
				timer.stop();
			// Restore existing controls even if rebuilding the inventory throws.
			for (const button of this.jobButtons ?? [])
				button.disabled = false;
			try {
				this.show_inventory();
			}
			catch (e) {
				this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
			}
		}
	},
	package_button: function(row, label, previous) {
		return E('button', { type: 'button', disabled: row.disabled,
			class: 'cbi-button ' + (previous ? 'cbi-button-remove' : 'cbi-button-action'),
			click: ui.createHandlerFn(this, async function() {
				if (previous && !await ap.confirm({
					title: _('Roll back %s', 'aether-proxy').replace('%s', row.name),
					text: row.confirmation,
					ok: _('Roll back', 'aether-proxy'),
					destructive: true
				}))
					return;
				return this.run('update_package', row.name, previous);
			}) }, label);
	},
	show_inventory: function() {
		const vm = model.table(this.status, this.busy, Date.now() / 1000);
		const check = E('button', {
			type: 'button', class: 'cbi-button cbi-button-action', disabled: !vm.can_check,
			click: ui.createHandlerFn(this, function() { return this.run('update_check'); })
		}, _('Check for updates', 'aether-proxy'));
		const jobButtons = [check];
		this.inventory.replaceChildren(E('p', {}, vm.error ?? ''), E('table', { class: 'table' }, [
			E('tr', { class: 'tr table-titles' },
				[ _('Name', 'aether-proxy'), _('Installed', 'aether-proxy'), _('Latest', 'aether-proxy'), _('Previous', 'aether-proxy'), _('Status', 'aether-proxy'), _('Actions', 'aether-proxy') ]
					.map(text => E('th', { class: 'th' }, text))),
			...vm.rows.map(row => {
				const actions = [];
				if (row.install)
					actions.push(this.package_button(row, _('Install', 'aether-proxy'), false));
				if (row.update)
					actions.push(this.package_button(row, _('Update now', 'aether-proxy'), false));
				if (row.rollback)
					actions.push(this.package_button(row, row.rollback_label, true));
				jobButtons.push(...actions);
				return E('tr', { class: 'tr' }, [
					...[ row.name, row.installed, row.available, row.previous, row.status ]
						.map(text => E('td', { class: 'td' }, text)), E('td', { class: 'td' }, actions)
				]);
			})
		]), E('p', {}, [ _('Last checked', 'aether-proxy'), ': ', vm.checked, ' — ', vm.url ]),
		check, this.progress,
		E('h3', {}, _('Running components', 'aether-proxy')),
		...model.components(this.status).map(row => E('p', {},
			[ row.name, ': ', row.version, ' — ', row.path, ' ', row.note ])));
		this.jobButtons = jobButtons;
	},
	render: function(data) {
		this.status = data[1];
		this.busy = false;
		this.inventory = E('div');
		this.summary = E('p');
		this.progress = E('p');
		this.show_inventory();
		const map = new form.Map('aetherproxy', _('Updates', 'aether-proxy'));
		const section = map.section(form.NamedSection, 'update', 'update', _('Update policy', 'aether-proxy'));
		let option = section.option(form.ListValue, 'xray_auto', _('Xray update policy', 'aether-proxy'));
		option.value('off', _('Off — do not notify', 'aether-proxy'));
		option.value('notify', _('Notify — do not install automatically', 'aether-proxy'));
		option.value('auto', _('Auto — install only while healthy; try each version once; roll back on check failure', 'aether-proxy'));
		option.default = 'notify';
		option = section.option(form.Flag, 'data_auto', _('Automatically update rule data', 'aether-proxy'));
		option.default = '1';
		option = section.option(form.Value, 'data_hour', _('Update hour', 'aether-proxy'));
		option.datatype = 'range(0,23)';
		option.default = '4';
		option = section.option(form.Value, 'data_minute', _('Update minute', 'aether-proxy'));
		option.datatype = 'range(0,59)';
		option.placeholder = '30';
		option = section.option(form.DynamicList, 'channel_urls', _('Channel URLs', 'aether-proxy'),
			_('Leave empty to use the default release channel.', 'aether-proxy'));
		option.validate = function(section_id, value) { return model.validate_url(value); };
		return map.render().then(node => E('div', {}, [ node, this.inventory, this.summary ]));
	}
});
