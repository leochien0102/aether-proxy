'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.overview as model';

/*
 * Overview/Dashboard view (docs/10 「概览页」「Dashboard：概览页升级」).
 * Dashboard controls keep DOM state across refreshes; the model calculates
 * rates and completion messages, while this view owns requests and timers.
 *
 * The view only fetches data through ap, hands it to the pure model and renders
 * the view model the model returns: state wording, notice texts, button
 * availability and the stop confirmation are all decided there. status is
 * refreshed at the selected interval via ap.poll; version and the UCI node labels plus
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
			ap.call('status').then(function(reply) {
				return ap.call('stats').then(function(stats) { return { reply: reply, stats: stats }; });
			}),
			ap.call('version'),
			uci.load('aetherproxy').then(function() {
				const labels = {}, subscriptions = {};

				uci.sections('aetherproxy', 'node', function(s) {
					labels[s['.name']] = s.label || s['.name'];
				});

				uci.sections('aetherproxy', 'subscription', function(s) {
					subscriptions[s['.name']] = s.name || s['.name'];
				});

				/* docs/10 「启用开关」: the switch reflects main.enabled at page
				   load; an unset option means 0, the schema default. */
				return {
					labels: labels,
					subscriptions: subscriptions,
					node: uci.get('aetherproxy', 'main', 'node'),
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
			E('label', { 'class': 'cbi-value-title' }, _('Enable', 'aether-proxy')),
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
					E('p', {}, _('The service action failed: %s (%s).', 'aether-proxy').replace('%s', res.code).replace('%s', res.detail ?? '')),
					'error');

			/* Keep service actions useful even when automatic refresh is off. */
			window.setTimeout(function() {
				self.fetchRefresh();
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
			btn(_('Start', 'aether-proxy'), 'cbi-button-apply', buttons.start, () => self.handleService('start')),
			btn(_('Restart', 'aether-proxy'), 'cbi-button-apply', buttons.restart, () => self.handleService('restart')),
			btn(_('Stop', 'aether-proxy'), 'cbi-button-negative', buttons.stop, () => self.handleService('stop'))
		]);
	},

	/* Manual refresh, service actions and replacement pollers share the same
	   promise: ap.poll alone cannot serialize these independent entry points. */
	fetchRefresh: function() {
		if (this.refreshing)
			return this.refreshing;
		this.refreshing = ap.call('status').then((reply) => {
			return ap.call('stats').then((stats) => {
				this.refresh(reply, stats);
			});
		}).finally(() => { this.refreshing = null; });
		return this.refreshing;
	},

	readInterval: function() {
		try {
			return model.refresh_interval(window.localStorage.getItem('aether-proxy.refresh'));
		}
		catch (e) {
			console.warn('Unable to read Dashboard refresh preference:', e);
			return model.refresh_interval(null);
		}
	},

	setInterval: function(value) {
		try {
			window.localStorage.setItem('aether-proxy.refresh', value);
		}
		catch (e) {
			console.warn('Unable to save Dashboard refresh preference:', e);
		}
		this.startPolling(model.refresh_interval(value));
	},

	startPolling: function(interval) {
		if (this.poller)
			this.poller.stop();
		this.poller = interval ? ap.poll(() => this.fetchRefresh(), interval) : null;
	},

	handleNode: function(node) {
		uci.set('aetherproxy', 'main', 'node', node);
		return uci.save().then(function() { return ui.changes.apply(true); });
	},

	handleProbe: function() {
		const button = this.probeButton;
		button.disabled = true;
		return ap.call('probe_now').then((reply) => {
			if (!reply.ok)
				return model.probe_result(reply);
			/* The deadline also covers a slow status RPC. Late replies must not
			   start another poll or overwrite the displayed timeout. */
			return new Promise((resolve) => {
				let finished = false, next;
				const finish = (text) => {
					if (finished)
						return;
					finished = true;
					window.clearTimeout(deadline);
					window.clearTimeout(next);
					resolve(text);
				};
				const deadline = window.setTimeout(() => {
					finish(model.probe_result({ code: 'TIMEOUT' }));
				}, 15000);
				const poll = () => ap.call('status').then((status) => {
					if (finished)
						return;
					const completion = model.probe_completion(status, reply.requested_at);
					if (completion.done)
						finish(completion.text);
					else
						next = window.setTimeout(poll, 1000);
				});
				next = window.setTimeout(poll, 1000);
			});
		}).then((text) => {
			dom.content(this.probeMessage, text);
		}).finally(() => { button.disabled = false; });
	},

	handleSubscriptions: function() {
		this.subButton.disabled = true;
		return ap.run_job('sub_update', []).then((job) => {
			const result = model.subscription_result(job, this.subscriptions);
			dom.content(this.subMessage, E('div', {}, [
				E('p', {}, result.text), E('ul', {}, result.failures.map((text) => E('li', {}, text)))
			]));
		}).finally(() => { this.subButton.disabled = false; });
	},

	dashboardControls: function(interval, node) {
		const select = E('select', { change: (ev) => this.setInterval(ev.target.value) },
			model.refresh_options().map((option) => E('option', {
				value: option.value, selected: Number(option.value) * 1000 === interval ? 'selected' : null
			}, option.text)));
		const nodes = E('select', {}, Object.keys(this.labels).map((id) => E('option', {
			value: id, selected: id === node ? 'selected' : null
		}, this.labels[id])));
		const button = (text, fn) => E('button', {
			'class': 'cbi-button cbi-button-apply', click: ui.createHandlerFn(this, fn)
		}, text);
		this.probeButton = button(_('Measure latency', 'aether-proxy'), () => this.handleProbe());
		this.subButton = button(_('Update subscriptions', 'aether-proxy'), () => this.handleSubscriptions());
		this.probeMessage = E('div', { 'aria-live': 'polite' });
		this.subMessage = E('div', { 'aria-live': 'polite' });
		return E('div', {}, [
			E('label', {}, [ _('Refresh interval', 'aether-proxy'), select ]),
			button(_('Refresh', 'aether-proxy'), () => this.fetchRefresh()),
			nodes, button(_('Switch', 'aether-proxy'), () => this.handleNode(nodes.value)),
			this.probeButton, this.probeMessage, this.subButton, this.subMessage
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
				E('th', {}, _('Component', 'aether-proxy')),
				E('th', {}, _('Version', 'aether-proxy')),
				E('th', {}, _('Path', 'aether-proxy'))
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
		this.version = data[1];
		this.labels = data[2].labels;
		this.subscriptions = data[2].subscriptions;
		this.enabled = data[2].enabled;

		this.content = E('div', {});

		/* Build the view model once here so the switch description also comes
		   from the model; later refreshes replace only this.content, never the
		   switch, so polling cannot fight with the user's checkbox. */
		const vm = this.refresh(data[0].reply, data[0].stats);
		const interval = this.readInterval();

		const root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('aether-proxy', 'aether-proxy')),
			E('div', { 'class': 'cbi-map-descr' }, _('Service status, pending notices and start/stop controls.', 'aether-proxy')),
			this.enableSwitch(vm.enabled_note),
			this.dashboardControls(interval, data[2].node),
			this.content
		]);

		this.startPolling(interval);

		return root;
	},

	refresh: function(status, stats) {
		const vm = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000), this.enabled);

		/* Keep the latest model output so handleService can use its
		   stop_confirmation without rebuilding the model. */
		this.vm = vm;

		const traffic = model.traffic(this.previousStats, stats);
		this.previousStats = stats;
		const parts = [ E('table', { 'class': 'table' }, [
			this.row(_('Proxy traffic ↑ / ↓', 'aether-proxy'), traffic.proxy.tx, ' / ', traffic.proxy.rx),
			this.row(_('Direct traffic ↑ / ↓', 'aether-proxy'), traffic.direct.tx, ' / ', traffic.direct.rx),
			this.row(_('Total traffic ↑ / ↓', 'aether-proxy'), traffic.total.tx, ' / ', traffic.total.rx),
			this.row(_('Proxy connections', 'aether-proxy'), traffic.connections.proxy),
			this.row(_('Total connections (conntrack)', 'aether-proxy'), traffic.connections.total)
		]) ];

		if (!vm.ok) {
			parts.push(E('div', { 'class': 'alert-message error' }, vm.error));
		}
		else {
			parts.push(E('table', { 'class': 'table' }, [
				this.row(_('Status', 'aether-proxy'), vm.state_text,
					vm.dns_failsafe ? _('DNS has fallen back to the original upstream configuration.', 'aether-proxy') : null,
					vm.state_since_text),
				this.row(_('DNS level', 'aether-proxy'), vm.dns_tier_text),
				this.row(_('Current node', 'aether-proxy'), vm.node_text, vm.node_ip),
				this.row(_('Last health probe', 'aether-proxy'), vm.probe_text, vm.probe_since_text),
				this.row(_('aether-proxy version', 'aether-proxy'), vm.own_version ?? _('Unable to read the version.', 'aether-proxy'))
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
