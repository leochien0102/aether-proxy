'use strict';
'require view';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.overview as model';

/*
 * Overview page (docs/10 「概览页」).
 *
 * The view only fetches data through ap, hands it to the pure model and renders
 * the view model the model returns: state wording, notice texts and button
 * availability are all decided there. status is refreshed every 5 seconds via
 * ap.poll; version and the UCI node labels are read once per page load.
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

				return labels;
			})
		]);
	},

	handleService: function(action) {
		const self = this;

		if (action == 'stop' && !confirm(_('Stopping aether-proxy leaves all traffic going out directly. Really stop the service?')))
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
				attrs.click = ui.createHandlerFn(fn);
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
		this.labels = data[2];

		const root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('aether-proxy')),
			E('div', { 'class': 'cbi-map-descr' }, _('Service status, pending notices and start/stop controls.'))
		]);

		this.content = E('div', {});
		root.appendChild(this.content);

		this.refresh(data[0]);

		this.poller = ap.poll(function() {
			return ap.call('status').then(function(status) {
				self.refresh(status);
			});
		}, 5000);

		return root;
	},

	refresh: function(status) {
		const vm = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000));
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

		dom.content(this.content, E('div', {}, parts));
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
