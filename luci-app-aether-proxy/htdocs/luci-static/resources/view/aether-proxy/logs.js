'use strict';
'require view';
'require uci';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.logs as model';

/* Log-page controller (docs/10 「日志页」). Only events are polled; raw logs
 * can be large and are fetched on demand. All untrusted content is text.
 * T16.13 keeps destructive actions persistent at the right of the shared tab row.
 * T10.39 reads name maps from the already loaded UCI; hover keeps original IDs.
 * Block action rows follow docs/10 "UI 规则" (T10.27); the wrapping filter row
 * follows "r16 修正：日志页筛选行与事件文字" (T10.56).
 */
return view.extend({
	load: function() {
		return ap.load_config();
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
		const request = this.eventsRequest = (this.eventsRequest ?? 0) + 1;
		return ap.call('events', {}).then(res => {
			// Tabs and polling can fetch while the first deferred read is in flight.
			if (request == this.eventsRequest)
				this.showEvents(res);
		});
	},

	showEvents: function(res) {
		this.eventsReply = res;
		const vm = model.events(res, this.lastEvents, this.level.value, this.code.value, this.names);
		this.lastEvents = vm.data;
		this.level.disabled = this.code.disabled = vm.filters_disabled;
		const selected = this.code.value;
		dom.content(this.code, [ E('option', { value: '' }, _('All', 'aether-proxy')) ].concat(
			vm.codes.map(code => E('option', { value: code }, [ code ]))));
		this.code.value = vm.codes.indexOf(selected) >= 0 ? selected : '';
		if (vm.loading) {
			dom.content(this.eventContent, vm.loading);
			return;
		}
		const parts = [];
		if (vm.error)
			parts.push(E('p', { 'class': 'alert-message error' }, [ vm.error ]));
		if (vm.skipped)
			parts.push(E('p', { 'class': 'alert-message warning' }, [ vm.skipped ]));
		parts.push(E('table', { 'class': 'table' }, [
			E('tr', {}, [ _('Time', 'aether-proxy'), _('Level', 'aether-proxy'), _('Event code', 'aether-proxy'), _('Description', 'aether-proxy') ].map(t => E('th', {}, t)))
		].concat(vm.rows.map(row => E('tr', { title: row.title }, [
			E('td', {}, [ row.time ]),
			E('td', {}, E('span', { 'class': row.class_name }, [ row.level ])),
			E('td', {}, [ row.code ]),
			/* Event parameters (node and subscription names) are user input. */
			E('td', {}, [ row.text ])
		])))));
		dom.content(this.eventContent, parts);
	},

	fetchLog: function() {
		const request = this.rawRequest = (this.rawRequest ?? 0) + 1;
		return ap.call('log', model.log_params(this.source.value, this.lines.value)).then(res => {
			if (request != this.rawRequest)
				return;
			const vm = model.raw(res, uci.get('aetherproxy', 'main', 'log_level'));
			const parts = [];
			if (vm.hint)
				parts.push(E('p', { 'class': 'alert-message warning' }, [ vm.hint ]));
			if (vm.error)
				parts.push(E('p', { 'class': 'alert-message error' }, [ vm.error ]));
			/* Raw log lines are arbitrary device output: text node only. */
			parts.push(E('pre', {}, [ vm.text ]));
			dom.content(this.rawContent, parts);
		});
	},

	changeLogs: async function(truncate) {
		if (this.clearButton.disabled)
			return;
		this.clearButton.disabled = this.truncateButton.disabled = true;
		const title = truncate ? _('Truncate to last startup', 'aether-proxy') : _('Clear logs', 'aether-proxy');
		try {
			if (!await ap.confirm({
				title,
				text: truncate
					? _('Only logs (events and raw logs) since the most recent service startup will be kept. Earlier records will be deleted. This cannot be undone.', 'aether-proxy')
					: _('Only %s raw logs and event history will be cleared. System logs are not affected. This cannot be undone.',
						'aether-proxy').replace('%s', 'aether-proxy'),
				ok: title, destructive: true
			}))
				return;
			dom.content(this.toolbarError, []);
			const res = await ap.call(truncate ? 'log_truncate' : 'log_clear', {});
			if (!res?.ok)
				throw new Error([ res?.code, res?.detail ].filter(Boolean).join(': ')
					|| _('Unable to modify logs.', 'aether-proxy'));
			// Invalidate both tabs' pre-action reads so late replies cannot restore deleted records.
			this.rawRequest = (this.rawRequest ?? 0) + 1;
			this.eventsRequest = (this.eventsRequest ?? 0) + 1;
			this.lastEvents = null;
			await (this.tab == 'events' ? this.fetchEvents() : this.fetchLog());
		}
		catch (err) {
			const prefix = truncate
				? _('Unable to truncate logs:', 'aether-proxy') : _('Unable to clear logs:', 'aether-proxy');
			dom.content(this.toolbarError, E('p', { 'class': 'alert-message error' }, [ prefix + ' ' + err.message ]));
		}
		finally {
			this.clearButton.disabled = this.truncateButton.disabled = false;
		}
	},

	switchTab: function(tab) {
		this.tab = tab;
		for (const [id, item] of Object.entries(this.tabs)) {
			item.setAttribute('class', id == tab ? 'cbi-tab' : 'cbi-tab-disabled');
			item.setAttribute('aria-selected', String(id == tab));
		}
		this.eventPanel.hidden = tab != 'events';
		this.rawPanel.hidden = tab != 'raw';
		this.startPolling();
		return tab == 'raw' ? this.fetchLog() : this.fetchEvents();
	},

	render: function() {
		this.names = { nodes: Object.create(null), subscriptions: Object.create(null) };
		uci.sections('aetherproxy', 'node', s => {
			this.names.nodes[s['.name']] = s.label || s['.name'];
		});
		uci.sections('aetherproxy', 'subscription', s => {
			this.names.subscriptions[s['.name']] = s.name || s['.name'];
		});
		this.eventsRequest = 0;
		this.tab = 'events';
		this.auto = E('input', { type: 'checkbox', checked: true, change: () => this.startPolling() });
		const refilter = () => this.showEvents(this.eventsReply);
		this.level = E('select', { change: refilter, style: 'width:auto; max-width:100%' }, [
			[ '', _('All', 'aether-proxy') ], [ 'error', _('Error', 'aether-proxy') ],
			[ 'warn', _('Warning and above', 'aether-proxy') ], [ 'notice', _('Notice and above', 'aether-proxy') ]
		].map(pair => E('option', { value: pair[0] }, pair[1])));
		this.code = E('select', { change: refilter, style: 'width:auto; max-width:100%' });
		this.eventContent = E('div', {});
		this.eventPanel = E('div', {}, [
			E('div', {
				style: 'display:flex; align-items:center; justify-content:space-between; gap:1em; '
					+ 'flex-wrap:wrap; margin:0.5em 0 1em'
			}, [
				E('div', {
					style: 'display:flex; align-items:center; gap:1em; flex-wrap:wrap; max-width:100%'
				}, [
					E('label', {
						style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap; max-width:100%'
					}, [ E('span', { style: 'white-space:nowrap' }, _('Level', 'aether-proxy')), this.level ]),
					E('label', {
						style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap; max-width:100%'
					}, [ E('span', { style: 'white-space:nowrap' }, _('Event code', 'aether-proxy')), this.code ])
				]),
				E('label', { style: 'display:flex; align-items:center; gap:0.5em' }, [
					E('span', { style: 'white-space:nowrap' }, _('Automatic refresh', 'aether-proxy')), this.auto
				])
			]), this.eventContent
		]);
		const rowStyle = 'display:flex; align-items:center; gap:0.5em; '
			+ 'flex-wrap:wrap; margin:0.5em 0 1em';
		const groupStyle = 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap; max-width:100%';
		const selectStyle = 'width:auto; max-width:100%';
		this.source = E('select', { style: selectStyle }, model.sources().map(pair => E('option', { value: pair[0] }, pair[1])));
		this.lines = E('select', { style: selectStyle }, model.line_counts().map(n => E('option', { value: String(n) }, String(n))));
		this.lines.value = '200';
		this.rawContent = E('div', {});
		this.toolbarError = E('div', {});
		this.clearButton = E('button', {
			'class': 'cbi-button cbi-button-remove', click: () => this.changeLogs(false)
		}, _('Clear logs', 'aether-proxy'));
		this.truncateButton = E('button', {
			'class': 'cbi-button cbi-button-remove', click: () => this.changeLogs(true)
		}, _('Truncate to last startup', 'aether-proxy'));
		// Page-level controls stay mounted when either tab's data is refreshed.
		const tabItem = (id, label) => E('li', {
			'class': this.tab == id ? 'cbi-tab' : 'cbi-tab-disabled',
			role: 'tab', 'aria-selected': String(this.tab == id)
		}, E('a', {
			href: '#', click: ev => {
				ev.preventDefault();
				return this.switchTab(id);
			}
		}, label));
		this.tabs = {
			events: tabItem('events', _('Events', 'aether-proxy')),
			raw: tabItem('raw', _('Raw logs', 'aether-proxy'))
		};
		const tabs = E('ul', { 'class': 'cbi-tabmenu', role: 'tablist' }, Object.values(this.tabs));
		const actions = E('div', { style: groupStyle + '; margin-inline-start:auto' },
			[ this.clearButton, this.truncateButton ]);
		this.toolbar = ap.section_actions([actions], tabs);
		this.rawPanel = E('div', { hidden: true }, [
			E('div', { style: rowStyle + '; justify-content:space-between' }, [
				E('div', { style: groupStyle }, [
					E('label', { style: groupStyle }, [ E('span', {}, _('Source', 'aether-proxy')), this.source ]),
					E('label', { style: groupStyle }, [ E('span', {}, _('Lines', 'aether-proxy')), this.lines ])
				]),
				E('div', { style: groupStyle + '; justify-content:flex-end' }, [
					E('button', { 'class': 'cbi-button', click: () => this.fetchLog() }, _('Refresh', 'aether-proxy'))
				])
			]),
			this.rawContent
		]);
		this.showEvents();
		const root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Logs', 'aether-proxy')),
			ap.section({
				actions: this.toolbar, stacked: true,
				body: [this.toolbarError, this.eventPanel, this.rawPanel]
			})
		]);
		/* Give LuCI a turn to display the complete page before fetching events. */
		window.setTimeout(() => {
			this.fetchEvents();
			this.startPolling();
		}, 0);
		return root;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
