'use strict';

// docs/05 optional node fields: compare whole outbound objects, not just Xray acceptance.
import * as config from 'aetherproxy.config';
import * as outbound from 'aetherproxy.render.outbound';
import * as identity from 'aetherproxy.identity';
import * as node from 'aetherproxy.node';
import * as sub from 'aetherproxy.sub';
import * as uri from 'aetherproxy.uri';

const ID = 'n_11111111111111111111111111111111';
const BASE = {
	protocol: 'vless', address: 'edge.example', port: '443', uuid: 'u',
	transport: 'raw', security: 'tls'
};
const BASE_OUT = {
	tag: 'proxy', protocol: 'vless',
	settings: { address: 'edge.example', port: 443, id: 'u', encryption: 'none' },
	streamSettings: { network: 'raw', security: 'tls', tlsSettings: { serverName: 'edge.example' } }
};
const EXTENSIONS = {
	reality_pqv: 'opaque-pqv', ech_config_list: 'opaque-ech', grpc_multi_mode: '1',
	ws_heartbeat: '30', xhttp_extra: '{"headers":{"X-Test":"yes"}}', mux: '1',
	mux_concurrency: '0', mux_xudp_concurrency: '-1', mux_xudp_udp443: 'allow',
	tcp_fast_open: '1', tcp_mptcp: '1'
};

function rendered_case(name, extra, stream, mux) {
	let expect = { ...BASE_OUT, streamSettings: { ...BASE_OUT.streamSettings, ...(stream ?? {}) } };
	if (extra.security == 'reality')
		delete expect.streamSettings.tlsSettings;
	if (mux != null)
		expect.mux = mux;
	return { name, extra, expect };
}

export const cases = [
	rendered_case('unset extensions omit every new key', {}),
	rendered_case('mux enabled exact key', { mux: '1' }, null, { enabled: true }),
	rendered_case('mux concurrency preserves zero', { mux: '1', mux_concurrency: '0' },
		null, { enabled: true, concurrency: 0 }),
	rendered_case('mux xudpConcurrency preserves minus one', { mux: '1', mux_xudp_concurrency: '-1' },
		null, { enabled: true, xudpConcurrency: -1 }),
	rendered_case('mux xudpProxyUDP443 exact key', { mux: '1', mux_xudp_udp443: 'skip' },
		null, { enabled: true, xudpProxyUDP443: 'skip' }),
	rendered_case('mux off omits all tuning', {
		mux: '0', mux_concurrency: '8', mux_xudp_concurrency: '16', mux_xudp_udp443: 'allow'
	}),
	rendered_case('mux unset omits all tuning', {
		mux_concurrency: '8', mux_xudp_concurrency: '16', mux_xudp_udp443: 'reject'
	}),
	rendered_case('grpc multiMode exact key', { transport: 'grpc', grpc_multi_mode: '1' },
		{ network: 'grpc', grpcSettings: { multiMode: true } }),
	rendered_case('grpc explicit false stays false', { transport: 'grpc', grpc_multi_mode: '0' },
		{ network: 'grpc', grpcSettings: { multiMode: false } }),
	rendered_case('grpc unset multiMode omitted', { transport: 'grpc' },
		{ network: 'grpc', grpcSettings: {} }),
	rendered_case('ws heartbeatPeriod exact key and early data path', {
		transport: 'ws', ws_heartbeat: '30', path: '/ws?ed=2048'
	}, { network: 'ws', wsSettings: { path: '/ws?ed=2048', host: 'edge.example', heartbeatPeriod: 30 } }),
	rendered_case('ws unset heartbeat omitted', { transport: 'ws' },
		{ network: 'ws', wsSettings: { host: 'edge.example' } }),
	rendered_case('xhttp extra is object not string', { transport: 'xhttp', xhttp_extra: EXTENSIONS.xhttp_extra },
		{ network: 'xhttp', xhttpSettings: { host: 'edge.example', extra: { headers: { 'X-Test': 'yes' } } } }),
	rendered_case('xhttp unset extra omitted', { transport: 'xhttp' },
		{ network: 'xhttp', xhttpSettings: { host: 'edge.example' } }),
	rendered_case('tls echConfigList exact key', { ech_config_list: 'opaque-ech' },
		{ tlsSettings: { serverName: 'edge.example', echConfigList: 'opaque-ech' } }),
	rendered_case('reality mldsa65Verify exact key', {
		security: 'reality', sni: 'edge.example', reality_pbk: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
		reality_pqv: 'opaque-pqv'
	}, { security: 'reality', realitySettings: {
		serverName: 'edge.example', fingerprint: 'chrome',
		publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', mldsa65Verify: 'opaque-pqv'
	} }),
	rendered_case('sockopt tcpFastOpen exact key', { tcp_fast_open: '1' },
		{ sockopt: { tcpFastOpen: true } }),
	rendered_case('sockopt tcpMptcp exact key', { tcp_mptcp: '1' },
		{ sockopt: { tcpMptcp: true } }),
	rendered_case('sockopt both keys', { tcp_fast_open: '1', tcp_mptcp: '1' },
		{ sockopt: { tcpFastOpen: true, tcpMptcp: true } }),
	rendered_case('sockopt disabled omitted', { tcp_fast_open: '0', tcp_mptcp: '0' }),
	rendered_case('other transport and security extensions do not leak', {
		ws_heartbeat: '30', grpc_multi_mode: '1', xhttp_extra: '{}', reality_pqv: 'opaque-pqv'
	}),
	{ name: 'all extensions roundtrip through node_options and import field table', fn: 'options', expect: true },
	{ name: 'all extensions excluded from strong and weak identity', fn: 'identity', expect: true },
	{ name: 'subscription deletes every omitted extension and reuses ID', fn: 'delete', expect: true },
	{ name: 'subscription writes every extension', fn: 'set', expect: true },
	{ name: 'unchanged grpc multi does not update or reload', fn: 'unchanged', mode: 'multi', expect: true },
	{ name: 'unchanged grpc gun does not update or reload', fn: 'unchanged', mode: 'gun', expect: true }
];

