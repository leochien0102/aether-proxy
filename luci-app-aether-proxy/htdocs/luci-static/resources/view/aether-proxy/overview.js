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
 * T10.24 follows docs/10 「概览页第七轮修正」: restart-aware inventory,
 * manual health display, remembered/retryable sites and pending-switch guards.
 * T10.38 follows docs/10 「概览页：默认模式下拉」 for one-shot node/mode apply.
 * T10.48 synchronizes UCI on refresh, preserves unapplied selections and
 * distinguishes restart's stopping phase from the new process's startup.
 * T10.52 shares one event read between pending switches and startup failures.
 * T10.55 maps docs/10 r16's busy grade to blue and dims only stopped status.
 * T10.62 follows docs/10 r18: sites first, one timeout retry per inventory generation.
 * T10.65 follows docs/10 r19: gap-only runtime rows and a labeled empty latency.
 * T10.43 follows docs/10 「r13 修正：概览页启动反馈与节点下拉」: a bounded,
 * independent startup watcher, armed for Enable only after LuCI confirms apply.
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
				mode: uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn',
				enabled: uci.get('aetherproxy', 'main', 'enabled') === '1'
			};
		});
	},

	/* Startup retries are warn events, while switch diagnostics need only errors.
	   One cumulative warn request serves both when needed (docs/10 T10.52). */
	diagnosticEvents: function(status, configured_node, configured_mode) {
		const startup = model.startup_events_needed(status);
		if (!startup && !model.switch_pending(status, configured_node, configured_mode))
			return Promise.resolve(null);
		return ap.call('events', {
			since: Math.floor(Date.now() / 1000) - 600,
			level: startup ? 'warn' : 'error'
		});
	},

	/* Toggle handler for the enable switch: stage the UCI value and go through
	   LuCI's standard save & apply with rollback confirmation. No `service` call is made:
	   the reload trigger starts or stops the service. */
	handleEnable: async function(checked) {
		this.enabling = true;
		try {
			/* Finish an already-issued cache read before staging a local write. */
			if (this.configRequest)
				await this.configRequest;
			await this.saveEnable(checked);
		}
		finally {
			this.enabling = false;
		}
	},

	saveEnable: async function(checked) {
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

		this.clearEnableApply?.();
		await uci.save();
		/* apply() returns undefined, not a completion promise (LuCI ui.js).
		   Only uci-applied means the checked apply actually succeeded. */
		if (this.enabled)
			this.watchEnableApply();
		try {
			ui.changes.apply(true);
		}
		catch (e) {
			this.clearEnableApply?.();
			throw e;
		}
	},

	enableSwitch: function(note) {
		const self = this;

		this.enableInput = E('input', {
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
		});
		/* The explanation is a tooltip now, not a visible line (docs/10 T10.9). */
		return E('label', { 'title': note, 'style': 'display:flex; align-items:center; gap:0.5em' }, [
			_('Enable', 'aether-proxy'), this.enableInput
		]);
	},

	watchEnableApply: function() {
		const clear = this.clearEnableApply = () => {
			document.removeEventListener('uci-applied', applied);
			document.removeEventListener('uci-reverted', clear);
			window.removeEventListener('pagehide', clear);
			this.clearEnableApply = null;
		};
		const applied = () => {
			clear();
			this.beginStartup(true);
		};
		/* LuCI emits no apply-cancelled/apply-failed event: the intent stays
		   dormant until a successful apply, a new toggle, revert or page exit
		   (docs/10「r13 修正：概览页启动反馈与节点下拉」复审结论). */
		document.addEventListener('uci-applied', applied);
		document.addEventListener('uci-reverted', clear);
		window.addEventListener('pagehide', clear);
	},

	endStartup: function(phase) {
		if (this.startup) {
			this.startup.poller.stop();
			window.clearTimeout(this.startup.deadline);
			window.removeEventListener('pagehide', this.startup.cleanup);
		}
		this.startup = null;
		this.startupPhase = phase;
	},

	beginStartup: function(ready, action = 'start') {
		this.endStartup(action === 'restart' ? 'stopping' : 'waiting');
		const session = { ready, action, baseline: this.status?.since, reading: false };
		this.startup = session;
		session.cleanup = () => this.endStartup(null);
		window.addEventListener('pagehide', session.cleanup);
		/* This cadence ignores the user's automatic-refresh preference. The hard
		   deadline also releases controls when status itself is slow or fails. */
		session.poller = ap.poll(() => this.fetchStartup(session), 2000);
		session.deadline = window.setTimeout(() => {
			if (this.startup !== session)
				return;
			this.endStartup('timeout');
			this.refresh(this.status, undefined, this.latestEvents);
		}, 60000);
		this.refresh(this.status, undefined, this.latestEvents);
		return session;
	},

	fetchStartup: async function(session) {
		if (this.startup !== session || session.reading)
			return;
		session.reading = true;
		/* Poll immediately at the requested cadence, but a read issued before
		   service acknowledges restart may still describe the old process. */
		const ready = session.ready;
		const read = this.nextStatusRead();
		try {
			const reply = await ap.call('status');
			if (this.startup !== session || read < (this.acceptedRead ?? 0))
				return;
			this.advanceStartup(reply, ready);
			this.acceptStatus(reply, read);
		}
		finally {
			session.reading = false;
		}
	},

	advanceStartup: function(reply, ready) {
		if (!this.startup)
			return;
		const phase = model.startup_phase(reply, this.startup, ready);
		if (phase === null)
			this.endStartup(null);
		else {
			this.startup.phase = phase;
			this.startupPhase = phase;
		}
	},

	handleService: async function(action) {
		if (action !== 'stop' && this.startup)
			return;

		/* The wording comes from the model so it stays in one place (docs/10
		   「启用开关」). */
		if (action == 'stop' && !await ap.confirm({
			title: _('Stop service', 'aether-proxy'),
			text: this.vm.stop_confirmation,
			ok: _('Stop', 'aether-proxy'),
			destructive: true
		}))
			return;

		this.clearEnableApply?.();
		const session = action === 'stop' ? null : this.beginStartup(false, action);
		if (action === 'stop' && this.startupPhase) {
			this.endStartup(null);
			this.refresh(this.status, undefined, this.latestEvents);
		}
		const res = await ap.call('service', { action: action });
		if (res && res.ok === false) {
			if (this.startup === session) {
				this.endStartup(null);
				this.refresh(this.status, undefined, this.latestEvents);
			}
			ui.addNotification(null,
				E('p', {}, _('The service action failed: %s (%s).', 'aether-proxy')
					.replace('%s', res.code).replace('%s', res.detail ?? '')), 'error');
		}
		else if (this.startup === session && session)
			session.ready = true;
		/* Stop keeps the old one-shot refresh; start/restart have their own
		   status-only watcher and must not wait for stats or diagnostic events. */
		if (action === 'stop')
			window.setTimeout(() => this.fetchRefresh(), 1500);
	},

	buttonBar: function(buttons) {
		const self = this;

		const btn = (label, cls, enabled, fn) => {
			const attrs = { 'class': 'cbi-button ' + cls };

			/* The startup model owns disabled state; createHandlerFn would
			   unconditionally re-enable a completed action's button. */
			if (enabled)
				attrs.click = fn;
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

	nextStatusRead: function() {
		this.statusRead = (this.statusRead ?? 0) + 1;
		return this.statusRead;
	},

	/* A pre-action automatic read must not overwrite a newer startup result. */
	acceptStatus: function(reply, read) {
		if (read < (this.acceptedRead ?? 0))
			return false;
		this.acceptedRead = read;
		this.status = reply ?? null;
		const markers = model.status_markers(this.status);
		if (markers) {
			/* since has second precision. Activation can share the stopped stamp;
			   the inactive-to-active edge must also replace pre-start inventory. */
			const activated = this.lastMarkers && !this.lastActive && model.startup_complete(this.status);
			if (this.lastMarkers && (markers.since !== this.lastMarkers.since || activated)) {
				this.loadVersion(true);
				this.loadComponents(true);
			}
			this.lastMarkers = markers;
			this.lastActive = model.startup_complete(this.status);
		}
		if (this.startupPhase === 'timeout' && model.startup_complete(this.status))
			this.startupPhase = null;
		this.refresh(this.status, undefined, this.latestEvents);
		if (this.initialReading) {
			this.initialReading = false;
			this.startPolling(this.interval);
		}
		return true;
	},

	refreshConfig: function(read, was_switching) {
		/* A newly mismatched status can be an external change, not our pending
		   switch. Only an already-known, still-pending switch blocks the read. */
		if (this.enabling || this.switching || (was_switching && this.vm?.switch_busy))
			return Promise.resolve();
		/* unload is synchronous, and load alone would return the SDK's cache. */
		const request = Promise.resolve().then(() => {
			uci.unload('aetherproxy');
			return this.load();
		}).then((data) => {
			if (read !== this.acceptedRead || this.enabling || this.switching)
				return;
			const unchanged = this.currentNode === data.node && this.currentMode === data.mode
				&& this.enabled === data.enabled && JSON.stringify(this.labels) === JSON.stringify(data.labels);
			if (unchanged)
				return;
			this.labels = data.labels;
			this.currentNode = data.node;
			this.currentMode = data.mode;
			this.enabled = data.enabled;
			this.refresh(this.status, undefined, this.latestEvents);
		}).catch((e) => {
			/* A failed UCI read keeps the last complete snapshot and retries on
			   the next refresh (docs/10 r14 概览页复审结论). */
			console.warn('aether-proxy: reading overview configuration failed:', e);
		}).finally(() => {
			if (this.configRequest === request)
				this.configRequest = null;
		});
		this.configRequest = request;
		return request;
	},

	/* Manual refresh, service actions and replacement pollers share the same
	   promise: ap.poll alone cannot serialize these independent entry points. */
	fetchRefresh: function() {
		if (this.refreshing)
			return this.refreshing;
		const read = this.nextStatusRead();
		this.refreshing = ap.call('status').then((reply) => {
			const was_switching = this.vm?.switch_busy;
			/* Status controls update before the slower stats/events reads. */
			if (!this.acceptStatus(reply, read))
				return;
			return this.refreshConfig(read, was_switching).then(() => ap.call('stats')).then((stats) => {
				this.updateTraffic(stats);
				return this.diagnosticEvents(reply, this.currentNode, this.currentMode).then((events) => {
					if (read !== this.acceptedRead)
						return;
					const startup = model.startup_events_needed(reply);
					/* A switch floor excludes an earlier target's failure. Startup attempts
					   have their own START_RETRY boundaries and must keep same-second events. */
					if (!startup)
						events = model.newer_events(events, this.reasonFloor);
					this.latestEvents = events;
					/* Startup details live in the runtime block; switch diagnostics change only
					   the banner and guards so edited controls stay mounted. */
					if (startup) {
						this.refresh(reply, undefined, events);
						return;
					}
					const next = model.build(reply, this.version, this.labels,
						Math.floor(Date.now() / 1000), this.enabled, this.currentNode, this.components,
						events, this.manualProbe, this.currentMode);
					for (const key of ['switch_notice', 'switch_busy', 'switch_title'])
						this.vm[key] = next[key];
					this.updateNodeButton?.();
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

	handleNode: async function(node, mode) {
		if (this.switching || this.vm?.switch_busy)
			return;
		const request = model.switch_request(node, mode, this.vm?.current_node, this.vm?.current_mode);
		if (!request)
			return;
		this.switching = true;
		this.nodeEdited = false;
		this.modeEdited = false;
		this.updateNodeButton?.();
		try {
			if (this.configRequest)
				await this.configRequest;
			const reply = await ap.call(request.method, request.params);
			if (reply.ok) {
				uci.unload('aetherproxy');
				const data = await this.load();
				this.currentNode = data.node;
				this.currentMode = data.mode;
				this.labels = data.labels;
				this.enabled = data.enabled;
				/* A reason found for the previous target is not about this switch. */
				this.reasonFloor = model.switch_floor(this.latestEvents, this.reasonFloor);
				this.latestEvents = null;
				/* An older in-flight read cannot stand in for the post-switch status. */
				await this.refreshing;
				await this.fetchRefresh();
			}
			const text = model.node_use_message(reply, this.status, request.kind);
			if (text)
				ui.addNotification(null, E('p', {}, text), reply.ok ? 'info' : 'error');
		}
		catch (e) {
			/* ap.call never rejects, so reaching here means the write already
			   succeeded and only the page refresh failed: never call it a failed
			   switch (design lead, T10.23 TODO, 2026-10-21). No write is retried. */
			ui.addNotification(null, E('p', {},
				(request.kind === 'node'
					? _('The node was switched, but refreshing the page data failed: %s. Reload the page.',
						'aether-proxy')
					: _('Settings were switched, but refreshing the page data failed: %s. Reload the page.',
						'aether-proxy'))
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
		/* Display only: this one-shot result never writes monitor health or polls. */
		return ap.call('probe_url', { site: site }).then((reply) => {
			const result = model.manual_probe(reply, label, this.status, Math.floor(Date.now() / 1000));
			if (result) {
				this.manualProbe = result;
				this.refresh(this.status, undefined, this.latestEvents);
			}
			else
				ui.addNotification(null, E('p', {}, model.probe_error(reply)), 'error');
		}).finally(() => {
			this.probing = false;
			dom.content(this.probeButton, _('Test real latency', 'aether-proxy'));
			this.updateProbeButton();
		});
	},

	updateProbeButton: function() {
		this.probeButton.disabled = !this.siteOptions?.length || this.vm?.probe_disabled !== false || !!this.probing;
	},

	probeSitePlaceholder: function(text) {
		dom.content(this.probeSites, [ E('option', { disabled: true, selected: true }, text) ]);
		this.probeSites.disabled = true;
	},

	readProbeSite: function() {
		try {
			return window.localStorage.getItem('aether-proxy.probe-site');
		}
		catch (e) {
			console.warn('Unable to read probe site preference:', e);
			return null;
		}
	},

	saveProbeSite: function(value) {
		try {
			window.localStorage.setItem('aether-proxy.probe-site', value);
		}
		catch (e) {
			console.warn('Unable to save probe site preference:', e);
		}
	},

	loadProbeSites: function() {
		if (this.siteRequest)
			return this.siteRequest;
		this.siteOptions = [];
		this.probeSitePlaceholder(_('Reading…', 'aether-proxy'));
		dom.content(this.probeMessage, '');
		this.updateProbeButton();
		this.siteRequest = Promise.resolve().then(() => ap.call('probe_sites')).then((reply) => {
			const sites = model.probe_sites(reply);
			this.siteOptions = sites.options;
			if (sites.error) {
				this.probeSitePlaceholder(_('Reading failed', 'aether-proxy'));
				dom.content(this.probeMessage, [ E('span', {}, sites.error), E('button', {
					'class': 'cbi-button cbi-button-action', click: () => this.loadProbeSites()
				}, _('Retry', 'aether-proxy')) ]);
			}
			else {
				const saved = this.readProbeSite();
				const selected = sites.options.find(option => option.value === saved) ?? sites.options[0];
				dom.content(this.probeSites, sites.options.map((option) => E('option', {
					value: option.value, selected: option === selected ? 'selected' : null
				}, option.text)));
				this.probeSites.value = selected.value;
				this.probeSites.disabled = false;
			}
			this.updateProbeButton();
		}).finally(() => { this.siteRequest = null; });
		return this.siteRequest;
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
			'aria-label': _('Probe site', 'aether-proxy'),
			change: (ev) => this.saveProbeSite(ev.target.value) });
		this.probeSitePlaceholder(_('Reading…', 'aether-proxy'));
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

	nodeControls: function(vm, selected = {}) {
		const current = vm.current_node;
		/* Themes size select at 100% (proton2025). Keep the 16em minimum for long
		   labels, but clamp it to the row on screens narrower than 16em; CSS min
		   width otherwise wins over max-width and causes horizontal overflow. */
		const nodes = E('select', {
			style: 'width:auto; min-width:min(16em, 100%); max-width:24em'
		}, vm.node_options.map((option) => E('option', {
			value: option.value, selected: option.value === current ? 'selected' : null
		}, option.text)));
		const modes = E('select', { style: 'width:auto; min-width:0' },
			model.mode_options().map((option) => E('option', {
				value: option.value, selected: option.value === vm.current_mode ? 'selected' : null
			}, option.text)));
		/* Do not let the browser silently select its first mode when runtime mode is unknown. */
		modes.value = selected.mode ?? vm.current_mode ?? '';
		if (selected.node && vm.node_options.some(option => option.value === selected.node))
			nodes.value = selected.node;
		this.nodeSelect = nodes;
		this.modeSelect = modes;
		const button = E('button', {
			'class': 'cbi-button cbi-button-apply', click: () => this.handleNode(nodes.value, modes.value)
		}, _('Apply', 'aether-proxy'));
		const update = this.updateNodeButton = () => {
			const busy = !!this.switching || !!this.vm.switch_busy;
			nodes.disabled = busy;
			modes.disabled = busy || !vm.current_mode;
			button.disabled = busy || !model.switch_request(nodes.value, modes.value, current, vm.current_mode);
			nodes.title = this.vm.switch_title ?? this.labels[nodes.value] ?? nodes.value;
			for (const control of [modes, button])
				control.title = this.vm.switch_title ?? '';
		};
		const changed = () => {
			/* Only a user's change event marks an edit. A temporarily absent node
			   option may make the browser choose its first entry during refresh. */
			this.nodeEdited = nodes.value !== this.controlNode;
			this.modeEdited = modes.value !== this.controlMode;
			update();
		};
		nodes.addEventListener('change', changed);
		modes.addEventListener('change', changed);
		update();
		return E('div', {
			style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap; min-width:0; max-width:100%'
		}, [
			E('div', { style: 'display:flex; align-items:center; min-width:0; max-width:100%' }, [nodes]),
			E('div', { style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:nowrap; '
				+ 'white-space:nowrap; min-width:0; max-width:100%' }, [
				E('label', { style: 'display:flex; align-items:center; gap:0.5em; min-width:0' }, [
					_('Default mode', 'aether-proxy'), modes
				]), button
			])
		]);
	},

	colorStyle: function(level) {
		const colors = {
			ok: 'var(--success-color-high, #2f855a)',
			busy: 'var(--primary-color-high, #2b6cb0)',
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
				style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
					+ 'flex-wrap:wrap; margin:0.5em 0 1em'
			}, [
				E('span', {}, error.text),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					click: ui.createHandlerFn(this, this.loadComponents)
				}, _('Retry', 'aether-proxy'))
			]));
		dom.content(this.componentContent, children);
	},

	/* A restart invalidates even an in-flight pre-restart reply. Ordinary polls
	   share requests; generation identity prevents stale versions winning a race. */
	loadVersion: function(restarted) {
		if (this.versionRequest && !restarted)
			return this.versionRequest;
		this.version = undefined;
		this.updateComponents();
		const request = Promise.resolve().then(() => ap.call('version')).then((reply) => {
			if (this.versionRequest === request) {
				this.version = reply ?? null;
				this.updateComponents();
			}
		}).finally(() => {
			if (this.versionRequest === request)
				this.versionRequest = null;
		});
		this.versionRequest = request;
		return request;
	},

	loadComponents: function(restarted) {
		/* createHandlerFn passes a click event; only a literal true forces a new generation. */
		if (this.componentRequest && restarted !== true)
			return this.componentRequest;
		this.components = undefined;
		this.updateComponents();
		const request = Promise.resolve().then(() => ap.call('components')).then(async (reply) => {
			if (this.componentRequest !== request)
				return;
			/* Keep the loading cells during the single retry. The generation guard
			   applies both before sending it and after its reply (docs/10 r18). */
			if (model.component_retryable(reply))
				reply = await ap.call('components');
			if (this.componentRequest === request) {
				this.components = reply ?? null;
				this.updateComponents();
			}
		}).finally(() => {
			if (this.componentRequest === request)
				this.componentRequest = null;
		});
		this.componentRequest = request;
		return request;
	},

	render: function(data) {
		this.labels = data.labels;
		this.currentNode = data.node;
		this.currentMode = data.mode;
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
		   Sites go first so slow inventory cannot block the small dropdown read;
		   common.js still owns the shared concurrency limit (docs/10 r18). */
		this.sitesRequest = this.loadProbeSites();
		this.initialRequest = Promise.resolve().then(() => this.fetchRefresh());
		this.loadVersion();
		this.loadComponents();

		return root;
	},

	refresh: function(status, stats, events) {
		this.status = status;
		const markers = model.status_markers(status);
		if (markers && this.manualProbe && markers.probe_at !== this.manualProbe.monitor_at)
			this.manualProbe = null;
		const normal = model.build(status, this.version, this.labels, Math.floor(Date.now() / 1000),
			this.enabled, this.currentNode, this.components, events, this.manualProbe, this.currentMode);
		const vm = model.startup_view(normal, this.startupPhase);

		/* Keep confirmations from the latest model output for both controls. */
		this.vm = vm;

		this.probeControl ??= this.probeControls();
		this.updateProbeButton();
		/* Reuse controls when moving them into fresh sections: polling must not
		   reset an edited selection, the enable switch or an in-flight probe. */
		this.enableControl ??= this.enableSwitch(vm.enabled_note);
		this.enableInput.checked = this.enabled;
		/* Rebase current labels and guards, but keep each independently edited
		   dropdown even when an external change moves the effective settings. */
		const labels = JSON.stringify(vm.node_options);
		const changed = this.controlNode !== vm.current_node || this.controlMode !== vm.current_mode;
		if (!this.nodeControl || changed || this.controlLabels !== labels) {
			const selected = {};
			if (!this.switching) {
				if (this.nodeEdited && this.nodeSelect)
					selected.node = this.nodeSelect.value;
				if (this.modeEdited && this.modeSelect)
					selected.mode = this.modeSelect.value;
			}
			this.nodeControl = vm.node_options.length ? this.nodeControls(vm, selected) : null;
			this.controlNode = vm.current_node;
			this.controlMode = vm.current_mode;
			this.controlLabels = labels;
		}
		this.updateNodeButton?.();
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
				E('strong', {
					style: 'font-size: 1.6em;' + this.colorStyle(vm.state_level)
						+ (vm.state_dimmed ? ';opacity:0.7' : '')
				}, vm.state_text ?? '–'),
				' ', E('span', {}, vm.state_duration_text ?? ''), ' ',
				...(vm.dns_failsafe ? [ E('span', { style: this.colorStyle('warn') },
					_('DNS has fallen back to the original upstream configuration.', 'aether-proxy')) ] : []),
				...(vm.degradation_notice ? [ ' ', E('span', { style: this.colorStyle('warn') },
					vm.degradation_notice) ] : [])
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
			details.push(E('div', {},
				_('Overseas domain resolution: %s', 'aether-proxy').replace('%s', vm.dns_text)));
		if (details.length)
			stateRows.push(E('div', {}, details));

		stateRows.push(E('div', {
			style: 'display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:0.5em 1em'
		}, [
			this.nodeControl ?? E('p', {}, vm.node_text),
			E('div', { style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
				...(vm.node_address_text ? [ E('span', {}, vm.node_address_text) ] : []),
				E('span', { style: this.colorStyle(vm.probe_level) },
					vm.probe_text ?? _('Latency: –', 'aether-proxy')),
				E('small', {}, vm.probe_since_text ?? ''), this.probeControl
			])
		]));
		/* Only present rows take a gap; div details avoid theme-specific paragraph margins. */
		dom.content(this.runtimeContent, this.section(_('Runtime status', 'aether-proxy'), [ E('div', {
			style: 'display:flex; flex-direction:column; align-items:stretch; gap:0.75em'
		}, stateRows) ]));
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
