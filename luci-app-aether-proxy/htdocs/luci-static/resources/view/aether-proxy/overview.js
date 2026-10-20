'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.overview as model';

/*
 * Overview view (docs/10 「概览页」「Dashboard：概览页升级」「概览页第五轮修正」).
 * Dashboard controls keep DOM state across refreshes; the model calculates
 * rates and completion messages, while this view owns requests and timers.
 *
 * The view only fetches data through ap, hands it to the pure model and renders
 * the view model the model returns: state wording, notice texts, button
 * availability and the stop confirmation are all decided there. status is
 * refreshed at the selected interval via ap.poll; version and the UCI node labels plus
 * main.enabled are read at load; installed components are read once after rendering
 * and update only their table, without delaying the first screen (docs/10 T10.5).
 * Failed inventory calls can be explicitly retried without reloading the page (T10.13).
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
		]).then((data) => this.switchEvents(data[0].reply, data[2].node).then((events) => {
			data[0].events = events;
			return data;
		}));
	},

	/* Only mismatched runtime/configured nodes need diagnostic events. ap.call
	   settles RPC failures; the model treats those as a switch still in progress. */
	switchEvents: function(status, configured_node) {
		if (!model.switch_pending(status, configured_node))
			return Promise.resolve(null);
		return ap.call('events', { since: Math.floor(Date.now() / 1000) - 600, level: 'error' });
	},

	/* Toggle handler for the enable switch: stage the UCI value and go through
	   LuCI's standard save & apply with rollback confirmation, exactly like the
	   node page's 「设为当前」 (docs/10 「节点页」). No `service` call is made:
	   the reload trigger starts or stops the service. */
	handleEnable: async function(checked) {
		/* Disabling is persistent and immediately stops traffic interception;
		   cancelling must leave both the local setting and UCI untouched. */
		if (this.enabled && !checked && !await ap.confirm({
			title: _('Turn off Enable', 'aether-proxy'),
			text: this.vm.disable_confirmation,
			ok: _('Disable', 'aether-proxy'),
			destructive: true
		}))
			return;

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
					await self.handleEnable(ev.target.checked);
					/* Restore the browser's toggled checkbox after an async cancellation. */
					ev.target.checked = self.enabled;
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
			return ap.call('stats').then((stats) => {
				return this.switchEvents(reply, this.currentNode).then((events) => {
					this.refresh(reply, stats, events);
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
		this.poller = interval ? ap.poll(() => this.fetchRefresh(), interval) : null;
	},

	handleNode: function(node) {
		uci.set('aetherproxy', 'main', 'node', node);
		return uci.save().then(function() { return ui.changes.apply(true); });
	},

	handleProbe: function() {
		const button = this.probeButton;
		button.disabled = true;
		dom.content(this.probeMessage, _('Measuring latency…', 'aether-proxy'));
		return ap.call('probe_now').then((reply) => {
			if (!reply.ok)
				return { text: model.probe_result(reply) };
			/* The deadline also covers a slow status RPC. Late replies must not
			   start another poll or overwrite the displayed timeout. */
			return new Promise((resolve) => {
				let finished = false, next;
				const finish = (completion) => {
					if (finished)
						return;
					finished = true;
					window.clearTimeout(deadline);
					window.clearTimeout(next);
					resolve(completion);
				};
				const deadline = window.setTimeout(() => {
					finish({ text: model.probe_result({ code: 'TIMEOUT' }) });
				}, 15000);
				const poll = () => ap.call('status').then((status) => {
					if (finished)
						return;
					const completion = model.probe_completion(status, reply.requested_at);
					if (completion.done)
						finish(completion);
					else
						next = window.setTimeout(poll, 1000);
				});
				next = window.setTimeout(poll, 1000);
			});
		}).then((completion) => {
			dom.content(this.probeMessage, completion.text);
			/* A normal poll may still carry an older status. Finish it first so
			   the health item is populated by a new read even with auto-refresh off. */
			if (completion.refresh)
				return Promise.resolve(this.refreshing).then(() => this.fetchRefresh());
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
		this.probeButton = this.button(_('Measure latency', 'aether-proxy'), () => this.handleProbe());
		this.probeMessage = E('span', { 'aria-live': 'polite' });
		return E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
			this.probeButton, this.probeMessage
		]);
	},

	nodeControls: function(vm) {
		const current = vm.current_node;
		/* Themes size select at 100% (proton2025); inside a flex row that pushes the
		   button to the next line (docs/10 「样式」). */
		const nodes = E('select', { style: 'width:auto' }, vm.node_options.map((option) => E('option', {
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
		if (model.components_failed(this.components))
			children.push(E('button', {
				'class': 'cbi-button cbi-button-action',
				click: ui.createHandlerFn(this, this.loadComponents)
			}, _('Retry', 'aether-proxy')));
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
		this.version = data[1];
		this.labels = data[2].labels;
		this.currentNode = data[2].node;
		this.enabled = data[2].enabled;

		this.content = E('div', {});

		this.refresh(data[0].reply, data[0].stats, data[0].events);
		const interval = this.readInterval();

		const root = E('div', { 'class': 'cbi-map' }, [
			this.titleLine(interval),
			this.content
		]);

		this.startPolling(interval);
		this.loadComponents();

		return root;
	},

	refresh: function(status, stats, events) {
		const vm = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000),
			this.enabled, this.currentNode, this.components, events);

		/* Keep confirmations from the latest model output for both controls. */
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
		if (vm.switch_notice)
			notices.push(E('div', { 'class': 'alert-message warning' }, vm.switch_notice));
		parts.push(...notices);

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
		parts.push(this.section(_('Runtime status', 'aether-proxy'), stateRows));
		parts.push(this.trafficSection(traffic, vm.traffic_note));
		parts.push(this.section(_('Component versions', 'aether-proxy'), [ this.componentContent ]));

		dom.content(this.content, E('div', {}, parts));

		return vm;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
