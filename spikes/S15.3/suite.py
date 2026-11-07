#!/usr/bin/env python3
"""Run both negative controls and restore the normal probe (no production mutation)."""
import json
from pathlib import Path
import subprocess
import sys

BASE = Path(__file__).resolve().parent
ENGINES = ['aether-dns', 'chinadns-ng']


def run(name, extra=()):
	with (BASE / 'evidence' / (name + '.jsonl')).open('w') as out:
		with (BASE / 'evidence' / (name + '.stderr')).open('w') as err:
			r = subprocess.run([sys.executable, str(BASE / 'probe.py'), '--aether', sys.argv[1],
				'--fallback', sys.argv[2], *extra], stdout=out, stderr=err, timeout=90)
	rows = [json.loads(s) for s in (BASE / 'evidence' / (name + '.jsonl')).read_text().splitlines()]
	(BASE / 'evidence' / (name + '.exit')).write_text(str(r.returncode) + '\n')
	return r.returncode, rows


def positive(name):
	code, rows = run(name)
	states = {(r['engine'], r['id']): r['status'] for r in rows if r['event'] == 'scenario'}
	stderr = (BASE / 'evidence' / (name + '.stderr')).read_text()
	valid = code == 0 and not stderr
	if stderr:
		print(f'FAIL {name}: unexpected stderr (see evidence)', flush=True)
	for engine in ENGINES:
		for n in range(1, 11):
			wanted = 'UNSUPPORTED' if engine == 'aether-dns' and n == 6 else 'PASS'
			status = states.get((engine, f'E{n}'), 'BLOCKED')
			print(f'{status} {name} {engine} E{n}', flush=True)
			valid = valid and status == wanted
	return valid


def main():
	ok = positive('normal')
	for mutation, suffix in [('closed-formal', 'E2 node IPv4 from explicit private endpoint'),
		('impostor', 'E7 readiness requires owned child and expected source')]:
		for engine in ENGINES:
			name = mutation + '-' + engine
			code, rows = run(name, ['--mutation', mutation, '--only-engine', engine])
			failed = [r['label'] for r in rows if r['event'] == 'assert' and r['status'] == 'FAIL']
			stderr = (BASE / 'evidence' / (name + '.stderr')).read_text()
			valid = code != 0 and failed == [engine + ' ' + suffix]
			valid = valid and 'AssertionError: ' + engine + ' ' + suffix in stderr
			valid = valid and 'Task exception was never retrieved' not in stderr
			valid = valid and any(r.get('label') == 'E8 all runtime resources removed' for r in rows)
			print(f'{"PASS" if valid else "FAIL"} negative {name}: exit={code}, assertions={failed}', flush=True)
			ok = ok and valid
	# Always rerun the restored implementation even if a negative control failed.
	ok = positive('restored') and ok
	return 0 if ok else 1


if __name__ == '__main__':
	sys.exit(main())
