#!/usr/bin/env python3
"""T9.7: test exec identity, crash filtering, EOF lifecycle and absent-mkfifo fallback."""
import ctypes
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
FILTER = ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'
NAME = 'fixture $(echo INJECTED)'
ARG = 'arg \' " ; $(touch SENTINEL)'
CHILD = '''import json, os, pathlib, signal, sys, time
root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
count_file = root / 'launch-count'
count = int(count_file.read_text()) + 1 if count_file.exists() else 1
count_file.write_text(str(count))
(root / ('actual-' + str(count))).write_text(json.dumps({'pid': os.getpid(), 'arg': sys.argv[3]}))
# Keep the entire burst well inside one wall-clock second.
time.sleep(1 - time.time() % 1 + 0.05)
for i in range(500 if mode == 'crash' else 3):
    os.write(1 if i % 2 == 0 else 2, ('launch-%s line-%s\\n' % (count, i)).encode())
if mode == 'crash' and count == 1:
    sys.exit(7)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    signal.pause()
'''


def check(value, name, detail=''):
	if not value:
		raise AssertionError(name + '\n' + detail)
	print('PASS  ' + name)


def executable(path, content):
	path.write_text(content)
	path.chmod(0o755)


def reap_filters():
	# Shell exec intentionally orphans awk; be its reaper on minimal container hosts.
	while True:
		try:
			pid, _ = os.waitpid(-1, os.WNOHANG)
		except ChildProcessError:
			return
		if not pid:
			return


def exercise(work, mode):
	root = work / (mode + " ' space")
	root.mkdir()
	bin_dir = root / 'bin'
	bin_dir.mkdir()
	for tool in ('sh', 'bash', 'mktemp', 'rm', 'kill'):
		(bin_dir / tool).symlink_to(shutil.which(tool))
	# PATH really has no mkfifo in fallback mode; no failing fake mkfifo is substituted.
	if mode not in ('missing', 'nofilter'):
		executable(bin_dir / 'mkfifo', '#!/bin/sh\nprintf "mkfifo\\n" >> "$CASE/mkfifos"\nexec "' +
			shutil.which('mkfifo') + '" "$@"\n')
	(bin_dir / 'awk').symlink_to(shutil.which('awk'))
	child = root / 'child.py'
	child.write_text(CHILD)
	env = dict(os.environ, PATH=str(bin_dir), CASE=str(root), TZ='UTC',
		AETHER_PROXY_TEST_LOGFILTER=str(root / 'absent.awk') if mode == 'nofilter' else str(FILTER))
	argv = [str(ROOT / 'tests/host/ucode'), str(ROOT / 'tests/daemon/supervise-log.uc'),
		'--', str(root), mode, sys.executable, str(child)]
	# tests/host/ucode itself needs dirname and readlink before it reaches ucode.
	for tool in ('dirname', 'readlink'):
		(bin_dir / tool).symlink_to(shutil.which(tool))
	fifo = root / "run ' directory" / (NAME + '.log.fifo')
	stale_fd, stale_inode = None, None
	if mode == 'normal':
		fifo.parent.mkdir()
		os.mkfifo(fifo)
		stale_fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
		stale_inode = fifo.stat().st_ino
	with subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=root) as p:
		deadline = time.monotonic() + 5
		while mode not in ('missing', 'nofilter') and time.monotonic() < deadline:
			if p.poll() is not None:
				break
			if fifo.exists() and fifo.stat().st_ino != stale_inode:
				break
			time.sleep(0.01)
		if mode not in ('missing', 'nofilter'):
			check(fifo.exists() and stat.S_ISFIFO(fifo.stat().st_mode) and
				stat.S_IMODE(fifo.stat().st_mode) == 0o600, f'{mode}: private FIFO created',
				p.stderr.read().decode() if p.poll() is not None else '')
		if stale_fd is not None:
			check(fifo.stat().st_ino != stale_inode, 'normal: stale FIFO unlinked before creation')
			os.close(stale_fd)
		filter_pids = set()
		while p.poll() is None:
			for proc in Path('/proc').glob('[0-9]*'):
				try:
					if os.readlink(proc / 'fd/0') == str(fifo):
						filter_pids.add(int(proc.name))
				except (FileNotFoundError, PermissionError, ProcessLookupError):
					continue
			check_deadline = time.monotonic() < deadline + 8
			if not check_deadline:
				p.kill()
				raise AssertionError('supervisor exceeded test deadline')
			time.sleep(0.02)
		out, err = p.communicate(timeout=1)
	check(p.returncode == 0, f'{mode}: supervisor exits successfully', err.decode())
	verify_output(root, mode, fifo, filter_pids, out, err)


