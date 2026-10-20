#!/usr/bin/env python3
"""T10.7: real data status CLI, old-algorithm oracle and recording grep faults.

All fixtures, module copies, runtime events and sys.run scratch stay inside this
worktree. Only test constants change in the copy to detect default-path logging.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
PREFIX = ROOT / 'tests/host/prefix'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
NAMES = ['gfwlist', 'chnlist', 'apple', 'chnroute4', 'gfw_static4']


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS  T10.7 data status: ' + name, flush=True)


with tempfile.TemporaryDirectory(prefix='.data-status-', dir=ROOT / 'tests/cli') as temp:
	base = Path(temp)
	# A colon tests output parsing; spaces and a quote test sys.run argv handling.
	root = base / "root: with ' spaces"
	baseline = root / 'usr/share/aether-proxy/data'
	downloaded = root / 'etc/aether-proxy/data'
	run = root / 'var/run/aether-proxy'
	default_run = base / 'default-run'
	binaries = base / 'bin'
	scratch = base / 'tmp'
	for directory in (baseline, downloaded, run, default_run, binaries, scratch):
		directory.mkdir(parents=True)
	for directory in (run, default_run):
		(directory / 'events.jsonl').write_text('sentinel\n')

	modules = base / 'modules/aetherproxy'
	shutil.copytree(ROOT / 'aether-proxy/src/lib', modules)
	constants = modules / 'const.uc'
	text = constants.read_text()
	for name, path in [('RUN_DIR', default_run), ('TMP_DIR', scratch)]:
		text, count = re.subn(rf"export const {name} = '[^']+';",
			f"export const {name} = '{path}';", text)
		assert count == 1
	constants.write_text(text)

	real_grep = shutil.which('grep')
	assert real_grep is not None
	env = dict(os.environ, LD_LIBRARY_PATH=str(PREFIX / 'lib'),
		PATH=str(binaries) + os.pathsep + os.environ['PATH'],
		DATA_GREP_REAL=real_grep, DATA_GREP_LOG=str(base / 'grep.jsonl'),
		DATA_GREP_RC=str(base / 'grep.rc'))
	ucode = [str(PREFIX / 'bin/ucode'), '-L', str(base / 'modules/*.uc'),
		'-L', str(PREFIX / 'lib/ucode/*.so')]
	command = ucode + ['-S', str(ENTRY), '--', 'data', 'status', '--json',
		'--sys-root', str(root), '--run-dir', str(run)]

	wrapper = binaries / 'grep'
	wrapper.write_text(f'#!{sys.executable}\n' + '''import json
import os
from pathlib import Path
import subprocess
import sys
import time

args = sys.argv[1:]
with open(os.environ['DATA_GREP_LOG'], 'a') as log:
	log.write(json.dumps(args) + '\\n')
mode = os.environ['DATA_GREP_MODE']
if mode == 'timeout':
	time.sleep(30)
if mode == 'exit2':
	print('injected grep failure', file=sys.stderr)
	sys.exit(2)
result = subprocess.run([os.environ['DATA_GREP_REAL'], *args], capture_output=True)
Path(os.environ['DATA_GREP_RC']).write_text(str(result.returncode))
rows = result.stdout.splitlines()
if mode == 'missing':
	rows.pop()
elif mode == 'nonnumeric':
	rows[0] = rows[0].rsplit(b':', 1)[0] + b':NaN'
elif mode == 'duplicate':
	rows[-1] = rows[0]
elif mode == 'reverse':
	rows.reverse()
sys.stdout.buffer.write(b'\\n'.join(rows) + b'\\n')
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
''')
	wrapper.chmod(0o755)

	paths = {}
	for i, name in enumerate(NAMES):
		# Every file contains each whitespace/comment case plus a final data line
		# without a newline. Distinct counts expose accidental positional mapping.
		content = (b'# comment\n\n \n\t\n\r\n \t\r\n  # indented\n'
			b'\t# tab comment\n\r# CR comment\nordinary.example\n'
			b'  padded.example \t\r\ndata-with-CR.example\r\n'
			+ b'extra.example\n' * (2 * i) + b'last-no-newline.example')
		(baseline / f'{name}.txt').write_bytes(content)
		path = baseline / f'{name}.txt'
		if i % 2 == 0:
			path = downloaded / f'{name}.txt'
			path.write_bytes(content + b'\nonly-downloaded.example')
			os.utime(path, (1700000000, 1700000000))
			# Must preserve the authoritative hash rather than hashing the data file.
			(downloaded / f'{name}.sha256').write_text('a' * 64 + '\n')
		paths[name] = str(path)
	(run / 'updates.json').write_text(json.dumps({'checked': 123, 'data': {
		'gfwlist': {'changed': False}, 'chnlist': {'changed': True}
	}}))

	def invoke(mode='normal', expected=0):
		log = base / 'grep.jsonl'
		log.write_text('')
		started = time.monotonic()
		result = subprocess.run(command, env=dict(env, DATA_GREP_MODE=mode),
			capture_output=True, text=True, timeout=10)
		elapsed = time.monotonic() - started
		check(f'{mode}: exit {expected}, one JSON object and empty stderr',
			result.returncode == expected and result.stderr == '')
		value = json.loads(result.stdout)
		assert isinstance(value, dict)
		check(f'{mode}: no event written to explicit or default runtime directory', all(
			(directory / 'events.jsonl').read_text() == 'sentinel\n'
			for directory in (run, default_run)))
		calls = [json.loads(line) for line in log.read_text().splitlines()]
		check(f'{mode}: exactly one grep with flags, literal TAB/CR and all five selected paths',
			len(calls) == 1 and calls[0][:5] == ['-H', '-c', '-v', '-E', '^[ \t\r]*(#|$)']
			and len(calls[0][5:]) == 5 and set(calls[0][5:]) == set(paths.values()))
		return value, elapsed

	reference = subprocess.run(ucode + [str(ROOT / 'tests/cli/data-lines-reference.uc'),
		*paths.values()], env=env, capture_output=True, text=True, timeout=10)
	assert reference.returncode == 0 and reference.stderr == '', reference.stderr
	counts = json.loads(reference.stdout)
	assert len(set(counts.values())) == 5 and all(count > 0 for count in counts.values())
	value, _ = invoke('reverse')
	check('mixed sources: checked timestamp and five inventory items preserved',
		value['ok'] is True and value['checked'] == 123 and set(value['items']) == set(NAMES))
	for i, name in enumerate(NAMES):
		check(f'{name}: whitespace/comments/CR/final line match original trim algorithm',
			value['items'][name]['lines'] == counts[paths[name]])
		hash_prefix = ('a' * 12 if i % 2 == 0 else
			hashlib.sha256((baseline / f'{name}.txt').read_bytes()).hexdigest()[:12])
		check(f'{name}: source, authoritative version, mtime and changed unchanged',
			value['items'][name] == {
				'source': 'downloaded' if i % 2 == 0 else 'baseline',
				'version': hash_prefix, 'lines': counts[paths[name]],
				'updated_at': 1700000000 if i % 2 == 0 else None,
				'changed': False if i == 0 else True if i == 1 else None
			})

	Path(paths['apple']).write_bytes(b'\n \t\r\n # comment\n\t# comment\n\r# final')
	value, _ = invoke()
	check('one all-comment file: zero lines and overall ok true',
		value['ok'] is True and value['items']['apple']['lines'] == 0)
	for mode in ('missing', 'nonnumeric'):
		value, _ = invoke(mode, expected=1)
		check(f'{mode}: exact CMD_FAILED reply including grep exit 0', value == {
			'ok': False, 'code': 'CMD_FAILED', 'detail': 'grep exit 0'
		})
	for path in paths.values():
		Path(path).write_bytes(b'\n \t\r\n # comment\n\t# comment\n\r# final')
	value, _ = invoke()
	check('grep exit 1: all five counts zero and overall ok true',
		(base / 'grep.rc').read_text() == '1' and value['ok'] is True
		and all(item['lines'] == 0 for item in value['items'].values()))

	for mode, code in [('exit2', 2), ('missing', 1), ('nonnumeric', 1),
		('duplicate', 1), ('timeout', 124)]:
		value, elapsed = invoke(mode, expected=1)
		check(f'{mode}: exact CMD_FAILED reply including grep exit {code}', value == {
			'ok': False, 'code': 'CMD_FAILED', 'detail': f'grep exit {code}'
		})
		if mode == 'timeout':
			check('hung grep: real 5-second timeout enforced', 4.5 <= elapsed < 8)
			print(f'INFO  T10.7 data status: timeout elapsed {elapsed:.2f}s', flush=True)
