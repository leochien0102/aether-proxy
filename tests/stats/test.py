"""Isolated proc/nft sources for docs/10 Dashboard snapshots; no privileges needed."""
import datetime
import hashlib
import json
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
CLI = [str(ROOT / 'tests/host/ucode'), str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'stats']
HIST = [str(ROOT / 'tests/host/ucode'), str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'stats', 'history']
BLOCK = '''\tcounter proxy_tx {}
\tcounter proxy_rx {}
\tchain traffic_out {
\t\ttype filter hook output priority filter; policy accept;
\t\tip daddr @node_ip4 counter name proxy_tx
\t}
\tchain traffic_in {
\t\ttype filter hook input priority filter - 2; policy accept;
\t\tip saddr @node_ip4 counter name proxy_rx
\t}
'''


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS ' + name)


def counter(name, value):
	return {'counter': {'family': 'inet', 'table': 'aetherproxy', 'name': name,
		'packets': 7, 'bytes': value}}


def tcp(remote, state='01'):
	return f' 0: 00000000:1234 {remote}:01BB {state} 00000000:00000000\n'


def golden_tests():
	# Fingerprints of pre-card golden files: enforce an additive change without needing git history in CI.
	original_hashes = {
		't13-bypass-cn': '9937c035c394f8066c1e32f7f17bfb8b801cee6eda4656858b72659887891c8f',
		't13-gfw-hosts': '05ef465cc4488081b28d1d48440ac27dc52b24af3f08322568f698dd0a30d360',
		't13-global': '18da73bea266a8ce6a82fafb8ff88cbd6098fd8e0b812200d348c9d691b95f66',
		't13-global-follow-off': '64d35169ee813e21ea6ab1dc0e6d773bd57c275e7e74d84c291e12cd7a226b22',
	}
	for name, digest in original_hashes.items():
		path = ROOT / 'tests/fixtures' / name / 'expected/aether-proxy.nft'
		new = path.read_text()
		stripped_hash = hashlib.sha256(new.replace(BLOCK, '').encode()).hexdigest()
		check(f'1. {name} golden only adds two counters and two chains',
			new.count(BLOCK) == 1 and stripped_hash == digest)
	text = subprocess.check_output([str(ROOT / 'tests/host/ucode'), 'tests/stats/render.uc'], cwd=ROOT).decode()
	check('1. degraded renderer retains traffic chains with empty node_ip4',
		BLOCK in text and 'set node_ip4 { type ipv4_addr; flags interval; auto-merge; }' in text)


def setup_sources(base):
	run = base / 'run'
	proc = base / 'proc'
	bin_dir = base / 'bin'
	for directory in [run, proc / 'net', proc / 'sys/net/netfilter', bin_dir]:
		directory.mkdir(parents=True, exist_ok=True)
	state = run / 'state.json'
	route = proc / 'net/route'
	dev = proc / 'net/dev'
	tcp4 = proc / 'net/tcp'
	tcp6 = proc / 'net/tcp6'
	conntrack = proc / 'sys/net/netfilter/nf_conntrack_count'
	payload = bin_dir / 'counters.json'
	mode = bin_dir / 'mode'
	argv = bin_dir / 'argv'
	nft = bin_dir / 'nft'
	nft.write_text('''#!/usr/bin/env python3
import pathlib, sys, time
base = pathlib.Path(__file__).parent
(base / 'argv').write_text('\\n'.join(sys.argv[1:]))
mode = (base / 'mode').read_text()
if mode == 'timeout':
	time.sleep(8)
if mode == 'fail':
	print('table missing', file=sys.stderr)
	sys.exit(1)
print((base / 'counters.json').read_text())
''')
	nft.chmod(0o755)
	mode.write_text('ok')
	payload.write_text(json.dumps({'nftables': [{'metainfo': {'version': 'test'}},
		counter('proxy_tx', 12345), counter('proxy_rx', 67890)]}))
	state.write_text(json.dumps({'node_ip': '1.2.3.4'}))
	route.write_text('Iface Destination Gateway Flags RefCnt Use Metric Mask\n'
		'eth0 00000000 01010101 0003 0 0 20 00000000\n'
		'eth1 00000000 01010101 0003 0 0 5 00000000\n'
		'lan 0002A8C0 00000000 0001 0 0 0 00FFFFFF\n')
	dev.write_text('Inter-| Receive | Transmit\n'
		' eth0: 10 0 0 0 0 0 0 0 20 0 0 0 0 0 0 0\n'
		' eth1: 1000 1 2 3 4 5 6 7 2000 9 10 11 12 13 14 15\n')
	tcp4.write_text('sl local_address rem_address st\n' + tcp('04030201') + tcp('04030201')
		+ tcp('04030201', '02') + tcp('01020304') + tcp('08080808'))
	tcp6.write_text('sl local_address rem_address st\n' + tcp('0000000000000000FFFF000004030201')
		+ tcp('0000000000000000FFFF000004030201', '06') + tcp('0000000000000000FFFF000001020304')
		+ tcp('00000000000000000000000004030201'))
	conntrack.write_text('42\n')
	# A sentinel proves every read/failure path leaves the event stream untouched.
	events = run / 'events.jsonl'
	events.write_text('sentinel\n')
	return run, route, dev, tcp4, tcp6, conntrack, payload, mode, argv, state


