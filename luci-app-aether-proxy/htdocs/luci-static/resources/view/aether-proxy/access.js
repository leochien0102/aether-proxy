'use strict';
'require view';
'require form';
'require dom';
'require aether-proxy.form-defaults as form_defaults';
'require uci';
'require ui';
'require network';
'require aether-proxy.model.access as model';

/*
 * Access control (docs/10 「访问控制页定案」 and 「r14 修正：访问控制 IP 范围与说明」).
 * Action sizing follows docs/10 「r13 修正：块内行与表格操作列」.
 * Table flag frames follow docs/10 「r16 修正：窄屏卡片里开关与标签同一行」.
 * The model owns wording, summaries and validation. Staged LuCI changes are
 * invisible to the command line, so footer and modal saves precheck them here
 * (docs/10 「r16 修正：访问控制编辑框里的校验与重叠提示」);
 * the backend remains authoritative. Display sorting must not reorder UCI.
 * Local input feedback follows docs/10 「r17 修正：访问控制的反馈、措辞与名称不重复」;
 * pending text and device dropdown layout follow 「r18：访问控制的未添加内容与设备下拉」
 * and 「r19：访问控制设备下拉的顺序与校验提示」.
 */

/* Theme invalid classes alone are invisible in proton2025. Keep feedback next
   to the actual input, and restore its original border when the user edits. */
function inputError(input, text, shake = true) {
	if (!input)
		return;
	if (!input.accessFeedback) {
		const message = E('div', { style: 'display:block; flex-basis:100%; color:var(--error-color-high, #c53030)' });
		/* SDK's + handler reads previousElementSibling as the input. Append
		   after the button, never between it and the input. */
		input.parentNode.insertBefore(message, null);
		input.parentNode.style.flexWrap = 'wrap';
		const border = input.style.borderColor;
		input.accessFeedback = message;
		input.accessClearFeedback = function() {
			input.style.borderColor = border;
			message.textContent = '';
		};
		input.addEventListener('input', input.accessClearFeedback);
	}
	input.accessFeedback.textContent = text;
	input.style.borderColor = 'var(--error-color-high, #c53030)';
	if (shake && typeof input.animate == 'function')
		input.animate([ { transform: 'translateX(0)' }, { transform: 'translateX(-0.4em)' },
			{ transform: 'translateX(0.4em)' }, { transform: 'translateX(0)' } ], { duration: 300 });
}

