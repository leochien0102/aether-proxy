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
 * node as current stages the UCI change and goes through LuCI's standard
 * save & apply with rollback confirmation; node edits use the GridSection
 * modal and form.Map's standard save flow. Probe recovery follows docs/10 「UI 规则」.
 * Defer the first result read until after rendering (docs/10 「其余页面先出页面」).
 */

return view.extend({
	load: function() {
		return uci.load('aetherproxy');
	},

	render: function() {
		this.results = undefined;
		this.resultsRequest = 0;
		this.probing = false;

		const root = E('div', { 'class': 'cbi-map' });
		this.root = root;
		const self = this;

		return this.buildPage().then(function(content) {
			dom.content(root, content);
			self.updateProbeColumns();
			window.setTimeout(() => self.refreshResults(), 0);
			return root;
		});
	},

	/* Re-fetches the page data (used after imports added nodes) and rebuilds
	   the whole page in place. */
	rebuild: function() {
		const self = this;
		// Import can finish while the initial read is still in flight.
		this.resultsRequest = (this.resultsRequest ?? 0) + 1;

		return Promise.all([
			uci.unload('aetherproxy').then(function() { return uci.load('aetherproxy'); }),
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

		this.progressEl = E('div', { 'class': 'cbi-map-descr' });

		this.importText = E('textarea', {
			'class': 'cbi-input-textarea',
			'rows': 4,
			'placeholder': _('One node share URI per line.', 'aether-proxy')
		});

		const importBox = E('div', { 'class': 'cbi-map-descr' }, [
			E('h3', {}, _('Import URIs', 'aether-proxy')),
			this.importText,
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(self, 'handleImport')
			}, [ _('Import', 'aether-proxy') ])
		]);

		const probeAll = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(self, 'handleProbeAll'),
			'disabled': this.probing || null
		}, [ _('Probe all', 'aether-proxy') ]);
		this.probeButtons.push(probeAll);

		const controls = E('div', { 'class': 'cbi-map-descr' }, [ probeAll, ' ', importBox ]);

		const mapNodePromise = this.buildMap().render();

		return mapNodePromise.then(function(mapNode) {
			return E('div', {}, [
				E('h2', {}, _('Nodes', 'aether-proxy')),
				E('div', { 'class': 'cbi-map-descr' }, _('Manage the proxy nodes, probe their TCP reachability and import node share links.', 'aether-proxy')),
				self.progressEl,
				controls,
				mapNode
			]);
		});
	},

	buildMap: function() {
		const self = this;
		const rowMap = this.rowMap;
		let m, s, o;

		m = new form.Map('aetherproxy');

		s = m.section(form.GridSection, 'node');
		s.addremove = true;

		/* Nodes are named sections (n_<32 hex digits>, docs/05 「config node」)
		   and are added via the URI import, so the grid's generic add button
		   (which would create an anonymous section) is not rendered. */
		s.renderSectionAdd = function() {
			return E([]);
		};

		/* The per-row operations: 设为当前 / 检测 come first, then the built-in
		   Edit and Delete buttons of the grid section. */
		s.renderRowActions = function(section_id) {
			const tdEl = this.super('renderRowActions', [ section_id ]);
			const row = rowMap[section_id];
			const extra = [];

			if (row && row.can_set_current) {
				extra.push(E('button', {
					'class': 'btn cbi-button cbi-button-positive',
					'title': _('Set this node as the current node', 'aether-proxy'),
					'click': ui.createHandlerFn(self, 'handleSetCurrent', section_id)
				}, [ _('Set as current', 'aether-proxy') ]));
			}

			const probeBtn = E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'title': _('Probe the TCP reachability of this node', 'aether-proxy'),
				'click': ui.createHandlerFn(self, 'handleProbeOne', section_id),
				'disabled': self.probing || null
			}, [ _('Probe', 'aether-proxy') ]);
			self.probeButtons.push(probeBtn);
			extra.push(probeBtn);

			/* builtins: [0] is Edit, [1] the Delete button (cbi-button-remove).
			   The current node cannot be deleted (docs/10 「节点页」), so its
			   delete button is not rendered at all. */
			const builtins = tdEl.lastChild.childNodes;
			const keep = row && !row.can_delete ? [ builtins[0] ] : [ builtins[0], builtins[1] ];

			dom.content(tdEl.lastChild, [ ...extra, ...keep ]);

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

			return this.super('handleRemove', [ section_id, ev ]);
		};

		/* Subscription nodes warn about being overwritten before the modal is
		   entered (docs/10 「节点页」). */
		s.addModalOptions = function(modalSection, section_id) {
			const row = rowMap[section_id];

			if (row && row.modal_hint)
				modalSection.description = row.modal_hint;
		};

		/* Table columns; all computed by the model, none editable in the table. */
		o = s.option(form.DummyValue, '_label', _('Name', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return row ? row.name : section_id;
		};

		o = s.option(form.DummyValue, '_address', _('Address', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return row ? row.address : '–';
		};

		o = s.option(form.DummyValue, '_summary', _('Protocol / Transport / Security', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return row ? row.summary : '–';
		};

		o = s.option(form.DummyValue, '_source', _('Source', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return row ? row.source : '–';
		};

		o = s.option(form.DummyValue, '_marks', _('Marks', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const row = rowMap[section_id];
			return (row && row.marks.length) ? row.marks.join(', ') : '–';
		};

		o = s.option(form.DummyValue, '_probe', _('TCP reachability / latency', 'aether-proxy'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			/* The span is kept so the probe column can be refreshed in place
			   while a probe job is running. */
			const span = E('span', {});
			self.probeCells[section_id] = span;
			// GridSection may render again after an edit without rebuilding the map.
			dom.content(span, [ model.probe_column(section_id, self.results) ]);
			return span;
		};

		/* Modal edit fields (docs/05 「config node」); source, stale and the
		   match_* keys are deliberately not editable. */
		o = s.option(form.Value, 'label', _('Display name', 'aether-proxy'));
		o.modalonly = true;

		o = s.option(form.ListValue, 'protocol', _('Protocol', 'aether-proxy'));
		o.modalonly = true;
		o.value('vless', 'VLESS');
		o.value('vmess', 'VMess');
		o.value('trojan', 'Trojan');
		o.value('shadowsocks', 'Shadowsocks');

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
		o.depends('transport', 'ws');
		o.depends('transport', 'httpupgrade');
		o.depends('transport', 'xhttp');

		o = s.option(form.Value, 'service_name', _('gRPC service name', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'grpc');

		o = s.option(form.Value, 'xhttp_mode', _('XHTTP mode', 'aether-proxy'));
		o.modalonly = true;
		o.depends('transport', 'xhttp');

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

		o = s.option(form.Value, 'reality_pbk', _('REALITY public key', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.option(form.Value, 'reality_sid', _('REALITY short ID', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		o = s.option(form.Value, 'reality_spx', _('REALITY spiderX', 'aether-proxy'));
		o.modalonly = true;
		o.depends('security', 'reality');

		return m;
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

			self.updateProbeColumns();
		});
	},

	updateProbeColumns: function() {
		const vm = model.build(
			uci.sections('aetherproxy', 'node'),
			uci.get('aetherproxy', 'main', 'node'),
			uci.sections('aetherproxy', 'subscription'),
			this.results
		);
		const rows = {};

		for (const row of vm.rows)
			rows[row.id] = row;

		for (const [sid, span] of Object.entries(this.probeCells)) {
			const row = rows[sid];
			dom.content(span, [ row ? row.probe : '–' ]);
		}

		dom.content(this.progressEl, [ vm.progress ]);
	},

	/* 设为当前: stage the UCI change and go through LuCI's standard save &
	   apply with rollback confirmation (docs/10 「节点页」). */
	handleSetCurrent: function(section_id, ev) {
		uci.set('aetherproxy', 'main', 'node', section_id);

		return uci.save().then(function() {
			return ui.changes.apply(true);
		});
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

			ui.addNotification(null, E('div', {}, [
				E('p', {}, sum.text),
				items.length ? E('ul', {}, items) : E([])
			]));

			if (sum.added > 0)
				return self.rebuild();
		});
	}
});