def snapshots(base):
	run, route, dev, tcp4, tcp6, conntrack, payload, mode, argv, state = setup_sources(base)
	events = run / 'events.jsonl'
	args = ['--json', '--run-dir', str(run), '--sys-root', str(base), '--bin-dir', str(base / 'bin')]

	def read():
		result = subprocess.run(CLI + args, cwd=ROOT, text=True, capture_output=True, timeout=12)
		assert result.returncode == 0, result.stderr
		value = json.loads(result.stdout)
		assert value['ok'] is True
		assert events.read_text() == 'sentinel\n'
		return value

	full = read()
	check('2. nft receives exact table query', argv.read_text().splitlines() ==
		['-j', 'list', 'counters', 'table', 'inet', 'aetherproxy'])
	check('2. every snapshot field matches all readable sources',
		full['proxy'] == {'tx_bytes': 12345, 'rx_bytes': 67890}
		and full['wan'] == {'dev': 'eth1', 'tx_bytes': 2000, 'rx_bytes': 1000}
		and full['connections'] == {'proxy': 3, 'total': 42})

	def missing(name, path, replacement, expected):
		original = path.read_bytes()
		if replacement is None:
			path.unlink()
		else:
			path.write_text(replacement)
		value = read()
		path.write_bytes(original)
		value.pop('at_ms')
		check(name, value == expected)

	baseline = {key: value for key, value in full.items() if key != 'at_ms'}
	for variant in ['fail', 'ok']:
		mode.write_text(variant)
		expected = dict(baseline, proxy=None)
		if variant == 'fail':
			check('3. nft failure only nulls proxy without events',
				{key: value for key, value in read().items() if key != 'at_ms'} == expected)
		else:
			for content in ['{"nftables":[]}', '{"nftables":[' + json.dumps(counter('proxy_tx', 5)) + ']}',
				'not json', '{"nftables":{}}']:
				missing('3. absent or malformed counters only null proxy without events', payload, content, expected)
	missing('3. no default route only nulls wan', route, 'Iface Destination\n', dict(baseline, wan=None))
	missing('3. unreadable route only nulls wan', route, None, dict(baseline, wan=None))
	missing('3. unreadable device only nulls wan', dev, None, dict(baseline, wan=None))
	missing('3. empty node_ip only nulls proxy connections', state, '{"node_ip":null}',
		dict(baseline, connections={'proxy': None, 'total': 42}))
	missing('3. missing state only nulls proxy connections', state, None,
		dict(baseline, connections={'proxy': None, 'total': 42}))
	missing('3. corrupt state only nulls proxy connections', state, 'broken',
		dict(baseline, connections={'proxy': None, 'total': 42}))
	for path in [tcp4, tcp6]:
		missing(f'3. unreadable {path.name} only nulls proxy connections', path, None,
			dict(baseline, connections={'proxy': None, 'total': 42}))
	missing('3. missing conntrack only nulls total', conntrack, None,
		dict(baseline, connections={'proxy': 3, 'total': None}))
	missing('3. invalid conntrack only nulls total', conntrack, 'bad',
		dict(baseline, connections={'proxy': 3, 'total': None}))
	tcp4.write_text(tcp('01020304'))
	tcp6.write_text(tcp('0000000000000000FFFF000001020304'))
	check('4. big-endian lookalikes do not match 1.2.3.4', read()['connections']['proxy'] == 0)
	tcp4.write_text(tcp('04030201'))
	tcp6.write_text(tcp('0000000000000000FFFF000004030201'))
	check('4. little-endian IPv4 and mapped IPv6 both match 1.2.3.4', read()['connections']['proxy'] == 2)
	first, second = read(), read()
	check('5. at_ms is numeric and monotonic', isinstance(first['at_ms'], (int, float))
		and isinstance(second['at_ms'], (int, float)) and second['at_ms'] >= first['at_ms'])
	# A monotonic clock counts from boot; wall-clock milliseconds since 1970 are far larger.
	check('5. at_ms is monotonic time, not a wall-clock timestamp',
		first['at_ms'] < time.time() * 1000 - 1e11)
	for invalid in [['extra'], ['--confdir', str(base)], ['--run-dir'], ['--unknown']]:
		result = subprocess.run(CLI + ['--json'] + invalid, cwd=ROOT, text=True, capture_output=True)
		check('usage rejects ' + ' '.join(invalid), result.returncode == 2
			and json.loads(result.stdout)['code'] == 'USAGE')


def confdir(base, heatmap):
	# A minimal valid configuration (main disabled) whose only variable is the B25 switch.
	path = base / ('heatmap-on' if heatmap else 'heatmap-off')
	path.mkdir(parents=True, exist_ok=True)
	(path / 'aetherproxy').write_text(
		"config main 'main'\n\toption enabled '0'\n"
		+ ("config stats 'stats'\n\toption heatmap_enabled '1'\n" if heatmap else
			"config stats 'stats'\n\toption heatmap_enabled '0'\n"))
	return path


