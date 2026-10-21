#!/usr/bin/env python3
"""T9.7: verify daemon's inherited stdout, per-child quota and post-stop FIFO-reader exit."""
from collections import defaultdict
import os
from pathlib import Path
import re
import sys
import time

root = Path(sys.argv[1])
amount = int(sys.argv[2])
run_dir = str(root / 'var/run/aether-proxy')


def readers():
	found = []
	for proc in Path('/proc').glob('[0-9]*'):
		try:
			if os.readlink(proc / 'fd/0').startswith(run_dir) and '.log.fifo' in os.readlink(proc / 'fd/0'):
				found.append(proc.name)
		except (FileNotFoundError, PermissionError, ProcessLookupError):
			continue
	return found


# Shell fixture sleeps may briefly inherit the FIFO write end after the shell exits.
for _ in range(150):
	if not readers():
		break
	time.sleep(0.02)
assert not readers(), 'daemon stop left live FIFO readers'
assert not list((root / 'var/run/aether-proxy').glob('*.log.fifo')), 'daemon stop left FIFOs'
print(f'PASS  daemon {amount}: stop leaves no live filters or FIFO')
lines = (root / 'daemon.stdout').read_text().splitlines()
groups = defaultdict(list)
for line in lines:
	match = re.fullmatch(r'(xray|chinadns-ng) log ([0-9]+) ([0-9]+)', line)
	if match:
		groups[match[1], match[2]].append(int(match[3]))
for name in ('xray', 'chinadns-ng'):
	bursts = [values for (child, _), values in groups.items() if child == name]
	assert bursts and all(values == list(range(1, min(20, amount) + 1)) for values in bursts), (name, groups)
	print(f'PASS  daemon {amount}: {name} emits exactly first {min(20, amount)} lines per second unchanged')
	summaries = [line for line in lines if line.startswith(f'aether-proxy: {name} output rate limited, ')]
	if amount > 20:
		assert len(summaries) == len(bursts) and all('dropped 480 lines between' in line for line in summaries)
		print(f'PASS  daemon {amount}: {name} has one dropped 480 EOF summary per burst')
	else:
		assert not summaries, summaries
		print(f'PASS  daemon {amount}: {name} small output needs no summary')
assert not (root / 'daemon.stderr').read_text(), 'child output unexpectedly bypassed filter to daemon stderr'
print(f'PASS  daemon {amount}: both children output only through filtered stdout')
