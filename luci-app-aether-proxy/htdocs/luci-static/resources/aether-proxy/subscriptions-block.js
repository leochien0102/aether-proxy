'use strict';
// Bind subscription forms, confirmed deletion and background updates to UCI and shared RPC helpers.
// Design: docs/10「订阅页」「订阅页修正」「作业机制」「UI 规则」「其余页面先出页面」「r12 缺陷修正」.
// Also follows docs/10「订阅：通用设置、获取方式与行首开关」「节点与订阅合并为一页」.
// Global failover follows docs/10「节点故障自动切换」(T16.18).
// r13 pending-state and tooltip rules: docs/10「r13 修正：订阅编辑框与启用开关」.
// Inline feedback and action sizing: docs/10「r13 修正：块内行与表格操作列」.
// Saved disabled state and card alignment: docs/10「r14 修正：订阅已停用时「立即更新」不可用、窄屏卡片」.
// Flag frames follow docs/10「r16 修正：窄屏卡片里开关与标签同一行」.
// Node/subscription preflight follows docs/10 r17 required fields and r18 format-error collection.
// Initial RPC reads only fill cells/placeholders; never redraw an open edit modal for them.
'require baseclass';
'require form';
'require aether-proxy.form-defaults as form_defaults';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.subscriptions as model';

const FAILOVER_RISK = _(
	'Frequent changes to your exit IP may trigger security checks on some sites or apps. Enable only when needed.',
	'aether-proxy');
const FAILOVER_TITLE = _('Automatic failover', 'aether-proxy');
const FAILOVER_INACTIVE = _('The main switch is off; these settings are not active.', 'aether-proxy');
const FAILOVER_MAX_NODES = 64; // Matches NODE_FAILOVER_MAX_NODES in const.uc.
const failoverLimitText = () => _('Automatic failover supports at most %s nodes.', 'aether-proxy')
	.format(FAILOVER_MAX_NODES);
const REQUIRED_COLOR = 'var(--error-color-high, #c53030)';

function requiredValue(map, id, field) {
	// SDK lookupOption searches mounted frames; initial renderFrame runs before
	// they are attached. The cloned section is already complete at that point.
	const option = map.children[0].children.find(option => option.option === field);
	return option?.formvalue(id) ?? option?.cfgvalue(id);
}

function isRequired(option, id, rules) {
	const rule = rules[option.option];
	if (!rule)
		return false;
	const protocol = requiredValue(option.map, id, 'protocol');
	if (rule.protocols && !rule.protocols.includes(protocol))
		return false;
	if (rule.required === true || rule.required?.includes(protocol))
		return true;
	return !!rule.requires_when && requiredValue(option.map, id, rule.requires_when.field) === rule.requires_when.value;
}

function missingRequired(option, id, rules) {
	return isRequired(option, id, rules) && option.isActive(id) && !String(option.formvalue(id) ?? '').trim();
}

function requiredBorder(option, id, invalid) {
	const frame = option.map.findElement('data-field', option.cbid(id));
	for (const input of frame?.querySelectorAll('input, select, textarea') ?? [])
		input.style.borderColor = invalid ? REQUIRED_COLOR : '';
}

function refreshRequired(map, id, rules) {
	for (const option of map.children[0].children) {
		if (option.requiredMarker)
			option.requiredMarker.style.display = isRequired(option, id, rules) ? '' : 'none';
		if (!missingRequired(option, id, rules) && (!option.isActive(id) || option.isValid(id)))
			requiredBorder(option, id, false);
	}
}

/* One page owns both grids. Share their modal-only presentation/preflight here,
 * not in common.js; the pure rule tables remain in their respective models.
 * SDK cloneOptions copies these methods, but not map/section ownership. Always
 * read the cloned map's live widgets, never the parent table or stored UCI. */
