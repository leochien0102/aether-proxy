'use strict';
'require baseclass';
'require rpc';
'require ui';
'require uci';

/*
 * Shared helpers for the aether-proxy LuCI pages (docs/10 「公共模块与菜单」).
 *
 * Pages load this module with 'require aether-proxy.common as ap' and never
 * call rpc.declare themselves. Every rpcd access goes through ap.call(), which
 * settles exactly once — rpc reply, rpc failure or hard timeout, whichever
 * comes first — and never rejects. At most 2 calls are in flight at any time;
 * further calls wait in a FIFO queue (docs/10 「UI 规则」: 为 uhttpd 的
 * max_requests 3 留出余量). Module loading also checks for a stale browser
 * copy of this script (docs/10 「页面脚本过期检测」), independently of RPC.
 * Confirmations and elapsed job progress follow docs/10 「UI 规则」.
 */

var SCRIPT_VERSION = '@@VERSION@@';

/* LuCI caches the module instance: run once here, not on each ap.call or
   construction. Do not block page loading on this best-effort static fetch. */
function check_script_version() {
	/* Split the sentinel so the build's replacement cannot rewrite this guard. */
	if (SCRIPT_VERSION === '@@' + 'VERSION@@')
		return;

	Promise.resolve().then(function() {
		return fetch(L.resource('aether-proxy/build.json'), { cache: 'no-store' });
	}).then(function(response) {
		if (!response.ok)
			throw new Error('build.json HTTP status ' + response.status);

		return response.json();
	}).then(function(build) {
		if (!build || typeof build.version != 'string' || !build.version)
			throw new Error('build.json has no version');

		if (build.version !== SCRIPT_VERSION)
			ui.addNotification(null, E('p', {}, [
				_('Page scripts are out of date: installed %s, but the browser is still using %s. '
					+ 'Clear your browser cache and reload the page (some third-party themes do not '
					+ 'automatically refresh page scripts after an upgrade).', 'aether-proxy')
					.format(build.version, SCRIPT_VERSION)
			]), 'warning');
	}).catch(function(e) {
		console.warn('aether-proxy: page script version check failed', e);
	});
}

check_script_version();

/* uci.load caches rejected promises too. Clear that cache before one retry;
   leave the second rejection untouched so persistent faults remain visible. */
function load_config() {
	return uci.load('aetherproxy').catch(function() {
		uci.unload('aetherproxy');
		return uci.load('aetherproxy');
	});
}

/* docs/10 「rpcd 插件」: all ubus methods of the aetherproxy object with
   their named parameters, in declaration order. */
var METHODS = {
	version: [],
	status: [],
	components: [],
	service: [ 'action' ],
	check: [],
	job_start: [ 'kind', 'args' ],
	job_status: [ 'id' ],
	events: [ 'since', 'level' ],
	probe_results: [],
	probe_now: [],
	node_use: [ 'id', 'mode', 'port_scope' ],
	mode_use: [ 'mode', 'port_scope' ],
	probe_url: [ 'site' ],
	probe_sites: [],
	sub_status: [],
	data_status: [],
	stats: [],
	/* T12.6 (docs/10 「B25：概览页使用热力图」): days is optional, the plugin
	   defaults to 90. The overview heatmap is the only caller. */
	stats_history: [ 'days' ],
	stats_quota: [ 'action', 'bytes' ],
	log: [ 'source', 'lines' ],
	log_clear: [],
	log_truncate: [],
	node_import: [ 'uri' ],
	node_parse: [ 'uri' ],
	list_file: [ 'name' ],
	save_file: [ 'name', 'content' ]
};

/* docs/10 「检测真实延迟与切换节点」: probe_url uses the long tier because
   its plugin timeout follows the configurable probe.timeout rather than 10s. */
