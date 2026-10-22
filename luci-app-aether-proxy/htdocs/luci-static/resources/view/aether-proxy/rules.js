'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require aether-proxy.common as ap';
'require aether-proxy.model.rules as model';

/* Rules/DNS form and independent custom-file editors (docs/10 "规则与 DNS 页").
 * Lists deliberately bypass UCI: each save is validated by the CLI independently.
 * Per docs/10 "名单改为标签页", group only the editors in standard LuCI tabs.
 * Per docs/10 "先出页面", defer RPC until the form and disabled editors are rendered.
 * Job progress and unconditional recovery follow docs/10 "UI 规则".
 * Composite trust rows and deferred WAN hints follow docs/10 "DNS 常用地址与协议".
 */
const LISTS = [
	[ 'direct_domain', _('Direct domains', 'aether-proxy') ], [ 'proxy_domain', _('Proxy domains', 'aether-proxy') ],
	[ 'direct_ip', _('Direct IPv4 addresses', 'aether-proxy') ], [ 'proxy_ip', _('Proxy IPv4 addresses', 'aether-proxy') ]
];
/* One form option owns both rows and the UCI list: independent options could
 * overwrite each other or leave temporary UI-only keys in the configuration. */
function trust_option(section) {
	const option = section.option(form.Value, 'trust_dns', _('Trust DNS', 'aether-proxy'));
	option.rmempty = false;
	option.description = _('UDP is for DNS servers without TCP query support and requires UDP forwarding '
		+ 'on the node; the two entries can use different protocols as backups.', 'aether-proxy');
	option.widgets = {};
	option.renderWidget = function(section_id, option_index, cfgvalue) {
		const labels = [ _('Trust DNS 1', 'aether-proxy'), _('Trust DNS 2 (optional)', 'aether-proxy') ];
		const choices = Object.fromEntries(model.presets('trust_dns'));
		this.widgets[section_id] = model.trust_rows(cfgvalue).map((row, i) => {
			const id = this.cbid(section_id) + '.' + i;
			const address = new ui.Combobox(row.address, choices, {
				id: id + '.address', sort: Object.keys(choices),
				validate: value => model.trust_input(value, i == 1),
				disabled: (this.readonly ?? this.map.readonly) || null
			});
			const protocol = new ui.Select(row.protocol, {
				tcp: _('TCP (default)', 'aether-proxy'), udp: _('UDP', 'aether-proxy')
			}, { id: id + '.protocol', disabled: (this.readonly ?? this.map.readonly) || null });
			const select = protocol.render();
			select.querySelector('select').style.width = 'auto';
			return { address, protocol, node: E('div', {
				style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap; margin:0.5em 0'
			}, [ E('label', { for: 'widget.' + id + '.address' }, labels[i]), address.render(), select ]) };
		});
		return E('div', { id: this.cbid(section_id) }, this.widgets[section_id].map(row => row.node));
	};
	option.formvalue = function(section_id) {
		return model.trust_values(this.widgets[section_id].map(row => ({
			address: row.address.getValue() ?? '', protocol: row.protocol.getValue()
		})));
	};
	option.write = function(section_id, value) {
		return this.map.data.set(this.map.config, section_id, 'trust_dns', value);
	};
	option.validate = function(section_id, value) { return model.validate('trust_dns', value); };
	option.getValidationError = function(section_id) {
		const rows = this.widgets[section_id];
		for (const [i, row] of rows.entries()) {
			const result = model.trust_input(row.address.getValue() ?? '', i == 1);
			if (result !== true)
				return result;
		}
		const result = this.validate(section_id, this.formvalue(section_id));
		return result === true ? '' : result;
	};
	/* Combobox is always optional in LuCI. Aggregate validation must still
	 * reject an empty first address when AbstractValue.parse() saves the map. */
	option.isValid = function(section_id) { return this.getValidationError(section_id) == ''; };
	return option;
}
return view.extend({
	load: function() {
		return uci.load('aetherproxy');
	},
	list_editor: function(item) {
		const pending = model.list_state();
		const input = E('textarea', { rows: 8, style: 'width:100%',
			disabled: pending.disabled || null, placeholder: pending.placeholder });
		const message = E('div');
		const button = E('button', { class: 'cbi-button cbi-button-save', type: 'button',
			disabled: pending.disabled || null,
			click: ui.createHandlerFn(this, function() {
				button.disabled = true;
				return ap.call('save_file', { name: item[0], content: input.value }).then(r => {
					this.show_save(message, r);
					button.disabled = false;
				});
			}) }, _('Save list', 'aether-proxy'));
		return {
			node: E('div', { class: 'cbi-section', 'data-tab': item[0], 'data-tab-title': item[1] },
				[ E('h3', {}, item[1]), input,
					E('div', {
						style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
							+ 'flex-wrap:wrap; margin:0.5em 0 1em'
					}, [ message, button ]) ]),
			load: () => ap.call('list_file', { name: item[0] }).then(result => {
				const vm = model.list_state(result);
				input.value = vm.content;
				input.placeholder = vm.placeholder;
				input.disabled = button.disabled = vm.disabled;
				if (vm.error)
					this.show_message(message, vm.error);
			})
		};
	},
	show_message: function(target, vm) {
		target.replaceChildren(E('p', {}, vm.text), ...vm.errors.map(text => E('p', {}, text)));
	},
	show_save: function(target, result) {
		this.show_message(target, model.save_result(result));
	},
	show_data: function(target, result) {
		const vm = model.table(result, Date.now() / 1000);
		target.replaceChildren(E('p', {}, [ _('Last checked', 'aether-proxy'), ': ', vm.checked ]),
			E('table', { class: 'table' }, [
				E('tr', { class: 'tr table-titles' },
					[ _('Name', 'aether-proxy'), _('Source', 'aether-proxy'), _('Version', 'aether-proxy'), _('Lines', 'aether-proxy'), _('Updated', 'aether-proxy'), _('Status', 'aether-proxy') ]
						.map(text => E('th', { class: 'th' }, text))),
				...vm.rows.map(row => E('tr', { class: 'tr' }, row.map(text => E('td', { class: 'td' }, text))))
			]), E('p', {}, vm.error ?? ''));
	},
	render: function() {
		const map = new form.Map('aetherproxy', _('Rules and DNS', 'aether-proxy'));
		let section = map.section(form.NamedSection, 'main', 'global');
		let option = section.option(form.ListValue, 'mode', _('Mode', 'aether-proxy'));
		model.modes().forEach(item => option.value(item[0], item[1]));
		section = map.section(form.NamedSection, 'dns', 'dns', _('DNS settings', 'aether-proxy'));
		const wan_hint = E('div');
		const china = section.option(form.DynamicList, 'china_dns', _('China DNS', 'aether-proxy'));
		china.rmempty = false;
		model.presets('china_dns').forEach(item => china.value(item[0], item[1]));
		china.validate = function(section_id, value) { return model.validate('china_dns', value); };
		china.renderWidget = function(section_id, option_index, cfgvalue) {
			/* form.Value only renders string descriptions; keep the asynchronous
			 * hint in a DOM description owned by this widget instead. */
			return E('div', {}, [ form.DynamicList.prototype.renderWidget.call(this,
				section_id, option_index, cfgvalue), E('div', { class: 'cbi-value-description' }, [
					E('div', {}, _('Some ISP DNS servers resolve nonexistent domains to advertising pages; '
						+ 'use public DNS if this concerns you.', 'aether-proxy')), wan_hint
				]) ]);
		};
		trust_option(section);
		const direct = section.option(form.DynamicList, 'direct_dns', _('Direct DNS', 'aether-proxy'));
		direct.rmempty = false;
		model.presets('direct_dns').forEach(item => direct.value(item[0], item[1]));
		direct.validate = function(section_id, value) { return model.validate('direct_dns', value); };
		direct.description = _('TCP queries to 8.8.8.8 and 1.1.1.1 may be reset on some networks; '
			+ 'try tcp://9.9.9.9 first.', 'aether-proxy');
		const fields = [
			[ 'allow_china_fallback', _('Allow China fallback', 'aether-proxy'), form.Flag ],
			[ 'dns_probe_domain', _('DNS probe domain', 'aether-proxy'), form.Value ] ];
		fields.forEach(field => {
			const o = section.option(field[2], field[0], field[1]);
			o.rmempty = false;
			o.validate = function(section_id, value) { return model.validate(field[0], value); };
		});
		const inventory = E('div', {}, model.loading_text), summary = E('div'), progress = E('div');
		const update = E('button', { type: 'button', class: 'cbi-button cbi-button-action',
			click: ui.createHandlerFn(this, async function() {
				update.disabled = true;
				let timer;
				try {
					summary.replaceChildren();
					timer = ap.job_progress(progress, _('Updating rule data…', 'aether-proxy'));
					const job = await ap.run_job('update_data', []);
					timer.stop();
					summary.replaceChildren(...model.job_result(job).map(text => E('p', {}, text)));
					this.show_data(inventory, await ap.call('data_status'));
				}
				catch (e) {
					summary.textContent = _('Operation failed: %s', 'aether-proxy').format(e?.message ?? String(e));
				}
				finally {
					if (timer)
						timer.stop();
					update.disabled = false;
				}
			}) }, _('Update now', 'aether-proxy'));
		return map.render().then(node => {
			const editors = LISTS.map(item => this.list_editor(item));
			const panes = editors.map(editor => editor.node);
			const root = E('div', {}, [ node, E('div', {}, panes),
				E('h3', {}, _('Rule data', 'aether-proxy')), inventory,
				E('div', {
					style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
						+ 'flex-wrap:wrap; margin:0.5em 0 1em'
				}, [ summary, progress, update ]) ]);
			/* A new turn lets LuCI attach the panes before tab initialization and
			 * display the page before RPC starts. Enqueue in page order; ap.call
			 * owns the shared two-request concurrency limit. */
			window.setTimeout(() => {
				ui.tabs.initTabGroup(panes);
				editors.forEach(editor => editor.load());
				ap.call('data_status').then(r => this.show_data(inventory, r));
				/* Optional runtime context never blocks the form or changes UCI. A
				 * failed read intentionally leaves this hint absent (docs/10). */
				ap.call('status').then(r => {
					const message = model.wan_dns_text(r);
					wan_hint.replaceChildren(...(message == null ? [] : [ E('div', {}, message) ]));
				}, () => wan_hint.replaceChildren());
			}, 0);
			return root;
		});
	}
});
