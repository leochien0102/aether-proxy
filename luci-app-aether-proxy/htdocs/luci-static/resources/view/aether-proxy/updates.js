'use strict';
'require view';
'require form';
'require aether-proxy.form-defaults as form_defaults';
'require ui';
'require aether-proxy.common as ap';
'require aether-proxy.model.updates as model';
'require aether-proxy.changelog as changelog';

/* Update inventory, job controls and policy form (docs/10 "更新页").
 * Defer the initial status read until render returns (docs/10 "其余页面先出页面").
 * Refresh only the inventory, leaving unsaved policy edits intact.
 * Job progress and unconditional recovery follow docs/10 "UI 规则".
 * Group update progress comes from the model (docs/10 "B17").
 * Xray-only rollback and manual installation guidance follow docs/10 "r13：取消三包手动回滚".
 * Component update layout follows docs/10 "更新页".
 */
return view.extend({
	load: function() {
		return ap.load_config();
	},
	run: async function(kind, name, previous) {
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
				await ap.run_job('update_package', previous ? [ name, '--previous' ] : [ name ]);
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
				// Companion rows must not install the target's page/translation independently.
				return this.run('update_package', row.bridge_required && !previous ? 'aether-proxy' : row.name, previous);
			}) }, [ label ]);
	},
	show_inventory: function() {
		const vm = model.table(this.status, this.busy, Date.now() / 1000);
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
					actions.push(this.package_button(row, row.bridge_required ? row.update_label : _('Install', 'aether-proxy'), false));
				if (row.update || row.blocked)
					actions.push(this.package_button(row, row.update_label, false));
				if (row.rollback)
					actions.push(this.package_button(row, row.rollback_label, true));
				jobButtons.push(...actions);
				const target = this.status?.updates_available?.packages?.['aether-proxy'];
				const releaseUrl = row.name == 'aether-proxy' && target?.newer === true &&
					target.installed != null && target.installed !== row.available ?
					changelog.url(row.available) : null;
				if (releaseUrl)
					actions.push(E('a', { href: releaseUrl, target: '_blank', rel: 'noopener noreferrer',
						style: 'display:block; margin-top:0.5em; white-space:normal; overflow-wrap:anywhere' },
						_('Target release notes (online)', 'aether-proxy')));
				return E('tr', { class: 'tr' }, [
					/* Version strings come from the signed manifest, not from this page. */
					...[ row.name, row.installed, row.available, row.previous, row.status ]
						.map(text => E('td', { class: 'td' }, [ text ])),
					E('td', { class: 'td' }, actions)
				]);
			})
		]);
		this.summary.hidden = !this.summary.textContent;
		this.progress.hidden = !this.busy;
		const statusRow = E('div', { class: 'aether-update-status',
			style: 'display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:0.5em 1em; min-width:0; margin:0 0 0.75em' }, [
			E('span', { style: 'min-width:0' }, [
				_('Last checked', 'aether-proxy'), ': ',
				this.status === undefined ? _('Not checked yet', 'aether-proxy') : vm.checked,
			]),
			this.summary,
			this.progress,
			...(vm.error ? [ E('span', { style: 'min-width:0; overflow-wrap:anywhere' }, [ vm.error ]) ] : []),
			E('div', { style: 'display:flex; flex-wrap:wrap; align-items:center; min-width:0; gap:0.5em 1em; margin-inline-start:auto' },
				[ check ])
		]);
		const heading = E('h3', { class: 'aether-update-heading',
			style: 'display:flex; flex-wrap:wrap; align-items:baseline; gap:0.25em 1em' }, [
			E('span', {}, _('Component updates', 'aether-proxy')),
			E('span', { class: 'aether-update-manual-note',
				style: 'flex:1 1 28em; min-width:0; font-size:0.75em; font-weight:400; line-height:1.45; '
					+ 'white-space:normal; overflow-wrap:anywhere' }, model.manual_install_note())
		]);
		this.inventory.replaceChildren(ap.section({
			body: [ heading, statusRow, table ]
		}), ap.section({
			title: _('Running components', 'aether-proxy'),
			description: E('span', { title: model.migration_note() },
				_('This application updates only aether-xray.', 'aether-proxy')),
			body: model.components(this.status).map(row => E('p', {},
				[ row.name, ': ', row.version, ' — ', row.path, ' ', row.note ])),
			stacked: true
		}));
		const installed = this.status?.updates_available?.packages?.['aether-proxy']?.installed;
		this.changelogBody?.replaceChildren(changelog.render(installed));
		this.jobButtons = jobButtons;
	},
	render: function() {
		this.status = undefined;
		this.busy = false;
		this.inventory = E('div');
		this.changelogBody = E('div');
		const history = E('details', { class: 'cbi-section' }, [
			E('summary', {}, _('Version changes', 'aether-proxy')), this.changelogBody
		]);
		this.summary = E('span', { role: 'status', style: 'min-width:0; overflow-wrap:anywhere' });
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
		const channelDefault = 'https://github.com/leochien0102/aether-proxy-channel/releases/download/channel-stable/';
		option = section.option(form.DynamicList, 'channel_urls', _('Channel URLs', 'aether-proxy'),
			E('span', {}, [
				_('Leave empty to use the default release channel.', 'aether-proxy'), ' ',
				E('code', { style: '-webkit-user-select:text; user-select:text; overflow-wrap:anywhere' }, [ channelDefault ])
			]));
		// Empty means the built-in channel; a default would pin today's URL on Save.
		option.placeholder = channelDefault;
		// The optional add box is validated even while empty (docs/10 r14); it is not a URL item.
		option.validate = function(section_id, value) { return value === '' ? true : model.validate_url(value); };
		form_defaults.section(section, {
			data_hour: '4', data_minute: '30', channel_urls: [option.placeholder]
		});
		return map.render().then(node => {
			const root = E('div', {}, [ node, this.inventory, history ]);
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
