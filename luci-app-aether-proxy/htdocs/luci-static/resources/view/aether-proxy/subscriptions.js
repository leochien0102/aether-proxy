'use strict';
// Bind subscription forms, confirmed deletion and background updates to UCI and shared RPC helpers.
// Design: docs/10「订阅页」「订阅页修正」「作业机制」「UI 规则」「其余页面先出页面」.
// The initial status read only fills result cells; never redraw an open edit modal for it.
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.subscriptions as model';

return view.extend({
	load: function() {
		return uci.load('aetherproxy');
	},
	render: function() {
		this.status = undefined;
		this.busy = false;
		this.pendingIds = new Set();
		this.changesGeneration = 0;
		this.root = E('div');
		// Keep these nodes across redraws so the timer never targets a detached node.
		this.progress = E('div');
		this.summary = E('div');
		return this.redraw().then(() => {
			window.setTimeout(() => ap.call('sub_status').then(status => {
				// A completed update may have already supplied fresher status.
				if (this.status !== undefined)
					return;
				this.status = status ?? { ok: false, code: 'RPC_FAILED' };
				this.show_results();
			}), 0);
			return this.root;
		});
	},
	result_content: function(result) {
		return [result.text, E('br'), result.time, E('br'), result.skipped];
	},
	show_results: function() {
		const vm = model.build(uci.sections('aetherproxy', 'subscription'),
			this.status, Date.now() / 1000, this.busy);
		this.statusError.textContent = vm.error;
		for (const row of vm.rows) {
			if (this.resultCells[row.id])
				dom.content(this.resultCells[row.id], this.result_content(row.result));
		}
	},
	sync_buttons: function() {
		for (const [id, button] of this.rowButtons ?? []) {
			const pending = this.pendingIds.has(id);
			button.disabled = this.busy || pending;
			button.title = pending ? _('Please save and apply first', 'aether-proxy') : '';
		}
		if (this.updateAll)
			this.updateAll.disabled = this.busy;
		if (this.pendingHint)
			this.pendingHint.textContent = this.pendingIds.size
				? _('Unapplied subscriptions will not be updated', 'aether-proxy') : '';
	},
	refresh_changes: async function() {
		const generation = ++this.changesGeneration;
		let changes;
		try {
			changes = await uci.changes();
		}
		catch (e) {
			// This check is advisory; job_result supplies the fallback if the RPC fails.
			changes = {};
		}
		// A slow reply from an older form must not undo a newer session check.
		if (generation !== this.changesGeneration)
			return;
		this.pendingIds = model.pending_ids(changes);
		this.sync_buttons();
	},
	table_columns: function(s) {
		const self = this;
		const columns = [
			['_name', _('Name', 'aether-proxy')], ['_address', _('Address', 'aether-proxy')],
			['_enabled', _('Enabled', 'aether-proxy')], ['_interval', _('Update interval', 'aether-proxy')],
			['_via', _('Fetch via', 'aether-proxy')], ['_result', _('Last result', 'aether-proxy')]
		];
		for (const [field, title] of columns) {
			const o = s.option(form.DummyValue, field, title);
			o.modalonly = false;
			o.textvalue = function(id) {
				const row = model.row(uci.get('aetherproxy', id), self.status, Date.now() / 1000, self.busy);
				if (!row)
					return '–';
				if (field === '_result') {
					// An edit can make GridSection render cells again on the same map.
					const span = E('span', {}, self.result_content(row.result));
					self.resultCells[id] = span;
					return span;
				}
				return row[field.slice(1)];
			};
		}
	},
	redraw: function() {
		const self = this;
		this.pendingIds ??= new Set();
		this.changesGeneration ??= 0;
		this.resultCells = {};
		this.statusError = E('p');
		const subs = uci.sections('aetherproxy', 'subscription');
		const vm = model.build(subs, this.status, Date.now() / 1000, this.busy);
		this.rowButtons = new Map();
		const m = new form.Map('aetherproxy', _('Subscriptions', 'aether-proxy'));
		this.map = m;
		const s = m.section(form.GridSection, 'subscription');
		this.grid = s;
		s.addremove = true;
		s.anonymous = true;
		s.render = function(...args) {
			self.rowButtons = new Map();
			return this.super('render', args).then(content => {
				// Map.reset after modal Save also renders this section, not the whole page.
				self.refresh_changes();
				return content;
			});
		};
		// The generic Add creates anonymous sections, which are not subscription IDs.
		s.renderSectionAdd = function() { return E([]); };
		s.renderRowActions = function(id) {
			const td = this.super('renderRowActions', [id]);
			const button = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'disabled': self.busy || self.pendingIds.has(id) || null,
				'click': ui.createHandlerFn(self, 'update', [id])
			}, _('Update now', 'aether-proxy'));
			self.rowButtons.set(id, button);
			self.sync_buttons();
			dom.content(td.lastChild, [button, ...Array.from(td.lastChild.childNodes)]);
			return td;
		};
		// GridSection's built-in cbi-button-remove dispatches here.
		s.handleRemove = async function(id) {
			const plan = model.delete_plan(id,
				uci.sections('aetherproxy', 'node'), uci.get('aetherproxy', 'main', 'node'));
			if (!await ap.confirm({
				title: _('Delete subscription', 'aether-proxy'),
				text: plan.confirm,
				ok: _('Delete', 'aether-proxy'),
				destructive: true
			}))
				return;

			for (const node of plan.remove)
				uci.remove('aetherproxy', node);
			for (const node of plan.manual) {
				uci.set('aetherproxy', node, 'source', 'manual');
				uci.set('aetherproxy', node, 'stale', '0');
			}
			uci.remove('aetherproxy', id);
			return self.redraw();
		};
		this.table_columns(s);
		let o = s.option(form.Value, 'name', _('Name', 'aether-proxy')); o.modalonly = true;
		o = s.option(form.Value, 'url', _('Subscription URL', 'aether-proxy')); o.modalonly = true; o.password = true; o.rmempty = false;
		o = s.option(form.Flag, 'enabled', _('Enabled', 'aether-proxy')); o.modalonly = true; o.default = '1';
		o = s.option(form.Value, 'interval_hours', _('Update interval', 'aether-proxy')); o.modalonly = true; o.datatype = 'uinteger'; o.default = '24';
		o = s.option(form.ListValue, 'fetch_via', _('Fetch via', 'aether-proxy')); o.modalonly = true; o.default = 'auto';
		o.value('auto', _('Automatic', 'aether-proxy')); o.value('direct', _('Direct', 'aether-proxy')); o.value('proxy', _('Proxy', 'aether-proxy'));
		o = s.option(form.Value, 'user_agent', _('User agent', 'aether-proxy')); o.modalonly = true;
		return m.render().then(content => {
			const updateAll = E('button', {
				'class': 'btn cbi-button cbi-button-action', 'disabled': !vm.can_update || null,
				'click': ui.createHandlerFn(self, 'update', [])
			}, _('Update all', 'aether-proxy'));
			self.updateAll = updateAll;
			self.pendingHint = E('span');
			dom.content(self.root, [
				E('div', {
					style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
						+ 'flex-wrap:wrap; margin:0.5em 0 1em'
				}, [ self.statusError, self.progress, self.summary, self.pendingHint, updateAll,
					E('button', {
						'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(self, 'add')
					}, _('Add', 'aether-proxy')) ]),
				content
			]);
			self.sync_buttons();
			self.show_results();
		});
	},
	add: function() {
		const id = model.new_id(uci.sections('aetherproxy').map(s => s['.name']), () => window.crypto.getRandomValues(new Uint8Array(4)));
		uci.add('aetherproxy', 'subscription', id);
		/* Same as GridSection.handleAdd: Cancel removes the new section and Save
		   keeps it (the modal Save re-renders the table). Without this, Cancel
		   left an empty subscription in the page. */
		this.map.addedSection = id;
		return this.grid.renderMoreOptionsModal(id);
	},
	update: async function(ids) {
		if (this.busy || ids.some(id => this.pendingIds.has(id)))
			return;
		this.busy = true;
		this.sync_buttons();
		let timer;
		try {
			this.summary.replaceChildren();
			timer = ap.job_progress(this.progress, _('Updating subscriptions…', 'aether-proxy'));
			await this.redraw();
			const job = await ap.run_job('sub_update', ids);
			timer.stop();
			const lines = model.job_result(job, id => uci.get('aetherproxy', id)?.name || id);
			this.summary.replaceChildren(...lines.map(text => E('p', {}, text)));
			if (lines.length)
				ui.addNotification(null, E('div', {}, lines.map(text => E('p', {}, text))));
			const data = await Promise.all([
				uci.unload('aetherproxy').then(() => uci.load('aetherproxy')), ap.call('sub_status')
			]);
			this.status = data[1];
		}
		catch (e) {
			this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
		}
		finally {
			this.busy = false;
			if (timer)
				timer.stop();
			// A rendering error must not strand the previously rendered buttons.
			this.sync_buttons();
			try {
				await this.redraw();
			}
			catch (e) {
				this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
			}
		}
	}
});
