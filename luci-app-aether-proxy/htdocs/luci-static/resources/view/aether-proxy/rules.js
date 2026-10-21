'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require aether-proxy.common as ap';
'require aether-proxy.model.rules as model';

/* Rules/DNS form and independent custom-file editors (docs/10 "规则与 DNS 页").
 * Lists deliberately bypass UCI: each save is validated by the CLI independently.
 * Per docs/10 "先出页面", defer RPC until the form and disabled editors are rendered.
 * Job progress and unconditional recovery follow docs/10 "UI 规则".
 */
const LISTS = [
	[ 'direct_domain', _('Direct domains', 'aether-proxy') ], [ 'proxy_domain', _('Proxy domains', 'aether-proxy') ],
	[ 'direct_ip', _('Direct IPv4 addresses', 'aether-proxy') ], [ 'proxy_ip', _('Proxy IPv4 addresses', 'aether-proxy') ]
];
return view.extend({
	load: function() {
		return uci.load('aetherproxy');
	},
	list_editor: function(item) {
		const pending = model.list_state();
		const input = E('textarea', { rows: 8, style: 'width:100%',
			disabled: pending.disabled, placeholder: pending.placeholder });
		const message = E('div');
		const button = E('button', { class: 'cbi-button cbi-button-save', type: 'button',
			disabled: pending.disabled,
			click: ui.createHandlerFn(this, function() {
				button.disabled = true;
				return ap.call('save_file', { name: item[0], content: input.value }).then(r => {
					this.show_save(message, r);
					button.disabled = false;
				});
			}) }, _('Save list', 'aether-proxy'));
		return {
			node: E('div', { class: 'cbi-section' }, [ E('h3', {}, item[1]), input, button, message ]),
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
			const root = E('div', {}, [ node, ...editors.map(editor => editor.node),
				E('h3', {}, _('Rule data', 'aether-proxy')), inventory, update, summary, progress ]);
			/* A new turn lets LuCI display the page before RPC starts. Enqueue in
			 * page order; ap.call owns the shared two-request concurrency limit. */
			window.setTimeout(() => {
				editors.forEach(editor => editor.load());
				ap.call('data_status').then(r => this.show_data(inventory, r));
			}, 0);
			return root;
		});
	}
});
