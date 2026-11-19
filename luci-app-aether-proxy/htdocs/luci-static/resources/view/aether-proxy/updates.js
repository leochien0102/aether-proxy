'use strict';
'require view';
'require form';
'require aether-proxy.form-defaults as form_defaults';
'require uci';
'require ui';
'require aether-proxy.common as ap';
'require aether-proxy.model.updates as model';

/* Update inventory, job controls and policy form (docs/10 "更新页").
 * Defer the initial status read until render returns (docs/10 "其余页面先出页面").
 * Refresh only the inventory, leaving unsaved policy edits intact.
 * Job progress and unconditional recovery follow docs/10 "UI 规则".
 * Group update progress comes from the model (docs/10 "B17").
 * Xray-only rollback and manual installation guidance follow docs/10 "r13：取消三包手动回滚".
 * Component update layout and the RC discovery flag follow docs/10 "更新页".
 */
return view.extend({
	load: function() {
		return ap.load_config();
	},
	set_channel: async function(checked) {
		const value = checked ? 'rc' : 'stable';
		this.busy = true;
		this.summary.textContent = '';
		this.show_inventory();
		try {
			const reply = await ap.call('set_update_channel', { value });
			if (!reply?.ok)
				throw new Error(reply?.detail ?? reply?.code ?? 'RPC_FAILED');
			this.rc = checked;
			uci.unload('aetherproxy');
			await ap.load_config();
		}
		catch (e) {
			this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
			this.busy = false;
			this.show_inventory();
			return;
		}
		return this.run('update_check');
	},
	run: async function(kind, name, previous, channel) {
		const bridge = kind == 'update_package' && !previous &&
			this.status?.updates_available?.packages?.[name]?.bridge_required === true;
		this.busy = true;
		let timer;
		try {
			this.summary.textContent = '';
			this.show_inventory();
			const text = model.job_progress(kind, name, previous, this.status);
			timer = ap.job_progress(this.progress, text);
			const job = kind == 'update_check' ? await ap.run_job('update_check', []) :
				await ap.run_job('update_package', previous ? [ name, '--previous' ] :
					(channel ? [ name, '--channel', channel ] : [ name ]));
			timer.stop();
			this.summary.textContent = model.job_result(kind, name, job);
			if (bridge && job.state == 'ok' && job.result?.ok !== false) {
				// Re-check only: each following step still requires a separate click.
				// Clear stale actions if the check or subsequent status read fails.
				this.status = { updates_available: null };
				timer = ap.job_progress(this.progress, model.job_progress('update_check'));
				const check = await ap.run_job('update_check', []);
				timer.stop();
				this.summary.textContent += ' ' + model.job_result('update_check', null, check) + ' ' +
					_('Please refresh the page before continuing to the next update step.', 'aether-proxy');
				if (check.state == 'failed' || check.result?.ok === false)
					return;
			}
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
		return E('button', { type: 'button', disabled: row.disabled || null,
			class: 'cbi-button ' + (previous ? 'cbi-button-remove' : 'cbi-button-action'),
			click: ui.createHandlerFn(this, async function() {
				if (previous && !await ap.confirm({
					title: row.confirmation_title ?? _('Roll back %s', 'aether-proxy').replace('%s', row.name),
					text: row.confirmation,
					ok: _('Roll back', 'aether-proxy'),
					destructive: true
				}))
					return;
				if (row.disabled)
					return;
				if (row.prerelease && !previous && !await ap.confirm({
					title: label, text: model.prerelease_note(), ok: label, destructive: true
				}))
					return;
				// Explicitly pin the channel that the user saw and confirmed.
				const channel = row.prerelease ? 'rc' : 'stable';
				return this.run('update_package', row.bridge_required && !previous ? 'aether-proxy' : row.name, previous, channel);
			}) }, [ label ]);
	},
	show_inventory: function() {
		const vm = model.table(this.status, this.busy, Date.now() / 1000, this.rc);
		const check = E('button', {
			type: 'button', class: 'cbi-button cbi-button-action', disabled: !vm.can_check || null,
			click: ui.createHandlerFn(this, function() { return this.run('update_check'); })
		}, _('Check for updates', 'aether-proxy'));
		const jobButtons = [check];
		const table = E('table', { class: 'table' }, [
			E('tr', { class: 'tr table-titles' },
				[ _('Name', 'aether-proxy'), _('Installed', 'aether-proxy'), _('Version', 'aether-proxy'),
					_('Previous', 'aether-proxy'), _('Status', 'aether-proxy'), _('Actions', 'aether-proxy') ]
					.map(text => E('th', { class: 'th' }, text))),
			...vm.rows.map(row => {
				const actions = [];
				if (row.install)
					actions.push(this.package_button(row, row.install_label, false));
				if (row.update || row.blocked)
					actions.push(this.package_button(row, row.update_label, false));
				if (row.rollback)
					actions.push(this.package_button(row, row.rollback_label, true));
				jobButtons.push(...actions);
				return E('tr', { class: 'tr' }, [
					/* Version strings come from the signed manifest, not from this page. */
					...[ row.name, row.installed, row.available, row.previous ].map(text => E('td', { class: 'td' }, [ text ])),
					E('td', { class: 'td' }, [ row.status, ...(row.prerelease ? [ ' ',
						E('span', { class: 'label', title: _('Pre-release; may have the same version number as the stable release.', 'aether-proxy') },
							_('Pre-release', 'aether-proxy')) ] : []) ]),
					E('td', { class: 'td' }, actions)
				]);
			})
		]);
		const channel = E('label', { class: 'aether-update-channel', title: model.channel_note(),
			style: 'display:flex; align-items:center; gap:0.4em; min-width:0' }, [
			E('input', { type: 'checkbox', role: 'switch', checked: this.rc || null, disabled: !vm.can_check || null,
				'aria-describedby': 'aether-update-channel-note',
				change: ui.createHandlerFn(this, function(ev) { return this.set_channel(ev.target.checked); }) }),
			_('Check for release candidates', 'aether-proxy'),
			E('span', { id: 'aether-update-channel-note', hidden: true }, model.channel_note())
		]);
		const statusRow = E('div', { class: 'aether-update-status',
			style: 'display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:0.5em 1em; min-width:0' }, [
			E('span', { style: 'flex:1 1 21em; min-width:0; overflow-wrap:anywhere' },
				[ _('Last checked', 'aether-proxy'), ': ', vm.checked, ' — ', vm.url, ...(vm.rc_url ? [ ' · ', vm.rc_url ] : []) ]),
			E('div', { style: 'display:flex; flex-wrap:wrap; align-items:center; min-width:0; gap:0.5em 1em; margin-inline-start:auto' },
				[ channel, check ])
		]);
		const hasFeedback = this.busy || this.summary.textContent || vm.error;
		const feedback = E('div', { class: 'aether-update-feedback', style: 'margin:0.25em 0 0',
			role: 'status', hidden: !hasFeedback || null },
			[ this.progress, this.summary, ...(vm.error ? [E('div', {}, vm.error)] : []) ]);
		const heading = E('h3', { class: 'aether-update-heading',
			style: 'display:flex; flex-wrap:wrap; align-items:baseline; gap:0.25em 1em' }, [
			E('span', {}, _('Component updates', 'aether-proxy')),
			E('span', { class: 'aether-update-manual-note',
				style: 'flex:1 1 28em; min-width:0; font-size:0.75em; font-weight:400; line-height:1.45; '
					+ 'white-space:normal; overflow-wrap:anywhere' }, model.manual_install_note())
		]);
		this.inventory.replaceChildren(ap.section({
			body: [ heading, statusRow, feedback, table ]
		}), ap.section({
			title: _('Running components', 'aether-proxy'),
			description: E('span', { title: model.migration_note() },
				_('This application updates only aether-xray.', 'aether-proxy')),
			body: model.components(this.status).map(row => E('p', {},
				[ row.name, ': ', row.version, ' — ', row.path, ' ', row.note ])),
			stacked: true
		}));
		this.jobButtons = jobButtons;
	},
	render: function() {
		this.status = undefined;
		this.rc = uci.get('aetherproxy', 'main', 'update_channel') === 'rc';
		this.busy = false;
		this.inventory = E('div');
		this.summary = E('div');
		this.progress = E('span');
		this.show_inventory();
		const map = new form.Map('aetherproxy', _('Updates', 'aether-proxy'));
		const section = map.section(form.NamedSection, 'update', 'update', _('Update policy', 'aether-proxy'));
		ap.form_section(section);
		let option = section.option(form.ListValue, 'xray_auto', _('Xray update policy', 'aether-proxy'));
		option.value('off', _('Off — do not notify', 'aether-proxy'));
		option.value('notify', _('Notify — do not install automatically', 'aether-proxy'));
		option.value('auto',
			_('Auto — install only while healthy; try each version once; roll back on check failure', 'aether-proxy'));
		option.default = 'notify';
		option = section.option(form.Flag, 'data_auto', _('Automatically update rule data', 'aether-proxy'));
		option.default = '1';
		option = section.option(form.Value, 'data_hour', _('Update hour', 'aether-proxy'));
		option.validate = form_defaults.integer(0, 23);
		option.placeholder = '4';
		option = section.option(form.Value, 'data_minute', _('Update minute', 'aether-proxy'));
		option.validate = form_defaults.integer(0, 59);
		option.placeholder = '30';
		option = section.option(form.DynamicList, 'channel_urls', _('Channel URLs', 'aether-proxy'),
			_('Leave empty to use the default release channel.', 'aether-proxy'));
		// Empty means the built-in channel; a default would pin today's URL on Save.
		option.placeholder = 'https://github.com/leochien0102/aether-proxy-channel/releases/download/channel-stable/';
		// The optional add box is validated even while empty (docs/10 r14); it is not a URL item.
		option.validate = function(section_id, value) { return value === '' ? true : model.validate_url(value); };
		form_defaults.section(section, {
			data_hour: '4', data_minute: '30', channel_urls: [option.placeholder]
		});
		return map.render().then(node => {
			const root = E('div', {}, [ node, this.inventory ]);
			// A new turn lets LuCI display the complete page before starting RPC.
			window.setTimeout(() => {
				ap.call('status').then(status => {
					this.status = status;
					this.show_inventory();
				});
			}, 0);
			return root;
		});
	}
});
