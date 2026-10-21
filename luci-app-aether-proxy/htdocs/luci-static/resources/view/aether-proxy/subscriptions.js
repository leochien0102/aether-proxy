'use strict';
// Bind subscription forms, confirmed deletion and background updates to UCI and shared RPC helpers.
// Design: docs/10「订阅页」「作业机制」「UI 规则」「其余页面先出页面」.
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
	redraw: function() {
		const self = this;
		const jobButtons = [];
		this.resultCells = {};
		this.statusError = E('p');
		const subs = uci.sections('aetherproxy', 'subscription');
		const vm = model.build(subs, this.status, Date.now() / 1000, this.busy);
		const rows = Object.fromEntries(vm.rows.map(row => [row.id, row]));
		const m = new form.Map('aetherproxy', _('Subscriptions', 'aether-proxy'));
		this.map = m;
		const s = m.section(form.GridSection, 'subscription');
		this.grid = s;
		s.addremove = true;
		// The generic Add creates anonymous sections, which are not subscription IDs.
		s.renderSectionAdd = function() { return E([]); };
		s.renderRowActions = function(id) {
			const td = this.super('renderRowActions', [id]);
			const button = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'disabled': !rows[id].can_update || null,
				'click': ui.createHandlerFn(self, 'update', [id])
			}, _('Update now', 'aether-proxy'));
			jobButtons.push(button);
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
		for (const [field, title] of [['_name', _('Name', 'aether-proxy')], ['_address', _('Address', 'aether-proxy')], ['_enabled', _('Enabled', 'aether-proxy')], ['_interval', _('Update interval', 'aether-proxy')], ['_via', _('Fetch via', 'aether-proxy')], ['_result', _('Last result', 'aether-proxy')]]) {
			const o = s.option(form.DummyValue, field, title);
			o.modalonly = false;
			o.textvalue = function(id) {
				const row = rows[id];
				if (field === '_result') {
					// An edit can make GridSection render cells again on the same map.
					const result = model.status_result(self.status, id, Date.now() / 1000);
					const span = E('span', {}, self.result_content(result));
					self.resultCells[id] = span;
					return span;
				}
				return row[field.slice(1)];
			};
		}
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
			jobButtons.push(updateAll);
			dom.content(self.root, [
				self.statusError,
				E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(self, 'add') }, _('Add', 'aether-proxy')),
				updateAll,
				self.progress, self.summary, content
			]);
			self.jobButtons = jobButtons;
			self.show_results();
		});
	},
	add: function() {
		const id = model.new_id(uci.sections('aetherproxy').map(s => s['.name']), () => window.crypto.getRandomValues(new Uint8Array(4)));
		uci.add('aetherproxy', 'subscription', id);
		return this.redraw().then(() => this.grid.renderMoreOptionsModal(id));
	},
	update: async function(ids) {
		this.busy = true;
		let timer;
		try {
			this.summary.replaceChildren();
			timer = ap.job_progress(this.progress, _('Updating subscriptions…', 'aether-proxy'));
			const rows = model.build(uci.sections('aetherproxy', 'subscription'),
				this.status, Date.now() / 1000, true).rows;
			const names = Object.fromEntries(rows.map(r => [r.id, r.name]));
			await this.redraw();
			const job = await ap.run_job('sub_update', ids);
			timer.stop();
			const lines = model.job_result(job, names);
			this.summary.replaceChildren(...lines.map(text => E('p', {}, text)));
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
			for (const button of this.jobButtons ?? [])
				button.disabled = false;
			try {
				await this.redraw();
			}
			catch (e) {
				this.summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
			}
		}
	}
});
