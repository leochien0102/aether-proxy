'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require dom';
'require aether-proxy.common as ap';
'require aether-proxy.model.nodes as model';

/*
 * Nodes page (docs/10 「节点页」, docs/tasks/m8.md T8.5).
 *
 * The view only fetches data (uci + ap.call('probe_results')), hands it to the
 * pure model and renders what the model returns: row texts, the TCP
 * reachability column wording, the progress line and the allowed per-row
 * operations are all decided in the model. Probing runs through ap.run_job()
 * (docs/10 「作业机制」); after every job status update the probe results are
 * fetched once and the probe column and progress line are refreshed. Setting a
 * node as current uses node_use without applying session changes, then rereads
 * UCI and runtime status (docs/10 「检测真实延迟与切换节点」). Node edits use the
 * GridSection modal and form.Map's standard save flow. Probe recovery follows docs/10 「UI 规则」.
 * Defer the first result read until after rendering (docs/10 「其余页面先出页面」).
 * Row actions and immediate probe feedback follow docs/10 「节点页修正」 (T10.19).
 * Editing, multi-delete and bounded switch locking follow 「节点页第二轮修正」 (T10.25).
 * Manual additions and separate protocol columns follow 「添加节点」「节点表的协议列」 (T10.26).
 * Collapsible bulk imports retain input and results across redraws (「节点页第三轮修正」, T10.29).
 * Transport, security and Mux modal options follow 「节点编辑框新字段」 (T10.30).
 * Synchronous UCI unload and switch-banner cleanup follow 「r12 缺陷修正」 (T10.32).
 */