function requiredOptions(grid, rules) {
	for (const option of grid.children) {
		if (option.modalonly === false)
			continue;
		const renderFrame = option.renderFrame;
		option.renderFrame = function(id, in_table, index, nodes) {
			const frame = renderFrame.call(this, id, in_table, index, nodes);
			if (!in_table) {
				if (rules[this.option]) {
					this.requiredMarker = E('span', {
						style: 'color:' + REQUIRED_COLOR + ';display:' + (isRequired(this, id, rules) ? '' : 'none')
					}, ' *');
					frame.querySelector('label').appendChild(this.requiredMarker);
				}
				// Runs after the SDK frame's dependency handler, including protocol/security changes.
				frame.addEventListener('widget-change', () => refreshRequired(this.map, id, rules));
			}
			return frame;
		};
	}
	const addModalOptions = grid.addModalOptions;
	grid.addModalOptions = function(section, ...args) {
		if (addModalOptions)
			addModalOptions.call(this, section, ...args);
		section.description = (section.description ? section.description + '<br>' : '')
			+ _('Fields marked with * are required.', 'aether-proxy');
	};
	const save = grid.handleModalSave;
	grid.handleModalSave = function(modalMap, ...args) {
		const id = modalMap.section;
		const options = modalMap.children[0].children;
		const missing = options.filter(option => missingRequired(option, id, rules));
		const invalid = options.filter(option =>
			option.isActive(id) && !missing.includes(option) && !option.isValid(id));
		const errors = missing.map(option => _('%s is required.', 'aether-proxy').format(option.title))
			.concat(invalid.map(option => _('%s: %s', 'aether-proxy').format(option.title, option.getValidationError(id))));
		/* Never parse even the first field until all required and format checks pass:
		 * SDK parse can stage earlier values before a later field rejects. Its
		 * notification would also be hidden behind the still-open modal. */
		if (modalMap.requiredAlert)
			modalMap.requiredAlert.remove();
		for (const option of options)
			requiredBorder(option, id, missing.includes(option) || invalid.includes(option));
		if (errors.length) {
			modalMap.requiredAlert = E('div', { 'class': 'alert-message error' }, [
				E('ul', {}, errors.map(text => E('li', {}, [ text ])))
			]);
			modalMap.root.insertBefore(modalMap.requiredAlert, modalMap.root.firstChild);
			return Promise.resolve();
		}
		return save.call(this, modalMap, ...args);
	};
}

function addressControl(masked, url) {
	// Recreating the cell discards reveal state. The URL is never a link or an attribute.
	const show = _('Click to show full address', 'aether-proxy');
	const hide = _('Click to hide full address', 'aether-proxy');
	let revealed = false;
	const control = E('a', {
		role: 'button',
		tabindex: '0',
		title: show,
		style: 'display:block;color:inherit;text-decoration:none;cursor:pointer;overflow-wrap:anywhere',
		click: () => {
			revealed = !revealed;
			control.textContent = revealed ? url : masked;
			control.setAttribute('title', revealed ? hide : show);
			control.focus({ preventScroll: true });
		},
		keydown: ev => {
			if (ev.key !== 'Enter' && ev.key !== ' ')
				return;
			ev.preventDefault();
			if (!ev.repeat)
				control.click();
		}
	});
	control.textContent = masked;
	return control;
}

