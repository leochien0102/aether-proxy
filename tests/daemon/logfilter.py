#!/usr/bin/env python3
"""T9.7: deterministic quota, byte preservation and unbuffered FIFO-reader tests (docs/09)."""
import os
from pathlib import Path
import select
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FILTER = ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'
ENV = dict(os.environ, TZ='UTC')


def check(value, name):
	if not value:
		raise AssertionError(name)
	print('PASS  ' + name)


def summary(count, first, last):
	return (f'aether-proxy: fixture output rate limited, dropped {count} lines '
		f'between {first} and {last}')


def exercise(awk):
	label = ' '.join(awk)
	argv = awk + ['-v', 'test_clock=1', '-v', 'name=fixture', '-f', str(FILTER)]

	def run(lines):
		p = subprocess.run(argv, input='\n'.join(lines) + '\n', text=True,
			capture_output=True, env=ENV, check=True)
		check(not p.stderr, f'{label}: no filter diagnostics')
		return p.stdout.splitlines()

	plain = [f'line {i}' for i in range(20)]
	check(run([f'100 {line}' for line in plain]) == plain,
		f'{label}: same second 20 lines preserved in order')
	lines = [f'100 line {i}' for i in range(25)] + ['101 next']
	check(run(lines) == plain + [summary(5, '00:01:40', '00:01:40'), 'next'],
		f'{label}: same second 25 lines drops 5 before next second')
	check(run(lines[:-1]) == plain + [summary(5, '00:01:40', '00:01:40')],
		f'{label}: EOF flushes pending summary')
	lines = [f'{100 + i // 5} line {i}' for i in range(130)] + ['160 recovered']
	check(run(lines) == [f'line {i}' for i in range(120)] +
		[summary(10, '00:02:04', '00:02:05'), 'recovered'],
		f'{label}: rolling minute admits 120 of 130 then summarizes')
	# Quotas count admitted lines, not incoming attempts or the notification itself.
	lines = [f'{100 + i // 10} line {i}' for i in range(120)]
	lines += ['159 dropped-a', '159 dropped-b', '160 recovered']
	check(run(lines)[-2:] == [summary(2, '00:02:39', '00:02:39'), 'recovered'],
		f'{label}: rolling window boundary recovers at exactly 60 seconds')
	lines = ['100 ' + str(i) for i in range(25)] + ['100 another-drop', '99 rollback', '101 next']
	check(run(lines)[-2:] == [summary(7, '00:01:40', '00:01:40'), 'next'],
		f'{label}: clock rollback cannot grant extra quota')
	long_line = 'x' * 131072 + '\t  tail  '
	check(run(['100 ', '100 ' + long_line]) == ['', long_line],
		f'{label}: empty and very long lines preserved byte-for-byte')
	check(run([f'100 {i}' for i in range(25)] + [f'101 {i}' for i in range(25)])[20] ==
		summary(5, '00:01:40', '00:01:40'), f'{label}: separate suppressed runs have separate summaries')
	# The pipe stays open after this write. Waiting for EOF or the next line would fail.
	p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV)
	try:
		p.stdin.write(b'100 immediate\n')
		p.stdin.flush()
		ready = select.select([p.stdout], [], [], 1)[0]
		check(bool(ready) and os.read(p.stdout.fileno(), 4096) == b'immediate\n',
			f'{label}: one line flushed within 1 second without EOF')
	finally:
		p.stdin.close()
		p.wait(timeout=3)
		check(p.returncode == 0 and not p.stderr.read(), f'{label}: reader exits cleanly at EOF')
	check(subprocess.run(argv, input=b'', capture_output=True, env=ENV, check=True).stdout == b'',
		f'{label}: empty input emits nothing')


if __name__ == '__main__':
	exercise(['awk'])
	if shutil.which('busybox'):
		exercise(['busybox', 'awk'])
	else:
		print('WARN  BusyBox unavailable; native awk covered, firmware awk requires six-rootfs CI')
	print('logfilter: all assertions passed')
