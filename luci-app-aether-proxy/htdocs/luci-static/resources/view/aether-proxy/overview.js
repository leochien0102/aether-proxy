'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.overview as model';

/*
 * Overview view (docs/10 「概览页」「Dashboard：概览页升级」「其余页面先出页面」).
 * Dashboard controls keep DOM state across refreshes; the model calculates
 * rates and result messages, while this view owns requests and timers.
 * Real latency and direct node switching follow docs/10 「检测真实延迟与切换节点」.
 *
 * The view only fetches data through ap, hands it to the pure model and renders
 * the view model the model returns: state wording, notice texts, button
 * availability and the stop confirmation are all decided there. status is
 * refreshed at the selected interval via ap.poll. Only UCI is read at load;
 * status, stats, version and installed components fill their own regions after
 * rendering, without delaying the first screen (docs/10 T10.17).
 * Before disabling, warn about other staged session changes (docs/10 T10.22).
 * Failed inventory calls can be explicitly retried without reloading the page (T10.13).
 * Error summaries stay brief; raw diagnostics use tooltips or collapsed details (docs/10 T10.20).
 *
 * The 「启用」 switch never calls the `service` rpcd method: the init script
 * registers a reload trigger for the aetherproxy config, so saving the UCI
 * change starts the service when the switch is turned on and stops it when the
 * switch is turned off (docs/04 「重载」).
 */

