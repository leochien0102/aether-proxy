"""Disposable namespaces only; never execute network changes in the caller's netns."""
from contextlib import contextmanager
import json
import os
import shutil
import subprocess
import sys

LAN = '192.0.2.1'
CLIENT = '192.0.2.2'
IFACE = 'br-lan'
HEX_LAN = '010200C0'
IP = shutil.which('ip') or '/usr/bin/ip'


def isolated():
    marker = 'AETHER_TEST_PARENT_NETNS'
    current = os.readlink('/proc/self/ns/net')
    if marker not in os.environ:
        os.environ[marker] = current
        os.execvp('unshare', ['unshare', '--net', '--mount', '--propagation', 'private',
                             sys.executable, '-B', *sys.argv])
    if current == os.environ[marker]:
        raise AssertionError('refusing network changes in original namespace')


def ip(*args):
    subprocess.run([IP, *map(str, args)], check=True, capture_output=True, timeout=5)


@contextmanager
def lan_network():
    isolated()
    # No named netns or /run/netns mount, hence no host mount/interface cleanup.
    client = subprocess.Popen(['unshare', '--net', sys.executable, '-c',
                               'import time; time.sleep(3600)'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import time
        for _ in range(100):
            if client.poll() is not None:
                raise AssertionError('client network namespace unavailable')
            if os.readlink(f'/proc/{client.pid}/ns/net') != os.readlink('/proc/self/ns/net'):
                break
            time.sleep(0.01)
        else:
            raise AssertionError('client did not enter independent network namespace')
        ip('link', 'set', 'lo', 'up')
        ip('link', 'add', IFACE, 'type', 'veth', 'peer', 'name', 'lan-client')
        ip('link', 'set', 'lan-client', 'netns', client.pid)
        ip('addr', 'add', LAN + '/24', 'dev', IFACE)
        ip('link', 'set', IFACE, 'up')
        prefix = ['nsenter', '-t', str(client.pid), '-n', '--']
        for args in [('link', 'set', 'lo', 'up'),
                     ('addr', 'add', CLIENT + '/24', 'dev', 'lan-client'),
                     ('link', 'set', 'lan-client', 'up')]:
            subprocess.run([*prefix, IP, *args], check=True, capture_output=True, timeout=5)
        yield prefix
    finally:
        client.terminate()
        client.wait(timeout=5)


def live_ip_fixture(path):
    """Delegate only read-only address queries; retain rooted routing command stubs."""
    original = path.with_name('ip-rooted')
    path.rename(original)
    path.write_text('#!' + sys.executable + '\n'
                    'import os, sys\n'
                    'args = sys.argv[1:]\n'
                    "if args[:6] == ['-j', '-4', 'addr', 'show', 'dev', 'br-lan'] and len(args) == 6:\n"
                    f'    os.execv({json.dumps(IP)}, [{json.dumps(IP)}, *args])\n'
                    f'os.execv({json.dumps(str(original))}, [sys.argv[0], *args])\n')
    path.chmod(0o755)
