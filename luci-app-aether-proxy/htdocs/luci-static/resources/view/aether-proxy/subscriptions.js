'use strict';
// Bind subscription forms, confirmed deletion and background updates to UCI and shared RPC helpers.
// Design: docs/10「订阅页（2026-10-16 定，T8.6）」「作业机制」.
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.subscriptions as model';

return view.extend({
	load: function() {
		return Promise.all([uci.load('aetherproxy'), ap.call('sub_status')]);
	},
	render: function(data) {
		this.status = data[1];
		this.busy = false;
		this.root = E('div');
		return this.redraw().then(() => this.root);
	},
	redraw: function() {
		const self = this;
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
			dom.content(td.lastChild, [button, ...Array.from(td.lastChild.childNodes)]);
			return td;
		};
		// GridSection's built-in cbi-button-remove dispatches here.
		s.handleRemove = function(id) {
			const plan = model.delete_plan(id, uci.sections('aetherproxy', 'node'), uci.get('aetherproxy', 'main', 'node'));
			if (!confirm(plan.confirm)) return;
			for (const node of plan.remove) uci.remove('aetherproxy', node);
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
				if (field === '_result') return E('span', {}, [row.result.text, E('br'), row.result.time, E('br'), row.result.skipped]);
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
			dom.content(self.root, [
				E('p', {}, vm.error),
				E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(self, 'add') }, _('Add', 'aether-proxy')),
				E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': !vm.can_update || null, 'click': ui.createHandlerFn(self, 'update', []) }, _('Update all', 'aether-proxy')),
				content
			]);
		});
	},
	add: function() {
		const id = model.new_id(uci.sections('aetherproxy').map(s => s['.name']), () => window.crypto.getRandomValues(new Uint8Array(4)));
		uci.add('aetherproxy', 'subscription', id);
		return this.redraw().then(() => this.grid.renderMoreOptionsModal(id));
	},
	update: function(ids) {
		const self = this;
		this.busy = true;
		const names = Object.fromEntries(model.build(uci.sections('aetherproxy', 'subscription'), this.status, Date.now() / 1000, true).rows.map(r => [r.id, r.name]));
		return this.redraw().then(() => ap.run_job('sub_update', ids)).then(job => {
			ui.addNotification(null, E('div', {}, model.job_result(job, names).map(text => E('p', {}, text))));
			return Promise.all([uci.unload('aetherproxy').then(() => uci.load('aetherproxy')), ap.call('sub_status')]);
		}).then(data => {
			self.status = data[1];
		}).finally(() => {
			self.busy = false;
			return self.redraw();
		});
	}
});
