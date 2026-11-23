#!/usr/bin/env python3
"""T9.7: deterministic quota, byte preservation and unbuffered FIFO-reader tests (docs/09)."""
import ctypes
import json
import os
from pathlib import Path
import select
import shutil
import stat
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FILTER = Path(os.environ.get('AETHER_PROXY_TEST_LOGFILTER',
	ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'))
ENV = dict(os.environ, TZ='UTC')


def check(value, name):
	if not value:
		raise AssertionError(name)
	print('PASS  ' + name)


def summary(count, first, last, message):
	return (f'aether-proxy: fixture output rate limited, dropped {count} lines '
		f'between {first} and {last}, first: {message}')


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
	startup = [f'startup {i}' for i in range(25)]
	check(run([f'100 {line}' for line in startup] + [f'104 end {i}' for i in range(25)]) ==
		startup + [f'end {i}' for i in range(25)],
		f'{label}: 25 lines in each of startup seconds 1 and 5 all pass')
	check(run([f'100 startup {i}' for i in range(121)]) ==
		[f'startup {i}' for i in range(120)] + [summary(1, '00:01:40', '00:01:40', 'startup 120')],
		f'{label}: the rolling minute limit still applies during startup')
	lines = ['100 origin'] + [f'105 line {i}' for i in range(25)] + ['106 next']
	drops = [summary(n, '00:01:45', '00:01:45', 'line 20') for n in (1, 5)]
	check(run(lines) == ['origin'] + plain + drops + ['next'],
		f'{label}: sixth second applies the 20-line limit and summarizes on recovery')
	check(run(lines[:-1]) == ['origin'] + plain + drops,
		f'{label}: EOF flushes the full drop streak')
	lines = [f'{100 + i // 5} line {i}' for i in range(130)] + ['160 recovered']
	check(run(lines) == [f'line {i}' for i in range(120)] +
		[summary(1, '00:02:04', '00:02:04', 'line 120'),
			summary(10, '00:02:04', '00:02:05', 'line 120'), 'recovered'],
		f'{label}: rolling minute admits 120 of 130 then summarizes')
	lines = [f'{100 + i // 10} line {i}' for i in range(120)]
	lines += ['159 dropped-a', '159 dropped-b', '160 recovered']
	check(run(lines)[-3:] == [summary(n, '00:02:39', '00:02:39', 'dropped-a') for n in (1, 2)] + ['recovered'],
		f'{label}: rolling window boundary recovers at exactly 60 seconds')
	lines = ['95 origin'] + ['100 ' + str(i) for i in range(25)] + ['100 another-drop', '99 rollback', '99 again']
	check(run(lines)[-3:] == [summary(6, '00:01:40', '00:01:40', '20'), 'rollback', 'again'],
		f'{label}: clock rollback restarts the counts instead of silencing the child')
	lines = ['4995 origin'] + ['5000 ' + str(i) for i in range(25)] + [f'1400 back {i}' for i in range(21)]
	check(run(lines)[21:] == [summary(n, '01:23:20', '01:23:20', '20') for n in (1, 5)] +
		[f'back {i}' for i in range(20)] + [summary(1, '00:23:20', '00:23:20', 'back 20')],
		f'{label}: rollback clears the quota but does not renew startup grace')
	long_line = 'x' * 131072 + '\t  tail  '
	check(run(['100 ', '100 ' + long_line]) == ['', long_line],
		f'{label}: empty and very long lines preserved byte-for-byte')
	lines = ['95 origin'] + [f'100 first {i}' for i in range(25)] + [f'101 second {i}' for i in range(25)]
	notes = [line for line in run(lines) if 'rate limited' in line]
	check(notes == [summary(n, clock, clock, message)
		for clock, message in [('00:01:40', 'first 20'), ('00:01:41', 'second 20')] for n in (1, 5)],
		f'{label}: separate suppressed runs have separate summaries')
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
	argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=95', '-v', 'name=fixture', '-f', str(FILTER)]

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
	first = messages  # T9.31: colour codes and timestamp removed from the forwarded line
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
		['[Warning] transport: dial failed', '[Info] app: listener ready', repeated('[Warning] transport: dial failed', 3)],
		f'{label}: both Xray timestamp formats merge identical messages but preserve different messages')
	plain_dns = '2026-10-23 12:00:00 [dns.zig:123 recv] failed'
	colored_dns = '\x1b[33m\x1b[1m2026-10-23 12:00:01\x1b[0m [dns.zig:123 recv] failed'
	check(run([f'100 {plain_dns}', f'101 {colored_dns}']) ==
		['[dns.zig:123 recv] failed', repeated('[dns.zig:123 recv] failed', 1)],
		f'{label}: plain and colored chinadns timestamps share a key and forward without timestamp')

	# Stay below 20/s so this proves the tracking cap, not an incidental rate drop.
	lines = [f'{100 + i // 11} unique-{i}' for i in range(33)]
	# T9.31: message 33 now evicts the earliest zero-count entry (unique-0), so unique-32 is tracked
	# and unique-0 is not; the untracked-33rd case with all 32 repeating is in exercise_yield.
	check(run(lines + ['103 unique-0', '103 unique-32', '103 unique-32']) ==
		[f'unique-{i}' for i in range(33)] + ['unique-0', repeated('unique-32', 2)],
		f'{label}: message 33 evicts the earliest unrepeated message and is itself tracked')
	check(run(lines + ['110 unique-32', '110 unique-32']) ==
		[f'unique-{i}' for i in range(33)] + ['unique-32', repeated('unique-32', 1)],
		f'{label}: next window releases all 32 tracking slots')

	lines = ['100 anchor'] * 500 + [f'100 distinct-{i}' for i in range(19)]
	check(run(lines + ['100 overflow', '101 recovered']) ==
		['anchor'] + [f'distinct-{i}' for i in range(19)] +
		[summary(1, '00:01:40', '00:01:40', 'overflow'), 'recovered', repeated('anchor', 499)],
		f'{label}: merged lines consume neither the 20 per second quota nor the dropped counter')
	# Keep anchor in the bounded table while exercising the complete rolling minute quota.
	lines = ['100 anchor']
	for i in range(119):
		clock = 100 + (i + 1) // 20
		lines += [f'{clock} anchor', f'{clock} minute-{i}']
	check(run(lines + ['106 overflow', '160 recovered']) ==
		['anchor'] + [f'minute-{i}' for i in range(119)] +
		[summary(1, '00:01:46', '00:01:46', 'overflow'), repeated('anchor', 119), 'recovered'],
		f'{label}: merged lines leave all 120 rolling minute slots available')
	lines = [f'100 full-{i}' for i in range(20)] + ['100 full-0', '100 overflow', '100 full-0']
	check(run(lines) == [f'full-{i}' for i in range(20)] +
		[summary(1, '00:01:40', '00:01:40', 'overflow'), repeated('full-0', 2)],
		f'{label}: EOF repetition summaries bypass a saturated quota')
	# Conservatively track even a first occurrence dropped by the downstream rate limiter.
	lines = [f'100 full-{i}' for i in range(20)] + ['100 overflow', '101 overflow']
	check(run(lines) == [f'full-{i}' for i in range(20)] +
		[summary(1, '00:01:40', '00:01:40', 'overflow'), repeated('overflow', 1)],
		f'{label}: quota-dropped first occurrence still participates in deduplication')

	check(run(['0 epoch', '9 epoch', '10 epoch', '10 epoch']) ==
		['epoch', repeated('epoch', 1), 'epoch', repeated('epoch', 1)],
		f'{label}: fixed window expires at exactly 10 seconds even when the first clock is zero')
	check(run(['100 old', '100 old', '100 old', '99 old', '99 old']) ==
		['old', 'old', repeated('old', 1)],
		f'{label}: clock rollback discards old repeats and admits the same message afresh')
	lines = [f'100 old-{i}' for i in range(32)] + ['99 fresh', '99 fresh']
	check(run(lines)[-3:] == [summary(12, '00:01:40', '00:01:40', 'old-20'), 'fresh', repeated('fresh', 1)],
		f'{label}: clock rollback clears a full table as well as rate quota')

	prefix = 'x' * 160
	check(run([f'100 {prefix}a', f'100 {prefix}b', f'100 {prefix}a', f'100 {prefix}b']) ==
		[prefix + 'a', prefix + 'b', repeated(prefix, 1), repeated(prefix, 1)],
		f'{label}: only summaries truncate to 160 characters while full keys remain distinct')
	check(run(['100 ', '100 ']) == ['', repeated('', 1)],
		f'{label}: empty messages can be tracked without confusing absence with zero repeats')
	untimestamped = '\x1b[32m[main.zig:1] ready\x1b[0m'
	check(run([f'100 {untimestamped}', '100 [main.zig:1] ready']) ==
		['[main.zig:1] ready', repeated('[main.zig:1] ready', 1)],
		f'{label}: lines without a timestamp lose only colour codes and then share a key')


def exercise_yield(awk):
	"""T9.31: slot yielding and forwarded-text rules (docs/09)."""
	label = ' '.join(awk)
	argv = awk + ['-v', 'test_clock=1', '-v', 'name=fixture', '-f', str(FILTER)]

	def run(lines):
		p = subprocess.run(argv, input='\n'.join(lines) + '\n', text=True,
			capture_output=True, env=ENV, check=True)
		check(not p.stderr, f'{label}: yield emits no filter diagnostics')
		return p.stdout.splitlines()

	def repeated(message, count):
		return f'aether-proxy: fixture repeated {count} more times: {message[:160]}'

	# Scenario 1: the r14 sample (real chinadns-ng line layout, reset after the level letter).
	def cdns(second, text, level='W'):
		return (f'\x1b[33;1m2026-10-23 07:31:{second:02d} {level}\x1b[0m '
			f'\x1b[1m[Upstream.zig:825 TCP.on_error]\x1b[0m {text}')

	startup = [f'{100 + i // 10} ' + cdns(i % 60, f'config item {i}', 'I') for i in range(40)]
	fail = [f'tcp://127.0.0.1#3108{n}' for n in (2, 3)]
	failing = [f'connect({a}) failed: (111) Connection refused' for a in fail]
	lines = startup[:]
	for i in range(2000):
		# 2000 lines over 4 seconds would exceed 20/s if they were not merged.
		lines.append(f'{104 + i // 500} ' + cdns(40 + i // 500, failing[i % 2]))
	out = run(lines + ['114 end'])
	expect = [f'I [Upstream.zig:825 TCP.on_error] config item {i}' for i in range(40)]
	expect += ['W [Upstream.zig:825 TCP.on_error] ' + m for m in failing]
	expect += [repeated('W [Upstream.zig:825 TCP.on_error] ' + m, 999) for m in failing] + ['end']
	check(out == expect,
		f'{label}: r14 sample prints each failure once plus repeated 999, no rate-limit drops')
	check(not any('rate limited' in line or '\x1b' in line for line in out),
		f'{label}: r14 sample output has no drop summary and no ESC')

	# Scenario 2: yielding order. 32 tracked, repeat 2nd, new message evicts the 1st (count 0).
	base = [f'{100 + i // 10} m{i}' for i in range(32)]
	out = run(base + ['104 m1', '104 new-a', '104 m0', '104 m1'])
	check(out == [f'm{i}' for i in range(32)] + ['new-a', 'm0', repeated('m1', 2)],
		f'{label}: new message evicts the earliest zero-count entry; evicted one re-enters untracked-then-tracked')
	# Order stays first-seen: m5 and m9 repeat, new-a tracked after them.
	out = run(base + ['104 m9', '104 m5', '104 new-a', '104 new-a', '104 m9'])
	check(out[32:] == ['new-a', repeated('m5', 1), repeated('m9', 2), repeated('new-a', 1)],
		f'{label}: summaries keep first-seen order after yielding')
	# All 32 repeating: the 33rd passes but is not tracked.
	lines = base + [f'{104 + i // 10} m{i}' for i in range(32)] + ['108 extra', '108 extra']
	out = run(lines)
	check(out == [f'm{i}' for i in range(32)] + ['extra', 'extra'] + [repeated(f'm{i}', 1) for i in range(32)],
		f'{label}: all 32 repeated, 33rd message is forwarded but not tracked')

	# Scenario 3: forwarded content.
	ts = '\x1b[33;1m2026-10-23 07:31:53 W\x1b[0m \x1b[1m[a.zig:1 f]\x1b[0m hello'
	check(run(['100 ' + ts]) == ['W [a.zig:1 f] hello'], f'{label}: chinadns-ng line loses ESC and timestamp (level letter stays)')
	check(run(['100 2026/10/23 07:31:53 [Info] x', '100 2026/10/23 07:31:53.123456   [Info] y']) ==
		['[Info] x', '[Info] y'], f'{label}: both Xray timestamp formats and trailing spaces removed')
	odd = '\x1b[32mhello\x1b[0m  keep   spacing  2026-10-23 12:00:00 inside'
	check(run(['100 ' + odd]) == ['hello  keep   spacing  2026-10-23 12:00:00 inside'],
		f'{label}: no leading timestamp, only colour codes removed, rest unchanged')
	check(run(['100 12:00:00 [Info] z', '100 20261023 12:00:00 q']) == ['12:00:00 [Info] z', '20261023 12:00:00 q'],
		f'{label}: unrecognized timestamp shapes are untouched')


class StatsWatch:
	"""Count kernel-level writes/renames to a stats filename without coalescing."""

	IN_CLOSE_WRITE = 0x00000008
	IN_OPEN = 0x00000020
	IN_MOVED_TO = 0x00000080
	IN_Q_OVERFLOW = 0x00004000
	IN_NONBLOCK = 0x00000800

	def __init__(self, path):
		self.path = Path(path)
		self.libc = ctypes.CDLL('libc.so.6', use_errno=True)
		self.fd = self.libc.inotify_init1(self.IN_NONBLOCK)
		if self.fd < 0:
			raise OSError(ctypes.get_errno(), 'inotify_init1 failed')
		mask = self.IN_OPEN | self.IN_CLOSE_WRITE | self.IN_MOVED_TO
		if self.libc.inotify_add_watch(self.fd, str(self.path.parent).encode(), mask) < 0:
			os.close(self.fd)
			raise OSError(ctypes.get_errno(), 'inotify_add_watch failed')
		self.close_writes = 0
		self.moved_tos = 0
		self.overflow = False

	def drain(self):
		while True:
			try:
				buf = os.read(self.fd, 65536)
			except BlockingIOError:
				break
			if not buf:
				break
			off = 0
			while off < len(buf):
				_, mask, _, nlen = struct.unpack_from('iIII', buf, off)
				off += 16
				name = buf[off:off + nlen].rstrip(b'\0').decode('utf-8', 'surrogateescape')
				off += nlen
				if mask & self.IN_Q_OVERFLOW:
					self.overflow = True
				if name == self.path.name:
					if mask & self.IN_CLOSE_WRITE:
						self.close_writes += 1
					if mask & self.IN_MOVED_TO:
						self.moved_tos += 1
		return self.close_writes, self.moved_tos

	def total(self):
		cw, mt = self.drain()
		return cw + mt

	def close(self):
		if self.fd >= 0:
			os.close(self.fd)
			self.fd = -1

	def __enter__(self):
		return self

	def __exit__(self, *args):
		self.close()


def wait_stats(path, expected, timeout=3.0):
	deadline = time.monotonic() + timeout
	last = None
	while time.monotonic() < deadline:
		try:
			last = json.loads(path.read_text())
			if last == expected:
				return last
		except (FileNotFoundError, json.JSONDecodeError):
			pass
		time.sleep(0.01)
	raise AssertionError(f'{path} did not reach {expected}; last={last}')


def wait_stdout_lines(proc, count, timeout=3.0):
	data = b''
	deadline = time.monotonic() + timeout
	while data.count(b'\n') < count:
		rem = deadline - time.monotonic()
		if rem <= 0 or not select.select([proc.stdout], [], [], rem)[0]:
			raise AssertionError(f'timed out waiting for {count} stdout lines; got {data!r}')
		chunk = os.read(proc.stdout.fileno(), 65536)
		if not chunk:
			raise AssertionError(f'EOF before {count} stdout lines; got {data!r}')
		data += chunk
	return data.decode().splitlines()


def snapshot(name, accepted, dropped, first=None, last=None):
	return dict(name=name, accepted=accepted, dropped=dropped, first_drop=first, last_drop=last,
		second_limit=20, minute_limit=120)


def exercise_stats(awk):
	"""T16.60: bounded writer calls under drop burst, atomic snapshot replacement, failure safety."""
	label = ' '.join(awk)

	def run_burst(count):
		with tempfile.TemporaryDirectory(prefix='logfilter-burst-') as tmp:
			stats = Path(tmp) / 'fixture.logstats'
			argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=100',
				'-v', 'name=fixture', '-v', f'stats={stats}', '-f', str(FILTER)]
			lines = [f'105 burst-{i}' for i in range(count)]
			with StatsWatch(stats) as watch:
				p = subprocess.run(argv, input='\n'.join(lines) + '\n', text=True,
					capture_output=True, env=ENV, check=True)
				cw, mt = watch.drain()
				check(not watch.overflow, f'{label}: inotify did not overflow ({count} lines)')
			check(not p.stderr, f'{label}: burst ({count}) emits no filter diagnostics')
			want_out = [f'burst-{i}' for i in range(20)] + [
				summary(1, '00:01:45', '00:01:45', 'burst-20'),
				summary(count - 20, '00:01:45', '00:01:45', 'burst-20'),
			]
			check(p.stdout.splitlines() == want_out, f'{label}: burst ({count}) preserves summaries and order')
			row = json.loads(stats.read_text())
			check(row == snapshot('fixture', 20, count - 20, 105, 105),
				f'{label}: burst ({count}) EOF stats exact')
			check(cw == 0 and mt == 4,
				f'{label}: burst ({count}) bounded atomic writes (IN_CLOSE_WRITE={cw}, IN_MOVED_TO={mt})')
			check(stat.S_IMODE(stats.stat().st_mode) == 0o600,
				f'{label}: burst ({count}) stats file keeps 0600 permissions')
			leftovers = [f.name for f in Path(tmp).iterdir() if f.name != stats.name]
			check(not leftovers, f'{label}: burst ({count}) leaves no temp files')

	run_burst(500)
	run_burst(1000)

	# Live progression: first drop visible before EOF, sustained drops refresh at 5s,
	# silence adds no writes, and old/new readers observe complete atomic snapshots.
	with tempfile.TemporaryDirectory(prefix='logfilter-live-') as tmp:
		stats = Path(tmp) / 'fixture.logstats'
		argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=100',
			'-v', 'name=fixture', '-v', f'stats={stats}', '-f', str(FILTER)]
		with StatsWatch(stats) as watch:
			p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
				stderr=subprocess.PIPE, env=ENV)
			try:
				wait_stats(stats, snapshot('fixture', 0, 0))
				# Exhaust rolling 60s minute quota (120) at t=100 so drops from t=105..111 stay one streak.
				p.stdin.write(('\n'.join(f'100 fill-{i}' for i in range(120)) + '\n').encode())
				p.stdin.flush()
				out = wait_stdout_lines(p, 120)
				check(out == [f'fill-{i}' for i in range(120)], f'{label}: live fill lines forwarded')
				wait_stats(stats, snapshot('fixture', 101, 0))

				# Hold an open FD to the old snapshot before triggering first drop.
				old_fp = stats.open('rb')
				old_ino = os.fstat(old_fp.fileno()).st_ino
				try:
					p.stdin.write(b'105 first-drop\n')
					p.stdin.flush()
					check(wait_stdout_lines(p, 1) == [summary(1, '00:01:45', '00:01:45', 'first-drop')],
						f'{label}: first drop summary emitted before EOF')
					wait_stats(stats, snapshot('fixture', 120, 1, 105, 105))
					new_ino = stats.stat().st_ino
					check(new_ino != old_ino, f'{label}: atomic replace swaps stats inode')
					check(json.loads(old_fp.read().decode()) == snapshot('fixture', 101, 0),
						f'{label}: pre-existing reader still sees complete old snapshot')
					check(json.loads(stats.read_text()) == snapshot('fixture', 120, 1, 105, 105),
						f'{label}: fresh reader sees complete new snapshot')
				finally:
					old_fp.close()

				cw_before, mt_before = watch.drain()
				# 50 more drops across t=105..109 (< 5s from 105) must not publish, then t=110 publishes once.
				sustained = [f'105 extra-{i}' for i in range(40)] + [f'{106 + i // 3} mid-{i}' for i in range(10)]
				sustained.append('110 five-sec-drop')
				p.stdin.write(('\n'.join(sustained) + '\n').encode())
				p.stdin.flush()
				wait_stats(stats, snapshot('fixture', 120, 52, 105, 110))
				cw_after, mt_after = watch.drain()
				check(cw_after == 0 and mt_after - mt_before == 1,
					f'{label}: 50 sub-5s drops add 0 writes and 5s drop adds exactly 1 write')

				# Silence (no input) adds no background writes; EOF flushes remaining 10 drops once.
				p.stdin.write(('\n'.join(f'111 tail-{i}' for i in range(10)) + '\n').encode())
				p.stdin.flush()
				p.stdin.close()
				tail_out = p.stdout.read().decode().splitlines()
				p.wait(timeout=3)
				check(p.returncode == 0 and not p.stderr.read(), f'{label}: live stats filter exits cleanly')
				check(tail_out == [summary(62, '00:01:45', '00:01:51', 'first-drop')],
					f'{label}: EOF summarizes full sustained drop streak')
				check(json.loads(stats.read_text()) == snapshot('fixture', 120, 62, 105, 111),
					f'{label}: EOF stats total exact after sustained drops')
				cw_end, mt_end = watch.drain()
				check(cw_end == 0 and mt_end - mt_after == 1,
					f'{label}: EOF adds exactly 1 final atomic write')
				check(not [f.name for f in Path(tmp).iterdir() if f.name != stats.name],
					f'{label}: live stats run leaves no temp files')
			finally:
				if p.poll() is None:
					p.kill()
					p.wait(timeout=3)

	# Unsafe targets (symlink, directory) and metacharacter paths.
	with tempfile.TemporaryDirectory(prefix="logfilter-neg-' ") as tmp:
		base = Path(tmp)
		target = base / 'target.txt'
		target.write_text('KEEP\n')
		sym = base / 'sym.logstats'
		sym.symlink_to(target)
		argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=100',
			'-v', 'name=fixture', '-v', f'stats={sym}', '-f', str(FILTER)]
		lines = [f'105 s-{i}' for i in range(25)]
		p = subprocess.run(argv, input='\n'.join(lines) + '\n', text=True,
			capture_output=True, env=ENV, check=True)
		check(target.read_text() == 'KEEP\n' and sym.is_symlink(),
			f'{label}: symlink stats target rejected without modifying referent')
		check(p.stdout.splitlines() == [f's-{i}' for i in range(20)] + [
			summary(1, '00:01:45', '00:01:45', 's-20'),
			summary(5, '00:01:45', '00:01:45', 's-20'),
		], f'{label}: symlink rejection does not interrupt log forwarding')
		check(not [f.name for f in base.iterdir() if f.name not in ('target.txt', 'sym.logstats')],
			f'{label}: symlink rejection leaves no temp files')

		dir_target = base / 'dir.logstats'
		dir_target.mkdir()
		argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=100',
			'-v', 'name=fixture', '-v', f'stats={dir_target}', '-f', str(FILTER)]
		p = subprocess.run(argv, input='100 ok\n', text=True, capture_output=True, env=ENV, check=True)
		check(dir_target.is_dir() and not list(dir_target.iterdir()) and p.stdout == 'ok\n',
			f'{label}: directory stats target rejected and log forwarded')

		meta_stats = base / 'quote \' $(touch SENTINEL).logstats'
		argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=100',
			'-v', 'name=fixture', '-v', f'stats={meta_stats}', '-f', str(FILTER)]
		p = subprocess.run(argv, input='100 meta-ok\n', text=True, capture_output=True, env=ENV, check=True)
		check(not p.stderr and p.stdout == 'meta-ok\n' and not (base / 'SENTINEL').exists(),
			f'{label}: metacharacters in stats path stay literal')
		check(json.loads(meta_stats.read_text()) == snapshot('fixture', 1, 0),
			f'{label}: metacharacter stats path published atomically')

	# Mid-session mv failure: preserves existing readable stats, cleans temp file, keeps forwarding.
	with tempfile.TemporaryDirectory(prefix='logfilter-fail-') as tmp:
		base = Path(tmp)
		bin_dir = base / 'bin'
		bin_dir.mkdir()
		mv_count = base / 'mv-count'
		mv_wrap = bin_dir / 'mv'
		mv_wrap.write_text(
			'#!/bin/sh\n'
			f'c=$(cat "{mv_count}" 2>/dev/null || echo 0)\n'
			'c=$((c + 1))\n'
			f'printf "%s" "$c" > "{mv_count}"\n'
			'if [ "$c" -eq 3 ]; then exit 1; fi\n'
			f'exec "{shutil.which("mv")}" "$@"\n'
		)
		mv_wrap.chmod(0o755)
		stats = base / 'fixture.logstats'
		env_fail = dict(ENV, PATH=f'{bin_dir}:{ENV.get("PATH", "")}')
		argv = awk + ['-v', 'test_clock=1', '-v', 'test_start=100',
			'-v', 'name=fixture', '-v', f'stats={stats}', '-f', str(FILTER)]
		# Call 1: BEGIN (0,0); Call 2: line 0 accepted (1,0); Call 3: first drop at 105 -> mv fails!
		lines = [f'105 fail-{i}' for i in range(25)] + ['106 recovered']
		p = subprocess.run(argv, input='\n'.join(lines) + '\n', text=True,
			capture_output=True, env=env_fail, check=True)
		check(p.stdout.splitlines() == [f'fail-{i}' for i in range(20)] + [
			summary(1, '00:01:45', '00:01:45', 'fail-20'),
			summary(5, '00:01:45', '00:01:45', 'fail-20'),
			'recovered',
		], f'{label}: mid-session publish failure does not break forwarding, recovery or EOF')
		check(json.loads(stats.read_text()) == snapshot('fixture', 1, 0),
			f'{label}: mid-session publish failure preserves previous readable snapshot')
		check(mv_count.read_text() == '3',
			f'{label}: publish failure disables further stats writes for the session')
		leftovers = [f.name for f in base.iterdir() if f.name not in ('bin', 'mv-count', stats.name)]
		check(not leftovers, f'{label}: failed mv cleans up its temporary file')


if __name__ == '__main__':
	exercise(['awk'])
	exercise_dedup(['awk'])
	exercise_yield(['awk'])
	exercise_stats(['awk'])
	if shutil.which('busybox'):
		exercise(['busybox', 'awk'])
		exercise_dedup(['busybox', 'awk'])
		exercise_yield(['busybox', 'awk'])
		exercise_stats(['busybox', 'awk'])
	else:
		print('WARN  BusyBox unavailable; native awk covered, firmware awk requires six-rootfs CI')
	print('logfilter: all assertions passed')
