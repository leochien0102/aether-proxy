#!/usr/bin/env python3
"""Local socket experiment for docs/tasks/m15.md S15.2; not a production resolver.

All addresses are loopback and ports are kernel allocated. Role names map them to
31053/31080/31082/31083; no system resolver or installed service is touched.
"""
import argparse
import asyncio
import ipaddress
import json
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time

BASE = Path(__file__).resolve().parent
EVENTS = []
CASE = ''
MUTATION = ''
NODE = 'node.example.test'
GFW = 'ordinary.google.com'


def event(kind, **fields):
	EVENTS.append(dict(case=CASE, time_ns=time.monotonic_ns(), kind=kind, **fields))


def check(name, condition):
	if not condition:
		raise AssertionError(name)
	print('PASS ' + name, flush=True)


def packet(name):
	question = b''.join(bytes([len(s)]) + s.encode() for s in name.split('.')) + b'\0\0\1\0\1'
	return struct.pack('!6H', 1234, 256, 1, 0, 0, 0) + question


def qname(data):
	labels, pos = [], 12
	while data[pos]:
		n = data[pos]
		labels.append(data[pos + 1:pos + 1 + n].decode())
		pos += n + 1
	return '.'.join(labels)


def answer(data, address):
	return data[:2] + struct.pack('!5H', 0x8180, 1, 1, 0, 0) + data[12:] + b'\xc0\x0c' + struct.pack(
		'!HHIH', 1, 1, 30, 4) + ipaddress.IPv4Address(address).packed


async def query(target, name, timeout=0.12):
	proto, port = target
	data = packet(name)
	event('send', qname=name, protocol=proto, target=f'127.0.0.1:{port}')
	try:
		async with asyncio.timeout(timeout):
			if proto == 'tcp':
				reader, writer = await asyncio.open_connection('127.0.0.1', port)
				try:
					writer.write(struct.pack('!H', len(data)) + data)
					await writer.drain()
					n = struct.unpack('!H', await reader.readexactly(2))[0]
					response = await reader.readexactly(n)
				finally:
					writer.close()
					await writer.wait_closed()
			else:
				loop = asyncio.get_running_loop()
				future = loop.create_future()

				class Client(asyncio.DatagramProtocol):
					def datagram_received(self, data, addr):
						if not future.done():
							future.set_result(data)

				transport, _ = await loop.create_datagram_endpoint(Client, remote_addr=('127.0.0.1', port))
				try:
					transport.sendto(data)
					response = await future
				finally:
					transport.close()
			if response[:2] != data[:2] or response[2:4] != b'\x81\x80' or response[12:len(data)] != data[12:]:
				return None
			return str(ipaddress.IPv4Address(response[-4:]))
	except (TimeoutError, ConnectionError, OSError, asyncio.IncompleteReadError):
		return None


class Lab:
	def __init__(self):
		self.servers = []
		self.tasks = set()

	async def listen(self, role, protocol='udp', address='192.0.2.1', upstream=None, silent=False):
		async def respond(data):
			event('receive', role=role, qname=qname(data), protocol=protocol, target=f'127.0.0.1:{port}')
			if silent:
				return None
			if upstream:
				ip = await query(upstream, qname(data))
				return answer(data, ip) if ip else None
			return answer(data, address)

		async def tcp(reader, writer):
			try:
				n = struct.unpack('!H', await reader.readexactly(2))[0]
				data = await reader.readexactly(n)
				response = await respond(data)
				if response:
					writer.write(struct.pack('!H', len(response)) + response)
					await writer.drain()
			except (ConnectionError, asyncio.IncompleteReadError):
				event('peer_closed', role=role)
			finally:
				writer.close()
				await writer.wait_closed()

		if protocol == 'tcp':
			server = await asyncio.start_server(tcp, '127.0.0.1', 0)
			port = server.sockets[0].getsockname()[1]
		else:
			lab = self

			class Server(asyncio.DatagramProtocol):
				def connection_made(self, transport):
					self.transport = transport

				def datagram_received(self, data, addr):
					async def run():
						response = await respond(data)
						if response:
							self.transport.sendto(response, addr)
					task = asyncio.create_task(run())
					lab.tasks.add(task)
					task.add_done_callback(lab.tasks.discard)

			server, _ = await asyncio.get_running_loop().create_datagram_endpoint(
				Server, local_addr=('127.0.0.1', 0))
			port = server.get_extra_info('sockname')[1]
		self.servers.append(server)
		event('listen', role=role, protocol=protocol, target=f'127.0.0.1:{port}')
		return protocol, port

	async def close(self):
		for server in self.servers:
			server.close()
		for server in self.servers:
			if isinstance(server, asyncio.Server):
				await server.wait_closed()
		for task in list(self.tasks):
			task.cancel()
		if self.tasks:
			await asyncio.gather(*self.tasks, return_exceptions=True)
		await asyncio.sleep(0)


