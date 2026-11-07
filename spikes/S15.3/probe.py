#!/usr/bin/env python3
"""S15.3 real-engine contracts; fake services are terminal DNS authorities, never relays.

See docs/tasks/m15.md E1-E10. Only literal loopback sockets and owned child PIDs
are used. The tiny A/IN decoder is evidence tooling, NOT a production resolver.
"""
import argparse
import asyncio
import contextlib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import time

BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[1]
NODE = 'node.s15.test'
FORBIDDEN = {53, 31053, 31082, 31083}
START = time.monotonic()
ARGS = None
ACTIVE = set()
TLS_NAMES = []


def audit(name, args):
	# Deliberately make system name resolution unavailable to this caller.
	if name == 'socket.getaddrinfo':
		raise RuntimeError('system resolver forbidden in S15.3')
	if name == 'socket.connect':
		address = args[1]
		if not isinstance(address, tuple) or address[0] != '127.0.0.1' or address[1] in FORBIDDEN:
			raise RuntimeError('non-private endpoint forbidden in S15.3')
	if name == 'subprocess.Popen':
		allowed = {str(ROOT / 'tests/host/ucode'), 'openssl', *ARGS.engines.values()}
		if args[0] not in allowed:
			raise RuntimeError('external command outside S15.3 allowlist: ' + str(args[0]))


def event(kind, **fields):
	print(json.dumps(dict(t=round(time.monotonic() - START, 6), event=kind, **fields)), flush=True)


def check(ok, label):
	event('assert', status='PASS' if ok else 'FAIL', label=label)
	if not ok:
		raise AssertionError(label)


def port():
	while True:
		with socket.socket() as s:
			s.bind(('127.0.0.1', 0))
			p = s.getsockname()[1]
		if p not in FORBIDDEN:
			return p


def packet():
	q = b''.join(bytes([len(x)]) + x.encode() for x in NODE.split('.')) + b'\0'
	return os.urandom(2) + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + q + b'\0\1\0\1'


def qname(data):
	i, labels = 12, []
	while data[i]:
		n = data[i]
		labels.append(data[i + 1:i + n + 1].decode())
		i += n + 1
	return '.'.join(labels)


