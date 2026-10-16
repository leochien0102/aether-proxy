'use strict';
'require view';
'require uci';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.logs as model';

/* Log-page controller (docs/10 「日志页」). Only events are polled; raw logs
 * can be large and are fetched on demand. All untrusted content is text.
 */
return view.extend({
	load: function() {
		return Promise.all([ ap.call('events', {}), uci.load('aetherproxy') ]);
	},

	stopPolling: function() {
		if (this.poller)
			this.poller.stop();
		this.poller = null;
	},

	startPolling: function() {
		this.stopPolling();
		if (this.tab == 'events' && this.auto.checked)
			this.poller = ap.poll(() => this.fetchEvents(), 5000);
	},

	fetchEvents: function() {
		return ap.call('events', {}).then(res => this.showEvents(res));
	},

	showEvents: function(res) {
		this.eventsReply = res;
		const vm = model.events(res, this.lastEvents, this.level.value, this.code.value);
		this.lastEvents = vm.data;
		const selected = this.code.value;
		dom.content(this.code, [ E('option', { value: '' }, _('All')) ].concat(
			vm.codes.map(code => E('option', { value: code }, code))));
		this.code.value = vm.codes.indexOf(selected) >= 0 ? selected : '';
		const parts = [];
		if (vm.error)
			parts.push(E('p', { 'class': 'alert-message error' }, vm.error));
		if (vm.skipped)
			parts.push(E('p', { 'class': 'alert-message warning' }, vm.skipped));
		parts.push(E('table', { 'class': 'table' }, [
			E('tr', {}, [ _('Time'), _('Level'), _('Event code'), _('Description') ].map(t => E('th', {}, t)))
		].concat(vm.rows.map(row => E('tr', { title: row.title }, [
			E('td', {}, row.time), E('td', {}, E('span', { 'class': row.class_name }, row.level)),
			E('td', {}, row.code), E('td', {}, row.text)
		])))));
		dom.content(this.eventContent, parts);
	},

	fetchLog: function() {
		return ap.call('log', model.log_params(this.source.value, this.lines.value)).then(res => {
			const vm = model.raw(res, uci.get('aetherproxy', 'main', 'log_level'));
			const parts = [];
			if (vm.hint)
				parts.push(E('p', { 'class': 'alert-message warning' }, vm.hint));
			if (vm.error)
				parts.push(E('p', { 'class': 'alert-message error' }, vm.error));
			parts.push(E('pre', {}, vm.text));
			dom.content(this.rawContent, parts);
		});
	},

	switchTab: function(tab) {
		this.tab = tab;
		this.eventPanel.hidden = tab != 'events';
		this.rawPanel.hidden = tab != 'raw';
		this.startPolling();
		return tab == 'raw' ? this.fetchLog() : this.fetchEvents();
	},

	render: function(data) {
		this.tab = 'events';
		this.auto = E('input', { type: 'checkbox', checked: true, change: () => this.startPolling() });
		const refilter = () => this.showEvents(this.eventsReply);
		this.level = E('select', { change: refilter }, [
			[ '', _('All') ], [ 'error', _('Error') ],
			[ 'warn', _('Warning and above') ], [ 'notice', _('Notice and above') ]
		].map(pair => E('option', { value: pair[0] }, pair[1])));
		this.code = E('select', { change: refilter });
		this.eventContent = E('div', {});
		this.eventPanel = E('div', {}, [
			E('label', {}, [ this.auto, _('Automatic refresh') ]),
			E('label', {}, [ _('Level'), this.level ]),
			E('label', {}, [ _('Event code'), this.code ]), this.eventContent
		]);
		this.source = E('select', {}, model.sources().map(pair => E('option', { value: pair[0] }, pair[1])));
		this.lines = E('select', {}, model.line_counts().map(n => E('option', { value: String(n) }, String(n))));
		this.lines.value = '200';
		this.rawContent = E('div', {});
		this.rawPanel = E('div', { hidden: true }, [
			E('label', {}, [ _('Source'), this.source ]), E('label', {}, [ _('Lines'), this.lines ]),
			E('button', { 'class': 'cbi-button', click: () => this.fetchLog() }, _('Refresh')), this.rawContent
		]);
		this.showEvents(data[0]);
		this.startPolling();
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Logs')),
			E('button', { 'class': 'cbi-button', click: () => this.switchTab('events') }, _('Events')),
			E('button', { 'class': 'cbi-button', click: () => this.switchTab('raw') }, _('Raw logs')),
			this.eventPanel, this.rawPanel
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
