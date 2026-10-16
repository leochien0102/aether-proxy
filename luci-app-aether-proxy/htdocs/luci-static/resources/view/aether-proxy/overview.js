'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.overview as model';

/*
 * Overview page (docs/10 「概览页」, including the 「启用开关」 section added for
 * T8.11a).
 *
 * The view only fetches data through ap, hands it to the pure model and renders
 * the view model the model returns: state wording, notice texts, button
 * availability and the stop confirmation are all decided there. status is
 * refreshed every 5 seconds via ap.poll; version and the UCI node labels plus
 * main.enabled are read once per page load.
 *
 * The 「启用」 switch never calls the `service` rpcd method: the init script
 * registers a reload trigger for the aetherproxy config, so saving the UCI
 * change starts the service when the switch is turned on and stops it when the
 * switch is turned off (docs/04 「重载」).
 */

return view.extend({
	load: function() {
		return Promise.all([
			ap.call('status'),
			ap.call('version'),
			uci.load('aetherproxy').then(function() {
				const labels = {};

				uci.sections('aetherproxy', 'node', function(s) {
					labels[s['.name']] = s.label || s['.name'];
				});

				/* docs/10 「启用开关」: the switch reflects main.enabled at page
				   load; an unset option means 0, the schema default. */
				return {
					labels: labels,
					enabled: uci.get('aetherproxy', 'main', 'enabled') === '1'
				};
			})
		]);
	},

	/* Toggle handler for the enable switch: stage the UCI value and go through
	   LuCI's standard save & apply with rollback confirmation, exactly like the
	   node page's 「设为当前」 (docs/10 「节点页」). No `service` call is made:
	   the reload trigger starts or stops the service. */
	handleEnable: function(checked) {
		this.enabled = (checked === true);

		uci.set('aetherproxy', 'main', 'enabled', this.enabled ? '1' : '0');

		return uci.save().then(function() {
			return ui.changes.apply(true);
		});
	},

	enableSwitch: function(note) {
		const self = this;

		return E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Enable')),
			E('div', { 'class': 'cbi-value-field' }, [
				E('input', {
					'type': 'checkbox',
					'id': 'aetherproxy-enabled',
					'checked': this.enabled ? 'checked' : null,
					'change': ui.createHandlerFn(this, function(ev) {
						return self.handleEnable(ev.target.checked);
					})
				}),
				E('div', { 'class': 'cbi-value-description' }, [ note ?? '' ])
			])
		]);
	},

	handleService: function(action) {
		const self = this;

		/* The wording comes from the model so it stays in one place (docs/10
		   「启用开关」). */
		if (action == 'stop' && !confirm(this.vm.stop_confirmation))
			return;

		return ap.call('service', { action: action }).then(function(res) {
			if (res && res.ok === false)
				ui.addNotification(null,
					E('p', {}, _('The service action failed: %s (%s).').replace('%s', res.code).replace('%s', res.detail ?? '')),
					'error');

			/* One immediate refresh after the action; the rest is the 5s poll. */
			window.setTimeout(function() {
				ap.call('status').then(function(status) {
					self.refresh(status);
				});
			}, 1500);
		});
	},

	buttonBar: function(buttons) {
		const self = this;

		const btn = (label, cls, enabled, fn) => {
			const attrs = { 'class': 'cbi-button ' + cls };

			if (enabled)
				attrs.click = ui.createHandlerFn(this, fn);
			else
				attrs.disabled = 'disabled';

			return E('button', attrs, [ label ]);
		};

		return E('div', { 'class': 'cbi-page-actions' }, [
			btn(_('Start'), 'cbi-button-apply', buttons.start, () => self.handleService('start')),
			btn(_('Restart'), 'cbi-button-apply', buttons.restart, () => self.handleService('restart')),
			btn(_('Stop'), 'cbi-button-negative', buttons.stop, () => self.handleService('stop'))
		]);
	},

	row: function(label, ...values) {
		const cells = [];

		for (const v of values)
			if (v != null)
				cells.push(v);

		return E('tr', {}, [
			E('td', {}, [ label ]),
			E('td', {}, cells.length ? cells : [ '–' ])
		]);
	},

	componentTable: function(components) {
		const rows = [
			E('tr', {}, [
				E('th', {}, _('Component')),
				E('th', {}, _('Version')),
				E('th', {}, _('Path'))
			])
		];

		for (const c of components)
			rows.push(E('tr', {}, [
				E('td', {}, c.name),
				E('td', {}, c.version ?? '–'),
				E('td', {}, c.path ?? '–')
			]));

		return E('table', { 'class': 'table' }, rows);
	},

	render: function(data) {
		const self = this;

		this.version = data[1];
		this.labels = data[2].labels;
		this.enabled = data[2].enabled;

		this.content = E('div', {});

		/* Build the view model once here so the switch description also comes
		   from the model; later refreshes replace only this.content, never the
		   switch, so the 5s poll cannot fight with the user's checkbox. */
		const vm = this.refresh(data[0]);

		const root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('aether-proxy')),
			E('div', { 'class': 'cbi-map-descr' }, _('Service status, pending notices and start/stop controls.')),
			this.enableSwitch(vm.enabled_note),
			this.content
		]);

		this.poller = ap.poll(function() {
			return ap.call('status').then(function(status) {
				self.refresh(status);
			});
		}, 5000);

		return root;
	},

	refresh: function(status) {
		const vm = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000), this.enabled);

		/* Keep the latest model output so handleService can use its
		   stop_confirmation without rebuilding the model. */
		this.vm = vm;

		const parts = [];

		if (!vm.ok) {
			parts.push(E('div', { 'class': 'alert-message error' }, vm.error));
		}
		else {
			parts.push(E('table', { 'class': 'table' }, [
				this.row(_('Status'), vm.state_text,
					vm.dns_failsafe ? _('DNS has fallen back to the original upstream configuration.') : null,
					vm.state_since_text),
				this.row(_('DNS level'), vm.dns_tier_text),
				this.row(_('Current node'), vm.node_text, vm.node_ip),
				this.row(_('Last health probe'), vm.probe_text, vm.probe_since_text),
				this.row(_('aether-proxy version'), vm.own_version ?? _('Unable to read the version.'))
			]));

			if (vm.components.length)
				parts.push(this.componentTable(vm.components));

			if (vm.notices.length) {
				const items = vm.notices.map((n) => E('li', {}, n));

				parts.push(E('div', { 'class': 'alert-message warning' }, E('ul', {}, items)));
			}

			parts.push(this.buttonBar(vm.buttons));
		}

		/* docs/10 「启用开关」: with the switch off, the status area says the
		   service is not enabled instead of pretending the buttons failed. */
		if (vm.disabled_notice)
			parts.unshift(E('div', { 'class': 'alert-message warning' }, vm.disabled_notice));

		dom.content(this.content, E('div', {}, parts));

		return vm;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
