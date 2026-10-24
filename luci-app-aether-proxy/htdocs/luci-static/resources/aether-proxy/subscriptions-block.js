'use strict';
// Bind subscription forms, confirmed deletion and background updates to UCI and shared RPC helpers.
// Design: docs/10「订阅页」「订阅页修正」「作业机制」「UI 规则」「其余页面先出页面」「r12 缺陷修正」.
// Also follows docs/10「订阅：通用设置、获取方式与行首开关」「节点与订阅合并为一页」.
// r13 pending-state and tooltip rules: docs/10「r13 修正：订阅编辑框与启用开关」.
// Inline feedback and action sizing: docs/10「r13 修正：块内行与表格操作列」.
// Saved disabled state and card alignment: docs/10「r14 修正：订阅已停用时「立即更新」不可用、窄屏卡片」.
// Initial RPC reads only fill cells/placeholders; never redraw an open edit modal for them.
'require baseclass';
'require form';
'require aether-proxy.form-defaults as form_defaults';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.subscriptions as model';

return baseclass.extend({
	load: function() {
		return uci.load('aetherproxy').then(() => {
			if (!uci.get('aetherproxy', 'sub'))
				uci.add('aetherproxy', 'sub', 'sub');
		});
	},
	render: function(refresh_nodes) {
		this.refresh_nodes = refresh_nodes;
		this.status = undefined;
		this.busy = false;
		this.pendingIds = new Set();
		this.sessionPendingIds = new Set();
		this.defaultUA = _('Reading…', 'aether-proxy');
		this.changesGeneration = 0;
		this.root = E('div');
		// Keep these nodes across redraws so the timer never targets a detached node.
		this.progress = E('div');
		this.summary = E('div');
		return this.redraw().then(() => {
			window.setTimeout(() => {
				this.read_version();
				ap.call('sub_status').then(status => {
					// A completed update may have already supplied fresher status.
					if (this.status !== undefined)
						return;
					this.status = status ?? { ok: false, code: 'RPC_FAILED' };
					this.show_results();
				});
			}, 0);
			return this.root;
		});
	},
	read_version: async function() {
		const reply = await ap.call('version');
		// A failed version read shows the UA's shape, never an error code in an input
		// (design lead, 2026-10-22); nothing is written to UCI either way.
		this.defaultUA = 'aether-proxy/' + (reply?.ok && reply.version ? reply.version : '…');
		const o = this.generalOptions.user_agent;
		o.placeholder = _('Default (%s)', 'aether-proxy').format(this.defaultUA);
		o.getUIElement('sub')?.setPlaceholder(o.placeholder);
		if (this.uaModal) {
			const { option, id } = this.uaModal;
			option.placeholder = model.follow(this.general_values().user_agent);
			option.getUIElement(id)?.setPlaceholder(option.placeholder);
		}
	},
	general_values: function() {
		const values = {};
		for (const field of ['interval_hours', 'fetch_via', 'user_agent']) {
			const option = this.generalOptions?.[field];
			values[field] = option?.formvalue('sub') ?? uci.get('aetherproxy', 'sub', field);
		}
		return model.general_values(values, this.defaultUA);
	},
	setting_option: function(section, field, title, inherited) {
		const self = this;
		const kind = field === 'user_agent' ? form.Value : form.ListValue;
		const o = section.option(kind, field, title);
		o.rmempty = true;
		if (inherited)
			o.modalonly = true;
		else if (field !== 'user_agent')
			o.default = field === 'interval_hours' ? '24' : 'auto';
		// Explicit values are preselected as stored; r13's 24 -> 0 is not reproducible
		// on the SDK (docs/10「r13 修正：订阅编辑框与启用开关」复审结论).
		// Capture the ListValue/Value method: instance super() would skip that class.
		const renderWidget = o.renderWidget;
		// Recompute when opening a modal: the common block may have unsaved input.
		o.renderWidget = function(id, index, value) {
			const common = self.general_values();
			if (field === 'user_agent') {
				this.placeholder = inherited ? model.follow(common.user_agent)
					: _('Default (%s)', 'aether-proxy').format(self.defaultUA);
				if (inherited)
					self.uaModal = { option: this, id };
			}
			else {
				this.keylist = [];
				this.vallist = [];
				const format = field === 'interval_hours' ? model.interval_text : model.fetch_text;
				if (inherited)
					this.value('', model.follow(format(common[field])));
				const choices = field === 'interval_hours' ? model.interval_choices(value)
					: ['auto', 'direct', 'proxy'].map(key => [key, model.fetch_text(key)]);
				for (const [key, label] of choices)
					this.value(key, label);
			}
			return renderWidget.call(this, id, index, value);
		};
		return o;
	},
	general_settings: function(m) {
		const s = m.section(form.NamedSection, 'sub', 'sub', _('General settings', 'aether-proxy'));
		this.generalOptions = {
			interval_hours: this.setting_option(s, 'interval_hours', _('Update interval', 'aether-proxy'), false),
			fetch_via: this.setting_option(s, 'fetch_via', _('Fetch method', 'aether-proxy'), false),
			user_agent: this.setting_option(s, 'user_agent', _('User agent', 'aether-proxy'), false)
		};
		form_defaults.section(s, { user_agent: () => this.defaultUA });
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
		this.pendingIds = new Set(this.sessionPendingIds);
		for (const [id, button] of this.rowButtons ?? []) {
			// Only a live difference is dirty: a round trip must not latch the row.
			const current = this.enabledOption?.formvalue(id);
			const saved = uci.get('aetherproxy', id, 'enabled') ?? this.enabledOption?.default;
			if (current != null && current !== saved)
				this.pendingIds.add(id);
			const state = model.update_state(uci.get('aetherproxy', id), this.busy, this.pendingIds.has(id));
			button.disabled = !state.can_update;
			// Disabled controls do not reliably receive hover events in all browsers.
			const wrapper = this.rowWrappers.get(id);
			if (state.hint)
				wrapper.setAttribute('title', state.hint);
			else
				wrapper.removeAttribute('title');
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
		this.sessionPendingIds = model.pending_ids(changes);
		this.sync_buttons();
	},
	table_columns: function(s) {
		const self = this;
		const enabled = s.option(form.Flag, 'enabled', _('Enabled', 'aether-proxy'));
		enabled.editable = true;
		enabled.modalonly = false;
		enabled.default = '1';
		this.enabledOption = enabled;
		const renderWidget = enabled.renderWidget;
		enabled.renderWidget = function(...args) {
			// Keep the theme's flag widget beside the card label, without changing its styling.
			return E('span', { style: 'display:inline-flex; align-items:center' }, [renderWidget.apply(this, args)]);
		};
		enabled.onchange = function() {
			// uci.changes() cannot see a widget change before the form is saved.
			self.sync_buttons();
		};
		const columns = [
			['_name', _('Name', 'aether-proxy')], ['_address', _('Address', 'aether-proxy')],
			['_interval', _('Update interval', 'aether-proxy')],
			['_via', _('Fetch method', 'aether-proxy')], ['_result', _('Last result', 'aether-proxy')]
		];
		for (const [field, title] of columns) {
			const o = s.option(form.DummyValue, field, title);
			o.modalonly = false;
			o.textvalue = function(id) {
				const row = model.row(uci.get('aetherproxy', id), self.status, Date.now() / 1000,
					self.busy, uci.get('aetherproxy', 'sub'));
				if (!row)
					return '–';
				if (field === '_result') {
					// An edit can make GridSection render cells again on the same map.
					// One inline block keeps all result lines in the card's value column.
					const span = E('span', { style: 'display:inline-block; vertical-align:top' },
						self.result_content(row.result));
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
		this.statusError = E('span', { style: 'margin:0' });
		const subs = uci.sections('aetherproxy', 'subscription');
		const vm = model.build(subs, this.status, Date.now() / 1000, this.busy);
		this.rowButtons = new Map();
		this.rowWrappers = new Map();
		const m = new form.Map('aetherproxy');
		this.map = m;
		this.general_settings(m);
		const s = m.section(form.GridSection, 'subscription');
		this.grid = s;
		s.addremove = true;
		s.anonymous = true;
		s.render = function(...args) {
			self.rowButtons = new Map();
			self.rowWrappers = new Map();
			return this.super('render', args).then(content => {
				// Map.reset after modal Save also renders this section, not the whole page.
				self.refresh_changes();
				return content;
			});
		};
		// The generic Add creates anonymous sections, which are not subscription IDs.
		s.renderSectionAdd = function() { return E([]); };
		s.renderRowActions = function(id) {
			const td = this.super('renderRowActions', [id, _('Edit', 'aether-proxy')]);
			const button = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'disabled': self.busy || self.pendingIds.has(id) || null,
				'click': ui.createHandlerFn(self, 'update', [id])
			}, _('Update now', 'aether-proxy'));
			const wrapper = E('span', {}, [button]);
			self.rowButtons.set(id, button);
			self.rowWrappers.set(id, wrapper);
			self.sync_buttons();
			const actions = [button, ...Array.from(td.lastChild.childNodes)];
			// Theme button rules can override inherited nowrap; retain built-in nodes and handlers.
			for (const action of actions)
				action.style = (action.style?.cssText ?? '') + ';white-space:nowrap';
			dom.content(td, E('div', {
				style: 'display:flex; flex-wrap:nowrap; gap:0.25em; align-items:center'
			}, [wrapper, ...actions.slice(1)]));
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
		this.setting_option(s, 'interval_hours', _('Update interval', 'aether-proxy'), true);
		this.setting_option(s, 'fetch_via', _('Fetch method', 'aether-proxy'), true);
		this.setting_option(s, 'user_agent', _('User agent', 'aether-proxy'), true);
		form_defaults.section(s);
		return m.render().then(content => {
			const updateAll = E('button', {
				'class': 'btn cbi-button cbi-button-action', 'disabled': !vm.can_update || null,
				'click': ui.createHandlerFn(self, 'update', [])
			}, _('Update all', 'aether-proxy'));
			self.updateAll = updateAll;
			self.pendingHint = E('span');
			dom.content(self.root, [
				content,
				E('div', {
					style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
						+ 'flex-wrap:wrap; margin:0.5em 0 1em'
				}, [ self.statusError, self.progress, self.summary, self.pendingHint, updateAll,
					E('button', {
						'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(self, 'add')
					}, _('Add', 'aether-proxy')) ]),
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
		if (this.busy || ids.some(id => !model.update_state(uci.get('aetherproxy', id),
			this.busy, this.pendingIds.has(id)).can_update))
			return;
		this.busy = true;
		this.sync_buttons();
		let timer;
		try {
			this.summary.replaceChildren();
			timer = ap.job_progress(this.progress, _('Updating subscriptions…', 'aether-proxy'));
			// Keep live common settings and editable flags mounted throughout the job.
			this.show_results();
			const job = await ap.run_job('sub_update', ids);
			timer.stop();
			const lines = model.job_result(job, id => uci.get('aetherproxy', id)?.name || id);
			// Paragraph margins would offset multi-subscription results from the adjacent buttons.
			this.summary.replaceChildren(...lines.map(text => E('div', { style: 'margin:0' }, text)));
			if (lines.length)
				ui.addNotification(null, E('div', {}, lines.map(text => E('p', {}, text))));
			// unload is synchronous in luci-base; only load returns a Promise.
			uci.unload('aetherproxy');
			const data = await Promise.all([this.load(), ap.call('sub_status')]);
			this.status = data[1];
			if (this.refresh_nodes)
				await this.refresh_nodes();
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
				this.show_results();
				await this.refresh_changes();
			}
			catch (e) {
				this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
			}
		}
	}
});
