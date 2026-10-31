'use strict';
// T9.47: real sys.run/observe with only the native syslog sink substituted.
import * as fs from 'fs';
import * as sys from 'aetherproxy.sys';
import * as log from 'aetherproxy.log';
import * as monitor from 'aetherproxy.monitor';
import * as check_cmd from 'aetherproxy.cmd.check';

let base = getenv('TEST_ROOT');
let capture = getenv('CAPTURE');
let failed = 0, passed = 0;
function check(name, ok) {
	printf('%s  T9.47 %s\n', ok ? 'PASS' : 'FAIL', name);
	if (ok) passed++; else failed++;
}
function lines() {
	return filter(split(trim(fs.readfile(capture) ?? ''), '\n'), s => s != '');
}
function reset() {
	fs.writefile(capture, '');
	fs.writefile(`${base}/events.jsonl`, '');
}
log.set_run_dir(base);
for (let configured in [ null, '' ]) {
	let found = check_cmd.find_component('xray', configured, { bin_dir: `${base}/bin` });
	check(`lookup explicit ${configured == null ? 'null' : 'empty'} uses isolated fallback`,
		found?.path == `${base}/bin/xray` && found?.source == 'bin-dir');
}
check('lookup omitted config uses isolated fallback',
	check_cmd.find_component('xray', {}.configured, { bin_dir: `${base}/bin` })?.path == `${base}/bin/xray`);
check('lookup explicit nonexistent path does not fall back',
	check_cmd.find_component('xray', `${base}/absent`) == null);
check('lookup explicit existing path is retained',
	check_cmd.find_component('xray', `${base}/bin/xray`)?.source == 'uci');
for (let level in [ 'info', 'debug' ]) {
	log.set_level(level);
	for (let quiet in [ false, true ]) {
		for (let sample in [
			{ name: 'default', argv: [ 'true' ], rc: 0 },
			{ name: 'null', argv: [ 'true' ], timeout: null, rc: 0 },
			{ name: 'zero', argv: [ 'sleep', '2' ], timeout: 0, rc: 124, timed: true },
			{ name: 'success', argv: [ 'sleep', '0.02' ], timeout: 2, rc: 0 },
			{ name: 'nonzero', argv: [ 'sh', '-c', 'echo original-error >&2; exit 7' ], rc: 7 },
			{ name: 'self124', argv: [ 'sh', '-c', 'exit 124' ], timeout: 2, rc: 124 },
			{ name: 'timeout', argv: [ 'sleep', '3' ], timeout: 0.05, rc: 124, timed: true }
		]) {
			reset();
			let opts = { quiet };
			if ('timeout' in sample) opts.timeout = sample.timeout;
			let res = sys.run(sample.argv, opts);
			let label = `${level} quiet=${quiet} ${sample.name}`;
			check(`${label} execution unchanged`, res.code == sample.rc && res.timed_out == (sample.timed ?? false));
			let debug = filter(lines(), s => index(s, 'CMD_RUN ') >= 0);
			check(`${label} exactly one CMD_RUN at debug only`, length(debug) == (level == 'debug' ? 1 : 0));
			if (length(debug)) {
				let line = json(debug[0]).line;
				let cmd = join(' ', sample.argv);
				let has_cmd = index(line, `cmd=${cmd}`) >= 0 || index(line, `cmd=${sprintf('%J', cmd)}`) >= 0;
				check(`${label} debug command and rc match result`, has_cmd && index(line, `rc=${res.code}`) >= 0);
				let ms = match(line, /ms=([0-9.]+)/);
				check(`${label} nonnegative monotonic ms`, ms != null && +ms[1] >= 0);
				if (sample.name == 'success') check(`${label} positive duration`, ms != null && +ms[1] >= 10);
			}
			let history = fs.readfile(`${base}/events.jsonl`);
			let errors = filter(lines(), s => index(s, 'CMD_FAILED ') >= 0);
			check(`${label} original CMD_FAILED policy`, length(errors) == (sample.rc != 0 && !quiet ? 1 : 0));
			if (sample.name == 'nonzero' && !quiet)
				check(`${label} original stderr retained`, index(history, 'original-error') >= 0);
			check(`${label} no debug in history`, index(history, 'CMD_RUN') < 0);
		}
	}
}
log.set_level('debug');
for (let rc in [ 0, 7 ]) {
	for (let prefix in [ '', '--url=', 'second=https://user:pass@example.com/first?token=subscription-secret ' ]) {
		reset();
		let url = prefix + 'https://user:pass@example.com/sub/path?token=subscription-secret&other=secret#fragment';
		let res = sys.run([ 'sh', '-c', `printf '%s' "$1"; printf '%s' "$1" >&2; exit ${rc}`, 'sh', url ]);
		let text = join('\n', lines()) + fs.readfile(`${base}/events.jsonl`);
		let label = `URL rc=${rc} ${prefix == '' ? 'plain' : (prefix == '--url=' ? 'embedded' : 'multiple')}`;
		check(`${label} keeps execution untouched`, res.stdout == url && res.stderr == url);
		let no_auth = index(text, 'user:pass') < 0;
		let no_query = index(text, 'subscription-secret') < 0 && index(text, 'other=secret') < 0;
		let path_kept = index(text, 'https://example.com/sub/path') >= 0;
		check(`${label} strips userinfo query and fragment from all diagnostics`,
			no_auth && no_query && index(text, '#fragment') < 0 && path_kept);
	}
}

