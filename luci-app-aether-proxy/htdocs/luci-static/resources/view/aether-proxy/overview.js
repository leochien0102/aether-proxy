'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.overview as model';

/*
 * Overview view (docs/10 「概览页」「Dashboard：概览页升级」「概览页第二轮修正」).
 * Dashboard controls keep DOM state across refreshes; the model calculates
 * rates and completion messages, while this view owns requests and timers.
 *
 * The view only fetches data through ap, hands it to the pure model and renders
 * the view model the model returns: state wording, notice texts, button
 * availability and the stop confirmation are all decided there. status is
 * refreshed at the selected interval via ap.poll; version and the UCI node labels plus
 * main.enabled are read at load; installed components are read once after rendering
 * and update only their table, without delaying the first screen (docs/10 T10.5).
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
				E('div', { 'class': 'cbi-value-description', 'style': 'font-size: 0.9em' }, [ note ?? '' ])
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

		return E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
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

	button: function(text, fn) {
		return E('button', {
			'class': 'cbi-button cbi-button-apply', click: ui.createHandlerFn(this, fn)
		}, text);
	},

	titleLine: function(interval) {
		const select = E('select', { change: (ev) => this.setInterval(ev.target.value) },
			model.refresh_options().map((option) => E('option', {
				value: option.value, selected: Number(option.value) * 1000 === interval ? 'selected' : null
			}, option.text)));
		return E('div', {
			style: 'display:flex; align-items:center; justify-content:space-between; gap:1em; '
				+ 'flex-wrap:wrap; margin-bottom:1em'
		}, [
			E('h2', {}, _('Aether Proxy', 'aether-proxy')),
			E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
				E('label', { style: 'display:flex; align-items:center; gap:0.5em' }, [
					E('span', { style: 'white-space: nowrap' }, _('Automatic refresh', 'aether-proxy')), select
				]),
				this.button(_('Refresh', 'aether-proxy'), () => this.fetchRefresh())
			])
		]);
	},

	probeControls: function() {
		this.probeButton = this.button(_('Measure latency', 'aether-proxy'), () => this.handleProbe());
		this.probeMessage = E('span', { 'aria-live': 'polite' });
		return E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
			this.probeButton, this.probeMessage
		]);
	},

	nodeControls: function(vm) {
		const current = vm.current_node;
		const nodes = E('select', {}, vm.node_options.map((option) => E('option', {
			value: option.value, selected: option.value === current ? 'selected' : null
		}, option.text)));
		const button = this.button(_('Use this node', 'aether-proxy'), () => this.handleNode(nodes.value));
		const update = () => { button.disabled = !model.can_switch(nodes.value, current); };
		nodes.addEventListener('change', update);
		update();
		return E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [ nodes, button ]);
	},

	colorStyle: function(level) {
		const colors = {
			ok: 'var(--success-color-high, #2f855a)',
			warn: 'var(--warning-color, #b7791f)',
			error: 'var(--error-color-high, #c53030)'
		};
		return colors[level] ? 'color:' + colors[level] : '';
	},

	section: function(title, children) {
		return E('div', { 'class': 'cbi-section' }, [ E('h3', {}, title), ...children ]);
	},

	trafficSection: function(traffic) {
		const rows = [ E('tr', {}, [
			E('th', {}, ''), E('th', {}, _('Upload', 'aether-proxy')), E('th', {}, _('Download', 'aether-proxy'))
		]) ];
		for (const [key, title] of [
			[ 'proxy', _('Proxy', 'aether-proxy') ],
			[ 'direct', _('Direct', 'aether-proxy') ],
			[ 'total', _('Total', 'aether-proxy') ]
		])
			rows.push(E('tr', {}, [
				E('td', {}, title), E('td', {}, traffic[key].tx), E('td', {}, traffic[key].rx)
			]));
		return this.section(_('Traffic and connections', 'aether-proxy'), [
			E('table', { 'class': 'table' }, rows),
			E('div', { 'style': 'display:flex; align-items:center; gap:1em; flex-wrap:wrap' }, [
				E('span', {}, [ _('Proxy connections', 'aether-proxy'), ' ', traffic.connections.proxy ]),
				E('span', {
					title: _('Total connections in the system connection tracking table (conntrack).', 'aether-proxy')
				}, [ _('Total connections', 'aether-proxy'), ' ', traffic.connections.total ])
			])
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

		return E('table', { 'class': 'table', 'style': 'font-size: 0.9em' }, rows);
	},

	/* ap.call settles failures too; an explicit null distinguishes failure from
	   the initial pending state. Updating this container leaves controls intact. */
	loadComponents: function() {
		this.componentRequest ??= Promise.resolve().then(() => ap.call('components')).then((reply) => {
			this.components = reply ?? null;
			this.vm.components = model.component_rows(this.version, this.components);
			dom.content(this.componentContent, this.componentTable(this.vm.components));
		});
		return this.componentRequest;
	},

	render: function(data) {
		this.version = data[1];
		this.labels = data[2].labels;
		this.currentNode = data[2].node;
		this.enabled = data[2].enabled;

		this.content = E('div', {});

		this.refresh(data[0].reply, data[0].stats);
		const interval = this.readInterval();

		const root = E('div', { 'class': 'cbi-map' }, [
			this.titleLine(interval),
			this.content
		]);

		this.startPolling(interval);
		this.loadComponents();

		return root;
	},

	refresh: function(status, stats) {
		const vm = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000),
			this.enabled, this.currentNode, this.components);

		/* Keep the latest model output so handleService can use its
		   stop_confirmation without rebuilding the model. */
		this.vm = vm;

		const traffic = model.traffic(this.previousStats, stats);
		this.previousStats = stats;
		/* Reuse controls when moving them into fresh sections: polling must not
		   reset an edited selection, the enable switch or an in-flight probe. */
		this.enableControl ??= this.enableSwitch(vm.enabled_note);
		/* Keep edits across ordinary polls, but rebase the suffix and switch
		   guard if the effective runtime node changes. */
		if (!this.nodeControl || this.controlNode !== vm.current_node) {
			this.nodeControl = vm.node_options.length ? this.nodeControls(vm) : null;
			this.controlNode = vm.current_node;
		}
		this.probeControl ??= this.probeControls();
		this.componentContent ??= E('div', {}, [ this.componentTable(vm.components) ]);

		const parts = [];
		const notices = [];
		if (vm.error)
			notices.push(E('div', { 'class': 'alert-message error' }, vm.error));
		if (vm.disabled_notice)
			notices.push(E('div', { 'class': 'alert-message warning' }, vm.disabled_notice));
		if (vm.notices.length)
			notices.push(E('ul', {}, vm.notices.map((text) =>
				E('li', { 'class': 'alert-message warning' }, text))));
		if (notices.length)
			parts.push(this.section(_('Pending notices', 'aether-proxy'), notices));

		const stateRows = [ E('div', {
			style: 'display:flex; align-items:center; justify-content:space-between; gap:1em; flex-wrap:wrap'
		}, [
			E('div', {}, [
				E('strong', { style: 'font-size: 1.6em;' + this.colorStyle(vm.state_level) }, vm.state_text ?? '–'),
				' ', E('span', {}, vm.state_duration_text ?? ''), ' ',
				...(vm.dns_failsafe ? [ E('span', { style: this.colorStyle('warn') },
					_('DNS has fallen back to the original upstream configuration.', 'aether-proxy')) ] : [])
			]),
			this.enableControl
		]) ];
		/* Label and value go through one msgid: concatenating ': ' here gave the
		   Chinese page a half-width colon (and a stray space after 「：」). */
		if (vm.error_text != null)
			stateRows.push(E('div', { style: this.colorStyle('error') },
				_('Reason: %s', 'aether-proxy').replace('%s', vm.error_text)));
		if (vm.dns_text != null)
			stateRows.push(E('p', {},
				_('Overseas domain resolution: %s', 'aether-proxy').replace('%s', vm.dns_text)));
		stateRows.push(this.buttonBar(vm.buttons));
		parts.push(this.section(_('Status', 'aether-proxy'), stateRows));

		parts.push(this.section(_('Current node', 'aether-proxy'), [
			this.nodeControl ?? E('p', {}, vm.node_text),
			E('div', { style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
				...(vm.node_address_text ? [ E('span', {}, vm.node_address_text) ] : []),
				E('span', { style: this.colorStyle(vm.probe_level) }, vm.probe_text ?? '–'),
				E('small', {}, vm.probe_since_text ?? ''), this.probeControl
			])
		]));
		parts.push(this.trafficSection(traffic));
		parts.push(this.section(_('Component versions', 'aether-proxy'), [ this.componentContent ]));

		dom.content(this.content, E('div', {}, parts));

		return vm;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