return baseclass.extend({
	required_options: requiredOptions,
	failover_risk: FAILOVER_RISK,
	load: function() {
		return uci.load('aetherproxy').then(() => {
			if (!uci.get('aetherproxy', 'sub'))
				uci.add('aetherproxy', 'sub', 'sub');
		});
	},
	render: function(refresh_nodes) {
		this.refresh_nodes = refresh_nodes;
		this.failoverEdits = new Map();
		this.failoverCells = { node: new Map(), subscription: new Map() };
		this.details = null;
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
	failover_enabled: function() {
		const flag = this.generalOptions?.failover;
		return (flag?.getUIElement?.('sub') ? flag.formvalue('sub') : uci.get('aetherproxy', 'sub', 'failover')) === '1';
	},
	failover_nodes: function(kind, id, nodes) {
		if (kind === 'node')
			return uci.get('aetherproxy', id) ? [id] : [];
		return (nodes ?? uci.sections('aetherproxy', 'node'))
			.filter(node => node.source === id).map(node => node['.name']);
	},
	saved_failover: function() {
		return model.failover_ids(uci.get('aetherproxy', 'main', 'failover_nodes'));
	},
	selected_failover: function(saved = this.saved_failover()) {
		const selected = new Set(saved);
		for (const [id, enabled] of this.failoverEdits) {
			if (uci.get('aetherproxy', id))
				enabled ? selected.add(id) : selected.delete(id);
		}
		return selected;
	},
	stage_failover: function(ids, enabled) {
		const saved = this.saved_failover();
		if (enabled) {
			const selected = this.selected_failover(saved);
			if (ids.some(id => !selected.has(id)) && new Set([...selected, ...ids]).size > FAILOVER_MAX_NODES) {
				ui.addNotification(null, E('p', {}, [failoverLimitText()]));
				return;
			}
		}
		for (const id of ids) {
			if (saved.has(id) === enabled)
				this.failoverEdits.delete(id);
			else
				this.failoverEdits.set(id, enabled);
		}
		this.refresh_failover();
	},
	save: async function() {
		// Use the footer save only. Modal saves and immediate RPC jobs must
		// not flush the list draft, and a UCI reload must not overwrite it.
		await this.map.save(() => {
			const saved = this.saved_failover();
			const selected = this.selected_failover(saved);
			if (selected.size === saved.size && [...selected].every(id => saved.has(id)))
				return;
			// A backend import or refresh can grow the base list after editing.
			if (selected.size > FAILOVER_MAX_NODES)
				throw new Error(failoverLimitText());
			if (selected.size)
				uci.set('aetherproxy', 'main', 'failover_nodes', [...selected]);
			else
				uci.unset('aetherproxy', 'main', 'failover_nodes');
		});
		this.failoverEdits.clear();
		this.refresh_failover();
	},
	reset: function() {
		this.failoverEdits.clear();
		return this.map.reset();
	},
	toggle_failover: async function(kind, id) {
		const ids = this.failover_nodes(kind, id);
		const { state, count } = model.failover_state(ids, this.selected_failover());
		if (kind === 'subscription' && state === 'on' && !await ap.confirm({
			title: FAILOVER_TITLE,
			text: _('Remove %s nodes from automatic failover?', 'aether-proxy').format(count),
			ok: _('Off', 'aether-proxy'),
			destructive: true
		}))
			return;
		// A background refresh may have removed IDs while the confirmation was open.
		const remaining = new Set(this.failover_nodes(kind, id));
		this.stage_failover(ids.filter(node => remaining.has(node)), state !== 'on');
	},
	paint_failover_setting: function(active, current, selected) {
		if (!this.failoverSetting)
			return;
		const { widget, description } = this.failoverSetting;
		let text = _('Switch automatically if the current node fails.', 'aether-proxy');
		let title = active ? '' : FAILOVER_INACTIVE;
		if (active) {
			const node = current ? uci.get('aetherproxy', current) : null;
			if (node?.disabled === '1') {
				text = _('The current node is disabled. Automatic failover is inactive.', 'aether-proxy');
				title = text;
			}
			else if (!node || !selected.has(current)) {
				text = _('The current node is not on the list. Automatic failover is inactive.', 'aether-proxy');
				title = _('The current node “%s” is not on the failover list. Add it to the list or turn off the main switch.',
					'aether-proxy').format(node?.label || current || '–');
			}
		}
		widget.setAttribute('title', title);
		description.textContent = text;
		description.setAttribute('style', active ? '' : 'opacity:0.65');
	},
	paint_failover: function(box, status, active, uncheckedHint) {
		const { state, count, total } = status;
		box.setAttribute('aria-checked', state === 'mixed' ? 'mixed' : String(state === 'on'));
		box.setAttribute('class', `aether-tri aether-tri--${state}${active ? '' : ' aether-tri--inactive'}`);
		const hint = state === 'mixed' ? _('Partial · %s/%s', 'aether-proxy').format(count, total)
			: FAILOVER_TITLE;
		const title = active ? hint : hint + ' — ' + FAILOVER_INACTIVE;
		const extra = state === 'off' ? uncheckedHint?.() : null;
		box.setAttribute('title', extra ? title + ' — ' + extra : title);
	},
	refresh_failover: function() {
		if (!this.failoverCells)
			return;
		const nodes = uci.sections('aetherproxy', 'node');
		const selected = this.selected_failover();
		const active = this.failover_enabled();
		this.paint_failover_setting(active, uci.get('aetherproxy', 'main', 'node'), selected);
		for (const [kind, cells] of Object.entries(this.failoverCells)) {
			const ids = new Set((kind === 'node' ? nodes : uci.sections('aetherproxy', 'subscription'))
				.map(section => section['.name']));
			for (const [id, { paint }] of cells) {
				if (!ids.has(id))
					cells.delete(id);
				else
					paint(model.failover_state(
						kind === 'node' ? [id] : this.failover_nodes(kind, id, nodes), selected), active);
			}
		}
	},
	failover_column: function(grid, kind, uncheckedHint) {
		this.failoverEdits ??= new Map();
		this.failoverCells ??= { node: new Map(), subscription: new Map() };
		const o = grid.option(form.DummyValue, '_failover',
			E('span', { 'class': 'aether-failover-title' }, FAILOVER_TITLE));
		o.width = '1%'; // Minimum table width; nowrap keeps the title's intrinsic width.
		o.modalonly = false;
		o.textvalue = id => {
			if (kind === 'subscription' && !uci.get('aetherproxy', id))
				return E('span', {}, [ '–' ]);
			const status = () => model.failover_state(this.failover_nodes(kind, id), this.selected_failover());
			const readonly = grid.map?.readonly;
			const box = E('span', {
				role: 'checkbox',
				tabindex: readonly ? '-1' : '0',
				'aria-label': FAILOVER_TITLE,
				'aria-disabled': readonly ? 'true' : null,
				click: () => {
					if (!readonly)
						return this.toggle_failover(kind, id);
				},
				keydown: ev => {
					if (ev.key !== ' ' && ev.key !== 'Enter')
						return;
					ev.preventDefault();
					if (!ev.repeat)
						return box.click();
				}
			}, E('span', { 'class': 'aether-tri-mark', 'aria-hidden': 'true' }));
			const hint = uncheckedHint ? () => uncheckedHint(id) : null;
			const paint = (state, active) => this.paint_failover(box, state, active, hint);
			this.failoverCells[kind].set(id, { box, paint });
			paint(status(), this.failover_enabled());
			return box;
		};
		const block = this;
		const renderTextValue = grid.renderTextValue;
		grid.renderTextValue = function(id, option) {
			const cell = renderTextValue.call(this, id, option);
			const box = cell.firstChild;
			if (option === o && box === block.failoverCells[kind].get(id)?.box && !this.map?.readonly) {
				cell.setAttribute('style', 'cursor:pointer');
				cell.addEventListener('click', ev => {
					// The control and its mark already go through the control's click handler.
					if (ev.target === cell)
						return box.click();
				});
			}
			return cell;
		};
	},
	failover_modal: function(grid) {
		const o = grid.option(form.Flag, '_failover_edit', FAILOVER_TITLE);
		o.modalonly = true;
		o.rmempty = true;
		const renderWidget = o.renderWidget;
		const block = this;
		o.renderWidget = function(id, index) {
			const active = block.failover_enabled();
			this.initialFailover = model.failover_state(block.failover_nodes('subscription', id),
				block.selected_failover()).state;
			this.failoverTouched = false;
			const widget = renderWidget.call(this, id, index, this.initialFailover === 'on' ? '1' : '0');
			return active ? widget : E('div', { style: 'opacity:0.65', title: FAILOVER_INACTIVE }, [widget]);
		};
		o.onchange = function() { this.failoverTouched = true; };
		o.write = function(id) { this.map.failoverChoice = { id, enabled: true }; };
		o.remove = function(id) {
			// An untouched binary flag must not clear a partial selection.
			this.map.failoverChoice = this.isActive(id) && (this.initialFailover === 'on' || this.failoverTouched)
				? { id, enabled: false } : null;
		};
		const cancel = grid.handleModalCancel;
		grid.handleModalCancel = function(modalMap, ev, isSaving) {
			const choice = modalMap.failoverChoice;
			delete modalMap.failoverChoice;
			return Promise.resolve(cancel.call(this, modalMap, ev, isSaving)).then(() => {
				if (isSaving && choice)
					block.stage_failover(block.failover_nodes('subscription', choice.id), choice.enabled);
			});
		};
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
		const s = m.section(form.NamedSection, 'sub', 'sub');
		const renderSection = s.render;
		s.render = function(...args) {
			return renderSection.apply(this, args).then(content => {
				// LuCI renders the label only when the option title is a string.
				const title = content.querySelector('[data-name="failover"] > .cbi-value-title');
				if (title) {
					title.appendChild(E('span', {
						'class': 'aether-warning',
						role: 'img',
						tabindex: '0',
						title: FAILOVER_RISK,
						'aria-label': FAILOVER_RISK,
						style: 'cursor:help; margin-left:0.35em; opacity:0.85',
						click: ev => {
							// The SDK label forwards clicks to the switch; the warning must not.
							ev.stopPropagation();
							ev.preventDefault();
						}
					}, [ '⚠' ]));
				}
				content.classList?.remove('cbi-section');
				return ap.section({ title: _('General settings', 'aether-proxy'), body: content });
			});
		};
		this.generalOptions = {
			interval_hours: this.setting_option(s, 'interval_hours', _('Update interval', 'aether-proxy'), false),
			fetch_via: this.setting_option(s, 'fetch_via', _('Fetch method', 'aether-proxy'), false),
			user_agent: this.setting_option(s, 'user_agent', _('User agent', 'aether-proxy'), false)
		};
		const failover = s.option(form.Flag, 'failover', FAILOVER_TITLE);
		failover.default = '0';
		failover.rmempty = true;
		const renderWidget = failover.renderWidget;
		const block = this;
		failover.renderWidget = function(id, index, value) {
			const widget = renderWidget.call(this, id, index, value);
			const description = E('span');
			block.failoverSetting = { widget, description };
			block.paint_failover_setting(value === '1', uci.get('aetherproxy', 'main', 'node'), block.selected_failover());
			widget.setAttribute('style', 'display:inline-flex; align-items:center');
			return E('div', {
				'class': 'aether-failover-setting',
				style: 'display:inline-flex; align-items:center; gap:0.5em; vertical-align:middle'
			}, [widget, description]);
		};
		failover.onchange = () => this.refresh_failover();
		this.generalOptions.failover = failover;
		form_defaults.section(s, { user_agent: () => this.defaultUA });
	},
	result_content: function(result) {
		/* Subscription names and backend detail text are user input, so each line
		 * is appended as a text child (a bare string would be innerHTML; a nested
		 * array would be stringified by luci-base's append). */
		const lines = [result.text, result.time, result.skipped].filter(Boolean);
		return lines.flatMap((line, index) => [
			...(index ? [E('br')] : []),
			E('span', { style: lines.length === 1 ? 'white-space:nowrap' : null }, [line])
		]);
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
		const renderFrame = enabled.renderFrame;
		enabled.renderFrame = function(id, in_table, index, nodes) {
			const frame = renderFrame.call(this, id, in_table, index, nodes);
			if (in_table) {
				// Both SDK divs break after proton2025's inline card label; a widget-only wrapper cannot fix it.
				frame.querySelector('[data-field]').style.display = 'inline';
				const checkbox = frame.querySelector('.cbi-checkbox');
				checkbox.style.display = 'inline-flex';
				checkbox.style.alignItems = 'center';
			}
			return frame;
		};
		enabled.onchange = function() {
			// uci.changes() cannot see a widget change before the form is saved.
			self.sync_buttons();
		};
		const columns = [
			['_name', _('Name', 'aether-proxy')], ['_address', _('Address', 'aether-proxy')],
			['_interval', _('Update interval', 'aether-proxy')],
			['_via', _('Fetch method', 'aether-proxy')], ['_failover', FAILOVER_TITLE],
			['_result', _('Last result', 'aether-proxy')]
		];
		for (const [field, title] of columns) {
			if (field === '_failover') {
				this.failover_column(s, 'subscription');
				continue;
			}
			const o = s.option(form.DummyValue, field, title);
			o.modalonly = false;
			o.textvalue = function(id) {
				const subscription = uci.get('aetherproxy', id);
				const row = model.row(subscription, self.status, Date.now() / 1000,
					self.busy, uci.get('aetherproxy', 'sub'));
				if (!row)
					return E('span', {}, [ '–' ]);
				if (field === '_address')
					return addressControl(row.address, subscription.url);
				if (field === '_result') {
					// An edit can make GridSection render cells again on the same map.
					// Keep the value wrapper mounted when fetched status changes.
					const span = E('span', { style: 'display:inline-block; vertical-align:top' },
						self.result_content(row.result));
					self.resultCells[id] = span;
					return span;
				}
				/* A string textvalue is rendered as HTML by luci-base (docs/10 「UI 规则」). */
				return E('span', {}, [ row[field.slice(1)] ]);
			};
			if (field === '_address') {
				const renderTextValue = s.renderTextValue;
				s.renderTextValue = function(id, option) {
					const cell = renderTextValue.call(this, id, option);
					const control = cell.firstChild;
					if (option === o && control?.getAttribute('role') === 'button') {
						cell.setAttribute('style', 'cursor:pointer');
						cell.addEventListener('click', ev => {
							// Include the cell padding without double-toggling on bubbled control clicks.
							if (ev.target === cell)
								control.click();
						});
					}
					return cell;
				};
			}
		}
	},
	redraw: function() {
		const self = this;
		this.pendingIds ??= new Set();
		this.changesGeneration ??= 0;
		this.resultCells = {};
		this.statusError = E('span', { style: 'margin:0' });
		this.rowButtons = new Map();
		this.rowWrappers = new Map();
		const m = new form.Map('aetherproxy');
		this.map = m;
		const renderContents = m.renderContents;
		m.renderContents = function(...args) {
			return renderContents.apply(this, args).then(content => {
				// Footer Reset and modal saves may replace the flag widget without firing onchange.
				self.sync_buttons();
				self.refresh_failover();
				return content;
			});
		};
		this.general_settings(m);
		const s = m.section(form.GridSection, 'subscription');
		this.grid = s;
		s.addremove = true;
		s.anonymous = true;
		s.render = function(...args) {
			self.rowButtons = new Map();
			self.rowWrappers = new Map();
			return this.super('render', args).then(content => {
				// Collapse only the list; keep the heading and tools available.
				content.classList?.remove('cbi-section');
				const open = self.details?.open ?? true;
				const listTitle = _('Subscription list', 'aether-proxy');
				self.details = E('details', { 'class': 'aether-subscription-list', open: open || null }, [
					E('summary', { style: 'margin-bottom:0.5em' }, listTitle),
					E('div', {
						'class': 'aether-subscription-scroll',
						style: 'max-width:100%; overflow-x:auto',
						tabindex: 0, role: 'region', 'aria-label': listTitle
					}, [content])
				]);
				const block = ap.section({
					title: _('Subscriptions', 'aether-proxy'),
					description: _('Manage subscriptions and update their nodes.', 'aether-proxy'),
					actions: self.update_controls(),
					body: self.details
				});
				self.refresh_changes();
				return block;
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
		o = s.option(form.Value, 'url', _('Subscription URL', 'aether-proxy')); o.password = true;
		o.modalonly = true;
		o.rmempty = false;
		o.validate = function(id, value) { return model.validate_url(value); };
		this.setting_option(s, 'interval_hours', _('Update interval', 'aether-proxy'), true);
		this.setting_option(s, 'fetch_via', _('Fetch method', 'aether-proxy'), true);
		this.failover_modal(s);
		this.setting_option(s, 'user_agent', _('User agent', 'aether-proxy'), true);
		form_defaults.section(s);
		requiredOptions(s, model.required_fields);
		return m.render().then(content => {
			dom.content(self.root, content);
			self.show_results();
		});
	},
	update_controls: function() {
		this.updateAll = E('button', {
			'class': 'btn cbi-button cbi-button-action', 'disabled': this.busy || null,
			'click': ui.createHandlerFn(this, 'update', [])
		}, _('Update all', 'aether-proxy'));
		this.pendingHint = E('span');
		return [ this.statusError, this.progress, this.summary, this.pendingHint, this.updateAll,
			E('button', {
				'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(this, 'add')
			}, _('Add', 'aether-proxy')) ];
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
			this.summary.replaceChildren(...lines.map(text => E('div', { style: 'margin:0' }, [ text ])));
			if (lines.length)
				ui.addNotification(null, E('div', {}, lines.map(text => E('p', {}, [ text ]))));
			// unload is synchronous in luci-base; only load returns a Promise.
			uci.unload('aetherproxy');
			const data = await Promise.all([this.load(), ap.call('sub_status')]);
			this.status = data[1];
			this.refresh_failover();
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
