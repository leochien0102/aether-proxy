#!/usr/bin/python3
"""Actual partial-listener fixture, not a DNS engine: UDP is deliberately absent."""
from pathlib import Path
import signal
import socket
import sys
import time

config = Path(sys.argv[sys.argv.index('-C') + 1]).read_text()
port = int(next(line.split()[1] for line in config.splitlines() if line.startswith('bind-port ')))
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.bind(('127.0.0.1', port))
listener.listen()
done = False


def stop(*_):
    global done
    done = True


signal.signal(signal.SIGTERM, stop)
try:
    while not done:
        time.sleep(.01)
finally:
    listener.close()
