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
	lines = ['100 ' + str(i) for i in range(25)] + ['100 another-drop', '99 rollback', '99 again']
	check(run(lines)[-3:] == [summary(6, '00:01:40', '00:01:40'), 'rollback', 'again'],
		f'{label}: clock rollback restarts the counts instead of silencing the child')
	lines = ['5000 ' + str(i) for i in range(25)] + [f'1400 back {i}' for i in range(20)]
	check(run(lines)[20:] == [summary(5, '01:23:20', '01:23:20')] + [f'back {i}' for i in range(20)],
		f'{label}: an hour-long rollback admits a full second at once')
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


def exercise_dedup(awk):
	"""T9.30: timestamp-independent, bounded deduplication before both quotas (docs/09)."""
	label = ' '.join(awk)
	argv = awk + ['-v', 'test_clock=1', '-v', 'name=fixture', '-f', str(FILTER)]

	def run(lines):
		p = subprocess.run(argv, input='\n'.join(lines) + '\n', text=True,
			capture_output=True, env=ENV, check=True)
		check(not p.stderr, f'{label}: dedup emits no filter diagnostics')
		return p.stdout.splitlines()

	def repeated(message, count):
		return f'aether-proxy: fixture repeated {count} more times: {message[:160]}'

	def dns_line(second, message):
		# Reconstruct the r13 recv failures with chinadns-ng's colored timestamp prefix.
		return f'\x1b[1;33m2026-10-23 12:00:{second:02d}\x1b[0m {message}'

	# Each resolver produces 30 lines, alternating at 10 incoming lines per second.
	messages = ['recv(tcp://8.8.8.8) failed', 'recv(tcp://1.1.1.1) failed']
	lines = [f'{100 + i // 5} {dns_line(i, message)}' for i in range(30) for message in messages]
	first = [dns_line(0, message) for message in messages]
	summaries = [repeated(message, 29) for message in messages]
	check(run(lines + ['110 window-end']) == first + summaries + ['window-end'],
		f'{label}: r13 alternating resolvers each emit first line and repeated 29 at 10 seconds')
	check(run(lines) == first + summaries,
		f'{label}: EOF flushes both unfinished r13 repetition summaries')

	# Xray with whole seconds and fractional seconds must share the same message key.
	xray = ['2026/10/23 12:00:00 [Warning] transport: dial failed',
		'2026/10/23 12:00:01 [Warning] transport: dial failed',
		'2026/10/23 12:00:02.123456 [Warning] transport: dial failed',
		'2026/10/23 12:00:03.654321 [Warning] transport: dial failed',
		'2026/10/23 12:00:04.000001 [Info] app: listener ready']
	check(run([f'100 {line}' for line in xray]) ==
		[xray[0], xray[4], repeated('[Warning] transport: dial failed', 3)],
		f'{label}: both Xray timestamp formats merge identical messages but preserve different messages')
	plain_dns = '2026-10-23 12:00:00 [dns.zig:123 recv] failed'
	colored_dns = '\x1b[33m\x1b[1m2026-10-23 12:00:01\x1b[0m [dns.zig:123 recv] failed'
	check(run([f'100 {plain_dns}', f'101 {colored_dns}']) ==
		[plain_dns, repeated('[dns.zig:123 recv] failed', 1)],
		f'{label}: plain and colored chinadns timestamps share a key and preserve the first bytes')

	# Stay below 20/s so this proves the tracking cap, not an incidental rate drop.
	lines = [f'{100 + i // 11} unique-{i}' for i in range(33)]
	check(run(lines + ['103 unique-0', '103 unique-32', '103 unique-32']) ==
		[f'unique-{i}' for i in range(33)] + ['unique-32', 'unique-32', repeated('unique-0', 1)],
		f'{label}: message 33 always passes through while message 1 remains tracked')
	check(run(lines + ['110 unique-32', '110 unique-32']) ==
		[f'unique-{i}' for i in range(33)] + ['unique-32', repeated('unique-32', 1)],
		f'{label}: next window releases all 32 tracking slots')

	lines = ['100 anchor'] * 500 + [f'100 distinct-{i}' for i in range(19)]
	check(run(lines + ['100 overflow', '101 recovered']) ==
		['anchor'] + [f'distinct-{i}' for i in range(19)] +
		[summary(1, '00:01:40', '00:01:40'), 'recovered', repeated('anchor', 499)],
		f'{label}: merged lines consume neither the 20 per second quota nor the dropped counter')
	# Keep anchor in the bounded table while exercising the complete rolling minute quota.
	lines = ['100 anchor']
	for i in range(119):
		clock = 100 + (i + 1) // 20
		lines += [f'{clock} anchor', f'{clock} minute-{i}']
	check(run(lines + ['106 overflow', '160 recovered']) ==
		['anchor'] + [f'minute-{i}' for i in range(119)] +
		[repeated('anchor', 119), summary(1, '00:01:46', '00:01:46'), 'recovered'],
		f'{label}: merged lines leave all 120 rolling minute slots available')
	lines = [f'100 full-{i}' for i in range(20)] + ['100 full-0', '100 overflow', '100 full-0']
	check(run(lines) == [f'full-{i}' for i in range(20)] +
		[summary(1, '00:01:40', '00:01:40'), repeated('full-0', 2)],
		f'{label}: EOF repetition summaries bypass a saturated quota')
	# Conservatively track even a first occurrence dropped by the downstream rate limiter.
	lines = [f'100 full-{i}' for i in range(20)] + ['100 overflow', '101 overflow']
	check(run(lines) == [f'full-{i}' for i in range(20)] +
		[summary(1, '00:01:40', '00:01:40'), repeated('overflow', 1)],
		f'{label}: quota-dropped first occurrence still participates in deduplication')

	check(run(['0 epoch', '9 epoch', '10 epoch', '10 epoch']) ==
		['epoch', repeated('epoch', 1), 'epoch', repeated('epoch', 1)],
		f'{label}: fixed window expires at exactly 10 seconds even when the first clock is zero')
	check(run(['100 old', '100 old', '100 old', '99 old', '99 old']) ==
		['old', 'old', repeated('old', 1)],
		f'{label}: clock rollback discards old repeats and admits the same message afresh')
	lines = [f'100 old-{i}' for i in range(32)] + ['99 fresh', '99 fresh']
	check(run(lines)[-3:] == [summary(12, '00:01:40', '00:01:40'), 'fresh', repeated('fresh', 1)],
		f'{label}: clock rollback clears a full table as well as rate quota')

	prefix = 'x' * 160
	check(run([f'100 {prefix}a', f'100 {prefix}b', f'100 {prefix}a', f'100 {prefix}b']) ==
		[prefix + 'a', prefix + 'b', repeated(prefix, 1), repeated(prefix, 1)],
		f'{label}: only summaries truncate to 160 characters while full keys remain distinct')
	check(run(['100 ', '100 ']) == ['', repeated('', 1)],
		f'{label}: empty messages can be tracked without confusing absence with zero repeats')
	untimestamped = '\x1b[32m[main.zig:1] ready\x1b[0m'
	check(run([f'100 {untimestamped}', '100 [main.zig:1] ready']) ==
		[untimestamped, '[main.zig:1] ready'],
		f'{label}: unrecognized prefixes are not normalized or rewritten')


if __name__ == '__main__':
	exercise(['awk'])
	exercise_dedup(['awk'])
	if shutil.which('busybox'):
		exercise(['busybox', 'awk'])
		exercise_dedup(['busybox', 'awk'])
	else:
		print('WARN  BusyBox unavailable; native awk covered, firmware awk requires six-rootfs CI')
	print('logfilter: all assertions passed')
