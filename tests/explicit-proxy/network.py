"""Disposable namespaces only; never execute network changes in the caller's netns."""
from contextlib import contextmanager
import json
import os
import shutil
import subprocess
import sys

LAN = '192.0.2.1'
CLIENT = '192.0.2.2'
IFACE = 'lan-test'
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


def lan_dump(addresses=(LAN,), up=True):
    # Deliberate WAN/default-route decoy: explicit listeners must use logical lan.
    return {'interface': [
        {'interface': 'wan', 'up': True, 'l3_device': 'wan-decoy',
         'route': [{'target': '0.0.0.0', 'mask': 0}],
         'ipv4-address': [{'address': '198.51.100.1', 'mask': 24}]},
        {'interface': 'lan', 'up': up, 'l3_device': IFACE,
         'ipv4-address': [{'address': address, 'mask': 24} for address in addresses]}]}


def ubus_fixture(bin_dir, addresses=(LAN,)):
    """Offline logical-LAN claims; real sockets independently prove actual binds."""
    bin_dir.mkdir(exist_ok=True)
    state = bin_dir / 'network-interface.json'
    state.write_text(json.dumps(lan_dump(addresses)))
    path = bin_dir / 'ubus'
    path.write_text('#!' + sys.executable + '\n'
                    'from pathlib import Path\nimport sys\n'
                    "if sys.argv[1:] != ['call', 'network.interface', 'dump']:\n"
                    '    sys.exit(1)\n'
                    f'with Path({str(bin_dir / "ubus-calls")!r}).open("a") as calls:\n'
                    '    calls.write("network.interface dump\\n")\n'
                    f'print(Path({str(state)!r}).read_text())\n')
    path.chmod(0o755)
    return state
