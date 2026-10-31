'use strict';
'require baseclass';

/*
 * Pure view model for the nodes page (docs/10 「节点页」, docs/tasks/m8.md T8.5).
 *
 * build() turns the raw UCI sections and the probe results into everything the
 * view renders: row texts, marks, the TCP reachability column wording, the
 * progress line and which per-row operations are allowed (the current node can
 * not be deleted). split_import()/summarize_import()
 * handle the URI import box: line splitting keeps the original line numbers and
 * the three reply kinds (new, duplicate, failed) are tallied here. Nothing in
 * this module issues requests or touches the DOM; every msgid used here must
 * have an entry in po/zh_Hans/aether-proxy.po. Undefined results mark the first
 * deferred read (docs/10 「其余页面先出页面」), not an unprobed node. Local
 * pending IDs cover the gap before the first job refresh (docs/10 「节点页修正」).
 * Selection marks and stale names follow 「节点页第二轮修正」 (T10.25).
 * T10.71 removes node-page switching; Overview is the only UI entry.
 * Protocol columns and manual node IDs follow 「节点表的协议列」「添加节点」 (T10.26).
 * Parse cleanup includes the advanced options from 「节点编辑框新字段」 (T10.30).
 * Required-field metadata mirrors schema.uc (docs/10 r17, T10.58).
 * Format validators and protocol method choices follow docs/10 r18 (T10.61),
 * config.uc/check_node and net.uc; UUID follows docs/05 rule 7 ahead of T9.37.
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

/* docs/10 「节点表的协议列」: protocol names are separate from the transport
   diagnostics, with defaults from docs/05 「config node」. */
const PROTOCOL_NAMES = {
	vless: _('VLESS', 'aether-proxy'),
	vmess: _('VMess', 'aether-proxy'),
	trojan: _('Trojan', 'aether-proxy'),
	shadowsocks: _('Shadowsocks', 'aether-proxy'),
	socks: _('SOCKS', 'aether-proxy'),
	http: _('HTTP', 'aether-proxy'),
	wireguard: _('WireGuard', 'aether-proxy')
};