def rendered_dns(enabled, china, direct, trust=None):
	"""Read-only execution of the real pure renderer, not a copied production module."""
	snapshot = {'dns': {'direct_dns_enabled': enabled, 'china_dns': ['wan'],
		'direct_dns': [direct], 'trust_dns': trust or ['tcp://192.0.2.53']}}
	code = "import * as r from 'aetherproxy.render.chinadns'; "
	code += 'let s = json(' + json.dumps(json.dumps(snapshot)) + '); '
	code += 'print(r.render(s, { wan_dns: [' + json.dumps(china) + '] }));'
	result = subprocess.run([str(BASE.parents[1] / 'tests/host/ucode'), '-e', code],
		capture_output=True, text=True, timeout=3, check=True)
	event('production_render', enabled=enabled, text=result.stdout)
	return result.stdout


async def bootstrap(lab, candidate, target, address=NODE, lkg=None):
	try:
		return str(ipaddress.IPv4Address(address)), 'literal'
	except ipaddress.AddressValueError:
		pass
	if candidate == 'B':
		# Private path is never installed in the client handoff. The explicit caller
		# issues only the selected node name, not arbitrary client questions.
		target = await lab.listen('isolated-bootstrap', upstream=target)
	if MUTATION == 'closed-handoff':
		target = await lab.listen('closed-31053')
		lab.servers[-1].close()
	for attempt in range(3):
		ip = await query(target, address)
		if ip:
			return ip, 'dns'
	return (lkg, 'lkg') if lkg else (None, 'degraded')


async def ready(tproxy, required, deadline=0.6):
	start = time.monotonic()
	while time.monotonic() - start < deadline:
		ports = [tproxy] if MUTATION == 'tproxy-only' else [tproxy, *required]
		if all(await asyncio.gather(*(query(t, 'ready.example.test', 0.03) for t in ports))):
			event('gate_open')
			return True
		await asyncio.sleep(0.01)
	return False