let daemon = {
	ctx: { root: base, bin_dir: `${base}/bin` },
	machine: { dns_tier: 'T2', dns_failsafe: false },
	snapshot: { probe: { timeout: 1, expect_code: 204, url: 'https://example.com/health' },
		dns: { direct_dns_enabled: true, dns_probe_domain: 'example.com' } }
};
let listeners = ' 0: 0100007F:7968 00000000:0000 0A\n 1: 0100007F:794D 00000000:0000 0A\n';
for (let sample in [ 'healthy1', 'healthy2', 'failed', 'not_running', 'disabled', 'failsafe', 'T1', 'dns_failed' ]) {
	reset();
	fs.writefile(`${base}/proc/net/tcp`, sample == 'not_running' ? '' : listeners);
	fs.writefile(`${base}/proc/net/tcp6`, '');
	if (sample == 'failed') fs.writefile(`${base}/fail`, '1');
	else if (fs.stat(`${base}/fail`)) fs.unlink(`${base}/fail`);
	daemon.snapshot.dns.direct_dns_enabled = sample != 'disabled';
	daemon.machine.dns_failsafe = sample == 'failsafe';
	daemon.machine.dns_tier = sample == 'T1' ? 'T1' : 'T2';
	if (sample == 'dns_failed') fs.writefile(`${base}/dns-fail`, '1');
	let obs = monitor.observe(daemon);
	let debug = filter(lines(), s => index(s, 'monitor observation') >= 0);
	check(`monitor ${sample} exactly one round diagnostic`, length(debug) == 1);
	let text = join('\n', debug);
	if (sample == 'not_running')
		check('monitor null differs from failure with not_running reason', obs.proxy_ok == null
			&& index(text, 'proxy_ok=null') >= 0 && index(text, 'proxy_reason=not_running') >= 0);
	else if (sample == 'failed')
		check('monitor actual failure is unhealthy not skipped', obs.proxy_ok == false
			&& index(text, 'proxy_ok=false') >= 0 && index(text, 'proxy_reason=unhealthy') >= 0);
	else
		check(`monitor ${sample} records success and latency`, obs.proxy_ok == true
			&& index(text, 'proxy_ok=true') >= 0 && index(text, 'proxy_latency_ms=') >= 0);
	if (index([ 'disabled', 'failsafe', 'T1' ], sample) >= 0) {
		let reason = sample == 'T1' ? 'proxy_healthy' : sample;
		check(`monitor ${sample} dns skip reason`, obs.dns_ok == null && index(text, `dns_reason=${reason}`) >= 0);
	}
	if (sample == 'dns_failed')
		check('monitor DNS actual failure records unhealthy', obs.dns_ok == false
			&& index(text, 'dns_ok=false') >= 0 && index(text, 'dns_reason=unhealthy') >= 0);
	else if (obs.dns_ok != null)
		check(`monitor ${sample} DNS observed success`, obs.dns_ok == true && index(text, 'dns_ok=true') >= 0);
	check(`monitor ${sample} diagnostics do not add events`, fs.readfile(`${base}/events.jsonl`) == '');
}
reset();
log.set_level('info');
monitor.observe(daemon);
check('monitor info threshold filters round diagnostics', length(lines()) == 0);
check('monitor info threshold leaves history empty', fs.readfile(`${base}/events.jsonl`) == '');
printf('T9.47 debug logging: %d passed, %d failed\n', passed, failed);
exit(failed ? 1 : 0);