def verify_output(root, mode, fifo, filter_pids, out, err):
	check(err == (b'launch-1 line-1\n' if mode in ('missing', 'nofilter') else b''),
		f'{mode}: no unexpected child or filter errors', err.decode())
	observed = json.loads((root / 'observed.json').read_text())
	started = [e for e in observed if e['kind'] == 'started']
	check(len(started) == (2 if mode == 'crash' else 1), f'{mode}: expected child launches')
	for i, event in enumerate(started, 1):
		actual = json.loads((root / f'actual-{i}').read_text())
		check(event['pid'] == actual['pid'], f'{mode}: launch {i} supervised pid equals actual child pid')
		check(actual['arg'] == ARG and not (root / 'SENTINEL').exists(),
			f'{mode}: launch {i} shell metacharacters stay literal')
	check(not fifo.exists() and not list(fifo.parent.glob('*.pid')),
		f'{mode}: stop and cleanup leave no FIFO or pid file')
	live = []
	if mode not in ('missing', 'nofilter'):
		pids = list(filter_pids)
		check(len(pids) == len(started), f'{mode}: one FIFO reader observed for each launch')
		for _ in range(100):
			reap_filters()
			live = [pid for pid in pids if Path(f'/proc/{pid}').exists()]
			if not live:
				break
			time.sleep(0.02)
		check(not live, f'{mode}: EOF leaves no awk processes', str(live))
	events_path = fifo.parent / 'events.jsonl'
	events = [json.loads(line) for line in events_path.read_text().splitlines()] if events_path.exists() else []
	crashes = [e for e in events if e['code'] == 'CHILD_CRASHED']
	lines = out.decode().splitlines()
	if mode == 'crash':
		check(len(crashes) == 1 and crashes[0]['args']['code'] == 7 and
			crashes[0]['args']['restart_in'] == 0.15,
			'crash: exit code and backoff preserved; active stop adds no crash')
		check((root / 'mkfifos').read_text().count('mkfifo') == 3,
			'crash: restart creates a fresh FIFO and cleanup removes pid-less FIFO')
		for i in (1, 2):
			check([line for line in lines if line.startswith(f'launch-{i} ')] ==
				[f'launch-{i} line-{j}' for j in range(20)], f'crash: launch {i} output still filtered')
		check(sum('dropped 480 lines between' in line for line in lines) == 2,
			'crash: both EOF summaries retain all 480 dropped lines')
	else:
		check(not crashes, f'{mode}: active stop emits no CHILD_CRASHED')
		want = [f'launch-1 line-{i}' for i in ((0, 2) if mode in ('missing', 'nofilter') else (0, 1, 2))]
		check(lines == want, f'{mode}: stdout and stderr inherited in order without changes')
	if mode in ('missing', 'nofilter'):
		failures = [e for e in events if e['code'] == 'FS_FAILED']
		op = 'mkfifo' if mode == 'missing' else 'read'
		check(len(failures) == 1 and failures[0]['args']['op'] == op,
			f'{mode}: exactly one FS_FAILED with op {op}')
		check(not filter_pids, f'{mode}: direct inheritance starts no filter')
		if mode == 'nofilter':
			check(not (root / 'mkfifos').exists(), 'nofilter: no FIFO is made without a filter script')


if __name__ == '__main__':
	libc = ctypes.CDLL(None, use_errno=True)
	check(libc.prctl(36, 1, 0, 0, 0) == 0, 'test harness reaps orphan filters as subreaper')
	with tempfile.TemporaryDirectory(prefix='supervise-log-') as temp:
		for mode in ('normal', 'crash', 'missing', 'nofilter'):
			exercise(Path(temp), mode)
	print('supervise-log: all assertions passed')