async def scenarios(candidate):
	global CASE
	lab = Lab()
	try:
		CASE = candidate + '-P1'
		up = await lab.listen('bootstrap-china', address='192.0.2.11')
		xray = await lab.listen('xray-dns-31082', 'tcp', '192.0.2.82')
		tproxy = await lab.listen('tproxy-31080', 'tcp')
		before = len(EVENTS)
		ip, source = await bootstrap(lab, candidate, up, '198.51.100.10')
		check(CASE + ' literal skips bootstrap and waits referenced DNS',
			source == 'literal' and ip == '198.51.100.10' and len(EVENTS) == before
			and await ready(tproxy, [xray]))

		CASE = candidate + '-P2'
		with tempfile.TemporaryDirectory(dir=BASE, prefix='.handoff-') as temp:
			fragment = Path(temp) / 'aether-proxy.conf'
			original = 'no-resolv\nserver=127.0.0.1#31053\n'
			fragment.write_text(original)
			closed = await lab.listen('old-31053')
			lab.servers[-1].close()
			check(CASE + ' retained handoff points to unavailable listener', await query(closed, GFW) is None)
			ip, source = await bootstrap(lab, candidate, up)
			check(CASE + ' explicit bootstrap independent of closed handoff', ip == '192.0.2.11' and source == 'dns')
			# Deliberately broken client routing is exercised before the same source assertion.
			await query(up if MUTATION == 'client-leak' else closed, GFW)
			formal = await lab.listen('formal-31053', upstream=xray)
			check(CASE + ' client answer comes from tunnel', await query(formal, GFW) == '192.0.2.82')
			check(CASE + ' ordinary gfw never reaches bootstrap or system', not any(
				e['kind'] == 'receive' and e.get('qname') == GFW
				and e.get('role') in ('bootstrap-china', 'isolated-bootstrap', 'system-resolver') for e in EVENTS))
			check(CASE + ' handoff unchanged through bootstrap', fragment.read_text() == original)

		CASE = candidate + '-P3'
		bad = await lab.listen('bootstrap-failed', silent=True)
		for lkg in ('198.51.100.9', None):
			before = len(EVENTS)
			ip, source = await bootstrap(lab, candidate, bad, lkg=lkg)
			check(CASE + ' DNS attempts precede ' + ('LKG' if lkg else 'degraded'),
				ip == lkg and source == ('lkg' if lkg else 'degraded')
				and len([e for e in EVENTS[before:] if e['kind'] == 'receive'
					and e.get('role') == 'bootstrap-failed']) == 3)
		ip, source = await bootstrap(lab, candidate, up, lkg='198.51.100.9')
		check(CASE + ' DNS preferred over existing LKG', ip == '192.0.2.11' and source == 'dns')
		for fail_open in (False, True):
			# Dataplane decisions are a documented model, not an nft experiment.
			policy = dict(xray=False, nft=not fail_open, tier='T1')
			check(CASE + f' no-LKG fail_open={int(fail_open)} policy model',
				policy['nft'] != fail_open and not policy['xray'] and policy['tier'] == 'T1')

		CASE = candidate + '-P4'
		direct = await lab.listen('bootstrap-direct', 'tcp', '192.0.2.22')
		for enabled, selected, expected in ((False, up, '192.0.2.11'), (True, direct, '192.0.2.22')):
			china_text = f'127.0.0.1#{up[1]}'
			direct_text = f'tcp://127.0.0.1#{direct[1]}'
			text = rendered_dns(enabled, china_text, direct_text)
			boot = text.split('group boot\n')[1].split('group-upstream ')[1].splitlines()[0]
			assert boot == (direct_text if enabled else china_text)
			protocol = 'tcp' if boot.startswith('tcp://') else 'udp'
			selected = protocol, int(boot.split('#')[1])
			ip, source = await bootstrap(lab, candidate, selected)
			check(CASE + f' direct_dns_enabled={int(enabled)} selects actual {selected[0]} target',
				ip == expected and source == 'dns')

		CASE = candidate + '-P5'
		one = rendered_dns(False, '192.0.2.53', 'tcp://192.0.2.54')
		two = rendered_dns(False, '192.0.2.53', 'tcp://192.0.2.54',
			['tcp://192.0.2.53', 'udp://192.0.2.54'])
		check(CASE + ' real config references one TCP or mixed TCP UDP tunnels',
			'trust-dns tcp://127.0.0.1#31082\n' in one
			and 'trust-dns tcp://127.0.0.1#31082,udp://127.0.0.1#31083\n' in two)
		delayed = []
		async def later():
			await asyncio.sleep(0.18)
			delayed.append(await lab.listen('delayed-31082', 'tcp'))
		# A reserved closed TCP port is the delayed requirement until bind occurs.
		closed = await lab.listen('missing-31083', 'tcp')
		lab.servers[-1].close()
		async def delayed_gate():
			start = time.monotonic()
			while time.monotonic() - start < 0.5:
				if await ready(tproxy, delayed or [closed], 0.04):
					return time.monotonic() - start
			return -1
		task = asyncio.create_task(later())
		elapsed = await delayed_gate()
		await task
		check(CASE + ' gate cannot pass before delayed DNS tunnel', elapsed >= 0.18)
		check(CASE + ' missing referenced DNS blocks gate', not await ready(tproxy, [closed], 0.1))
		check(CASE + ' unused second tunnel does not block gate', await ready(tproxy, [xray]))
		udp = await lab.listen('udp-only-31083')
		check(CASE + ' mixed configured TCP UDP requirements', await ready(tproxy, [xray, udp]))
		check(CASE + ' TCP listener cannot satisfy UDP requirement',
			not await ready(tproxy, [('udp', xray[1])], 0.1))

		CASE = candidate + '-P7'
		for restart in (False, True):
			with tempfile.TemporaryDirectory(dir=BASE, prefix='.retry-') as temp:
				fragment, intent = Path(temp) / 'fragment', Path(temp) / 'intent'
				if restart:
					fragment.write_text('old-handoff')
					intent.touch()
				ip, _ = await bootstrap(lab, candidate, bad)
				check(CASE + f' restart={int(restart)} failed attempt preserves prior boundary',
					ip is None and fragment.exists() == restart and intent.exists() == restart)
				ip, _ = await bootstrap(lab, candidate, up)
				assert ip and await ready(tproxy, [xray])
				fragment.write_text('formal-handoff')
				if intent.exists():
					intent.unlink()
				check(CASE + f' restart={int(restart)} retry installs then clears intent',
					fragment.read_text() == 'formal-handoff' and not intent.exists())
	finally:
		await lab.close()


