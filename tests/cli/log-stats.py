#!/usr/bin/env python3
"""T16.36: public CLI and live filter (wall clock, no EOF until after first notice)."""
import json
import os
from pathlib import Path
import select
import shlex
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
AWK = shlex.split(os.environ.get('LOG_STATS_AWK', 'awk'))


def cli(run_dir, *args):
	return subprocess.check_output(['bash', str(ROOT / 'tests/host/ucode'), '-S',
		str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'log', 'stats', '--run-dir', str(run_dir), *args], text=True)


def snapshot(name, accepted, dropped, first=None, last=None):
	return dict(name=name, accepted=accepted, dropped=dropped, first_drop=first, last_drop=last,
		second_limit=20, minute_limit=120)


def wait_for_row(path, expected):
	deadline = time.monotonic() + 3
	while time.monotonic() < deadline:
		try:
			if json.loads(path.read_text()) == expected:
				return
		except (FileNotFoundError, json.JSONDecodeError):
			pass
		time.sleep(.01)
	raise AssertionError(f'{path} did not become {expected}')


def live(run_dir):
	stats = run_dir / 'chinadns-ng.logstats'
	argv = [*AWK, '-v', 'name=chinadns-ng', '-v', f'stats={stats}', '-f',
		str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk')]
	with subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
			env=dict(os.environ, TZ='UTC0')) as proc:
		def send(lines):
			proc.stdin.write(('\n'.join(lines) + '\n').encode())
			proc.stdin.flush()

		def receive(count):
			data = b''
			while data.count(b'\n') < count:
				assert select.select([proc.stdout], [], [], 3)[0], data
				chunk = os.read(proc.stdout.fileno(), 65536)
				assert chunk, data
				data += chunk
			return data.decode().splitlines()

		wait_for_row(stats, snapshot('chinadns-ng', 0, 0))
		time.sleep(1.05 - time.time() % 1)
		startup = [f'I [main.zig:164 main] config item {i:02d}' for i in range(30)]
		begin = int(time.time())
		send([f'\x1b[33m2026-11-19 16:38:49\x1b[0m {line}' for line in startup])
		assert receive(30) == startup
		assert int(time.time()) == begin
		print(f'startup: all {len(startup)} lines forwarded at epoch {begin}')
		wait_for_row(stats, snapshot('chinadns-ng', 1, 0))

		time.sleep(max(begin + 5.05 - time.time(), 0))
		later = [f'live output {i:02d}' for i in range(20)]
		message = 'W [Upstream.zig:825 TCP.on_error] ' + 'x' * 180
		drop = int(time.time())
		send(later + [f'\x1b[31m2026-11-19 16:38:54\x1b[0m {message}'])
		hms = time.strftime('%H:%M:%S', time.gmtime(drop))
		notice = ('aether-proxy: chinadns-ng output rate limited, dropped 1 lines '
			f'between {hms} and {hms}, first: {message[:160]}')
		assert receive(21) == later + [notice]
		assert int(time.time()) == drop and proc.poll() is None
		print(f'first notice before EOF, in drop second {drop}: {notice}')
		row = snapshot('chinadns-ng', 50, 1, drop, drop)
		wait_for_row(stats, row)
		assert json.loads(cli(run_dir, '--json')) == {'ok': True, 'stats': [row]}
		print(cli(run_dir), end='')

		proc.stdin.close()
		assert proc.wait(timeout=3) == 0 and not proc.stderr.read()
		assert not proc.stdout.read(), 'single-drop streak must not notify twice'
	return row


with tempfile.TemporaryDirectory(prefix="log-stats-' ") as tmp:
	run_dir = Path(tmp)
	assert json.loads(cli(run_dir / 'missing', '--json')) == {'ok': True, 'stats': []}
	assert json.loads(cli(run_dir, '--json')) == {'ok': True, 'stats': []}
	assert cli(run_dir).splitlines() == ['NAME\tACCEPTED\tDROPPED\tFIRST_DROP\tLAST_DROP\tSECOND_LIMIT\tMINUTE_LIMIT']
	chinadns = live(run_dir)
	xray = snapshot('xray', 7, 0)
	(run_dir / 'xray.logstats').write_text(json.dumps(xray) + '\n')
	(run_dir / 'aether-dns.logstats').write_text('{')
	(run_dir / 'dir.logstats').mkdir()
	(run_dir / 'ignored.txt').write_text(json.dumps(xray))
	assert json.loads(cli(run_dir, '--json')) == {'ok': True, 'stats': [chinadns, xray]}
	print(cli(run_dir, '--json'), end='')
print('T16.36 log stats CLI scenarios passed')