function protocol_text(protocol) {
	return Object.prototype.hasOwnProperty.call(PROTOCOL_NAMES, protocol)
		? PROTOCOL_NAMES[protocol] : (protocol || '–');
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
function probe_column(id, results, local_pending) {
	if (local_pending?.includes(id))
		return _('Probing…', 'aether-proxy');
	if (results === undefined)
		return _('Reading…', 'aether-proxy');
	/* A failed read says so in each cell and gives the reason once, in the
	   progress line (design lead's decision on the T10.16 TODO, 2026-10-21):
	   repeating the RPC code in every row is noise. */
	if (results?.ok === false)
		return _('Reading failed', 'aether-proxy');
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

/* Only these fields come from node_parse (docs/05 「config node」). Clearing
   them prevents credentials/transport settings from a previous URI leaking
   into the next one; source, stale and match_* are not protocol fields. */
const NODE_FIELDS = [
	'label', 'protocol', 'address', 'port', 'secret_key', 'peer_public_key', 'local_address', 'preshared_key',
	'keepalive', 'uuid', 'username', 'password', 'method', 'flow', 'encryption',
	'transport', 'host', 'path', 'service_name', 'xhttp_mode', 'header_type', 'security',
	'sni', 'alpn', 'fingerprint', 'pinned_cert_sha256', 'verify_name',
	'reality_pbk', 'reality_sid', 'reality_spx', 'reality_pqv', 'ech_config_list',
	'grpc_multi_mode', 'ws_heartbeat', 'xhttp_extra', 'mux', 'mux_concurrency',
	'mux_xudp_concurrency', 'mux_xudp_udp443', 'tcp_fast_open', 'tcp_mptcp'
];

/* Keep this ordered list in sync with schema.uc; the test exports it through ucode. */
const SS_METHODS = [
	'aes-128-gcm', 'aes-256-gcm', 'chacha20-poly1305', 'chacha20-ietf-poly1305',
	'xchacha20-poly1305', 'xchacha20-ietf-poly1305',
	'2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm', '2022-blake3-chacha20-poly1305'
];

/* Whole-value match, like the backend's anchored regexes. */
function full_match(pattern, value) {
	return value.match(pattern)?.[0] === value;
}

function valid_address(value) {
	if (/^[0-9.]+$/.test(value)) {
		const octets = value.split('.');
		return octets.length === 4 && octets.every(o => full_match(/^(0|[1-9][0-9]{0,2})$/, o) && +o <= 255);
	}
	return value.length <= 253 && value.split('.').every(label =>
		label.length <= 63 && full_match(/^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$/, label));
}

function valid_uuid(value) {
	const bytes = new TextEncoder().encode(value).length;
	if (bytes >= 1 && bytes <= 30)
		return true;
	return bytes >= 32 && bytes <= 36 && full_match(/^[0-9a-fA-F]{32}$/, value.replace(/-/g, ''));
}

/* Optional emptiness is handled by modal required-field preflight, not format checks. */
function optional_format(check, message) {
	return (id, value) => value == null || value === '' || check(value) ? true : message;
}

return baseclass.extend({
	probe_column,
	ss_methods: SS_METHODS,
	validate_address: optional_format(valid_address,
		_('Must be a valid IPv4 address or domain name', 'aether-proxy')),
	validate_wireguard_key: optional_format(value => typeof value === 'string'
		&& full_match(/^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/, value),
		_('Must be a Base64-encoded 32-byte key', 'aether-proxy')),
	validate_local_address: optional_format(value => {
		const parts = value.split('/');
		return parts.length <= 2 && /^[0-9.]+$/.test(parts[0]) && valid_address(parts[0])
			&& (parts.length === 1 || (full_match(/^(0|[1-9][0-9]?)$/, parts[1]) && +parts[1] <= 32));
	}, _('Must be an IPv4 tunnel address or CIDR', 'aether-proxy')),
	validate_uuid: optional_format(valid_uuid,
		_('UUID must be 32 hexadecimal digits (hyphens allowed), or a string of at most 30 bytes', 'aether-proxy')),
	validate_method: optional_format(value => SS_METHODS.includes(value),
		_('Unsupported encryption method', 'aether-proxy')),
	validate_reality_pbk: optional_format(value => full_match(/^[A-Za-z0-9_-]{43}$/, value),
		_('REALITY public key must be 43 base64url characters', 'aether-proxy')),
	validate_reality_sid: optional_format(value => full_match(/^([0-9a-fA-F]{2}){0,8}$/, value),
		_('Short ID must be hexadecimal, with an even length of at most 16', 'aether-proxy')),
	validate_pinned_cert_sha256: optional_format(value => value.split(',').every(item =>
		item.trim() === '' || full_match(/^[0-9a-fA-F]{64}$/, item.trim().replace(/:/g, ''))),
		_('Each item must be 64 hexadecimal digits (colons allowed)', 'aether-proxy')),
	node_fields: NODE_FIELDS,
	required_fields: {
		protocol: { required: true },
		address: { required: true },
		port: { required: true },
		secret_key: { protocols: ['wireguard'], required: true },
		peer_public_key: { protocols: ['wireguard'], required: true },
		local_address: { protocols: ['wireguard'], required: true },
		uuid: { protocols: ['vless', 'vmess'], required: true },
		password: { protocols: ['trojan', 'shadowsocks', 'socks', 'http'], required: ['trojan', 'shadowsocks'] },
		method: { protocols: ['shadowsocks', 'vmess'], required: ['shadowsocks'] },
		sni: { requires_when: { field: 'security', value: 'reality' } },
		reality_pbk: { requires_when: { field: 'security', value: 'reality' } }
	},

	/* Random bytes are injected by the view, keeping UUID/collision tests pure.
	   Work on a copy so setting UUID bits never changes the caller's buffer. */
	new_id: function(existing, bytes) {
		let id;
		do {
			const random = Array.from(bytes());
			random[6] = (random[6] & 0x0f) | 0x40;
			random[8] = (random[8] & 0x3f) | 0x80;
			id = 'n_' + random.map(b => b.toString(16).padStart(2, '0')).join('');
		} while (existing.includes(id));
		return id;
	},

	/* sections: uci.sections('aetherproxy', 'node'), current: the value of
	   aetherproxy.main.node, subs: uci.sections('aetherproxy', 'subscription'),
	   results: the object resolved by ap.call('probe_results'), local_pending:
	   IDs awaiting the first job refresh. Returns one row per node and progress. */
	build: function(sections, current, subs, results, local_pending) {
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
				name: ((s.label != null && s.label !== '') ? s.label : id)
					+ (s.stale == '1' ? _('(stale)', 'aether-proxy') : ''),
				stale: s.stale == '1',
				current: id === current,
				protocol: protocol_text(s.protocol),
				transport_security: [ s.transport || 'raw', s.security || 'none' ].join(' / '),
				source: source_text(s, submap),
				probe: probe_column(id, results, local_pending),
				/* T10.71: switching belongs to Overview; keep deletion protection here. */
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

		if (r?.ok === false)
			return fmt(_('Reading probe results failed: %s', 'aether-proxy'),
				(r.code ?? 'RPC_FAILED') + (r.detail ? ': ' + r.detail : ''));

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