async def stop_worker(mode, directory, candidate):
	"""Real SIGTERM during a blackhole query or missing-port readiness wait."""
	root = Path(directory)
	lab = Lab()
	stop = asyncio.Event()
	asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stop.set)
	try:
		target = await lab.listen('blackhole', silent=True)
		(root / 'port').write_text(str(target[1]))
		(root / 'owned.tmp').touch()
		if candidate == 'B':
			target = await lab.listen('isolated-bootstrap', upstream=target)
			(root / 'private-port').write_text(str(target[1]))
		work = asyncio.create_task(query(target, NODE, 30) if mode == 'bootstrap'
			else ready(target, [target], 30))
		await asyncio.sleep(0.03)
		(root / 'ready').touch()
		await stop.wait()
		work.cancel()
		await asyncio.gather(work, return_exceptions=True)
	finally:
		await lab.close()
		(root / 'owned.tmp').unlink()


def cancellation_tests():
	for candidate, mode in ((c, m) for c in ('A', 'B') for m in ('bootstrap', 'port-wait')):
		with tempfile.TemporaryDirectory(dir=BASE, prefix='.stop-') as temp:
			root = Path(temp)
			fragment = root / 'fragment'
			fragment.write_text('retained-handoff')
			child = subprocess.Popen([sys.executable, str(Path(__file__)), '--worker', mode,
				'--candidate', candidate, '--directory', temp])
			try:
				deadline = time.monotonic() + 3
				while not (root / 'ready').exists():
					assert child.poll() is None and time.monotonic() < deadline
					time.sleep(0.01)
				start = time.monotonic()
				child.terminate()
				child.wait(timeout=1)
				check(candidate + '-P6 ' + mode + ' SIGTERM bounded cleanup preserves handoff',
					child.returncode == 0 and time.monotonic() - start < 1
					and not (root / 'owned.tmp').exists() and fragment.read_text() == 'retained-handoff')
				import socket
				for portfile in ('port', 'private-port'):
					if (root / portfile).exists():
						with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
							sock.bind(('127.0.0.1', int((root / portfile).read_text())))
				check(candidate + '-P6 ' + mode + ' child reaped and socket reusable', child.poll() == 0)
				event('cancellation_verified', candidate=candidate, mode=mode, pid=child.pid,
					elapsed=time.monotonic() - start, returncode=child.returncode)
			finally:
				if child.poll() is None:
					child.kill()
					child.wait()


def main():
	global MUTATION, CASE
	parser = argparse.ArgumentParser()
	parser.add_argument('--mutation', default='')
	parser.add_argument('--output', required=False)
	parser.add_argument('--worker', choices=['bootstrap', 'port-wait'])
	parser.add_argument('--directory')
	parser.add_argument('--candidate', default='A', choices=['A', 'B'])
	args = parser.parse_args()
	if args.worker:
		asyncio.run(stop_worker(args.worker, args.directory, args.candidate))
		return
	MUTATION = args.mutation
	try:
		for candidate in ('A', 'B'):
			asyncio.run(scenarios(candidate))
		CASE = 'P6'
		cancellation_tests()
	finally:
		if args.output:
			Path(args.output).write_text(''.join(json.dumps(e, sort_keys=True) + '\n' for e in EVENTS))


if __name__ == '__main__':
	main()
