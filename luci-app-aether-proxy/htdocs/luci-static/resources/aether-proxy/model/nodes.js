'use strict';
'require baseclass';

/*
 * Pure view model for the nodes page (docs/10 「节点页」, docs/tasks/m8.md T8.5).
 *
 * build() turns the raw UCI sections and the probe results into everything the
 * view renders: row texts, marks, the TCP reachability column wording, the
 * progress line and which per-row operations are allowed (the current node can
 * neither be deleted nor be made current). split_import()/summarize_import()
 * handle the URI import box: line splitting keeps the original line numbers and
 * the three reply kinds (new, duplicate, failed) are tallied here. Nothing in
 * this module issues requests or touches the DOM; every msgid used here must
 * have an entry in po/zh_Hans/aether-proxy.po.
 */

/* Replaces each %s with the corresponding extra argument, in order. */
function fmt(s) {
	for (let i = 1; i < arguments.length; i++)
		s = s.replace('%s', arguments[i]);

	return s;
}

/* docs/07: the fixed error enum of the node probe results. */
const PROBE_ERROR_TEXT = {
	resolve_failed: _('Resolve failed', 'aether-proxy'),
	timeout: _('Timed out', 'aether-proxy'),
	refused: _('Connection refused', 'aether-proxy'),
	unreachable: _('Unreachable', 'aether-proxy'),
	other: _('Other error', 'aether-proxy')
};

function sections_of(sections) {
	return Array.isArray(sections) ? sections : [];
}

/* docs/10 「节点页」: `protocol / transport / security`, with the config defaults
   raw / none filled in for missing values (docs/05 「config node」). */
function summary_text(s) {
	return [ s.protocol ?? '–', s.transport ?? 'raw', s.security ?? 'none' ].join(' / ');
}

function address_text(s) {
	if (s.address == null || s.address === '')
		return '–';

	return (s.port == null || s.port === '') ? String(s.address) : `${s.address}:${s.port}`;
}

/* docs/10: 「手动」 or the subscription's name; a source naming a subscription
   that no longer exists shows the raw section name. */
function source_text(s, subs) {
	const source = (s.source == null || s.source === '') ? 'manual' : String(s.source);

	if (source == 'manual')
		return _('Manual', 'aether-proxy');

	const sub = subs ? subs[source] : null;

	return (sub && sub.name != null && sub.name !== '') ? sub.name : source;
}

function marks_for(s, current) {
	const marks = [];

	if (current != null && s['.name'] == current)
		marks.push(_('Current node', 'aether-proxy'));

	if (s.stale == '1')
		marks.push(_('Stale', 'aether-proxy'));

	return marks;
}

function nodes_of(results) {
	return (results && typeof results == 'object' && typeof results.nodes == 'object' && results.nodes) ? results.nodes : null;
}

function pending_of(results) {
	return (results && Array.isArray(results.pending)) ? results.pending : null;
}

/* docs/10 「节点页」 column wording: pending → 检测中, ok > 0 → latency and count,
   ok == 0 → the error text, no result → 未检测. Being pending wins over a stale
   result from a previous run (docs/07: unfinished nodes keep the old result,
   marked as probing). */
function probe_column(id, results) {
	if (results == null || typeof results != 'object')
		return _('Not probed', 'aether-proxy');

	const pending = pending_of(results);

	if (pending && pending.indexOf(id) != -1)
		return _('Probing…', 'aether-proxy');

	const nodes = nodes_of(results);
	const res = nodes ? nodes[id] : null;

	if (res == null || typeof res != 'object')
		return _('Not probed', 'aether-proxy');

	if ((res.ok ?? 0) > 0)
		return fmt(_('%s ms (%s/3)', 'aether-proxy'), res.median_ms ?? '?', res.ok);

	const text = PROBE_ERROR_TEXT[res.error];

	return text ?? String(res.error ?? '?');
}