/* Hard timeouts in seconds (docs/10 「公共模块与菜单」). call/long are the
   ap.call tiers; job is the total budget for one background job (the job
   itself caps at 600s); job_poll is the job_status polling cadence required
   by docs/10 「作业机制」 (frontend polls every 2 seconds). */
var TIMEOUTS = {
	call: 15,
	long: 35,
	components: 20, /* Live inventory: plugin 15s + 5s transport margin (docs/10 T10.4). */
	job: 620,
	job_poll: 2
};

var LONG_CALLS = [ 'check', 'save_file', 'probe_url' ];

/* docs/10 「公共模块与菜单」: ap.poll() intervals below 2000ms count as 2000ms. */
var MIN_POLL_INTERVAL_MS = 2000;

var decls = {};

for (var method in METHODS)
	decls[method] = rpc.declare({
		object: 'aetherproxy',
		method: method,
		params: METHODS[method]
	});

/* In-flight counter and FIFO queue for the ≤2 concurrent calls rule. Module
   scope on purpose: LuCI keeps one instance per module name, so the limit
   covers ap.call and the job polling of every page alike. */
var inflight = 0;
var queue = [];

function error_text(e) {
	if (e instanceof Error)
		return e.message;

	return (e === null || e === undefined) ? 'unknown error' : String(e);
}

/* Send queued calls while fewer than 2 are in flight. */
function pump() {
	while (inflight < 2 && queue.length > 0) {
		var entry = queue.shift();

		inflight++;
		invoke(entry);
	}
}

function invoke(entry) {
	var fn = decls[entry.method];
	var settled = false;
	var timer = null;

	/* settle-once: only the first of reply, failure and hard timeout wins;
	   later ones are ignored and free the queue slot exactly once. */
	var finish = function(res) {
		if (settled)
			return;

		settled = true;

		if (timer != null)
			clearTimeout(timer);

		inflight--;
		entry.resolve(res);
		pump();
	};

	if (!fn) {
		/* Unreachable through the public API (ap.call only accepts the methods
		   declared above); fail the call instead of issuing an rpc.
		   TODO(design): docs/10 does not describe a reply shape for programming
		   errors, so the generic RPC_FAILED object is used. */
		finish({ ok: false, code: 'RPC_FAILED', detail: 'unknown method: ' + entry.method });
		return;
	}

	var timeout_s = (LONG_CALLS.indexOf(entry.method) != -1) ? TIMEOUTS.long : TIMEOUTS.call;
	if (entry.method === 'components')
		timeout_s = TIMEOUTS.components;

	timer = setTimeout(function() {
		finish({
			ok: false,
			code: 'TIMEOUT',
			detail: entry.method + ' did not answer in ' + timeout_s + 's'
		});
	}, timeout_s * 1000);

	try {
		Promise.resolve(fn.apply(null, entry.args)).then(finish, function(e) {
			finish({ ok: false, code: 'RPC_FAILED', detail: error_text(e) });
		});
	}
	catch (e) {
		finish({ ok: false, code: 'RPC_FAILED', detail: error_text(e) });
	}
}

/* Call one of the rpcd plugin methods (docs/10 「rpcd 插件」) and resolve
   exactly once: with the rpc reply, or { ok: false, code: "RPC_FAILED" }
   when the rpc layer rejects, or { ok: false, code: "TIMEOUT" } on hard
   timeout. Never rejects. Calls beyond 2 in flight wait in FIFO order and
   are sent when a slot frees up (docs/10 「UI 规则」). */
function call(method, params) {
	var names = METHODS[method] ?? [];
	var args = [];

	for (var i = 0; i < names.length; i++)
		args.push(params ? params[names[i]] : undefined);

	return new Promise(function(resolve) {
		queue.push({ method: method, args: args, resolve: resolve });
		pump();
	});
}

/* LuCI's baseclass.extend() returns a class; L.require hands views an instance
   of it. Code in this module must therefore use the module-level TIMEOUTS and
   call(), never `ap.TIMEOUTS` / `ap.call` (those are prototype members, absent
   on the class itself: the T8.13 device window failed on exactly that). */
