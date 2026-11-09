#!/usr/bin/env python3
"""T15.9: exercise the real B3 Authority with real loopback sockets.

Only candidate selection, syscall errors and Thread.start are controlled. Strong
socket references prevent GC from hiding missing explicit failure-path closes.
"""
import contextlib
import errno
import importlib.util
from pathlib import Path
import socket
import struct
import sys
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('b3_authority', HERE / 'run.py')
b3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b3)
REAL_SOCKET = socket.socket
REAL_START = threading.Thread.start


def fd_count():
    return len(list(Path('/proc/self/fd').iterdir()))


class Boundary:
    """Real sockets, optional forced UDP candidate and one precise error stage."""
    def __init__(self, candidate=None, collisions=0, stage=None, error=None):
        self.candidate = candidate
        self.collisions = collisions
        self.stage = stage
        self.error = error
        self.sockets = []
        self.creates = 0
        self.starts = 0
        self.binds = []
        self.listens = 0
        self.contention = 0

    def fail(self, stage):
        if self.stage == stage:
            raise self.error

    def factory(self, family, kind):
        self.creates += 1
        self.fail('create-' + str(self.creates))
        boundary = self

        class TrackedSocket(REAL_SOCKET):
            def __init__(self):
                super().__init__(family, kind)
                self.explicit_closes = 0

            def getsockname(self):
                boundary.fail('getsockname')
                return super().getsockname()

            def bind(self, address):
                protocol = 'udp' if kind == socket.SOCK_DGRAM else 'tcp'
                boundary.binds.append((protocol, address))
                boundary.fail('bind-' + protocol)
                if protocol == 'udp' and address[1] == 0 and boundary.collisions:
                    boundary.collisions -= 1
                    address = (address[0], boundary.candidate)
                try:
                    return super().bind(address)
                except OSError as error:
                    if error.errno == errno.EADDRINUSE:
                        boundary.contention += 1
                    raise

            def listen(self, *args):
                boundary.listens += 1
                boundary.fail('listen')
                return super().listen(*args)

            def close(self):
                self.explicit_closes += 1
                return super().close()

        resource = TrackedSocket()
        self.sockets.append(resource)
        return resource

    def start(self, thread):
        self.starts += 1
        self.fail('thread')
        return REAL_START(thread)

    @contextlib.contextmanager
    def installed(self):
        # Replace only B3's module reference: Python's accept() must keep its
        # real socket constructor for the accepted FD.
        socket_api = SimpleNamespace(socket=self.factory, AF_INET=socket.AF_INET,
                                     SOCK_DGRAM=socket.SOCK_DGRAM, SOCK_STREAM=socket.SOCK_STREAM,
                                     inet_aton=socket.inet_aton)
        with patch.object(b3, 'socket', socket_api), \
                patch.object(b3.threading.Thread, 'start', lambda thread: self.start(thread)):
            try:
                yield self
            finally:
                # Harness cleanup follows assertions, never substitutes for them.
                for resource in self.sockets:
                    if resource.fileno() != -1:
                        resource.close()


def occupied(kind):
    resource = REAL_SOCKET(socket.AF_INET, kind)
    resource.bind(('127.0.0.1', 0))
    if kind == socket.SOCK_STREAM:
        resource.listen()
    return resource


def query(authority, tcp=False):
    name = b'\x04node\x07startup\x04test\x00'
    packet = struct.pack('!6H', 0x1234, 0x0100, 1, 0, 0, 0) + name + b'\x00\x01\x00\x01'
    kind = socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM
    with REAL_SOCKET(socket.AF_INET, kind) as client:
        client.settimeout(1)
        endpoint = ('127.0.0.1', authority.port)
        if tcp:
            client.connect(endpoint)
            client.sendall(struct.pack('!H', len(packet)) + packet)
            prefix = client.recv(2)
            size = struct.unpack('!H', prefix)[0]
            response = b''
            while len(response) < size:
                chunk = client.recv(size - len(response))
                if not chunk:
                    raise AssertionError('truncated Authority TCP response')
                response += chunk
        else:
            client.sendto(packet, endpoint)
            response, source = client.recvfrom(65535)
            assert source == endpoint
    return response[:2] == packet[:2] and response[-4:] == socket.inet_aton(authority.ip)