def usage_document(count, updated_at=1790000000):
	# `count` valid local dates starting 2026-01-01 (tx marks the index, so order and
	# trimming are observable); junk keys ride along and must never surface.
	days = {}
	for i in range(count):
		date = (datetime.date(2026, 1, 1) + datetime.timedelta(days=i)).isoformat()
		days[date] = {'tx': i, 'rx': count - i, 'observed': 86400, 'healthy': 86000}
	days['not-a-date'] = {'tx': 1, 'rx': 1, 'observed': 1, 'healthy': 1}
	days['2026-99-99'] = 'junk'
	return json.dumps({'schema': 1, 'updated_at': updated_at, 'days': days})


def history(base):
	# docs/10 "stats history" (T12.5): read-only daily usage with the B25 switch.
	root = base / 'hist-root'
	(root / 'etc/aether-proxy').mkdir(parents=True, exist_ok=True)
	conf_on = confdir(base, True)
	file = root / 'etc/aether-proxy/usage.json'
	# 95 valid days: the persisted cap; --days must trim to the *last* N by date.
	file.write_text(usage_document(95))

	def run(*args):
		return subprocess.run(HIST + ['--json', '--sys-root', str(root),
			'--confdir', str(conf_on), *args], cwd=ROOT, text=True, capture_output=True, timeout=12)

	value = json.loads(run().stdout)
	check('6. history defaults to 90 days, oldest first, junk entries dropped',
		value['ok'] is True and value['enabled'] is True and len(value['days']) == 90
		and value['days'][0]['date'] == '2026-01-06' and value['days'][-1]['date'] == '2026-04-05'
		and value['updated_at'] == 1790000000
		and all(list(day.keys()) == ['date', 'tx', 'rx', 'observed', 'healthy'] for day in value['days']))
	check('6. history trims to the newest --days entries',
		json.loads(run('--days', '1').stdout)['days'] == [
			{'date': '2026-04-05', 'tx': 94, 'rx': 1, 'observed': 86400, 'healthy': 86000}]
		and len(json.loads(run('--days', '89').stdout)['days']) == 89)
	original = file.read_bytes()
	run('--days', '90')
	check('6. history leaves the usage file byte for byte unchanged', file.read_bytes() == original)
	for invalid in [['--days', '0'], ['--days', '91'], ['--days', 'abc'], ['--days'], ['--days', '-1'],
			['--days', '1.5'], ['--days', '1', '--days', '2'], ['extra'], ['--bin-dir', str(base)]]:
		result = run(*invalid)
		check('6. history usage rejects ' + ' '.join(invalid), result.returncode == 2
			and json.loads(result.stdout)['code'] == 'USAGE')

	file.unlink()
	value = json.loads(run().stdout)
	check('6. history with a missing file is an enabled empty history with null updated_at',
		value == {'ok': True, 'enabled': True, 'days': [], 'updated_at': None})
	file.write_text('{"days": { broken')
	value = json.loads(run().stdout)
	check('6. history with a corrupt file is the same empty history and keeps the bytes',
		value == {'ok': True, 'enabled': True, 'days': [], 'updated_at': None}
		and file.read_text() == '{"days": { broken')

	# With the switch off the file must not even be read: a full history is on disk.
	file.write_text(usage_document(95))
	conf_off = confdir(base, False)
	value = json.loads(subprocess.run(HIST + ['--json', '--sys-root', str(root),
		'--confdir', str(conf_off)], cwd=ROOT, text=True, capture_output=True, timeout=12).stdout)
	check('6. history with the switch off is exactly the disabled reply',
		value == {'ok': True, 'enabled': False, 'days': []})
	no_stats = root / 'conf-empty'
	no_stats.mkdir(exist_ok=True)
	(no_stats / 'aetherproxy').write_text("config main 'main'\n\toption enabled '0'\n")
	value = json.loads(subprocess.run(HIST + ['--json', '--sys-root', str(root),
		'--confdir', str(no_stats)], cwd=ROOT, text=True, capture_output=True, timeout=12).stdout)
	check('6. history without a stats section is off like the switch says',
		value == {'ok': True, 'enabled': False, 'days': []})

	# An unrelated invalid configuration fails the call like status does (docs/10).
	broken = root / 'conf-broken'
	broken.mkdir(exist_ok=True)
	(broken / 'aetherproxy').write_text("config main 'main'\n\toption enabled '1'\n")
	result = subprocess.run(HIST + ['--json', '--sys-root', str(root),
		'--confdir', str(broken)], cwd=ROOT, text=True, capture_output=True, timeout=12)
	check('6. history with an invalid configuration is CONFIG_INVALID', result.returncode == 2
		and json.loads(result.stdout)['code'] == 'CONFIG_INVALID')


golden_tests()
with tempfile.TemporaryDirectory(prefix='aether-stats-') as directory:
	snapshots(pathlib.Path(directory))
	history(pathlib.Path(directory))
print('stats: all scenarios passed')
