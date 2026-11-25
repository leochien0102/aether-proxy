#!/usr/bin/env python3
"""T16.82: reject unsupported tls:// DNS upstreams for aether-dns before teardown/takeover."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('version_gate', ROOT / 'tests/daemon/version-gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

passed = 0
failed = 0


def check(name, condition, detail=''):
	global passed, failed
	if condition:
		passed += 1
		print('PASS  T16.82 ' + name, flush=True)
	else:
		failed += 1
		suffix = f' ({detail})' if detail else ''
		print('FAIL  T16.82 ' + name + suffix, flush=True)


def install_engine(path, engine_name, version):
	body = (ROOT / 'tests/stubs/daemon-bin/chinadns-ng').read_text()
	reject_tls = ''
	if engine_name == 'aether-dns':
		reject_tls = '''if [ "$1" = -C ] && grep -q 'tls://' "$2"; then
	printf 'engine-reject-tls %s %s\\n' "$0" "$2" >> "$STUB_LOG"
	printf 'aether-dns: tls:// upstream unsupported\\n' >&2
	exit 1
fi
'''
	prefix = f'''#!/bin/sh
if [ "$1" = -V ]; then
	printf 'Aether-DNS {version}\\n'
	exit 0
fi
printf 'engine-start {engine_name} %s %s\\n' "$$" "$*" >> "$STUB_LOG"
{reject_tls}'''
	candidate = path.with_name(path.name + '.new')
	candidate.write_text(prefix + body.removeprefix('#!/bin/sh\n'))
	candidate.chmod(0o755)
	candidate.replace(path)


def write_config(f, *, china_dns, direct_dns, direct_dns_enabled=False, chinadns_bin=None, mode='bypass_cn'):
	lines = [
		"config main 'main'",
		"\toption enabled '1'",
		f"\toption mode '{mode}'",
		"\toption node 'n_00000000000000000000000000000001'",
		"\tlist lan_ifaces 'br-lan'",
	]
	if chinadns_bin is not None:
		lines.append(f"\toption chinadns_bin '{chinadns_bin}'")
	lines += [
		"",
		"config dns 'dns'",
	]
	for entry in china_dns:
		lines.append(f"\tlist china_dns '{entry}'")
	lines.append("\tlist trust_dns '8.8.8.8'")
	lines.append(f"\toption direct_dns_enabled '{'1' if direct_dns_enabled else '0'}'")
	for entry in direct_dns:
		lines.append(f"\tlist direct_dns '{entry}'")
	lines += [
		"",
		"config node 'n_00000000000000000000000000000001'",
		"\toption protocol 'trojan'",
		"\toption security 'tls'",
		"\toption address '203.0.113.10'",
		"\toption port '443'",
		"\toption password 'secret'",
		"",
	]
	(f.root / 'etc/config/aetherproxy').write_text('\n'.join(lines))


def run_check(f):
	r = subprocess.run([str(gate.UCODE), '-S', str(gate.ENTRY), '--', 'check', '--json',
		*f.args, '--run-dir', str(f.run)], env=f.env, capture_output=True, text=True, timeout=20)
	return r.returncode, json.loads(r.stdout), r.stderr


def wait_reload(f, child, before, expect_ok):
	deadline = time.monotonic() + 15
	while time.monotonic() < deadline:
		st = f.state()
		if st.get('last_reload', {}).get('at', 0) > before:
			return st
		if child.poll() is not None:
			raise AssertionError((f.root / 'stderr').read_text())
		time.sleep(0.03)
	raise AssertionError(('reload timed out', f.state(), (f.root / 'stderr').read_text()))


def proc_alive(pid):
	return Path(f'/proc/{pid}/stat').exists()


def scenario_aether_dns_tls_cold(base):
	# 1a. aether-dns + tls:// in china_dns: check & cold start fail early, then SIGHUP recovers.
	f = gate.Fixture(base, 'aether-china-tls', 'chinadns-ng', '2025.08.09')
	install_engine(f.bin / 'aether-dns', 'aether-dns', '1.0.0')
	write_config(f, china_dns=['tls://dns.alidns.com@223.5.5.5', '114.114.114.114'],
		direct_dns=['tcp://9.9.9.9'], direct_dns_enabled=False)

	rc, out, stderr = run_check(f)
	check('aether-dns + china_dns TLS: check rejects with PRECHECK_FAILED',
		rc == 1 and out.get('ok') is False and out.get('code') == 'PRECHECK_FAILED' and stderr == '',
		f'rc={rc} out={out}')
	errs = out.get('errors') or []
	check('aether-dns + china_dns TLS: check diagnostic names engine and field',
		any('aether-dns' in e.get('item', '') and 'dns.china_dns' in e.get('item', '')
			and 'aether-dns' in e.get('detail', '') and 'dns.china_dns' in e.get('detail', '')
			and 'tls://dns.alidns.com@223.5.5.5' in e.get('detail', '') for e in errs),
		f'errors={errs}')

	with f.daemon() as child:
		f.wait_started(child)
		st = f.state()
		events = f.events()
		calls = f.calls.read_text()
		check('aether-dns + china_dns TLS: cold start fails at precheck',
			st.get('state') == 'error' and st.get('failed_step') == 'precheck', f'state={st}')
		check('aether-dns + china_dns TLS: PRECHECK_FAILED event names engine and field',
			any(e.get('code') == 'PRECHECK_FAILED'
				and 'dns_upstream:aether-dns:dns.china_dns' in (e.get('args', {}).get('missing') or [])
				for e in events), f'events={events}')
		check('aether-dns + china_dns TLS: no child start or system takeover',
			'engine-start' not in calls and 'xray run ' not in calls
			and not (f.root / 'chinadns.pid').exists() and not (f.root / 'nft-table').exists(),
			f'calls={calls}')

		# Fix config and send SIGHUP while daemon is in error/retry state -> recovers cleanly.
		write_config(f, china_dns=['114.114.114.114'], direct_dns=['tcp://9.9.9.9'], direct_dns_enabled=False)
		child.send_signal(signal.SIGHUP)
		deadline = time.monotonic() + 15
		while time.monotonic() < deadline and f.state().get('state') != 'running':
			time.sleep(0.03)
		check('aether-dns + china_dns TLS: recovers after config fix + SIGHUP',
			f.state().get('state') == 'running'
			and f.state().get('components', {}).get('dns', {}).get('engine') == 'aether-dns',
			f'state={f.state()}')

	# 1b. aether-dns + tls:// in direct_dns with direct_dns_enabled=1: rejected early.
	f2 = gate.Fixture(base, 'aether-direct-tls-on', 'chinadns-ng', '2025.08.09')
	install_engine(f2.bin / 'aether-dns', 'aether-dns', '1.0.0')
	write_config(f2, china_dns=['114.114.114.114'],
		direct_dns=['tls://dns.google@8.8.8.8'], direct_dns_enabled=True)

	rc, out, _ = run_check(f2)
	check('aether-dns + direct_dns(enabled=1) TLS: check rejects with PRECHECK_FAILED',
		rc == 1 and out.get('code') == 'PRECHECK_FAILED'
		and any('aether-dns' in e.get('item', '') and 'dns.direct_dns' in e.get('item', '')
			for e in (out.get('errors') or [])),
		f'rc={rc} out={out}')

	with f2.daemon() as child:
		f2.wait_started(child)
		check('aether-dns + direct_dns(enabled=1) TLS: cold start fails at precheck untouched',
			f2.state().get('state') == 'error' and f2.state().get('failed_step') == 'precheck'
			and 'engine-start' not in f2.calls.read_text() and not (f2.root / 'nft-table').exists(),
			f'state={f2.state()} calls={f2.calls.read_text()}')


def scenario_aether_dns_supported_and_unused_direct(base):
	# 2a. aether-dns + ordinary supported upstreams (direct_dns_enabled=1 with tcp://) succeeds.
	f = gate.Fixture(base, 'aether-supported', 'chinadns-ng', '2025.08.09')
	install_engine(f.bin / 'aether-dns', 'aether-dns', '1.0.0')
	write_config(f, china_dns=['114.114.114.114', 'udp://223.5.5.5#53'],
		direct_dns=['tcp://9.9.9.9'], direct_dns_enabled=True)

	rc, out, stderr = run_check(f)
	check('aether-dns + supported upstreams: check passes',
		rc == 0 and out.get('ok') is True and stderr == '', f'rc={rc} out={out}')
	with f.daemon() as child:
		f.wait_started(child)
		check('aether-dns + supported upstreams: daemon starts running',
			f.state().get('state') == 'running'
			and f.state().get('components', {}).get('dns', {}).get('engine') == 'aether-dns',
			f'state={f.state()}')

	# 2b. aether-dns + tls:// in direct_dns when direct_dns_enabled=0 (not handed to DNS engine) succeeds.
	f2 = gate.Fixture(base, 'aether-direct-tls-off', 'chinadns-ng', '2025.08.09')
	install_engine(f2.bin / 'aether-dns', 'aether-dns', '1.0.0')
	write_config(f2, china_dns=['114.114.114.114'],
		direct_dns=['tls://dns.google@8.8.8.8'], direct_dns_enabled=False)

	rc, out, stderr = run_check(f2)
	check('aether-dns + direct_dns(enabled=0) TLS: check passes without false reject',
		rc == 0 and out.get('ok') is True and stderr == '', f'rc={rc} out={out}')
	with f2.daemon() as child:
		f2.wait_started(child)
		conf = (f2.run / 'current/chinadns.conf').read_text()
		check('aether-dns + direct_dns(enabled=0) TLS: starts running and conf has no tls://',
			f2.state().get('state') == 'running' and 'tls://' not in conf,
			f'state={f2.state()}')


def scenario_chinadns_ng_tls_allowed(base):
	# 3. chinadns-ng + valid tls:// in china_dns and direct_dns(enabled=1) is NOT falsely rejected.
	f = gate.Fixture(base, 'chinadns-tls-ok', 'chinadns-ng', '2025.08.09')
	install_engine(f.bin / 'chinadns-ng', 'chinadns-ng', '2025.08.09')
	write_config(f, china_dns=['tls://dns.alidns.com@223.5.5.5'],
		direct_dns=['tls://dns.google@8.8.8.8'], direct_dns_enabled=True)

	rc, out, stderr = run_check(f)
	check('chinadns-ng + valid TLS: check passes',
		rc == 0 and out.get('ok') is True and stderr == '', f'rc={rc} out={out}')
	with f.daemon() as child:
		f.wait_started(child)
		conf = (f.run / 'current/chinadns.conf').read_text()
		check('chinadns-ng + valid TLS: daemon starts running with tls:// in conf',
			f.state().get('state') == 'running'
			and f.state().get('components', {}).get('dns', {}).get('engine') == 'chinadns-ng'
			and 'tls://dns.google@8.8.8.8' in conf and 'tls://dns.alidns.com@223.5.5.5' in conf,
			f'state={f.state()}')


def scenario_live_reload_same_engine(base):
	# 4. Running aether-dns receives incompatible TLS upstream via real SIGHUP reload,
	#    then recovers on corrected config.
	f = gate.Fixture(base, 'reload-aether-tls', 'chinadns-ng', '2025.08.09')
	install_engine(f.bin / 'aether-dns', 'aether-dns', '1.0.0')
	write_config(f, china_dns=['114.114.114.114'], direct_dns=['tcp://9.9.9.9'], direct_dns_enabled=False)

	with f.daemon() as child:
		f.wait_started(child)
		check('reload-same: initial running with aether-dns',
			f.state().get('state') == 'running'
			and f.state().get('components', {}).get('dns', {}).get('engine') == 'aether-dns')
		old_pid = int((f.root / 'chinadns.pid').read_text())
		old_conf = (f.run / 'current/chinadns.conf').read_bytes()
		old_hashes = f.state().get('render_hash')
		old_starts = f.calls.read_text().count('engine-start ')
		old_applied = sum(1 for e in f.events() if e.get('code') == 'RELOAD_APPLIED')
		before = f.state().get('last_reload', {}).get('at', 0)

		# Submit incompatible candidate (china_dns has tls://)
		write_config(f, china_dns=['tls://dns.alidns.com@223.5.5.5'],
			direct_dns=['tcp://9.9.9.9'], direct_dns_enabled=False)
		time.sleep(0.05)
		child.send_signal(signal.SIGHUP)
		st = wait_reload(f, child, before, expect_ok=False)

		check('reload-same: last_reload.ok is False with diagnostic',
			st.get('last_reload', {}).get('ok') is False
			and 'aether-dns' in (st.get('last_reload', {}).get('error') or '')
			and 'dns.china_dns' in (st.get('last_reload', {}).get('error') or ''),
			f'last_reload={st.get("last_reload")}')
		check('reload-same: old DNS child still alive with same PID',
			proc_alive(old_pid) and int((f.root / 'chinadns.pid').read_text()) == old_pid,
			f'old_pid={old_pid}')
		check('reload-same: no new DNS child started',
			f.calls.read_text().count('engine-start ') == old_starts,
			f'calls={f.calls.read_text()}')
		check('reload-same: active config and render_hash untouched',
			(f.run / 'current/chinadns.conf').read_bytes() == old_conf
			and st.get('render_hash') == old_hashes,
			f'hashes={st.get("render_hash")}')
		check('reload-same: no RELOAD_APPLIED emitted and PRECHECK_FAILED recorded',
			sum(1 for e in f.events() if e.get('code') == 'RELOAD_APPLIED') == old_applied
			and any(e.get('code') == 'PRECHECK_FAILED'
				and 'dns_upstream:aether-dns:dns.china_dns' in (e.get('args', {}).get('missing') or [])
				for e in f.events()),
			f'events={f.events()}')

		# Correct config (ordinary upstream change) and reload again -> succeeds.
		before2 = st['last_reload']['at']
		write_config(f, china_dns=['223.5.5.5'], direct_dns=['tcp://9.9.9.9'], direct_dns_enabled=False)
		time.sleep(0.05)
		child.send_signal(signal.SIGHUP)
		st2 = wait_reload(f, child, before2, expect_ok=True)
		check('reload-same: corrected config reloads successfully',
			st2.get('last_reload', {}).get('ok') is True
			and sum(1 for e in f.events() if e.get('code') == 'RELOAD_APPLIED') == old_applied + 1
			and '223.5.5.5' in (f.run / 'current/chinadns.conf').read_text(),
			f'state={st2}')


def scenario_live_reload_engine_switch(base):
	# 5a. Running chinadns-ng WITH tls:// switches candidate engine to aether-dns -> must reject!
	f = gate.Fixture(base, 'reload-switch-to-aether', 'chinadns-ng', '2025.08.09')
	chinadns_path = f.bin / 'chinadns-ng'
	aether_path = f.bin / 'aether-dns'
	install_engine(chinadns_path, 'chinadns-ng', '2025.08.09')
	install_engine(aether_path, 'aether-dns', '1.0.0')
	write_config(f, china_dns=['114.114.114.114'], direct_dns=['tls://dns.google@8.8.8.8'],
		direct_dns_enabled=True, chinadns_bin=str(chinadns_path))

	with f.daemon() as child:
		f.wait_started(child)
		check('reload-switch-to-aether: initial running with chinadns-ng + TLS',
			f.state().get('state') == 'running'
			and f.state().get('components', {}).get('dns', {}).get('engine') == 'chinadns-ng')
		old_pid = int((f.root / 'chinadns.pid').read_text())
		old_conf = (f.run / 'current/chinadns.conf').read_bytes()
		old_hashes = f.state().get('render_hash')
		old_starts = f.calls.read_text().count('engine-start ')
		old_applied = sum(1 for e in f.events() if e.get('code') == 'RELOAD_APPLIED')
		before = f.state().get('last_reload', {}).get('at', 0)

		# Switch candidate engine to aether-dns while keeping tls:// in direct_dns (enabled=1)
		write_config(f, china_dns=['114.114.114.114'], direct_dns=['tls://dns.google@8.8.8.8'],
			direct_dns_enabled=True, chinadns_bin=str(aether_path))
		time.sleep(0.05)
		child.send_signal(signal.SIGHUP)
		st = wait_reload(f, child, before, expect_ok=False)

		check('reload-switch-to-aether: rejected by candidate engine with diagnostic',
			st.get('last_reload', {}).get('ok') is False
			and 'aether-dns' in (st.get('last_reload', {}).get('error') or '')
			and 'dns.direct_dns' in (st.get('last_reload', {}).get('error') or ''),
			f'last_reload={st.get("last_reload")}')
		check('reload-switch-to-aether: old chinadns-ng still alive with same PID',
			proc_alive(old_pid) and int((f.root / 'chinadns.pid').read_text()) == old_pid,
			f'old_pid={old_pid}')
		check('reload-switch-to-aether: no aether-dns child started',
			f.calls.read_text().count('engine-start ') == old_starts
			and 'engine-start aether-dns' not in f.calls.read_text(),
			f'calls={f.calls.read_text()}')
		check('reload-switch-to-aether: active config and engine metadata untouched',
			(f.run / 'current/chinadns.conf').read_bytes() == old_conf
			and st.get('render_hash') == old_hashes
			and st.get('components', {}).get('dns', {}).get('engine') == 'chinadns-ng',
			f'components={st.get("components")}')
		check('reload-switch-to-aether: no RELOAD_APPLIED and PRECHECK_FAILED emitted',
			sum(1 for e in f.events() if e.get('code') == 'RELOAD_APPLIED') == old_applied
			and any(e.get('code') == 'PRECHECK_FAILED'
				and 'dns_upstream:aether-dns:dns.direct_dns' in (e.get('args', {}).get('missing') or [])
				for e in f.events()),
			f'events={f.events()}')

		# Correct config (switch direct_dns to tcp://9.9.9.9 while keeping aether-dns) -> succeeds!
		before2 = st['last_reload']['at']
		write_config(f, china_dns=['114.114.114.114'], direct_dns=['tcp://9.9.9.9'],
			direct_dns_enabled=True, chinadns_bin=str(aether_path))
		time.sleep(0.05)
		child.send_signal(signal.SIGHUP)
		st2 = wait_reload(f, child, before2, expect_ok=True)
		new_pid = int((f.root / 'chinadns.pid').read_text())
		check('reload-switch-to-aether: corrected config switches to aether-dns',
			st2.get('last_reload', {}).get('ok') is True
			and st2.get('components', {}).get('dns', {}).get('engine') == 'aether-dns'
			and new_pid != old_pid
			and sum(1 for e in f.events() if e.get('code') == 'RELOAD_APPLIED') == old_applied + 1,
			f'state={st2}')

		# 5b. Reverse switch: running aether-dns -> switch candidate to chinadns-ng + TLS in one reload -> succeeds!
		before3 = st2['last_reload']['at']
		write_config(f, china_dns=['114.114.114.114'], direct_dns=['tls://dns.google@8.8.8.8'],
			direct_dns_enabled=True, chinadns_bin=str(chinadns_path))
		time.sleep(0.05)
		child.send_signal(signal.SIGHUP)
		st3 = wait_reload(f, child, before3, expect_ok=True)
		check('reload-switch-to-chinadns: candidate chinadns-ng + TLS succeeds (not judged by old aether-dns)',
			st3.get('last_reload', {}).get('ok') is True
			and st3.get('components', {}).get('dns', {}).get('engine') == 'chinadns-ng'
			and 'tls://dns.google@8.8.8.8' in (f.run / 'current/chinadns.conf').read_text(),
			f'state={st3}')


def main():
	with tempfile.TemporaryDirectory(prefix='.engine-upstream-', dir=ROOT / 'tests/daemon') as temp:
		base = Path(temp)
		scenario_aether_dns_tls_cold(base)
		scenario_aether_dns_supported_and_unused_direct(base)
		scenario_chinadns_ng_tls_allowed(base)
		scenario_live_reload_same_engine(base)
		scenario_live_reload_engine_switch(base)
	print(f'T16.82 engine upstream compat: {passed} passed, {failed} failed', flush=True)
	return 1 if failed else 0


if __name__ == '__main__':
	sys.exit(main())