return view.extend({
	load: function() {
		return uci.load('aetherproxy').then(function() {
			const labels = {};
			uci.sections('aetherproxy', 'node', function(s) {
				labels[s['.name']] = s.label || s['.name'];
			});
			/* An unset enabled option means 0, the schema default. */
			return {
				labels: labels,
				node: uci.get('aetherproxy', 'main', 'node'),
				enabled: uci.get('aetherproxy', 'main', 'enabled') === '1'
			};
		});
	},

	/* Only mismatched runtime/configured nodes need diagnostic events. ap.call
	   settles RPC failures; the model treats those as a switch still in progress. */
	switchEvents: function(status, configured_node) {
		if (!model.switch_pending(status, configured_node))
			return Promise.resolve(null);
		return ap.call('events', { since: Math.floor(Date.now() / 1000) - 600, level: 'error' });
	},

	/* Toggle handler for the enable switch: stage the UCI value and go through
	   LuCI's standard save & apply with rollback confirmation. No `service` call is made:
	   the reload trigger starts or stops the service. */
	handleEnable: async function(checked) {
		/* Disabling is persistent and immediately stops traffic interception;
		   cancelling must leave both the local setting and UCI untouched. */
		if (this.enabled && !checked) {
			/* A failed changes read must never apply an unread session; say so
			   instead of failing silently (design lead, T10.22 TODO, 2026-10-21). */
			let changes;
			try {
				changes = await uci.changes();
			}
			catch (e) {
				ui.addNotification(null, E('p', {},
					_('Reading unapplied changes failed, so Enable was not turned off: %s', 'aether-proxy')
						.replace('%s', e?.message ?? String(e))), 'error');
				return;
			}
			const staged = model.staged_confirmation(changes);
			if (staged && !await ap.confirm(staged))
				return;
			if (!await ap.confirm({
				title: _('Turn off Enable', 'aether-proxy'),
				text: this.vm.disable_confirmation,
				ok: _('Disable', 'aether-proxy'),
				destructive: true
			}))
				return;
		}

		this.enabled = (checked === true);

		uci.set('aetherproxy', 'main', 'enabled', this.enabled ? '1' : '0');

		return uci.save().then(function() {
			return ui.changes.apply(true);
		});
	},

	enableSwitch: function(note) {
		const self = this;

		/* The explanation is a tooltip now, not a visible line (docs/10 T10.9). */
		return E('label', { 'title': note, 'style': 'display:flex; align-items:center; gap:0.5em' }, [
			_('Enable', 'aether-proxy'),
			E('input', {
				'type': 'checkbox',
				'id': 'aetherproxy-enabled',
				'title': note,
				'checked': this.enabled ? 'checked' : null,
				'change': ui.createHandlerFn(this, async function(ev) {
					try {
						await self.handleEnable(ev.target.checked);
					}
					finally {
						/* Restore after cancellation or a failed staged-changes read. */
						ev.target.checked = self.enabled;
					}
				})
			})
		]);
	},

	handleService: async function(action) {
		const self = this;

		/* The wording comes from the model so it stays in one place (docs/10
		   「启用开关」). */
		if (action == 'stop' && !await ap.confirm({
			title: _('Stop service', 'aether-proxy'),
			text: this.vm.stop_confirmation,
			ok: _('Stop', 'aether-proxy'),
			destructive: true
		}))
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
			/* A slow stats/events read must not hold the runtime controls hostage.
			   Even a failed first status starts the normal retry cadence. */
			this.status = reply ?? null;
			this.refresh(this.status);
			if (this.initialReading) {
				this.initialReading = false;
				this.startPolling(this.interval);
			}
			return ap.call('stats').then((stats) => {
				this.updateTraffic(stats);
				return this.switchEvents(reply, this.currentNode).then((events) => {
					this.vm.switch_notice = model.build(reply, this.version, this.labels,
						Math.floor(Date.now() / 1000), this.enabled, this.currentNode,
						this.components, events).switch_notice;
					this.updateNotices();
				});
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
		this.interval = interval;
		this.poller = !this.initialReading && interval ? ap.poll(() => this.fetchRefresh(), interval) : null;
	},

	handleNode: async function(node) {
		if (this.switching)
			return;
		this.switching = true;
		this.updateNodeButton?.();
		try {
			const reply = await ap.call('node_use', { id: node });
			if (reply.ok) {
				await uci.unload('aetherproxy');
				const data = await this.load();
				this.currentNode = data.node;
				this.labels = data.labels;
				this.enabled = data.enabled;
				/* An older in-flight read cannot stand in for the post-switch status. */
				await this.refreshing;
				await this.fetchRefresh();
			}
			const text = model.node_use_message(reply, this.status);
			if (text)
				ui.addNotification(null, E('p', {}, text), reply.ok ? 'info' : 'error');
		}
		catch (e) {
			/* ap.call never rejects, so reaching here means node_use already
			   succeeded and only the page refresh failed: never call it a failed
			   switch (design lead, T10.23 TODO, 2026-10-21). No write is retried. */
			ui.addNotification(null, E('p', {},
				_('The node was switched, but refreshing the page data failed: %s. Reload the page.', 'aether-proxy')
					.replace('%s', e?.message ?? String(e))), 'warning');
		}
		finally {
			this.switching = false;
			this.updateNodeButton?.();
		}
	},

	handleProbe: function() {
		if (this.probing || this.probeButton.disabled)
			return;
		const site = this.probeSites.value;
		const label = this.siteOptions.find(option => option.value === site).text;
		this.probing = true;
		this.updateProbeButton();
		dom.content(this.probeButton, _('Measuring latency…', 'aether-proxy'));
		dom.content(this.probeMessage, '');
		/* This one-shot request must not poll or overwrite monitor health. */
		return ap.call('probe_url', { site: site }).then((reply) => {
			dom.content(this.probeMessage, model.probe_result(reply, label));
		}).finally(() => {
			this.probing = false;
			dom.content(this.probeButton, _('Test real latency', 'aether-proxy'));
			this.updateProbeButton();
		});
	},

	updateProbeButton: function() {
		this.probeButton.disabled = !this.siteOptions?.length || this.vm?.probe_disabled !== false || !!this.probing;
	},

	loadProbeSites: function() {
		return ap.call('probe_sites').then((reply) => {
			const sites = model.probe_sites(reply);
			this.siteOptions = sites.options;
			dom.content(this.probeSites, sites.options.map((option, index) => E('option', {
				value: option.value, selected: index === 0 ? 'selected' : null
			}, option.text)));
			if (sites.options.length)
				this.probeSites.value = sites.options[0].value;
			this.probeSites.disabled = !sites.options.length;
			dom.content(this.probeMessage, sites.error ?? '');
			this.updateProbeButton();
		});
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
			E('div', { style: 'display:flex; align-items:center; gap:1em; flex-wrap:wrap' }, [
				E('h2', {}, _('Aether Proxy', 'aether-proxy')), this.enableControl
			]),
			E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
				E('label', { style: 'display:flex; align-items:center; gap:0.5em' }, [
					E('span', { style: 'white-space: nowrap' }, _('Automatic refresh', 'aether-proxy')), select
				]),
				this.button(_('Refresh', 'aether-proxy'), () => this.fetchRefresh())
			])
		]);
	},

	probeControls: function() {
		this.probeSites = E('select', { disabled: true, style: 'width:auto',
			'aria-label': _('Probe site', 'aether-proxy') });
		/* Own the disabled state: createHandlerFn unconditionally enables on completion. */
		this.probeButton = E('button', {
			'class': 'cbi-button cbi-button-apply', click: () => this.handleProbe()
		}, _('Test real latency', 'aether-proxy'));
		this.probeButton.disabled = true;
		this.probeMessage = E('span', { 'aria-live': 'polite' });
		return E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
			this.probeSites, this.probeButton, this.probeMessage
		]);
	},

	nodeControls: function(vm) {
		const current = vm.current_node;
		/* Themes size select at 100% (proton2025); inside a flex row that pushes the
		   button to the next line (docs/10 「样式」). */
		const nodes = E('select', { style: 'width:auto' }, vm.node_options.map((option) => E('option', {
			value: option.value, selected: option.value === current ? 'selected' : null
		}, option.text)));
		const button = E('button', {
			'class': 'cbi-button cbi-button-apply', click: () => this.handleNode(nodes.value)
		}, _('Use this node', 'aether-proxy'));
		const update = this.updateNodeButton = () => {
			button.disabled = !!this.switching || !model.can_switch(nodes.value, current);
		};
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

	trafficSection: function(traffic, note) {
		const rows = [ E('tr', {}, [
			E('th', {}, ''), E('th', {}, _('Upload', 'aether-proxy')), E('th', {}, _('Download', 'aether-proxy'))
		]) ];
		for (const [key, title] of [
			[ 'proxy', _('Proxy', 'aether-proxy') ],
			[ 'direct', _('Direct', 'aether-proxy') ],
			[ 'total', traffic.total_label ]
		])
			rows.push(E('tr', {}, [
				/* The inactive note sits under the WAN label: it explains why only
				   this row has rates (owner's choice, 2026-10-20). */
				E('td', { title: key === 'total' ? traffic.total_title : null },
					key === 'total' && note ? [ title, E('br'), E('small', {}, note) ] : title),
				E('td', {}, traffic[key].tx), E('td', {}, traffic[key].rx)
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

	updateComponents: function() {
		this.vm.components = model.component_rows(this.version, this.components);
		const children = [ this.componentTable(this.vm.components) ];
		const error = model.component_error(this.components);
		if (error)
			children.push(E('div', {
				title: error.detail,
				style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap'
			}, [
				E('span', {}, error.text),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					click: ui.createHandlerFn(this, this.loadComponents)
				}, _('Retry', 'aether-proxy'))
			]));
		dom.content(this.componentContent, children);
	},

	/* Only explicit retries reissue inventory calls; ordinary status polls never
	   do. Reset cells synchronously, and share an in-flight request on repeated clicks. */
	loadComponents: function() {
		if (this.componentRequest)
			return this.componentRequest;
		this.components = undefined;
		this.updateComponents();
		this.componentRequest = Promise.resolve().then(() => ap.call('components')).then((reply) => {
			this.components = reply ?? null;
			this.updateComponents();
		}).finally(() => { this.componentRequest = null; });
		return this.componentRequest;
	},

	render: function(data) {
		this.labels = data.labels;
		this.currentNode = data.node;
		this.enabled = data.enabled;
		this.initialReading = true;

		this.content = E('div', {});

		this.refresh(undefined);
		const interval = this.readInterval();

		const root = E('div', { 'class': 'cbi-map' }, [
			this.titleLine(interval),
			this.content
		]);

		this.interval = interval;
		/* Microtasks run after render returns its complete, UCI-backed skeleton.
		   Enqueue requests in page order; common.js owns the concurrency limit. */
		this.initialRequest = Promise.resolve().then(() => this.fetchRefresh());
		this.versionRequest = Promise.resolve().then(() => ap.call('version')).then((reply) => {
			this.version = reply ?? null;
			this.updateComponents();
		});
		this.loadComponents();
		this.sitesRequest = Promise.resolve().then(() => this.loadProbeSites());

		return root;
	},

	refresh: function(status, stats, events) {
		const vm = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000),
			this.enabled, this.currentNode, this.components, events);

		/* Keep confirmations from the latest model output for both controls. */
		this.vm = vm;

		this.probeControl ??= this.probeControls();
		this.updateProbeButton();
		/* Reuse controls when moving them into fresh sections: polling must not
		   reset an edited selection, the enable switch or an in-flight probe. */
		this.enableControl ??= this.enableSwitch(vm.enabled_note);
		/* Keep edits across ordinary polls, but rebase the suffix and switch
		   guard if the effective runtime node changes. */
		if (!this.nodeControl || this.controlNode !== vm.current_node) {
			this.nodeControl = vm.node_options.length ? this.nodeControls(vm) : null;
			this.controlNode = vm.current_node;
		}
		this.componentContent ??= E('div', {}, [ this.componentTable(vm.components) ]);
		this.componentSection ??= this.section(_('Component versions', 'aether-proxy'), [ this.componentContent ]);
		if (!this.noticeContent) {
			this.noticeContent = E('div', {});
			this.runtimeContent = E('div', {});
			this.trafficContainer = E('div', {});
			dom.content(this.content, [
				this.noticeContent, this.runtimeContent, this.trafficContainer, this.componentSection
			]);
		}

		const stateRows = [ E('div', {
			style: 'display:flex; align-items:center; justify-content:space-between; gap:1em; flex-wrap:wrap'
		}, [
			E('div', {}, [
				E('strong', { style: 'font-size: 1.6em;' + this.colorStyle(vm.state_level) }, vm.state_text ?? '–'),
				' ', E('span', {}, vm.state_duration_text ?? ''), ' ',
				...(vm.dns_failsafe ? [ E('span', { style: this.colorStyle('warn') },
					_('DNS has fallen back to the original upstream configuration.', 'aether-proxy')) ] : [])
			]),
			this.buttonBar(vm.buttons)
		]) ];
		const details = [];
		/* Label and value go through one msgid: concatenating ': ' here gave the
		   Chinese page a half-width colon (and a stray space after 「：」). */
		if (vm.error_text != null)
			details.push(E('div', { style: this.colorStyle('error') },
				_('Reason: %s', 'aether-proxy').replace('%s', vm.error_text)));
		if (vm.dns_text != null)
			details.push(E('p', {},
				_('Overseas domain resolution: %s', 'aether-proxy').replace('%s', vm.dns_text)));
		if (details.length)
			stateRows.push(E('div', {}, details));

		stateRows.push(E('div', {
			style: 'display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:0.5em 1em'
		}, [
			this.nodeControl ?? E('p', {}, vm.node_text),
			E('div', { style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
				...(vm.node_address_text ? [ E('span', {}, vm.node_address_text) ] : []),
				E('span', { style: this.colorStyle(vm.probe_level) }, vm.probe_text ?? '–'),
				E('small', {}, vm.probe_since_text ?? ''), this.probeControl
			])
		]));
		dom.content(this.runtimeContent, this.section(_('Runtime status', 'aether-proxy'), stateRows));
		/* Status may change the WAN explanation, but it must not consume a
			second counter sample or replace the independent component table. */
		if (stats !== undefined || !this.traffic)
			this.updateTraffic(stats);
		else
			dom.content(this.trafficContainer, this.trafficSection(this.traffic, vm.traffic_note));
		this.updateNotices();

		return vm;
	},

	updateTraffic: function(stats) {
		this.traffic = model.traffic(this.previousStats, stats);
		this.previousStats = stats;
		dom.content(this.trafficContainer, this.trafficSection(this.traffic, this.vm.traffic_note));
	},

	/* Each late reply writes only its own region; diagnostics cannot recreate
	   runtime controls or move an edited selection out of the live document. */
	updateNotices: function() {
		const vm = this.vm;
		const parts = [];
		if (vm.error)
			parts.push(E('div', { 'class': 'alert-message error' }, [
				vm.error,
				...(vm.error_detail ? [ E('details', {}, [
					E('summary', {}, _('Details', 'aether-proxy')),
					E('pre', {}, vm.error_detail)
				]) ] : [])
			]));
		if (vm.disabled_notice)
			parts.push(E('div', { 'class': 'alert-message warning' }, vm.disabled_notice));
		if (vm.notices.length)
			parts.push(E('ul', {}, vm.notices.map((text) =>
				E('li', { 'class': 'alert-message warning' }, text))));
		if (vm.switch_notice)
			parts.push(E('div', { 'class': 'alert-message warning' }, vm.switch_notice));
		dom.content(this.noticeContent, parts);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
