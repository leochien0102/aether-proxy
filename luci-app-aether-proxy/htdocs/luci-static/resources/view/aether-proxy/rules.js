'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require aether-proxy.common as ap';
'require aether-proxy.model.rules as model';

/* Rules/DNS form and independent custom-file editors (docs/10 "规则与 DNS 页").
 * Lists deliberately bypass UCI: each save is validated by the CLI independently.
 */
const LISTS = [
	[ 'direct_domain', _('Direct domains', 'aether-proxy') ], [ 'proxy_domain', _('Proxy domains', 'aether-proxy') ],
	[ 'direct_ip', _('Direct IPv4 addresses', 'aether-proxy') ], [ 'proxy_ip', _('Proxy IPv4 addresses', 'aether-proxy') ]
];
return view.extend({
	load: function() {
		return Promise.all([ uci.load('aetherproxy'), ap.call('data_status'),
			Promise.all(LISTS.map(item => ap.call('list_file', { name: item[0] }))) ]);
	},
	list_editor: function(item, result) {
		const input = E('textarea', { rows: 8, style: 'width:100%' });
		input.value = result.content ?? '';
		const message = E('div');
		if (!result.ok)
			this.show_save(message, result);
		const button = E('button', { class: 'cbi-button cbi-button-save', type: 'button',
			click: ui.createHandlerFn(this, function() {
				button.disabled = true;
				return ap.call('save_file', { name: item[0], content: input.value }).then(r => {
					this.show_save(message, r);
					button.disabled = false;
				});
			}) }, _('Save list', 'aether-proxy'));
		return E('div', { class: 'cbi-section' }, [ E('h3', {}, item[1]), input, button, message ]);
	},
	show_save: function(target, result) {
		const vm = model.save_result(result);
		target.replaceChildren(E('p', {}, vm.text), ...vm.errors.map(text => E('p', {}, text)));
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
	render: function(data) {
		const map = new form.Map('aetherproxy', _('Rules and DNS', 'aether-proxy'));
		let section = map.section(form.NamedSection, 'main', 'global');
		let option = section.option(form.ListValue, 'mode', _('Mode', 'aether-proxy'));
		model.modes().forEach(item => option.value(item[0], item[1]));
		section = map.section(form.NamedSection, 'dns', 'dns', _('DNS settings', 'aether-proxy'));
		const fields = [ [ 'china_dns', _('China DNS', 'aether-proxy'), form.DynamicList ],
			[ 'trust_dns', _('Trust DNS', 'aether-proxy'), form.DynamicList ],
			[ 'direct_dns', _('Direct DNS', 'aether-proxy'), form.DynamicList ],
			[ 'allow_china_fallback', _('Allow China fallback', 'aether-proxy'), form.Flag ],
			[ 'dns_probe_domain', _('DNS probe domain', 'aether-proxy'), form.Value ] ];
		fields.forEach(field => {
			const o = section.option(field[2], field[0], field[1]);
			o.rmempty = false;
			o.validate = function(section_id, value) { return model.validate(field[0], value); };
		});
		const inventory = E('div'), summary = E('div');
		this.show_data(inventory, data[1]);
		const update = E('button', { type: 'button', class: 'cbi-button cbi-button-action',
			click: ui.createHandlerFn(this, function() {
				update.disabled = true;
				return ap.run_job('update_data', []).then(job => {
					summary.replaceChildren(...model.job_result(job).map(text => E('p', {}, text)));
					return ap.call('data_status');
				}).then(r => {
					this.show_data(inventory, r);
					update.disabled = false;
				});
			}) }, _('Update now', 'aether-proxy'));
		return map.render().then(node => E('div', {}, [ node,
			...LISTS.map((item, i) => this.list_editor(item, data[2][i])),
			E('h3', {}, _('Rule data', 'aether-proxy')), inventory, update, summary ]));
	}
});
