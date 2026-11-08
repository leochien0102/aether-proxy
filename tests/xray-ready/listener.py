#!/usr/bin/env python3
"""Controlled bind/connect/listen state; never sends DNS or judges readiness."""
import json
import pathlib
import select
import signal
import socket
import sys
import time

spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
started = time.monotonic()
sockets = []
counts = {}
for item in spec:
    if 'count_path' in item:
        path = pathlib.Path(item['count_path'])
        path.write_text('0')
        counts[item['port']] = (path, 0)
pending = list(spec)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
try:
    while True:
        for item in pending[:]:
            if time.monotonic() - started < item.get('delay', 0):
                continue
            family = socket.AF_INET6 if ':' in item['address'] else socket.AF_INET
            tcp = item['protocol'] == 'tcp'
            sock = socket.socket(family, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM)
            sockets.append(sock)
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, item.get('v6only', 1))
            sock.bind((item['address'], item['port']))
            if not tcp and 'peer' in item:
                sock.connect((item['peer']['address'], item['peer']['port']))
            if tcp:
                sock.listen(128)
            pending.remove(item)
        readers = [s for s in sockets if s.type == socket.SOCK_STREAM]
        ready, _, _ = select.select(readers, [], [], 0.01)
        for server in ready:
            conn, _ = server.accept()
            conn.close()
            port = server.getsockname()[1]
            if port in counts:
                path, count = counts[port]
                counts[port] = (path, count + 1)
                path.write_text(str(count + 1))
except SystemExit:
    pass
finally:
    for sock in sockets:
        sock.close()