const INVALID = [
	[ 'extra invalid JSON', { xhttp_extra: '{bad' }, 'xhttp_extra:invalid_value' ],
	[ 'extra array', { xhttp_extra: '[]' }, 'xhttp_extra:invalid_value' ],
	[ 'extra null', { xhttp_extra: 'null' }, 'xhttp_extra:invalid_value' ],
	[ 'extra scalar', { xhttp_extra: '42' }, 'xhttp_extra:invalid_value' ],
	[ 'mux Vision conflict', { mux: '1', flow: 'xtls-rprx-vision' }, 'mux:conflict' ],
	[ 'mux Vision UDP443 conflict', { mux: '1', flow: 'xtls-rprx-vision-udp443' }, 'mux:conflict' ],
	[ 'legacy flow rejects enum', { flow: 'xtls-rprx-direct' }, 'flow:invalid_enum' ],
	[ 'unknown flow rejects enum', { flow: 'arbitrary' }, 'flow:invalid_enum' ],
	[ 'mux concurrency below minimum', { mux_concurrency: '-2' }, 'mux_concurrency:out_of_range' ],
	[ 'mux concurrency above maximum', { mux_concurrency: '1025' }, 'mux_concurrency:out_of_range' ],
	[ 'xudp concurrency below minimum', { mux_xudp_concurrency: '-2' }, 'mux_xudp_concurrency:out_of_range' ],
	[ 'xudp concurrency above maximum', { mux_xudp_concurrency: '1025' }, 'mux_xudp_concurrency:out_of_range' ],
	[ 'mux UDP443 invalid enum', { mux_xudp_udp443: 'yes' }, 'mux_xudp_udp443:invalid_enum' ],
	[ 'heartbeat below minimum', { ws_heartbeat: '0' }, 'ws_heartbeat:out_of_range' ],
	[ 'heartbeat above maximum', { ws_heartbeat: '3601' }, 'ws_heartbeat:out_of_range' ],
	[ 'heartbeat fractional', { ws_heartbeat: '1.5' }, 'ws_heartbeat:invalid_int' ]
];
for (let item in INVALID)
	push(cases, { name: item[0], fn: 'invalid', extra: item[1], expect: [ 'node.' + ID + '.' + item[2] ] });
for (let field in [ 'mux', 'grpc_multi_mode', 'tcp_fast_open', 'tcp_mptcp' ])
	push(cases, { name: field + ' rejects non-UCI bool', fn: 'invalid', extra: { [field]: 'true' },
		expect: [ 'node.' + ID + '.' + field + ':invalid_bool' ] });
for (let value in [ '-1', '0', '1024' ])
	push(cases, { name: 'concurrency boundary ' + value, fn: 'invalid',
		extra: { mux_concurrency: value, mux_xudp_concurrency: value }, expect: [] });