function addInput(node) {
	return node?.querySelector('.add-item > input[type="text"], .create-item-input');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('aetherproxy'),
			/* Hints are optional: manual MAC input works after lookup failure. */
			L.resolveDefault(network.getHostHints(), null)
		]);
	},

	render: function(data) {
		this.candidates = model.mac_candidates(data[1]);
		this.map = this.buildMap();
		return this.map.render();
	},

	unlistedPolicy: function() {
		return this.unlistedOption.formvalue('main') || uci.get('aetherproxy', 'main', 'unlisted_policy') || 'follow';
	},

	updateNotice: function() {
		if (this.notice)
			this.notice.textContent = model.unlisted_notice(this.unlistedPolicy(),
				uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn');
	},

	/* Read unsaved inline edits too; moving existing DOM rows preserves widgets.
	   No uci.move() or whole-map rerender is allowed for presentation sorting. */
	updateRows: function() {
		if (!this.tableNode)
			return;

		const self = this;
		const rows = Array.from(this.tableNode.querySelectorAll('tr[data-sid]'));
		const hosts = uci.sections('aetherproxy', 'host').map(function(host) {
			const current = Object.assign({}, host);
			for (const key of [ 'enabled', 'policy', 'udp' ]) {
				const option = self.hostSection.children.find((o) => o.option == key);
				current[key] = option.formvalue(host['.name']) ?? host[key];
			}
			return current;
		});

		for (const host of model.sort_hosts(hosts)) {
			const row = rows.find((r) => r.getAttribute('data-sid') == host['.name']);
			if (!row)
				continue;

			const inactive = model.ineffective(host, this.unlistedPolicy());
			row.style.opacity = inactive ? '0.6' : '';
			row.style.whiteSpace = 'nowrap';
			const cell = row.querySelector('[data-name="policy"]');
			let note = cell.querySelector('[data-access-note]');
			if (!note) {
				note = E('span', { 'data-access-note': '1' });
				cell.appendChild(note);
			}
			/* The space stays outside the msgid: po2lmo keeps it but _() trims it (X3). */
			note.textContent = inactive
				? ' ' + _('(same as unlisted devices; has no effect)', 'aether-proxy') : '';
			row.parentNode.appendChild(row);
		}
	},

	buildMap: function() {
		const self = this;
		const m = new form.Map('aetherproxy', _('Access Control', 'aether-proxy'),
			_('Set the policy for each LAN device and for devices that are not listed.', 'aether-proxy'));
		const renderContents = m.renderContents.bind(m);
		/* Section rendering builds detached nodes; formvalue() still searches
		   the old Map root then. Wait for replacement so modal saves and resets
		   read the new widgets, not the previous inline policy/game-mode values. */
		m.renderContents = function() {
			return renderContents().then(function(node) {
				self.updateRows();
				return node;
			});
		};
		this.addMainOptions(m);
		this.addHostOptions(m);
		for (const section of m.children)
			form_defaults.section(section, null, { udp: { clear_inactive: true } });
		return m;
	},

	addMainOptions: function(m) {
		const self = this;
		const s = m.section(form.NamedSection, 'main', 'global');
		let o;
		s.description = [
			_('To proxy all devices, set Unlisted devices to Follow default mode, then set exceptions below to Direct.',
				'aether-proxy'),
			_('To proxy only some devices, set Unlisted devices to Direct, then list the devices to proxy below.',
				'aether-proxy')
		].join(' ');
		o = s.option(form.DummyValue, '_mode', _('Default mode', 'aether-proxy'));
		o.cfgvalue = function() {
			return model.mode_text(uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn');
		};

		o = this.unlistedOption = s.option(form.ListValue, 'unlisted_policy', _('Unlisted devices', 'aether-proxy'));
		o.value('follow', model.unlisted_text('follow'));
		o.value('direct', model.unlisted_text('direct'));
		o.default = 'follow';
		o.onchange = function() {
			self.updateNotice();
			self.updateRows();
		};
		o = s.option(form.DummyValue, '_notice');
		o.renderWidget = function() {
			self.notice = E('span', {}, model.unlisted_notice(
				uci.get('aetherproxy', 'main', 'unlisted_policy') || 'follow',
				uci.get('aetherproxy', 'main', 'mode') || 'bypass_cn'));
			return self.notice;
		};

	},

	inlineFlag: function(option) {
		const renderFrame = option.renderFrame;
		option.renderFrame = function(id, in_table, index, nodes) {
			const frame = renderFrame.call(this, id, in_table, index, nodes);
			if (in_table) {
				// Editable flags have two block divs; read-only GridSection cells have neither.
				const field = frame.querySelector('[data-field]');
				field.style.display = field.classList.contains('hidden') ? 'none' : 'inline';
				const checkbox = frame.querySelector('.cbi-checkbox');
				checkbox.style.display = 'inline-flex';
				checkbox.style.alignItems = 'center';
			}
			return frame;
		};
		const setActive = option.setActive;
		option.setActive = function(id, active) {
			const changed = setActive.call(this, id, active);
			const field = this.map.findElement('data-field', this.cbid(id));
			// Bootstrap's .hidden has no !important: do not let our inline display unhide Game mode.
			// Modal frames keep the theme's own grid layout and dependency styling.
			if (field?.parentNode.matches('td'))
				field.style.display = active ? 'inline' : 'none';
			return changed;
		};
	},

	/* Capture before SDK click/Enter handlers: dropdown creation happens on the
	   input itself, before a bubbling listener on DynamicList could reject it. */
	listFeedback: function(option, validate) {
		/* Whitespace in an optional add box is not pending content. Stored
		   whitespace list items are still rejected by the whole-host model. */
		option.validate = function(sid, value) {
			return typeof value == 'string' && !value.trim() ? true : validate(value);
		};
		const renderWidget = option.renderWidget;
		option.renderWidget = function() {
			const node = renderWidget.apply(this, arguments);
			const attempt = function(ev) {
				const input = addInput(node);
				const enter = ev.type == 'keydown' && ev.keyCode == 13 && ev.target == input;
				const plus = ev.type == 'click' && ev.target.closest('.cbi-button-add');
				if (!input || (!enter && !plus))
					return;
				const error = validate(input.value);
				if (error !== true) {
					ev.preventDefault();
					ev.stopPropagation();
					inputError(input, error);
				}
			};
			node.addEventListener('click', attempt, true);
			node.addEventListener('keydown', attempt, true);
			/* SDK sets tooltip attributes before dispatching these bubbling events.
			   Only add boxes use inline reasons; stored items and other fields
			   keep stock LuCI tooltips. Typing must not trigger the action shake. */
			node.addEventListener('validation-failure', function(ev) {
				const input = addInput(node);
				if (ev.target != input)
					return;
				input.removeAttribute('data-tooltip');
				input.removeAttribute('data-tooltip-style');
				ui.hideTooltip({ target: input });
				inputError(input, ev.detail.message, false);
			});
			node.addEventListener('validation-success', function(ev) {
				const input = addInput(node);
				if (ev.target == input) {
					ui.hideTooltip({ target: input });
					input.accessClearFeedback?.();
				}
			});
			return node;
		};
	},

	/* SDK creation and arrow navigation require the custom entry to remain last.
	   Both themes turn the open list into a block; override only this instance
	   after SDK clones its closed preview, and restore layout on close.
	   A column keeps full-width rows with stretch, as the block layout did. */
	deviceInputFirst: function(option) {
		const renderWidget = option.renderWidget;
		option.renderWidget = function() {
			const node = renderWidget.apply(this, arguments);
			const input = node.querySelector('.create-item-input');
			if (!input)
				return node;
			const item = input.closest('li');
			const list = item.parentNode;
			item.style.order = '-1';
			/* SDK's optional Combobox inserts li[placeholder] without data-value.
			   Keep it above the custom entry so SDK's selected-item scroll is 0. */
			const placeholder = list.querySelector('li[placeholder], li[data-value=""]');
			if (placeholder)
				placeholder.style.order = '-2';
			const dropdown = dom.findClassInstance(input.closest('.cbi-dropdown'));
			const open = dropdown.openDropdown;
			const close = dropdown.closeDropdown;
			const layout = [ list.style.display, list.style.flexDirection, list.style.alignItems ];
			dropdown.openDropdown = function() {
				const result = open.apply(this, arguments);
				list.style.display = 'flex';
				list.style.flexDirection = 'column';
				list.style.alignItems = 'stretch';
				return result;
			};
			dropdown.closeDropdown = function() {
				const result = close.apply(this, arguments);
				[ list.style.display, list.style.flexDirection, list.style.alignItems ] = layout;
				return result;
			};
			return node;
		};
	},

	addHostOptions: function(m) {
		const self = this;
		let o;
		const Hosts = form.GridSection.extend({
			cfgsections: function() {
				return model.sort_hosts(uci.sections('aetherproxy', 'host')).map((h) => h['.name']);
			},
			handleModalSave: function(modalMap, ev) {
				/* Precheck before parse(): parsing may already write earlier
				   fields, even when a later widget rejects the save. */
				const result = self.validateModal(modalMap);
				if (result.errors.length) {
					self.showErrors(result.errors, modalMap);
					return Promise.resolve();
				}

				/* This page has one modal level. Keep the SDK save → parent
				   reload/reset → cancel(isSaving) sequence, but report failures
				   explicitly and warn only after a successful session save. */
				return modalMap.save(null, true)
					.then(() => this.map.load())
					.then(() => this.map.reset())
					.then(() => this.handleModalCancel(modalMap, ev, true))
					.then(() => self.showWarnings(result.warnings))
					.catch((e) => self.showModalError(modalMap, E('p', {}, e?.message || String(e))));
			},
			renderSectionAdd: function() { return E([]); },
			renderRowActions: function(id) {
				const td = form.GridSection.prototype.renderRowActions.call(this, id);
				const actions = td.lastChild;
				// Keep intrinsic button widths without changing the theme's narrow-screen card layout.
				for (const button of actions.childNodes)
					button.style = (button.style?.cssText ?? '') + ';white-space:nowrap';
				actions.style = 'display:flex; flex-wrap:nowrap; gap:0.25em; align-items:center';
				return td;
			},
			renderContents: function(ids, nodes) {
				const node = form.GridSection.prototype.renderContents.call(this, ids, nodes);
				node.insertBefore(E('div', {
					style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
						+ 'flex-wrap:wrap; margin:0.5em 0 1em'
				}, E('button', {
					'class': 'cbi-button cbi-button-add',
					'click': ui.createHandlerFn(this, 'handleAdd'),
					'disabled': this.map.readonly || null
				}, _('Add', 'aether-proxy'))), node.querySelector('table'));
				self.tableNode = node;
				return node;
			}
		});
		const s = this.hostSection = m.section(Hosts, 'host');
		s.anonymous = true;
		s.addremove = true;
		s.nodescriptions = true;

		o = s.option(form.Flag, 'enabled', _('Enabled', 'aether-proxy'));
		this.inlineFlag(o);
		o.editable = true;
		o.default = '1';
		o.onchange = function() { self.updateRows(); };

		o = s.option(form.Value, 'name', _('Name', 'aether-proxy'));
		o.rmempty = true;
		const nameValue = o.formvalue;
		o.formvalue = function(sid) {
			const value = nameValue.call(this, sid);
			const mac = this.map.lookupOption('mac', sid)?.[0].formvalue(sid);
			const saved = uci.get('aetherproxy', sid, 'mac');
			/* Selecting a different device still supplies its suggested name.
			 * An untouched unnamed rule must not acquire a name merely on Save. */
			if (!value && !form_defaults.equal(mac, saved))
				return model.default_name(mac, self.candidates) || value;
			return value;
		};
		/* GridSection modals save independently of the page footer. Fill the
		   name in both write/remove paths, including an empty optional field. */
		o.write = function(sid, value) {
			const mac = this.map.lookupOption('mac', sid)?.[0].formvalue(sid);
			const name = value || model.default_name(mac, self.candidates);
			if (name)
				uci.set('aetherproxy', sid, 'name', name);
			else
				uci.unset('aetherproxy', sid, 'name');
		};
		o.remove = function(sid) { return this.write(sid, ''); };

		/* Keep both match inputs together in the modal, absent from the table.
		   DynamicList allows manual/multiple MACs; never copy DHCP IPs to ip. */
		o = s.option(form.DynamicList, 'mac', _('Device', 'aether-proxy'));
		o.modalonly = true;
		o.rmempty = true;
		this.listFeedback(o, model.validate_mac);
		this.deviceInputFirst(o);
		for (const c of self.candidates)
			o.value(c.mac, c.label);

		o = s.option(form.DummyValue, '_devices', _('Device', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(sid) {
			const summary = model.device_summary(uci.get('aetherproxy', sid), self.candidates);
			return E('span', { title: summary.title, style: 'white-space:nowrap' }, summary.text);
		};

		o = s.option(form.DynamicList, 'ip', _('IP / range / subnet (optional)', 'aether-proxy'));
		o.modalonly = true;
		o.rmempty = true;
		this.listFeedback(o, model.validate_ip);
		o.description = _('%s %s', 'aether-proxy').replace('%s', _(
			'Match MAC or IP (either suffices). Use IP for fixed addresses, subnets or devices behind a router.',
			'aether-proxy')).replace('%s', _(
			'Single 192.168.8.250; range 192.168.8.250-192.168.8.254; subnet 192.168.8.0/24.',
			'aether-proxy'));

		o = s.option(form.ListValue, 'policy', _('Policy', 'aether-proxy'));
		o.editable = true;
		o.default = 'follow';
		for (const policy of [ 'follow', 'direct', 'bypass_cn', 'gfw', 'proxy' ])
			o.value(policy, model.policy_text(policy));
		o.description = _(
			'DNS uses the default mode. Web pages and most apps connect by domain name through the node.',
			'aether-proxy');
		o.onchange = function() { self.updateRows(); };

		o = s.option(form.Flag, 'udp', _('Game mode', 'aether-proxy'));
		this.inlineFlag(o);
		o.editable = true;
		o.default = '0';
		for (const policy of [ 'follow', 'proxy', 'bypass_cn', 'gfw' ])
			o.depends({ policy: policy });
		o.onchange = function() { self.updateRows(); };

	},

	handleSave: function(ev) {
		return this.saveChecked(false);
	},

	handleSaveApply: function(ev) {
		return this.saveChecked(true);
	},

	saveChecked: function(apply_after_save) {
		const self = this;
		return this.map.parse().then(function() {
			const result = model.validate(uci.sections('aetherproxy', 'host'));
			const errors = result.errors;
			if (errors.length > 0) {
				self.showErrors(errors);
				return;
			}

			self.showWarnings(result.warnings);

			return uci.save().then(function() {
				if (apply_after_save)
					return ui.changes.apply(true);
				return self.map.reset();
			});
		}).catch(function(e) {
			/* Widget validation failures must remain visible, like stock save. */
			ui.addNotification(null, E('p', {}, e?.message || String(e)), 'error');
		});
	},

	validateModal: function(modalMap) {
		const sid = modalMap.section;
		const current = Object.assign({}, uci.get('aetherproxy', sid));
		const errors = [];
		modalMap.checkDepends();
		for (const option of modalMap.children[0].children) {
			const key = option.option;
			if (!option.isActive(sid)) {
				if (!option.retain)
					delete current[key];
				continue;
			}
			/* SDK getValue includes valid pending plain text but drops dropdown
			   text. Inspect both DOM shapes before either can be parsed. */
			if (key == 'ip' || key == 'mac') {
				const input = addInput(option.getUIElement(sid)?.node);
				if (input?.value.trim()) {
					const text = model.pending_text(key, input.value);
					errors.push({ text: text });
					inputError(input, text);
					/* The widget validates this same pending value too; do not
					   repeat its error without the short field name below. */
					continue;
				}
			}
			if (!option.isValid(sid))
				errors.push({ text: option.getValidationError(sid) });
			current[key] = option.formvalue(sid);
		}
		const hosts = uci.sections('aetherproxy', 'host');
		const nameError = model.validate_name(current, hosts);
		if (nameError) {
			errors.push({ text: nameError });
			const option = modalMap.lookupOption('name', sid)[0];
			inputError(option.getUIElement(sid)?.node.querySelector('input'), nameError);
		}
		if (errors.length)
			return { errors: errors, warnings: [] };

		/* Replace, never append: a rule must not conflict with its old values.
		   Other rules come from the session; modal options are cloned and
		   their current values must not be read from the parent Map. */
		return model.validate(hosts.map((host) => host['.name'] == sid ? current : host), sid);
	},

	showWarnings: function(warnings) {
		if (warnings.length)
			ui.addNotification(null, E('ul', {}, warnings.map((w) => E('li', {}, w.text))), 'warning');
	},

	showErrors: function(errors, modalMap) {
		const content = E('div', {}, [
			E('p', {}, _('The host configuration has %s error(s); nothing was saved.', 'aether-proxy')
				.replace('%s', errors.length)),
			E('ul', {}, errors.map((e) => E('li', {}, e.text)))
		]);
		if (modalMap)
			this.showModalError(modalMap, content);
		else
			ui.addNotification(null, content, 'error');
	},

	/* Page notifications go to #maincontent, behind the modal overlay: an open
	   editor shows its own errors at its top, replacing the previous attempt's. */
	showModalError: function(modalMap, content) {
		const root = modalMap.root;
		if (!root) {
			ui.addNotification(null, content, 'error');
			return;
		}
		if (this.modalAlert?.parentNode)
			this.modalAlert.parentNode.removeChild(this.modalAlert);
		this.modalAlert = E('div', { 'class': 'alert-message error' }, content);
		root.insertBefore(this.modalAlert, root.firstChild);
	}
});
