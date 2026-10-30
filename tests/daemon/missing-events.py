#!/usr/bin/env python3
"""T9.47: missing component start events and read-only check/status channels."""
import json
import subprocess
import tempfile
from pathlib import Path

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location('version_gate', ROOT / 'tests/daemon/version-gate.py')
fixture = module_from_spec(spec)
spec.loader.exec_module(fixture)
passed = failed = 0


def check(name, ok):
	global passed, failed
	passed += bool(ok)
	failed += not ok
	print(('PASS  ' if ok else 'FAIL  ') + 'T9.47 ' + name, flush=True)


def main():
	with tempfile.TemporaryDirectory(prefix='.missing-', dir=ROOT / 'tests/daemon') as temp:
		for index, (missing, policy) in enumerate([
			(['xray'], 'default'), (['chinadns-ng'], 'default'),
			(['xray', 'chinadns-ng'], 'default'), ([], 'default'),
			(['xray', 'chinadns-ng'], 'explicit'), ([], 'empty'), ([], 'path')
		]):
			f = fixture.Fixture(Path(temp), str(index), 'xray', '26.3.27')
			for name in missing:
				(f.bin / name).unlink()
			conf = f.root / 'etc/config/aetherproxy'
			if policy in ('explicit', 'empty'):
				value = str(f.root / 'absent') if policy == 'explicit' else ''
				conf.write_text(conf.read_text() + f"\nconfig main 'main'\n\toption xray_bin '{value}'\n"
					+ f"\toption chinadns_bin '{value}'\n")
			if policy == 'path':
				# Keep command substitutes in --bin-dir, but resolve components through PATH.
				path = f.root / 'path-bin'
				path.mkdir()
				for name in fixture.MINIMUM:
					for suffix in ('', '-original'):
						(f.bin / (name + suffix)).rename(path / (name + suffix))
				f.env['PATH'] = str(path) + ':' + f.env['PATH']
			label = f'{policy} missing={",".join(missing) or "none"}'
			# check/status must remain read-only even after repeated page polling.
			before = f.events()
			for command in ('check', 'status', 'status'):
				args = f.args if command == 'check' else f.args[:6]
				r = subprocess.run([str(fixture.UCODE), '-S', str(fixture.ENTRY), '--', command,
					'--json', *args, '--run-dir', str(f.run)],
					env=f.env, capture_output=True, text=True, timeout=20)
				value = json.loads(r.stdout)
				channel = 'warnings' if command == 'check' else 'notices'
				items = [w['args']['component'] for w in value.get(channel, [])
					if w['code'] == 'COMPONENT_MISSING']
				check(f'{label} {command} exact {channel}', r.returncode == 0 and sorted(items) == sorted(missing))
				if command == 'check':
					check(f'{label} check skips only missing Xray validation',
						value['validation']['xray'].get('skipped', False) == ('xray' in missing)
						and (value['validation']['xray'].get('ok') is True if 'xray' not in missing else True))
			check(f'{label} polling writes no events', f.events() == before)
			with f.daemon() as child:
				f.wait_started(child)
				events = f.events()
				items = [e for e in events if e['code'] == 'COMPONENT_MISSING']
				check(f'{label} start exact missing error events',
					sorted(e['args']['component'] for e in items) == sorted(missing)
					and all(e['level'] == 'error' and set(e['args']) == {'component'} for e in items))
				pre = [e for e in events if e['code'] == 'PRECHECK_FAILED']
				check(f'{label} aggregate precheck preserved',
					len(pre) == 1 and sorted(pre[0]['args']['missing']) == sorted('component:' + n for n in missing)
					if missing else not pre)
				calls = f.calls.read_text()
				children_absent = not (f.root / 'xray.pid').exists() and not (f.root / 'chinadns.pid').exists()
				nft_absent = not (f.root / 'nft-table').exists() and 'nft -f ' not in calls
				dns_absent = 'dnsmasq ' not in calls and not (f.root / 'tmp/dnsmasq.d/aether-proxy.conf').exists()
				routing_empty = (f.root / 'ip-rules').read_text() == '' and (f.root / 'ip-routes').read_text() == ''
				untouched = children_absent and nft_absent and dns_absent and routing_empty
				check(f'{label} no takeover on missing or runs with both present',
					f.state().get('failed_step') == 'precheck' and untouched
					if missing else f.state().get('state') == 'running')
	print(f'T9.47 missing events: {passed} passed, {failed} failed')
	return int(failed != 0)


if __name__ == '__main__':
	raise SystemExit(main())