for (let value in [ '1', '3600' ])
	push(cases, { name: 'heartbeat boundary ' + value, fn: 'invalid', extra: { ws_heartbeat: value }, expect: [] });
for (let value in [ 'reject', 'allow', 'skip' ])
	push(cases, { name: 'UDP443 enum ' + value, fn: 'invalid', extra: { mux_xudp_udp443: value }, expect: [] });
push(cases, { name: 'Vision with disabled Mux is valid', fn: 'invalid',
	extra: { mux: '0', flow: 'xtls-rprx-vision' }, expect: [] });
push(cases, { name: 'empty JSON object valid', fn: 'invalid', extra: { xhttp_extra: '{}' }, expect: [] });

// Compare the complete outbound to prove accepted flow values survive normalization unchanged.
for (let flow in [ 'xtls-rprx-vision', 'xtls-rprx-vision-udp443' ]) {
	for (let mux in [ null, '0' ])
		push(cases, { name: flow + ' renders unchanged with mux ' + (mux ?? 'unset'),
			extra: { flow, mux }, expect: { ...BASE_OUT, settings: { ...BASE_OUT.settings, flow } } });
}
push(cases, rendered_case('empty flow is unset and allows Mux', { flow: '', mux: '1' }, null, { enabled: true }));
push(cases, { name: 'empty flow normalizes to null', fn: 'flow', extra: { flow: '' }, expect: null });

function extension_plan(remove) {
	let old = { ...BASE, port: 443, ...(remove ? EXTENSIONS : {}) };
	let fresh = { ...BASE, port: 443, ...(remove ? {} : EXTENSIONS) };
	let result = sub.plan({ [ID]: old }, { nodes: [ fresh ] }, {
		sub_name: 's_1234abcd', current: ID, new_id: () => die('must reuse the old identity')
	});
	let changes = filter(result.changes, c => index(keys(EXTENSIONS), c.option) >= 0);
	let identity_reused = result.counts.added == 0 && result.counts.removed == 0 && result.counts.updated == 1;
	let correct_operations = filter(changes, c => {
		if (c.section != ID || c.op != (remove ? 'delete_option' : 'set'))
			return false;
		return remove || c.value == EXTENSIONS[c.option];
	});
	return identity_reused && result.current_changed && length(changes) == length(keys(EXTENSIONS))
		&& length(correct_operations) == length(keys(EXTENSIONS));
}

function unchanged_grpc(mode) {
	let parsed = uri.parse_line('trojan://secret@edge.example:443?type=grpc&mode=' + mode + '#same-label').node;
	let raw = node.node_options(parsed);
	let old = config.normalize({ nodes: { [ID]: raw } }).snapshot.nodes[ID];
	let result = sub.plan({ [ID]: old }, { nodes: [ parsed ] }, {
		sub_name: 's_1234abcd', current: ID, new_id: () => die('must reuse the old identity')
	});
	return result.counts.updated == 0 && !result.current_changed
		&& !length(filter(result.changes, v => v.option == 'grpc_multi_mode'));
}

export function run(c) {
	if (c.fn == 'unchanged')
		return unchanged_grpc(c.mode);
	if (c.fn == 'identity')
		return sprintf('%.J', identity.keys(BASE)) == sprintf('%.J', identity.keys({ ...BASE, ...EXTENSIONS }));
	if (c.fn == 'delete' || c.fn == 'set')
		return extension_plan(c.fn == 'delete');
	if (c.fn == 'options') {
		let options = node.node_options({ ...BASE, ...EXTENSIONS });
		let plan = node.plan_changes({ ...BASE, ...EXTENSIONS }, ID);
		return length(filter(keys(EXTENSIONS), k => options[k] == EXTENSIONS[k])) == length(keys(EXTENSIONS))
			&& length(filter(plan.changes, v => v.op == 'set' && v.value == EXTENSIONS[v.option]))
				== length(keys(EXTENSIONS));
	}
	let normalized = config.normalize({ nodes: { [ID]: { ...BASE, ...(c.extra ?? {}) } } });
	if (c.fn == 'invalid')
		return map(normalized.errors ?? [], e => e.field + ':' + e.code);
	if (c.fn == 'flow')
		return normalized.ok ? normalized.snapshot.nodes[ID].flow : normalized.errors;
	if (!normalized.ok)
		return normalized.errors;
	let actual = outbound.build_outbound(normalized.snapshot.nodes[ID]);
	return actual;
};