var ap = baseclass.extend({
	// Overlay a native button in the input's grid cell, without changing SDK widget identity.
	input_action: function(input, icon, label, click, inset = 0) {
		const host = input.parentElement;
		host.style.display = 'inline-grid';
		host.style.maxWidth = '100%';
		input.style.gridArea = '1 / 1';
		input.style.boxSizing = 'border-box';
		input.style.paddingRight = Math.max((input.style.paddingRight || '').endsWith('rem') ? parseFloat(input.style.paddingRight) : 0, 2 + inset) + 'rem';
		// Theme button defaults (including adjacent margins and hover transforms) must not enlarge the hit slots.
		const button = E('button', { type: 'button', click, style: 'grid-area:1/1;justify-self:end;align-self:center;position:relative;box-sizing:border-box!important;width:1.75rem!important;min-width:1.75rem!important;max-width:1.75rem!important;height:1.75rem!important;min-height:1.75rem!important;max-height:1.75rem!important;padding:0!important;border:0!important;border-radius:0!important;background:transparent!important;box-shadow:none!important;transform:none!important;transition:none!important;color:inherit;cursor:pointer;margin:0 ' + inset + 'rem 0 0!important;display:inline-flex;align-items:center;justify-content:center' });
		const ns = 'http://www.w3.org/2000/svg';
		const svg = document.createElementNS(ns, 'svg');
		for (const [key, value] of Object.entries({ viewBox:'0 0 24 24', width:18, height:18, fill:'none', stroke:'currentColor', 'stroke-width':2, 'stroke-linecap':'round', 'stroke-linejoin':'round', 'aria-hidden':'true' })) svg.setAttribute(key, value);
		const path = document.createElementNS(ns, 'path');
		svg.append(path); button.append(svg); host.append(button);
		const paths = {
			copy:'M7 15H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v2 M11 9h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-8a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2Z',
			check:'M4 12l5 5L20 6', clear:'M6 6l12 12 M18 6L6 18',
			eye:'M2 12Q12-3 22 12Q12 27 2 12Z M15 12a3 3 0 1 1-6 0a3 3 0 1 1 6 0Z'
		};
		button.setIcon = (name, text) => {
			path.setAttribute('d', name === 'hidden' ? paths.eye + ' M3 3l18 18' : paths[name]);
			button.title = text; button.setAttribute('aria-label', text);
		};
		button.setIcon(icon, label);
		// Shrink only the clear glyph, not its 1.75rem pointer/keyboard target.
		if (icon === 'clear') {
			svg.style.setProperty('width', '14px', 'important');
			svg.style.setProperty('height', '14px', 'important');
		}
		return button;
	},
	/* Assemble actions on the SDK Value, including cloned GridSection options.
	 * Call after setting option.password; labels belong to the caller's field.
	 * A DynamicList caller selects its add-item input, never a saved list item.
	 * Keep validation, formvalue and writers owned by LuCI, not a replacement input.
	 */
	field_actions: function(option, labels, selector = 'input') {
		// ap is the LuCI constructor; retain this module instance across option cloning.
		const actions = this;
		const render = option.renderWidget;
		option.renderWidget = function(section_id, ...args) {
			const node = render.call(this, section_id, ...args);
			const input = node.querySelector(selector);
			if (this.password) {
				input.nextElementSibling.remove(); // Replace SDK's external reveal button.
				input.type = 'password';
				const eye = actions.input_action(input, 'hidden', labels.show, () => {
					const reveal = input.type === 'password';
					input.type = reveal ? 'text' : 'password';
					eye.setIcon(reveal ? 'eye' : 'hidden', reveal ? labels.hide : labels.show);
				});
			}
			const clear = actions.input_action(input, 'clear', labels.clear, () => {
				input.value = '';
				input.dispatchEvent(new Event('input', { bubbles: true }));
				input.dispatchEvent(new Event('change', { bubbles: true }));
				this.triggerValidation(section_id);
				input.focus();
			}, this.password ? 1.75 : 0);
			const host = input.parentElement;
			const sync = (focus = document.activeElement) => {
				const visible = !!input.value && !input.readOnly && !input.disabled && host.contains(focus);
				clear.hidden = !visible;
				clear.disabled = !visible;
				clear.tabIndex = visible ? 0 : -1;
				// Author theme display rules override the browser's default [hidden] rule.
				clear.style.setProperty('display', visible ? 'inline-flex' : 'none', 'important');
			};
			input.addEventListener('input', () => sync());
			input.addEventListener('change', () => sync());
			host.addEventListener('focusin', () => sync());
			host.addEventListener('focusout', event => sync(event.relatedTarget));
			new MutationObserver(() => sync()).observe(input, {
				attributes: true, attributeFilter: ['disabled', 'readonly']
			});
			sync();
			return node;
		};
		return option;
	},
	/* Shared with the module-level TIMEOUTS object, so tests can shrink the
	   timeouts through the instance (docs/10 「公共模块与菜单」). */
	TIMEOUTS: TIMEOUTS,

	call: call,
	load_config: load_config,

	hint_icon: function({ text, label, icon = 'ⓘ' }) {
		const bubble = E('span', {
			hidden: true, style: 'position:absolute; top:100%; left:0; z-index:10; '
				+ 'text-align:start; white-space:normal; width:18em; max-width:70vw; padding:0.5em; '
				+ 'background:var(--background-color, Canvas); color:var(--text-color, CanvasText); '
				+ 'border:1px solid currentColor; border-radius:0.25em'
		}, [text]);
		let open = false, pointerOpen = null;
		const show = visible => {
			open = visible;
			bubble.hidden = !visible;
			button.setAttribute('aria-expanded', String(visible));
		};
		const button = E('span', {
			role: 'button', tabindex: '0', title: text,
			'aria-label': label, 'aria-expanded': 'false',
			style: 'position:relative; font-size:1em; cursor:help; margin-left:0.25em',
			// Pointer focus precedes click: toggle from the pre-focus state on touch too.
			pointerdown: () => { pointerOpen = open; },
			pointercancel: () => { pointerOpen = null; },
			focus: () => show(true),
			blur: () => { pointerOpen = null; show(false); },
			click: ev => {
				ev.preventDefault();
				ev.stopPropagation(); // A surrounding SDK label must not activate its control.
				show(!(pointerOpen ?? open));
				pointerOpen = null;
			},
			keydown: ev => {
				if (ev.key !== 'Escape' && ev.key !== 'Enter' && ev.key !== ' ')
					return;
				ev.preventDefault();
				ev.stopPropagation();
				pointerOpen = null;
				if (!ev.repeat)
					show(ev.key !== 'Escape' && !open);
			}
		}, [icon, bubble]);
		return button;
	},

	/* Pass the previous details (or { open: false }) as collapsible to retain
	   local disclosure state without coupling separate sections by title. */
	section_actions: function(actions, leading, inline = false) {
		return E('div', {
			'class': 'aether-section-actions',
			style: 'display:flex; align-items:center; gap:0.5em; flex-wrap:wrap; min-width:0; '
				+ (leading ? 'justify-content:space-between; ' : 'justify-content:flex-end; ')
				+ (inline ? 'margin-inline-start:auto' : 'margin:0.5em 0 1em; padding-inline:1.25rem')
		}, leading ? [leading, ...actions] : actions);
	},

	section: function({ title, description, actions, body, collapsible, stacked = false }) {
		const attrs = { 'class': 'cbi-section', style: 'margin:0 0 1em' };
		if (collapsible)
			attrs.open = (collapsible.open ?? true) || null;
		const children = [];
		if (typeof title == 'string' ? title.trim() : title)
			children.push(E(collapsible ? 'summary' : 'h3', {}, title));
		const toolbar = [];
		if (description)
			toolbar.push(E('div', { 'class': 'cbi-map-descr', style: 'margin:0' }, [description]));
		if (Array.isArray(actions) && actions.length)
			toolbar.push(this.section_actions(actions, null, !stacked));
		else if (actions && !Array.isArray(actions))
			toolbar.push(actions);
		// The Nodes & Subscriptions blocks retain their compact two-column header.
		if (stacked)
			children.push(...toolbar);
		else if (toolbar.length)
			children.push(E('div', {
				'class': 'aether-section-toolbar',
				style: 'display:flex; flex-wrap:wrap; align-items:center; gap:0.5em 1em; margin:0.5em 0 1em'
			}, toolbar));

		// The existing subscription wrapper already scrolls. Give the node GridSection
		// the same local scroll behavior without touching its columns or map lifecycle.
		const grid = Array.isArray(body) && body[0]?.querySelector?.('#cbi-aetherproxy-node.cbi-tblsection');
		if (grid) {
			const scroll = E('div', {
				'class': 'aether-node-scroll', style: 'max-width:100%; overflow-x:auto',
				tabindex: 0, role: 'region', 'aria-label': title
			}, body[0]);
			return E(collapsible ? 'details' : 'div', attrs, children.concat(scroll, body.slice(1), E('style', {}, [`
#cbi-aetherproxy-node.cbi-tblsection { overflow:visible; }
#cbi-aetherproxy-node > .cbi-section-table {
	display:table; width:100%; min-width:min-content; max-width:none; table-layout:auto;
}
#cbi-aetherproxy-node > .cbi-section-table .tr { display:table-row; }
#cbi-aetherproxy-node > .cbi-section-table :is(.th, .td) { display:table-cell !important; }
#cbi-aetherproxy-node > .cbi-section-table .td[data-title]::before,
#cbi-aetherproxy-node > .cbi-section-table .td[data-description]::after { content:none; }
`])));
		}
		return E(collapsible ? 'details' : 'div', attrs, children.concat(body ?? []));
	},

	/* Keep the SDK section DOM, bindings and tab panes; only replace its outer
	   presentation. This runs on each Map render/reset, not on modal clones. */
	form_section: function(section, { title = section.title, description, actions } = {}) {
		const render = section.render;
		section.hidetitle = true;
		section.render = (...args) => Promise.resolve(render.apply(section, args)).then(content => {
			content.classList?.remove('cbi-section');
			return this.section({
				title, description, actions: typeof actions == 'function' ? actions() : actions,
				body: content, stacked: true
			});
		});
	},

	/* Use elapsed wall time, not tick counts: background tabs can delay timers. */
	job_progress: function(target, text) {
		const started = Date.now();
		let stopped = false;
		const update = function() {
			if (!stopped)
				target.textContent = _('%s (elapsed %s seconds)', 'aether-proxy')
					.format(text, Math.floor((Date.now() - started) / 1000));
		};
		update();
		const timer = setInterval(update, 1000);
		return {
			stop: function() {
				stopped = true;
				clearInterval(timer);
				target.textContent = '';
			}
		};
	},

	/* docs/10 「UI 规则」: keep confirmations in the active LuCI theme and
	   close the modal before allowing the caller to perform its action. */
	confirm: function(options) {
		return new Promise(function(resolve) {
			const finish = function(answer) {
				ui.hideModal();
				resolve(answer);
			};

			ui.showModal(options.title, [
				/* The body may name a node or subscription: never parse it as HTML.
				 * `?? ''` keeps an absent body from rendering the string "undefined". */
				E('p', {}, [ options.text ?? '' ]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'type': 'button',
						'class': 'cbi-button',
						'click': function() { finish(false); }
					}, _('Cancel', 'aether-proxy')),
					' ',
					E('button', {
						'type': 'button',
						'class': 'cbi-button ' + (options.destructive ? 'cbi-button-remove' : 'cbi-button-action'),
						'click': function() { finish(true); }
					}, [ options.ok ])
				])
			]);
		});
	},

	/* Call fn (which returns a promise) every interval_ms, but at most every
	   2000ms. A tick is skipped while the previous run has not settled and
	   while document.hidden is true; on becoming visible fn runs once at once
	   and the cadence continues. Rejections of fn are contained here — the
	   poll loop must survive them, which is exactly what LuCI's own poll does
	   not guarantee (docs/10 「作业机制」). Returns { stop() }. */
	poll: function(fn, interval_ms) {
		var interval = (typeof interval_ms == 'number' && interval_ms >= MIN_POLL_INTERVAL_MS) ? interval_ms : MIN_POLL_INTERVAL_MS;
		var stopped = false;
		var busy = false;

		var run = function() {
			if (stopped || busy || document.hidden)
				return;

			busy = true;

			Promise.resolve().then(fn).catch(function() {}).then(function() {
				busy = false;
			});
		};

		var on_visibility = function() {
			if (!stopped && !document.hidden)
				run();
		};

		document.addEventListener('visibilitychange', on_visibility);

		var timer = setInterval(run, interval);

		return {
			stop: function() {
				stopped = true;
				clearInterval(timer);
				document.removeEventListener('visibilitychange', on_visibility);
			}
		};
	},

	/* Start a background job (docs/10 「作业机制」) and poll it until it reaches
	   state ok or failed; on_update(job) is called for every observed status.
	   Resolves the final job object — with attached: true when job_start
	   reported BUSY and an already running job was attached to — or the
	   failure object of job_start / job_status (USAGE, JOB_NOT_FOUND,
	   RPC_FAILED, TIMEOUT, …), or { ok: false, code: "TIMEOUT" } once the
	   total time exceeds ap.TIMEOUTS.job. Never rejects. */
	run_job: function(kind, args, on_update) {
		var started_at = Date.now();

		/* One job_status at a time: the next poll is scheduled only after the
		   previous reply, so a slow reply (up to the 15s call timeout) never
		   stacks polls, never takes both request slots and never reports a
		   status after the job already resolved. */
		var track = function(id, attached) {
			return new Promise(function(resolve) {
				var poll_once = function() {
					if (Date.now() - started_at > TIMEOUTS.job * 1000) {
						resolve({ ok: false, code: 'TIMEOUT' });
						return;
					}

					call('job_status', { id: id }).then(function(st) {
						if (!st || st.ok === false) {
							resolve(st ?? { ok: false, code: 'RPC_FAILED', detail: 'job_status returned nothing' });
							return;
						}

						var job = attached ? Object.assign({}, st, { attached: true }) : st;

						if (typeof on_update == 'function')
							on_update(job);

						if (st.state == 'ok' || st.state == 'failed') {
							resolve(job);
							return;
						}

						setTimeout(poll_once, TIMEOUTS.job_poll * 1000);
					});
				};

				/* First status right away, then job_poll seconds after each reply. */
				poll_once();
			});
		};

		return call('job_start', { kind: kind, args: args ?? [] }).then(function(started) {
			/* BUSY with a job id: attach to the already running job instead of
			   failing (docs/10 「公共模块与菜单」). */
			if (started && started.code == 'BUSY' && typeof started.job == 'string')
				return track(started.job, true);

			if (started && started.ok === false)
				return started;

			/* TODO(design): docs/10 does not say how to treat a successful
			   job_start that carries no job id; fail the job defensively. */
			if (!started || typeof started.job != 'string')
				return { ok: false, code: 'RPC_FAILED', detail: 'job_start did not return a job id' };

			return track(started.job, false);
		});
	}
});

return ap;