return baseclass.extend({
	/* sections: uci.sections('aetherproxy', 'node'), current: the value of
	   aetherproxy.main.node, subs: uci.sections('aetherproxy', 'subscription'),
	   results: the object resolved by ap.call('probe_results'). Returns the
	   view model: one row per node plus the progress line. */
	build: function(sections, current, subs, results) {
		const submap = {};

		for (const s of sections_of(subs))
			if (s && s['.name'] != null)
				submap[s['.name']] = s;

		current = (current == null || current === '') ? null : String(current);

		const rows = [];

		for (const s of sections_of(sections)) {
			const id = s['.name'];
			const from_subscription = (s.source != null && s.source !== '' && s.source != 'manual');

			rows.push({
				id,
				name: (s.label != null && s.label !== '') ? s.label : id,
				address: address_text(s),
				summary: summary_text(s),
				source: source_text(s, submap),
				marks: marks_for(s, current),
				probe: probe_column(id, results),
				/* docs/10: the current node can neither be deleted nor be
				   made current, so both operations are unavailable. */
				can_set_current: (current == null || id != current),
				can_delete: (current == null || id != current),
				modal_hint: from_subscription
					? _('This node comes from a subscription; edits will be overwritten at the next subscription update.', 'aether-proxy')
					: null
			});
		}

		return { rows, progress: this.progress(results) };
	},

	/* The progress line while a probe job is running: 「检测中 done/total」.
	   Once the run has finished (probe results carry finished: true) there is
	   no progress to show and null is returned (docs/tasks/m8.md T8.5). */
	progress: function(results) {
		const r = (results && typeof results == 'object') ? results : null;

		if (!r || r.finished)
			return null;

		return fmt(_('Probing %s/%s', 'aether-proxy'), r.done ?? 0, r.total ?? 0);
	},

	/* Text for a finished probe job that did not succeed; null when the job
	   ended fine. job: the object resolved by ap.run_job. */
	job_failure_text: function(job) {
		if (job == null || typeof job != 'object')
			return null;

		if (job.ok === false)
			return fmt(_('The probe job failed: %s (%s).', 'aether-proxy'), job.code ?? '?', job.detail ?? '');

		if (job.state == 'failed')
			return fmt(_('The probe job failed: %s (%s).', 'aether-proxy'), job.error ?? 'CMD_FAILED', 'exit ' + (job.exit ?? '?'));

		return null;
	},

	/* docs/10: one non-empty line per URI; blank lines are dropped and the
	   original line numbers are kept for the failure report. */
	split_import: function(text) {
		const lines = [];
		const raw = String(text ?? '').split(/\r?\n/);

		for (let i = 0; i < raw.length; i++) {
			const uri = raw[i].trim();

			if (uri !== '')
				lines.push({ line: i + 1, uri });
		}

		return lines;
	},

	/* lines: the array returned by split_import(), replies: the node_import
	   replies in the same order. duplicate: false counts as new, duplicate:
	   true as already present, ok: false as failed with line number and
	   code/detail (docs/tasks/m8.md T8.5 scenario 8). */
	summarize_import: function(lines, replies) {
		const list = Array.isArray(lines) ? lines : [];
		const got = Array.isArray(replies) ? replies : [];
		let added = 0;
		let existing = 0;
		const failed = [];

		for (let i = 0; i < list.length; i++) {
			const reply = got[i];

			if (reply && typeof reply == 'object' && reply.ok !== false) {
				if (reply.duplicate === true)
					existing++;
				else
					added++;
			}
			else {
				failed.push({
					line: list[i].line,
					code: (reply && typeof reply == 'object') ? (reply.code ?? '?') : '?',
					detail: (reply && typeof reply == 'object') ? (reply.detail ?? '') : ''
				});
			}
		}

		return {
			added,
			existing,
			failed,
			text: fmt(_('Imported: %s new, %s already present, %s failed.', 'aether-proxy'), added, existing, failed.length)
		};
	}
});