class Ports(unittest.TestCase):
    def setUp(self):
        self.before_fd = fd_count()
        self.before_threads = set(threading.enumerate())

    def tearDown(self):
        self.assertEqual(fd_count(), self.before_fd, 'FD baseline after harness cleanup')
        self.assertEqual(set(threading.enumerate()), self.before_threads, 'no leftover service thread')

    def closed(self, resources, label):
        self.assertTrue(all(s.fileno() == -1 and s.explicit_closes > 0 for s in resources), label)

    def test_P1_dynamic_answers_and_close(self):
        with Boundary().installed() as control:
            authority = b3.Authority()
            try:
                self.assertEqual(authority.udp.getsockname(), ('127.0.0.1', authority.port))
                self.assertEqual(authority.tcp.getsockname(), authority.udp.getsockname())
                self.assertEqual(authority.tcp.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN), 1)
                self.assertTrue(query(authority), 'P1 real UDP A/IN answer')
                self.assertTrue(query(authority, tcp=True), 'P1 real TCP A/IN answer')
                self.assertEqual([(tcp, name) for tcp, name, _ in authority.requests],
                                 [(False, 'node.startup.test'), (True, 'node.startup.test')])
                self.assertEqual(control.creates, 2)
                self.assertEqual(control.starts, 1)
            finally:
                authority.close()
            self.closed(control.sockets, 'P1 normal close explicitly closes both sockets')
            self.assertFalse(authority.thread.is_alive())
            self.assertEqual(fd_count(), self.before_fd)

    def test_P2_real_first_conflict_then_success(self):
        with occupied(socket.SOCK_STREAM) as blocker:
            port = blocker.getsockname()[1]
            with Boundary(candidate=port, collisions=1).installed() as control:
                try:
                    authority = b3.Authority()
                except OSError as error:
                    self.fail(f'P2 first real TCP conflict must retry, not escape: {error}')
                try:
                    self.assertEqual(control.contention, 1, 'P2 actual kernel EADDRINUSE')
                    self.assertEqual(control.creates, 4, 'P2 exactly two pair attempts')
                    self.closed(control.sockets[:2], 'P2 failed pair explicitly closed before success')
                    self.assertNotEqual(authority.port, port)
                    self.assertTrue(query(authority) and query(authority, tcp=True))
                    self.assertEqual(blocker.getsockname()[1], port, 'P2 original blocker still owns TCP')
                    # The failed UDP reservation is already reusable, while TCP remains blocked.
                    with REAL_SOCKET(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                        probe.bind(('127.0.0.1', port))
                finally:
                    authority.close()

    def test_P3_sixteen_conflicts_explicit_cleanup(self):
        with occupied(socket.SOCK_STREAM) as blocker:
            port = blocker.getsockname()[1]
            baseline = fd_count()
            for repeat in range(8):
                with Boundary(candidate=port, collisions=16).installed() as control:
                    with self.assertRaises(OSError) as caught:
                        b3.Authority()
                    self.assertEqual(caught.exception.errno, errno.EADDRINUSE)
                    self.assertEqual(control.creates, 32, 'P3 exactly 16 pair attempts')
                    self.assertEqual(control.contention, 16)
                    self.assertEqual(control.starts, 0, 'P3 no service thread on exhaustion')
                    self.closed(control.sockets, 'P3 failed candidates explicitly closed without GC')
                    self.assertEqual(fd_count(), baseline, f'P3 FD stable on repeat {repeat}')

    def test_P4_fixed_success_and_each_protocol_conflict(self):
        with b3.Authority() as initial:
            port = initial.port
        with b3.Authority(port=port) as authority:
            self.assertEqual(authority.port, port, 'P4 fixed available port unchanged')
            self.assertTrue(query(authority) and query(authority, tcp=True))
        for kind in (socket.SOCK_DGRAM, socket.SOCK_STREAM):
            with occupied(kind) as blocker:
                port = blocker.getsockname()[1]
                with Boundary().installed() as control:
                    with self.assertRaises(OSError) as caught:
                        b3.Authority(port=port)
                    self.assertEqual(caught.exception.errno, errno.EADDRINUSE)
                    self.assertEqual(control.creates, 2, 'P4 fixed conflict never retries')
                    self.assertTrue(all(address[1] == port for _, address in control.binds))
                    self.assertEqual(control.starts, 0)
                    self.closed(control.sockets, 'P4 fixed conflict explicitly closes acquired sockets')
                    self.assertEqual(blocker.getsockname()[1], port)

    def test_P5_non_contention_errors_and_thread_start(self):
        stages = ('create-1', 'create-2', 'bind-udp', 'getsockname', 'bind-tcp', 'listen', 'thread')
        for stage in stages:
            for code in (errno.EACCES, errno.EMFILE):
                with self.subTest(stage=stage, errno=code):
                    error = OSError(code, 'injected ' + stage)
                    with Boundary(stage=stage, error=error).installed() as control:
                        with self.assertRaises(OSError) as caught:
                            b3.Authority()
                        self.assertIs(caught.exception, error, 'P5 original error identity preserved')
                        self.assertEqual(control.creates, 1 if stage == 'create-1' else 2,
                                         'P5 non-contention error never retries')
                        self.assertEqual(control.starts, int(stage == 'thread'))
                        self.closed(control.sockets, 'P5 acquired resources explicitly closed without GC')
                        self.assertEqual(fd_count(), self.before_fd, 'P5 no FD pending GC')
                        self.assertEqual(set(threading.enumerate()), self.before_threads)
        # Even EADDRINUSE outside bind/listen is not port competition.
        for stage in ('create-2', 'getsockname', 'thread'):
            error = OSError(errno.EADDRINUSE, 'injected ' + stage)
            with Boundary(stage=stage, error=error).installed() as control:
                with self.assertRaises(OSError) as caught:
                    b3.Authority()
                self.assertIs(caught.exception, error)
                self.assertEqual(control.creates, 2)
                self.closed(control.sockets, 'P5 non-bind EADDRINUSE is propagated and cleaned')
        error = RuntimeError('injected native Thread.start failure')
        with Boundary(stage='thread', error=error).installed() as control:
            with self.assertRaises(RuntimeError) as caught:
                b3.Authority()
            self.assertIs(caught.exception, error)
            self.assertEqual(control.starts, 1)
            self.closed(control.sockets, 'P5 RuntimeError from Thread.start closes pair')

    def test_P5_listen_contention_is_bounded(self):
        error = OSError(errno.EADDRINUSE, 'injected listen')
        with Boundary(stage='listen', error=error).installed() as control:
            with self.assertRaises(OSError) as caught:
                b3.Authority()
            self.assertIs(caught.exception, error)
            self.assertEqual(control.listens, 16)
            self.assertEqual(control.starts, 0)
            self.closed(control.sockets, 'P5 listen contention closes all 16 pairs')
        with b3.Authority() as initial:
            fixed_port = initial.port
        with Boundary(stage='listen', error=error).installed() as control:
            with self.assertRaises(OSError):
                b3.Authority(port=fixed_port)
            self.assertEqual(control.listens, 1, 'P4 fixed listen conflict never retries')
            self.closed(control.sockets, 'P5 fixed listen failure closes pair')


if __name__ == '__main__':
    unittest.main(verbosity=2)