def answer(data, ip):
	return (data[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + data[12:]
		+ b'\xc0\x0c\0\1\0\1\0\0\0\0\0\4' + socket.inet_aton(ip))


async def query(p):
	data = packet()
	s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
	s.setblocking(False)
	try:
		s.connect(('127.0.0.1', p))
		loop = asyncio.get_running_loop()
		event('caller_send', qname=NODE, protocol='udp', target=['127.0.0.1', p])
		await loop.sock_sendall(s, data)
		r = await asyncio.wait_for(loop.sock_recv(s, 4096), .9)
		if r[:2] != data[:2] or r[2:4] != b'\x81\x80' or r[6:8] != b'\0\1':
			return None
		ip = socket.inet_ntoa(r[-4:])
		event('caller_answer', source=['127.0.0.1', p], ip=ip)
		return ip
	except (TimeoutError, ConnectionRefusedError):
		return None
	finally:
		s.close()


class Authority(asyncio.DatagramProtocol):
	def __init__(self, name, ip='192.0.2.11', delay=0, tls=None):
		self.name, self.ip, self.delay, self.tls = name, ip, delay, tls
		self.received, self.tasks = [], set()
		self.p = port()

	async def __aenter__(self):
		loop = asyncio.get_running_loop()
		self.udp, _ = await loop.create_datagram_endpoint(lambda: self,
			local_addr=('127.0.0.1', self.p))
		self.tcp = await asyncio.start_server(self.stream, '127.0.0.1', self.p, ssl=self.tls)
		event('authority', name=self.name, port=self.p, ip=self.ip, tls=bool(self.tls))
		return self

	def track(self, coro):
		task = asyncio.create_task(coro)
		self.tasks.add(task)
		# Retain completed tasks until exit so authority errors cannot go unobserved.

	def datagram_received(self, data, peer):
		self.track(self.datagram(data, peer))

	def record(self, data, proto, peer):
		row = dict(qname=qname(data), protocol=proto, target=['127.0.0.1', self.p],
			peer=peer, authority=self.name, response_ip=self.ip)
		self.received.append(row)
		event('upstream_receive', **row)

	async def datagram(self, data, peer):
		self.record(data, 'udp', peer)
		if self.ip is not None:
			await asyncio.sleep(self.delay)
			self.udp.sendto(answer(data, self.ip), peer)
			event('upstream_answer', authority=self.name, protocol='udp', ip=self.ip)

	async def stream(self, reader, writer):
		task = asyncio.current_task()
		self.tasks.add(task)
		proto = 'tls' if self.tls else 'tcp'
		try:
			if self.tls:
				event('tls_handshake', authority=self.name,
					version=writer.get_extra_info('ssl_object').version())
			while True:
				n = struct.unpack('!H', await reader.readexactly(2))[0]
				data = await reader.readexactly(n)
				self.record(data, proto, writer.get_extra_info('peername'))
				if self.ip is not None:
					await asyncio.sleep(self.delay)
					r = answer(data, self.ip)
					writer.write(struct.pack('!H', len(r)) + r)
					await writer.drain()
					event('upstream_answer', authority=self.name, protocol=proto, ip=self.ip)
		except (asyncio.IncompleteReadError, ConnectionResetError):
			pass  # Expected EOF from an owned engine; not an external-command failure.
		finally:
			writer.close()
			with contextlib.suppress(ConnectionResetError):
				await writer.wait_closed()

	async def __aexit__(self, *exc):
		self.tcp.close()
		# Cancel delayed UDP replies before closing their transport. Waiting for TCP
		# first lets slow UDP tasks wake and send on an already-closed socket.
		for t in self.tasks:
			t.cancel()
		results = await asyncio.gather(*self.tasks, return_exceptions=True)
		self.udp.close()
		await self.tcp.wait_closed()
		for result in results:
			if isinstance(result, BaseException) and not isinstance(result, asyncio.CancelledError):
				raise result


def owns_socket(pid, p):
	"""A random occupier must not satisfy readiness: intersect socket inode with child's fd table."""
	try:
		links = {os.readlink(f) for f in Path(f'/proc/{pid}/fd').iterdir()}
	except (FileNotFoundError, PermissionError):
		# An exiting process can lose its fd directory before the child watcher fires.
		return False
	for proto in ('udp', 'tcp'):
		found = False
		for line in Path('/proc/net/' + proto).read_text().splitlines()[1:]:
			fields = line.split()
			addr, number = fields[1].split(':')
			if addr == '0100007F' and int(number, 16) == p:
				if f'socket:[{fields[9]}]' in links:
					found = True
		if not found:
			return False
	return True


class Child:
	serial = 0

	def __init__(self, engine, upstream, p=None):
		Child.serial += 1
		self.engine, self.p = engine, p or port()
		self.directory = BASE / '.runtime' / f'{os.getpid()}-{Child.serial}'
		self.directory.mkdir(parents=True)
		self.config = self.directory / 'bootstrap.conf'
		self.text = (f'bind-addr 127.0.0.1\nbind-port {self.p}\n'
			f'china-dns {upstream}\ntrust-dns {upstream}\ndefault-tag gfw\n'
			'ipset-name4 null\nipset-name6 null\ncache 0\n')
		self.config.write_text(self.text)
		self.log = self.directory / 'child.log'
		self.proc = None
		ACTIVE.add(self)

	async def start(self):
		with self.log.open('wb') as out:
			self.proc = await asyncio.create_subprocess_exec(ARGS.engines[self.engine], '-C', str(self.config),
				stdout=out, stderr=out, cwd=self.directory)
		event('child', engine=self.engine, pid=self.proc.pid, config=str(self.config), text=self.text)
		for _ in range(100):
			if self.proc.returncode is not None:
				return False
			if owns_socket(self.proc.pid, self.p):
				event('ready_owned', pid=self.proc.pid, port=self.p)
				return True
			await asyncio.sleep(.01)
		return False

	def identity(self, pid):
		try:
			cmd = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
			return (pid == self.proc.pid and cmd[0] == os.fsencode(ARGS.engines[self.engine])
				and os.fsencode(self.config) in cmd and self.config.parent == self.directory)
		except FileNotFoundError:
			return False

	async def close(self, reusable=True):
		if self not in ACTIVE:
			return
		if self.proc:
			if self.proc.returncode is None and not self.identity(self.proc.pid):
				# The async child watcher may lag /proc disappearance after startup rejection.
				await asyncio.wait_for(self.proc.wait(), .5)
			if self.proc.returncode is None:
				check(self.identity(self.proc.pid), self.engine + ' cleanup verifies PID/argv/owned config')
				self.proc.terminate()
				try:
					await asyncio.wait_for(self.proc.wait(), 1)
				except TimeoutError:
					self.proc.kill()
					await self.proc.wait()
			event('wait', engine=self.engine, pid=self.proc.pid, exit=self.proc.returncode,
				log=self.log.read_text(errors='replace'))
			check(not Path(f'/proc/{self.proc.pid}').exists(), self.engine + ' child reaped')
		shutil.rmtree(self.directory)
		check(not self.directory.exists(), self.engine + ' owned temporary files removed')
		if reusable:
			with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
				s.bind(('127.0.0.1', self.p))
			with socket.socket() as s:
				s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
				s.bind(('127.0.0.1', self.p))
			event('socket_reusable', port=self.p, protocols=['udp', 'tcp'])
		ACTIVE.remove(self)


async def resolve(engine, upstream, label, expected='192.0.2.11', endpoint=None):
	c = Child(engine, upstream)
	try:
		check(await c.start(), label + ' owned readiness')
		ip = await query(endpoint or c.p)
		check(ip == expected, label + ' node IPv4 from explicit private endpoint')
	finally:
		await c.close()


def rendered(enabled, china, direct):
	snapshot = {'dns': {'direct_dns_enabled': enabled, 'china_dns': ['wan'], 'direct_dns': [direct]}}
	code = "import * as r from 'aetherproxy.render.chinadns'; "
	code += 'let s = json(' + json.dumps(json.dumps(snapshot)) + '); '
	code += 'print(r.render(s, {wan_dns:[' + json.dumps(china) + ']}));'
	r = subprocess.run([str(ROOT / 'tests/host/ucode'), '-e', code], capture_output=True, text=True,
		timeout=3, check=True)
	event('renderer', enabled=enabled, text=r.stdout)
	return r.stdout.split('group boot\n')[1].splitlines()[0].removeprefix('group-upstream ')


async def basic(engine):
	async with Authority('china') as china, Authority('direct', '192.0.2.22') as direct:
		u = f'udp://127.0.0.1#{china.p}'
		await resolve(engine, u, engine + ' E1 minimal')
		event('scenario', engine=engine, id='E1', status='PASS')
		closed = port()
		check(await query(closed) is None, engine + ' E2 formal stand-in closed')
		await resolve(engine, u, engine + ' E2', endpoint=closed if ARGS.mutation == 'closed-formal' else None)
		event('scenario', engine=engine, id='E2', status='PASS')
		for enabled in (False, True):
			selected = rendered(enabled, u, f'tcp://127.0.0.1#{direct.p}')
			check(selected == (f'tcp://127.0.0.1#{direct.p}' if enabled else u),
				engine + f' E3 renderer boot selection {enabled}')
			before = len(china.received), len(direct.received)
			await resolve(engine, selected, engine + f' E3 {enabled}', '192.0.2.22' if enabled else '192.0.2.11')
			after = len(china.received), len(direct.received)
			check(after[int(enabled)] > before[int(enabled)] and
				after[int(not enabled)] == before[int(not enabled)], engine + ' E3 only selected target receives')
		event('scenario', engine=engine, id='E3', status='PASS')
		for prefix in ('', 'udp://', 'tcp://'):
			for host in ('', 'boot.test@'):
				before = len(china.received)
				value = f'{prefix}{host}127.0.0.1#{china.p}'
				if engine == 'chinadns-ng' and host:
					c = Child(engine, value)
					try:
						check(not await c.start(), engine + ' E4 non-TLS host@IP rejects without stripping host')
						await asyncio.wait_for(c.proc.wait(), 1)
						check(c.proc.returncode != 0 and 'no host required' in c.log.read_text(),
							engine + ' E4 host@IP rejection diagnostic')
						check(len(china.received) == before, engine + ' E4 rejected host sends no traffic')
						event('syntax', engine=engine, value=value, status='UNSUPPORTED')
					finally:
						await c.close()
					continue
				await resolve(engine, value, engine + f' E4 {prefix}{host}')
				rows = china.received[before:]
				check(rows and all(r['protocol'] == ('tcp' if prefix == 'tcp://' else 'udp') for r in rows),
					engine + ' E4 actual transport and literal target')
		# No request to port 53: inspect bare-IP acceptance without contacting host DNS.
		c = Child(engine, '127.0.0.1')
		try:
			check(await c.start(), engine + ' E4 bare IP syntax accepted (no default-53 query)')
		finally:
			await c.close()
		event('scenario', engine=engine, id='E4', status='PASS',
			scope='bare IP startup only; supported #port forms queried; rejected host forms separately UNSUPPORTED')
		check(all(r['qname'] == NODE for r in china.received + direct.received),
			engine + ' E10 authorities receive node only, never ordinary gfw')


async def competition(engine):
	async with Authority('slow', '192.0.2.44', .45) as slow, Authority('fast', '192.0.2.55') as fast:
		for proto in ('udp', 'tcp'):
			for order in ((slow, fast), (fast, slow)):
				before = len(slow.received), len(fast.received)
				u = ','.join(f'{proto}://127.0.0.1#{a.p}' for a in order)
				await resolve(engine, u, engine + ' E5 ' + proto, '192.0.2.55')
				check((len(slow.received) - before[0], len(fast.received) - before[1]) == (1, 1),
					engine + ' E5 one caller query creates two concurrent exchanges')
		event('scenario', engine=engine, id='E5', status='PASS')


async def tls_contract(engine, ctx):
	async with Authority('tls', tls=ctx) as tls:
		for host in ('', 'boot.test@'):
			u = f'tls://{host}127.0.0.1#{tls.p}'
			if engine == 'aether-dns':
				c = Child(engine, u)
				try:
					check(not await c.start(), engine + ' E6 TLS must reject startup')
					await c.proc.wait()
					check(c.proc.returncode != 0 and 'tls://' in c.log.read_text(),
						engine + ' E6 explicit TLS diagnostic')
				finally:
					await c.close()
			else:
				before = len(tls.received)
				await resolve(engine, u, engine + ' E6 ' + host)
				check(len(tls.received) == before + 1 and tls.received[-1]['protocol'] == 'tls',
					engine + ' E6 TLS handshake and DNS query, no UDP fallback')
				check(TLS_NAMES[-1] == ('boot.test' if host else None), engine + ' E6 host preserved as TLS SNI')
		event('scenario', engine=engine, id='E6', status='UNSUPPORTED' if engine == 'aether-dns' else 'PASS',
			scope='local self-signed TLS; fallback cert verification default OFF; SNI logged separately')


async def conflict(engine):
	async with Authority('occupier', '192.0.2.99') as occupied, Authority('retry-upstream') as upstream:
		c = Child(engine, f'udp://127.0.0.1#{upstream.p}', occupied.p)
		try:
			ready = await c.start()
			if ARGS.mutation == 'impostor':
				ip = await query(occupied.p)
				check(ready and ip == '192.0.2.11', engine + ' E7 readiness requires owned child and expected source')
			else:
				check(not ready, engine + ' E7 readiness requires owned child and expected source')
			await asyncio.wait_for(c.proc.wait(), 1)
			check(c.proc.returncode != 0, engine + ' E7 collision explicitly exits nonzero')
		finally:
			await c.close(reusable=False)
		await resolve(engine, f'udp://127.0.0.1#{upstream.p}', engine + ' E7 retry candidate 2 of at most 10')
		check(not occupied.received, engine + ' E7 normal path never queries occupier')
		event('scenario', engine=engine, id='E7', status='PASS', attempts=2)


async def lifecycle(engine):
	sentinel = BASE / '.runtime' / 'external-preset'
	sentinel.write_bytes(b'not-owned-by-bootstrap\n')
	async with Authority('live') as live, Authority('blackhole', None) as blackhole:
		a = Child(engine, f'udp://127.0.0.1#{live.p}')
		b = Child(engine, f'udp://127.0.0.1#{blackhole.p}')
		try:
			check(await a.start() and await b.start(), engine + ' E8 parallel instances ready')
			check(await query(b.p) is None and blackhole.received, engine + ' E8 actual unanswered query times out')
			await b.close()
			check(await query(a.p) == '192.0.2.11', engine + ' E8 stopping one does not stop other')
			# Deliver real SIGTERM to this supervisor while its explicit query is pending.
			b = Child(engine, f'udp://127.0.0.1#{blackhole.p}')
			check(await b.start(), engine + ' E8 cancellation child ready')
			loop = asyncio.get_running_loop()
			stopped = asyncio.Event()
			loop.add_signal_handler(signal.SIGTERM, stopped.set)
			pending = asyncio.create_task(query(b.p))
			try:
				await asyncio.sleep(.05)
				t0 = time.monotonic()
				os.kill(os.getpid(), signal.SIGTERM)
				await asyncio.wait_for(stopped.wait(), .5)
				pending.cancel()
				await asyncio.gather(pending, return_exceptions=True)
				await b.close()
				check(time.monotonic() - t0 < 1.5, engine + ' E8 real SIGTERM bounded cancellation cleanup')
			finally:
				loop.remove_signal_handler(signal.SIGTERM)
			check(sentinel.read_bytes() == b'not-owned-by-bootstrap\n', engine + ' E8 external preset preserved')
			event('scenario', engine=engine, id='E8', status='PASS')
			b = Child(engine, f'udp://127.0.0.1#{live.p}')
			check(await b.start(), engine + ' E9 victim ready')
			check(not b.identity(a.proc.pid), engine + ' E9 reject same-name other instance PID/config')
			check(b.identity(b.proc.pid), engine + ' E9 verify owned PID/argv/directory before SIGKILL')
			b.proc.kill()
			await b.proc.wait()
			check(b.proc.returncode == -signal.SIGKILL and b.config.exists(),
				engine + ' E9 SIGKILL leaves owned config')
			await b.close()
			check(await query(a.p) == '192.0.2.11', engine + ' E9 same-name other instance remains responsive')
			event('scenario', engine=engine, id='E9', status='PASS')
		finally:
			await b.close()
			await a.close()
	# The fixture owner, not the bootstrap cleaner, removes its external preset.
	sentinel.unlink()


async def main():
	BASE.joinpath('.runtime').mkdir(exist_ok=True)
	handoff = BASE / '.runtime' / 'handoff'
	intent = BASE / '.runtime' / 'intent'
	handoff.write_bytes(b'no-resolv\nserver=127.0.0.1#ROLE_FORMAL\n')
	intent.write_bytes(b'restart intent fixture\n')
	original = {p: p.read_bytes() for p in (handoff, intent)}
	certdir = BASE / '.runtime' / 'tls-fixture'
	certdir.mkdir()
	r = subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
		'-subj', '/CN=boot.test', '-keyout', str(certdir / 'key.pem'), '-out', str(certdir / 'cert.pem')],
		capture_output=True, text=True, timeout=10)
	event('openssl', exit=r.returncode, stderr=r.stderr)
	r.check_returncode()
	ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
	ctx.load_cert_chain(certdir / 'cert.pem', certdir / 'key.pem')
	def sni(sslobj, name, context):
		TLS_NAMES.append(name)
		event('tls_sni', name=name)
	ctx.set_servername_callback(sni)
	try:
		for engine, binary in ARGS.engines.items():
			for flag in ('-V', '-h'):
				r = subprocess.run([binary, flag], capture_output=True, text=True, timeout=3)
				event('engine_info', engine=engine, path=binary, flag=flag, exit=r.returncode,
					stdout=r.stdout, stderr=r.stderr, sha256=hashlib.sha256(Path(binary).read_bytes()).hexdigest())
				r.check_returncode()
			await basic(engine)
			await competition(engine)
			await tls_contract(engine, ctx)
			await conflict(engine)
			await lifecycle(engine)
			check(all(p.read_bytes() == data for p, data in original.items()),
				engine + ' E10 handoff/intent bytes unchanged')
			event('scenario', engine=engine, id='E10', status='PASS',
				scope='literal loopback only; no system resolver, nft, route or service-management invocation')
	finally:
		for child in list(ACTIVE):
			await child.close()
		for p in original:
			check(p.read_bytes() == original[p], 'E10 fixture unchanged even on failure')
			p.unlink()
		shutil.rmtree(certdir)
		check(not list((BASE / '.runtime').iterdir()), 'E8 all runtime resources removed')
		(BASE / '.runtime').rmdir()


if __name__ == '__main__':
	parser = argparse.ArgumentParser()
	parser.add_argument('--aether', required=True)
	parser.add_argument('--fallback', required=True)
	parser.add_argument('--mutation', choices=['closed-formal', 'impostor'])
	parser.add_argument('--only-engine', choices=['aether-dns', 'chinadns-ng'])
	ARGS = parser.parse_args()
	ARGS.engines = {'aether-dns': str(Path(ARGS.aether).resolve()), 'chinadns-ng': str(Path(ARGS.fallback).resolve())}
	if ARGS.only_engine:
		ARGS.engines = {ARGS.only_engine: ARGS.engines[ARGS.only_engine]}
	sys.addaudithook(audit)
	try:
		asyncio.run(main())
	except Exception as exc:
		event('failure', status='FAIL', error=str(exc), type=type(exc).__name__)
		raise