return view.extend({
	load: function() {
		return uci.load('aetherproxy');
	},

	render: function() {
		this.results = undefined;
		this.resultsRequest = 0;
		this.probing = false;
		this.pendingProbes = [];
		this.selectedNodes = new Set();

		const root = E('div', { 'class': 'cbi-map' });
		this.root = root;
		const self = this;

		return this.buildPage().then(function(content) {
			dom.content(root, content);
			self.updateProbeColumns();
			window.setTimeout(() => {
				self.refreshResults();
				self.refreshSwitchStatus();
			}, 0);
			return root;
		});
	},

	/* Re-fetches the page data (used after imports added nodes) and rebuilds
	   the whole page in place. */
	rebuild: function() {
		const self = this;
		// Import can finish while the initial read is still in flight.
		this.resultsRequest = (this.resultsRequest ?? 0) + 1;

		// unload is synchronous in luci-base; only load returns a Promise.
		uci.unload('aetherproxy');
		return Promise.all([
			uci.load('aetherproxy'),
			ap.call('probe_results')
		]).then(function(res) {
			if ((res[1] && res[1].ok !== false) || self.results === undefined)
				self.results = res[1] ?? { ok: false, code: 'RPC_FAILED' };

			return self.buildPage().then(function(content) {
				dom.content(self.root, content);
				self.updateProbeColumns();
			});
		});
	},

	buildPage: function() {
		this.clearSwitchNotification();
		const self = this;
		const vm = model.build(
			uci.sections('aetherproxy', 'node'),
			uci.get('aetherproxy', 'main', 'node'),
			uci.sections('aetherproxy', 'subscription'),
			this.results
		);

		this.rowMap = {};
		for (const row of vm.rows)
			this.rowMap[row.id] = row;

		this.probeCells = {};
		this.probeButtons = [];
		this.switchButtons = [];
		this.selectionBoxes = {};

		this.progressEl = E('div', { 'class': 'cbi-map-descr' });

		// Rebuilds after imports, additions or switching must not discard bulk-import input.
		const importValue = this.importText?.value ?? '';
		const importOpen = this.importDetails?.open ?? false;
		this.importResult ??= E('div', {});
		this.importText = E('textarea', {
			'class': 'cbi-input-textarea',
			'rows': 4,
			'placeholder': _('One node share URI per line.', 'aether-proxy')
		});

		this.importText.value = importValue;

		const importBox = E('details', { 'class': 'cbi-section' }, [
			E('summary', {}, _('Batch import share links', 'aether-proxy')),
			E('p', {}, _('Import multiple lines at once, one link per line, directly into the node list.',
				'aether-proxy')),
			this.importText,
			E('div', {
				style: 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
					+ 'flex-wrap:wrap; margin:0.5em 0 1em'
			}, [ this.importResult, E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(self, 'handleImport')
			}, [ _('Import', 'aether-proxy') ]) ])
		]);
		this.importDetails = importBox;
		importBox.open = importOpen;

		const probeAll = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(self, 'handleProbeAll'),
			'disabled': this.probing || null
		}, [ _('Probe all', 'aether-proxy') ]);
		this.probeButtons.push(probeAll);

		this.deleteSelected = E('button', {
			'class': 'btn cbi-button cbi-button-remove',
			'disabled': true,
			// Keep the selection-dependent disabled state after the promise settles.
			'click': () => self.handleDeleteSelected()
		}, _('Delete selected', 'aether-proxy'));
		const addNode = E('button', {
			'class': 'btn cbi-button cbi-button-add',
			'click': ui.createHandlerFn(self, 'handleAddNode')
		}, _('Add node', 'aether-proxy'));
		const controls = E('div', {
			'style': 'display:flex; justify-content:flex-end; align-items:center; gap:0.5em; '
				+ 'flex-wrap:wrap; margin:0.5em 0 1em'
		}, [ this.progressEl, probeAll, this.deleteSelected, addNode ]);

		const mapNodePromise = this.buildMap().render();

		return mapNodePromise.then(function(mapNode) {
			self.updateSelection();
			return E('div', {}, [
				E('h2', {}, _('Nodes', 'aether-proxy')),
				E('div', { 'class': 'cbi-map-descr' }, _('Manage the proxy nodes, probe their TCP reachability and import node share links.', 'aether-proxy')),
				controls,
				mapNode,
				importBox
			]);
		});
	},

	buildMap: function() {
		const self = this;
		const rowMap = this.rowMap;
		let m, s, o;

		m = new form.Map('aetherproxy');
		this.nodeMap = m;

		s = m.section(form.GridSection, 'node');
		this.nodeGrid = s;
		s.addremove = true;
		// Keep the named UCI IDs, but do not expose a redundant section-name column.
		s.anonymous = true;

		/* Both manual addition and URI import create named node IDs. The grid's
		   generic add button would create an anonymous section instead. */
		s.renderSectionAdd = function() {
			return E([]);
		};

		/* The per-row operations: 设为当前 / 检测 come first, then the built-in
		   Edit and Delete buttons of the grid section. */
		s.renderRowActions = function(section_id) {
			const tdEl = this.super('renderRowActions', [ section_id, _('Edit', 'aether-proxy') ]);
			const row = rowMap[section_id];
			const extra = [];

			if (row && row.can_set_current) {
				const button = E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					/* Not createHandlerFn: it returns nothing and re-enables the button
					   when done, which would undo the switch lock. handleSetCurrent
					   disables the buttons and restores them itself. */
					'click': ev => self.handleSetCurrent(section_id, ev)
				}, [ _('Set as current', 'aether-proxy') ]);
				self.switchButtons.push(button);
				self.updateSwitchButtons();
				extra.push(button);
			}

			const probeBtn = E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'title': _('Probe the TCP reachability of this node', 'aether-proxy'),
				'click': ui.createHandlerFn(self, 'handleProbeOne', section_id),
				'disabled': self.probing || null
			}, [ _('Probe', 'aether-proxy') ]);
			self.probeButtons.push(probeBtn);
			extra.push(probeBtn);

			/* LuCI may supply only Delete, or Edit and Delete. Select by class,
			   not position; keep the original nodes and their event handlers. */
			const keep = Array.from(tdEl.lastChild.childNodes).filter(node =>
				!(row && !row.can_delete && node.classList?.contains('cbi-button-remove')));

			// Keep Edit ahead of Delete even if the parent adds actions in another order.
			keep.sort((a, b) => Number(a.classList?.contains('cbi-button-remove'))
				- Number(b.classList?.contains('cbi-button-remove')));
			const actions = [ ...extra, ...keep ];
			// Set nowrap on each button too, so theme rules cannot override inheritance.
			for (const button of actions)
				button.style = (button.style?.cssText ?? '') + ';white-space:nowrap';

			dom.content(tdEl, E('div', {
				'style': 'display:flex; flex-wrap:nowrap; gap:0.25em; align-items:center'
			}, actions));

			return tdEl;
		};

		/* Delete requires a confirmation (docs/10 「UI 规则」); the built-in
		   handler removes silently, so it is wrapped here. The model decides
		   whether the row may be deleted at all. */
		s.handleRemove = async function(section_id, ev) {
			const row = rowMap[section_id];

			if (row && !row.can_delete) {
				ui.addNotification(null, E('p', _('The current node cannot be deleted.', 'aether-proxy')));
				return;
			}

			if (!await ap.confirm({
				title: _('Delete node', 'aether-proxy'),
				text: _('Really delete this node?', 'aether-proxy'),
				ok: _('Delete', 'aether-proxy'),
				destructive: true
			}))
				return;

			self.selectedNodes?.delete(section_id);
			return Promise.resolve(this.super('handleRemove', [ section_id, ev ]))
				.finally(() => {
					if (self.deleteSelected)
						self.updateSelection();
				});
		};

		/* Call the captured GridSection handlers, not this.super(): an instance
		   override's super would skip GridSection and lose addedSection cleanup.
		   Its Cancel removes a new section; isSaving preserves it after Save.
		   Never unload UCI here: that would discard unrelated session edits. */
		const cancelModal = s.handleModalCancel;
		const saveModal = s.handleModalSave;
		s.handleModalCancel = function(modalMap, ev, isSaving) {
			const added = self.pendingAdd;
			self.pendingAdd = null;
			return Promise.resolve(cancelModal.call(this, modalMap, ev, isSaving))
				.then(async () => {
					if (added && isSaving) {
						// Refresh the row model; buildPage retains the unrelated bulk-import state.
						dom.content(self.root, await self.buildPage());
						self.updateProbeColumns();
					}
				});
		};
		s.handleModalSave = function(...args) {
			const added = self.pendingAdd;
			if (added)
				added.saving = true;
			return Promise.resolve(saveModal.apply(this, args)).finally(() => {
				if (added)
					added.saving = false;
			});
		};

		/* Subscription hints remain first on existing nodes. Only a new manual
		   node gets the share-link widget, before the cloned protocol fields. */
		s.addModalOptions = function(modalSection, section_id) {
			const row = rowMap[section_id];
			if (row && row.modal_hint)
				modalSection.description = row.modal_hint;
			if (self.pendingAdd?.id === section_id) {
				const share = modalSection.option(form.DummyValue, '_share',
					_('Fill from share link', 'aether-proxy'));
				share.renderWidget = () => self.shareLinkWidget(self.pendingAdd);
				modalSection.children.unshift(modalSection.children.pop());
			}
		};

		/* A DummyValue title may be a DOM node in LuCI. This keeps the checkbox
		   header and body aligned without changing GridSection's column layout. */
		this.selectAll = E('input', {
			'type': 'checkbox',
			'title': _('Select all deletable nodes', 'aether-proxy'),
			'change': ev => {
				for (const row of Object.values(rowMap)) {
					if (row.can_delete && ev.currentTarget.checked)
						self.selectedNodes.add(row.id);
					else
						self.selectedNodes.delete(row.id);
				}
				self.updateSelection();
			}
		});
		o = s.option(form.DummyValue, '_select', this.selectAll);
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			const box = E('input', {
				'type': 'checkbox',
				'disabled': (!row?.can_delete) || null,
				'title': row?.can_delete ? row.name : _('The current node cannot be deleted.', 'aether-proxy'),
				'checked': (row?.can_delete && self.selectedNodes.has(section_id)) || null,
				'change': ev => {
					if (row?.can_delete && ev.currentTarget.checked)
						self.selectedNodes.add(section_id);
					else
						self.selectedNodes.delete(section_id);
					self.updateSelection();
				}
			});
			self.selectionBoxes[section_id] = box;
			return box;
		};

		/* Table columns; all computed by the model, none editable in the table. */
		o = s.option(form.DummyValue, '_label', _('Name', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return E('span', { 'style': row?.stale ? 'opacity:0.6' : null }, row ? row.name : section_id);
		};

		o = s.option(form.DummyValue, '_protocol', _('Protocol', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return rowMap[section_id]?.protocol ?? '–';
		};

		o = s.option(form.DummyValue, '_transport_security', _('Transport / Security', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			return rowMap[section_id]?.transport_security ?? 'raw / none';
		};

		o = s.option(form.DummyValue, '_source', _('Source', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return row ? row.source : '–';
		};

		o = s.option(form.DummyValue, '_current', _('In use', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return row?.current ? E('span', {
				'title': _('Current node', 'aether-proxy'),
				'style': 'color:var(--success-color-high, #2f855a)'
			}, '✔') : E([]);
		};

		o = s.option(form.DummyValue, '_probe', _('TCP reachability / latency', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			/* The span is kept so the probe column can be refreshed in place
			   while a probe job is running. */
			const span = E('span', {});
			self.probeCells[section_id] = span;
			// GridSection may render again after an edit without rebuilding the map.
			dom.content(span, [ model.probe_column(section_id, self.results, self.pendingProbes) ]);
			return span;
		};

		/* Modal edit fields (docs/05 「config node」); source, stale and the
		   match_* keys are deliberately not editable. */
		o = s.option(form.Value, 'label', _('Display name', 'aether-proxy'));
		o.modalonly = true;

		o = s.option(form.ListValue, 'protocol', _('Protocol', 'aether-proxy'));
		o.modalonly = true;
		o.value('vless', _('VLESS', 'aether-proxy'));
		o.value('vmess', _('VMess', 'aether-proxy'));
		o.value('trojan', _('Trojan', 'aether-proxy'));
		o.value('shadowsocks', _('Shadowsocks', 'aether-proxy'));

		o = s.option(form.Value, 'address', _('Address', 'aether-proxy'));
		o.modalonly = true;
		o.datatype = 'host';

		o = s.option(form.Value, 'port', _('Port', 'aether-proxy'));
		o.modalonly = true;
		o.datatype = 'port';

		o = s.option(form.ListValue, 'transport', _('Transport', 'aether-proxy'));
		o.modalonly = true;
		o.value('raw', 'raw');
		o.value('ws', 'WebSocket');
		o.value('grpc', 'gRPC');
		o.value('httpupgrade', 'HTTPUpgrade');
		o.value('xhttp', 'XHTTP');
		o.optional = true;
		o.default = 'raw';

		o = s.option(form.Value, 'uuid', _('UUID', 'aether-proxy'));
		o.modalonly = true;
		o.depends('protocol', 'vless');
		o.depends('protocol', 'vmess');

		o = s.option(form.Value, 'password', _('Password', 'aether-proxy'));
		o.modalonly = true;
		o.depends('protocol', 'trojan');
		o.depends('protocol', 'shadowsocks');

		o = s.option(form.Value, 'method', _('Encryption method', 'aether-proxy'));
		o.modalonly = true;
		o.depends('protocol', 'shadowsocks');
		o.depends('protocol', 'vmess');

		o = s.option(form.Value, 'encryption', _('Encryption', 'aether-proxy'));
		o.modalonly = true;
		o.optional = true;
		o.placeholder = 'none';
		o.depends('protocol', 'vless');

		o = s.option(form.Value, 'flow', _('Flow', 'aether-proxy'));
		o.modalonly = true;
		o.depends('protocol', 'vless');
		o.description = _('Vision does not support multiplexing.', 'aether-proxy');

		o = s.option(form.ListValue, 'security', _('Security layer', 'aether-proxy'));
		o.modalonly = true;
		o.value('none', 'none');
		o.value('tls', 'TLS');
		o.value('reality', 'REALITY');
		o.optional = true;
		o.default = 'none';

		o = s.option(form.Value, 'host', _('Host', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'ws');
		o.depends('transport', 'httpupgrade');
		o.depends('transport', 'xhttp');

		o = s.option(form.Value, 'path', _('Path', 'aether-proxy'));
		o.modalonly = true;
		o.description = _('For WebSocket early data, use the path, e.g. /path?ed=2048.', 'aether-proxy');
		o.depends('transport', 'ws');
		o.depends('transport', 'httpupgrade');
		o.depends('transport', 'xhttp');

		o = s.option(form.Value, 'service_name', _('gRPC service name', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'grpc');

		o = s.option(form.Value, 'xhttp_mode', _('XHTTP mode', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'xhttp');

		o = s.option(form.Flag, 'grpc_multi_mode', _('gRPC multiMode', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'grpc');

		o = s.option(form.Value, 'ws_heartbeat', _('WebSocket heartbeat interval (seconds)', 'aether-proxy'));
		o.modalonly = true;
		o.datatype = 'range(1,3600)';
		o.depends('transport', 'ws');

		o = s.option(form.TextValue, 'xhttp_extra', _('XHTTP extra settings (JSON)', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'xhttp');
		o.validate = function(section_id, value) {
			if (value == null || value === '')
				return true;
			try {
				const extra = JSON.parse(value);
				if (extra !== null && typeof extra === 'object' && !Array.isArray(extra))
					return true;
			}
			catch (e) {
				return _('Must be a JSON object', 'aether-proxy');
			}
			return _('Must be a JSON object', 'aether-proxy');
		};

		o = s.option(form.ListValue, 'header_type', _('Header type', 'aether-proxy'));
		o.modalonly = true;
		o.value('none', 'none');
		o.value('http', 'http');
		o.optional = true;
		o.depends('transport', 'raw');

		o = s.option(form.Value, 'sni', _('SNI', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'tls');
		o.depends('security', 'reality');

		o = s.option(form.DynamicList, 'alpn', _('ALPN', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'tls');
		o.depends('security', 'reality');

		o = s.option(form.Value, 'fingerprint', _('TLS fingerprint', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'tls');
		o.depends('security', 'reality');

		o = s.option(form.Value, 'pinned_cert_sha256', _('Pinned certificate SHA-256', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'tls');

		o = s.option(form.Value, 'verify_name', _('Verify certificate by name', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'tls');

		o = s.option(form.Value, 'ech_config_list', _('ECH configuration', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'tls');

		o = s.option(form.Value, 'reality_pbk', _('REALITY public key', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.option(form.Value, 'reality_sid', _('REALITY short ID', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.option(form.Value, 'reality_spx', _('REALITY spiderX', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.option(form.Value, 'reality_pqv', _('REALITY post-quantum verification key (mldsa65Verify)',
			'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.option(form.Flag, 'mux', _('Multiplexing (Mux)', 'aether-proxy'));
		o.modalonly = true;
		o.depends({ flow: 'xtls-rprx-vision', '!reverse': true });
		o.validate = function(section_id, value) {
			// Read the modal's live input, not just UCI: flow may have unsaved edits.
			const flow = this.map.lookupOption('flow', section_id);
			const current = flow?.[0].formvalue(section_id) ?? uci.get('aetherproxy', section_id, 'flow');
			return value === '1' && current === 'xtls-rprx-vision'
				? _('Vision flow cannot be used with multiplexing enabled', 'aether-proxy') : true;
		};

		o = s.option(form.Value, 'mux_concurrency', _('Mux concurrency', 'aether-proxy'));
		o.modalonly = true;
		o.placeholder = '8';
		o.datatype = 'range(-1,1024)';
		o.depends('mux', '1');

		o = s.option(form.Value, 'mux_xudp_concurrency', _('XUDP concurrency', 'aether-proxy'));
		o.modalonly = true;
		o.placeholder = '16';
		o.datatype = 'range(-1,1024)';
		o.depends('mux', '1');

		o = s.option(form.ListValue, 'mux_xudp_udp443', _('XUDP handling of UDP/443', 'aether-proxy'));
		o.modalonly = true;
		o.value('', _('Default (reject)', 'aether-proxy'));
		o.value('reject', _('Reject', 'aether-proxy'));
		o.value('allow', _('Allow', 'aether-proxy'));
		o.value('skip', _('Do not multiplex', 'aether-proxy'));
		o.depends('mux', '1');

		o = s.option(form.Flag, 'tcp_fast_open', _('TCP Fast Open', 'aether-proxy'));
		o.modalonly = true;

		o = s.option(form.Flag, 'tcp_mptcp', _('MPTCP', 'aether-proxy'));
		o.modalonly = true;

		return m;
	},

	/* Follow GridSection.handleAdd without its anonymous section creation.
	   Do not redraw the table until Save: Cancel must leave the table intact. */
	handleAddNode: async function() {
		if (this.pendingAdd)
			return;
		const id = model.new_id(uci.sections('aetherproxy').map(s => s['.name']),
			() => window.crypto.getRandomValues(new Uint8Array(16)));
		try {
			uci.add('aetherproxy', 'node', id);
			uci.set('aetherproxy', id, 'source', 'manual');
			this.pendingAdd = { id, uri: '' };
			this.nodeMap.addedSection = id;
			await this.nodeGrid.renderMoreOptionsModal(id);
		}
		catch (e) {
			uci.remove('aetherproxy', id);
			delete this.nodeMap.addedSection;
			this.pendingAdd = null;
			ui.addNotification(null, E('p', _('Operation failed: %s', 'aether-proxy')
				.format(e?.message ?? String(e))));
		}
	},

	shareLinkWidget: function(added) {
		const input = E('input', {
			'type': 'text', 'class': 'cbi-input-text', 'value': added.uri
		});
		const error = E('div');
		return E('div', {}, [
			E('div', { 'style': 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap' }, [
				input,
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, () => this.handleParseNode(added, input, error))
				}, _('Parse', 'aether-proxy'))
			]),
			error
		]);
	},

	handleParseNode: async function(added, input, error) {
		added.uri = input.value;
		const reply = await ap.call('node_parse', { uri: added.uri });
		// A late reply after Cancel must not recreate the removed section.
		if (this.pendingAdd !== added)
			return;
		/* A reply arriving while Save validates is dropped (design lead,
		   2026-10-22): never change the data under LuCI's save. */
		if (added.saving)
			return;
		if (!reply.ok) {
			error.textContent = _('Unable to parse: %s', 'aether-proxy').format(reply.detail || reply.code);
			return;
		}
		for (const field of model.node_fields)
			uci.unset('aetherproxy', added.id, field);
		for (const [field, value] of Object.entries(reply.node))
			uci.set('aetherproxy', added.id, field, value);
		// Same parent and section: LuCI replaces this modal without saving its old widgets.
		return this.nodeGrid.renderMoreOptionsModal(added.id);
	},

	/* Recompute against live UCI: removal or switching may have invalidated a
	   selection while a modal or an RPC was open. Never select the current node. */
	updateSelection: function() {
		const current = uci.get('aetherproxy', 'main', 'node');
		const available = uci.sections('aetherproxy', 'node')
			.map(node => node['.name']).filter(id => id !== current);
		for (const id of this.selectedNodes) {
			if (!available.includes(id))
				this.selectedNodes.delete(id);
		}
		for (const [id, box] of Object.entries(this.selectionBoxes)) {
			box.disabled = !available.includes(id);
			box.checked = this.selectedNodes.has(id);
		}
		this.selectAll.checked = available.length > 0 && this.selectedNodes.size === available.length;
		this.selectAll.indeterminate = this.selectedNodes.size > 0 && !this.selectAll.checked;
		this.deleteSelected.disabled = this.deleting || !this.selectedNodes.size;
	},

	handleDeleteSelected: async function() {
		if (this.deleting)
			return;
		this.updateSelection();
		const ids = Array.from(this.selectedNodes);
		if (!ids.length)
			return;
		this.deleting = true;
		this.updateSelection();
		try {
			if (!await ap.confirm({
				title: _('Delete node', 'aether-proxy'),
				text: _('Really delete the %s selected nodes? Save & Apply is required for deletion to take effect.',
					'aether-proxy').format(ids.length),
				ok: _('Delete', 'aether-proxy'),
				destructive: true
			}))
				return;
			this.updateSelection();
			for (const id of ids) {
				if (this.selectedNodes.has(id)) {
					uci.remove('aetherproxy', id);
					this.selectedNodes.delete(id);
				}
			}
			// Match GridSection.handleRemove: stage and redraw, never apply changes.
			await this.nodeMap.save(null, true);
		}
		catch (e) {
			ui.addNotification(null, E('p', _('Operation failed: %s', 'aether-proxy')
				.format(e?.message ?? String(e))));
		}
		finally {
			this.deleting = false;
			this.updateSelection();
		}
	},

	updateSwitchButtons: function() {
		for (const button of this.switchButtons ?? []) {
			button.disabled = !!(this.switching || this.switchPending);
			button.title = this.switchPending
				? _('Switching nodes, please wait', 'aether-proxy')
				: _('Set this node as the current node', 'aether-proxy');
		}
	},

	clearSwitchNotification: function() {
		if (this.switchNoticeTimer != null)
			window.clearTimeout(this.switchNoticeTimer);
		this.switchNoticeTimer = null;
		this.switchNotice?.element.remove();
		this.switchNotice = null;
	},

	finishSwitch: function(timedOut) {
		this.stopSwitchWatch();
		this.switchOutcome = timedOut ? 'timeout' : 'complete';
		const notice = this.switchNotice;
		if (!notice)
			return;
		// Replace only our content: keep LuCI's banner and its Dismiss button intact.
		notice.content.textContent = (timedOut
			? _('Switching to “%s” has not finished yet; see the overview or logs for the reason.', 'aether-proxy')
			: _('Switched to “%s”', 'aether-proxy')).format(notice.name);
		if (!timedOut)
			this.switchNoticeTimer = window.setTimeout(() => this.clearSwitchNotification(), 5000);
	},

	stopSwitchWatch: function() {
		this.switchEpoch = (this.switchEpoch ?? 0) + 1;
		if (this.switchPoll != null)
			window.clearTimeout(this.switchPoll);
		if (this.switchDeadline != null)
			window.clearTimeout(this.switchDeadline);
		this.switchPoll = this.switchDeadline = null;
		this.switchPending = false;
		this.updateSwitchButtons();
	},

	/* The deadline is independent of RPC completion, so even an in-flight read
	   cannot keep the controls locked beyond 60 seconds. Epochs discard late
	   replies from the initial read or a previous node_use. */
	watchSwitch: function(status) {
		this.stopSwitchWatch();
		this.switchOutcome = null;
		if (!model.switch_pending(status, uci.get('aetherproxy', 'main', 'node')))
			return;
		this.switchPending = true;
		this.updateSwitchButtons();
		const epoch = this.switchEpoch;
		this.switchDeadline = window.setTimeout(() => this.finishSwitch(true), 60000);
		this.switchPoll = window.setTimeout(() => this.refreshSwitchStatus(epoch), 3000);
	},

	refreshSwitchStatus: async function(epoch = this.switchEpoch ?? 0) {
		const status = await ap.call('status');
		if (epoch !== (this.switchEpoch ?? 0))
			return;
		/* A failed read proves nothing either way (design lead, 2026-10-22):
		   keep an existing lock until its deadline, start none, notify nothing. */
		if (status && status.ok !== false) {
			if (!this.switchPending) {
				this.watchSwitch(status);
				return;
			}
			if (!model.switch_pending(status, uci.get('aetherproxy', 'main', 'node'))) {
				this.finishSwitch(false);
				return;
			}
		}
		if (this.switchPending)
			this.switchPoll = window.setTimeout(() => this.refreshSwitchStatus(epoch), 3000);
	},

	/* 「检测全部」 / per-row 「检测」: run the probe as a background job and
	   refresh the results and the progress line after every status update
	   (docs/10 「节点页」). Both probe buttons are unavailable while the job
	   is running. */
	handleProbe: async function(ev, ids) {
		if (this.probing)
			return;

		let refresh = Promise.resolve(), refresh_error, refresh_failed = false;
		try {
			// Invalidate the initial read: it predates this job and can erase feedback.
			this.resultsRequest = (this.resultsRequest ?? 0) + 1;
			this.pendingProbes = ids?.length ? ids.slice()
				: uci.sections('aetherproxy', 'node').map(node => node['.name']);
			this.setProbing(true);
			const job = await ap.run_job('probe_nodes', ids ?? [], () => {
				/* run_job does not await on_update: retain failures for the job chain
				 * and serialize refreshes so none reject unobserved or outlive cleanup. */
				refresh = refresh.then(() => this.refreshResults()).catch(e => {
					refresh_failed = true;
					refresh_error = e;
				});
			});
			await refresh;
			if (refresh_failed)
				throw refresh_error;
			await this.refreshResults();
			const text = model.job_failure_text(job);
			if (text)
				ui.addNotification(null, E('p', text));
		}
		catch (e) {
			ui.addNotification(null, E('p', _('Operation failed: %s', 'aether-proxy')
				.format(e?.message ?? String(e))));
		}
		finally {
			await refresh;
			try {
				this.pendingProbes = [];
				this.setProbing(false);
			}
			catch (e) {
				ui.addNotification(null, E('p', _('Operation failed: %s', 'aether-proxy')
					.format(e?.message ?? String(e))));
			}
		}
	},

	handleProbeAll: function(ev) {
		return this.handleProbe(ev, []);
	},

	/* ui.createHandlerFn passes its bound arguments first and the event last
	   (luci-base ui.js), so the row's section_id comes before ev. */
	handleProbeOne: function(section_id, ev) {
		return this.handleProbe(ev, [ section_id ]);
	},

	setProbing: function(probing) {
		this.probing = probing;

		for (const btn of this.probeButtons)
			btn.disabled = probing;

		this.updateProbeColumns();
	},

	refreshResults: function() {
		const self = this;
		const request = this.resultsRequest = (this.resultsRequest ?? 0) + 1;

		return ap.call('probe_results').then(function(res) {
			/* Probing is usable before the first read returns. An older read must
			 * not overwrite a newer job refresh, nor discard successful results. */
			if (request != self.resultsRequest)
				return;
			if ((res && res.ok !== false) || self.results === undefined)
				self.results = res ?? { ok: false, code: 'RPC_FAILED' };
			// Once available, the backend's pending list is authoritative.
			if (res && res.ok !== false)
				self.pendingProbes = [];

			self.updateProbeColumns();
		});
	},

	updateProbeColumns: function() {
		const vm = model.build(
			uci.sections('aetherproxy', 'node'),
			uci.get('aetherproxy', 'main', 'node'),
			uci.sections('aetherproxy', 'subscription'),
			this.results,
			this.pendingProbes
		);
		const rows = {};

		for (const row of vm.rows)
			rows[row.id] = row;

		for (const [sid, span] of Object.entries(this.probeCells)) {
			const row = rows[sid];
			dom.content(span, [ row ? row.probe : '–' ]);
		}

		// LuCI stringifies null children; an absent progress line must stay empty.
		dom.content(this.progressEl, vm.progress == null ? [] : [ vm.progress ]);
		this.progressEl.hidden = vm.progress == null;
	},

	/* Direct switching must not commit unrelated staged session changes. */
	handleSetCurrent: async function(section_id, ev) {
		if (this.switching || this.switchPending)
			return;
		this.switching = true;
		this.clearSwitchNotification();
		this.stopSwitchWatch();
		const button = ev.currentTarget;
		button.disabled = true;
		try {
			const reply = await ap.call('node_use', { id: section_id });
			let status;
			if (reply.ok) {
				uci.unload('aetherproxy');
				await uci.load('aetherproxy');
				status = await ap.call('status');
				this.watchSwitch(status);
				const content = await this.buildPage();
				dom.content(this.root, content);
				this.updateProbeColumns();
			}
			const text = model.node_use_message(reply, status,
				uci.get('aetherproxy', 'main', 'node'), uci.sections('aetherproxy', 'node'));
			if (text) {
				const content = E('p', {}, text);
				const element = ui.addNotification(null, content, reply.ok ? 'info' : 'error');
				if (reply.ok && model.switch_pending(status, uci.get('aetherproxy', 'main', 'node'))) {
					const node = uci.get('aetherproxy', section_id);
					this.switchNotice = { element, content, name: node?.label || section_id };
					// Form rendering may outlast the watch; never leave a stale pending banner.
					if (this.switchOutcome)
						this.finishSwitch(this.switchOutcome === 'timeout');
				}
			}
		}
		catch (e) {
			/* ap.call never rejects, so reaching here means node_use already
			   succeeded and only the page refresh failed: never call it a failed
			   switch (design lead, T10.23 TODO, 2026-10-21). No write is retried. */
			ui.addNotification(null, E('p', {},
				_('The node was switched, but refreshing the page data failed: %s. Reload the page.', 'aether-proxy')
					.replace('%s', e?.message ?? String(e))), 'warning');
		}
		finally {
			this.switching = false;
			button.disabled = false;
			this.updateSwitchButtons();
		}
	},

	handleImport: function(ev) {
		const self = this;
		const lines = model.split_import(this.importText.value);

		if (!lines.length) {
			ui.addNotification(null, E('p', _('Nothing to import.', 'aether-proxy')));
			return;
		}

		/* One node_import per line, strictly in order (docs/10 「节点页」). */
		const replies = [];
		let chain = Promise.resolve();

		for (const l of lines)
			chain = chain.then(function() {
				return ap.call('node_import', { uri: l.uri }).then(function(reply) {
					replies.push(reply);
				});
			});

		return chain.then(function() {
			const sum = model.summarize_import(lines, replies);
			const items = sum.failed.map(function(f) {
				return E('li', {}, `#${f.line} ${f.code}` + (f.detail !== '' ? `: ${f.detail}` : ''));
			});

			dom.content(self.importResult, [
				E('p', {}, sum.text),
				items.length ? E('ul', {}, items) : E([])
			]);

			if (sum.added > 0)
				return self.rebuild();
		});
	}
});
