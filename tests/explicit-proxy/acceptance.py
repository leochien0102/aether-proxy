#!/usr/bin/env python3
"""Offline UCI -> production renderer -> real Xray explicit-proxy acceptance."""

from contextlib import ExitStack, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time

from network import LAN, IFACE, HEX_LAN, lan_network, ubus_fixture

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
UCODE = ROOT / 'tests/host/ucode'
NODE = 'n_' + '1' * 32
BODY = b'explicit-proxy offline target\n'


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def run(command, label, **kwargs):
    result = subprocess.run(command, capture_output=True, timeout=20, **kwargs)
    # Never echo captured output or argv: either can contain proxy credentials.
    check(result.returncode == 0, label + ' failed (output withheld)')
    return result


def discover_xray():
    explicit = os.environ.get('XRAY_BIN')
    if explicit:
        candidates = [Path(explicit)]
    else:
        candidates = [Path(p) for name in ('aether-xray', 'xray')
                      if (p := shutil.which(name))]
        candidates += sorted(Path('/tmp/ci-tools').glob('xray-*/xray'), reverse=True)
        candidates += sorted(Path('/workspace/openwrt/ci-spike/tools').glob('xray-*/xray'),
                             reverse=True)
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            # Reject the repository's shell stubs, even if they report a version.
            with candidate.open('rb') as binary:
                if binary.read(4) != b'\x7fELF':
                    continue
            return candidate.resolve()
    raise AssertionError('real ELF Xray unavailable; set XRAY_BIN (no downloads are performed)')


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def listeners(pid):
    """Return actual TCP listeners belonging to this process, not another Xray."""
    inodes = set()
    for fd in Path(f'/proc/{pid}/fd').iterdir():
        try:
            link = os.readlink(fd)
        except FileNotFoundError:
            continue
        if link.startswith('socket:['):
            inodes.add(link[8:-1])
    found = []
    for table in ('tcp', 'tcp6'):
        for line in Path(f'/proc/{pid}/net/{table}').read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == '0A' and fields[9] in inodes:
                host, port = fields[1].split(':')
                found.append((host, int(port, 16)))
    return found


@contextmanager
def xray_process(binary, config, ports, env):
    # Do not change/filter production inbounds to evade tproxy privilege requirements.
    child = subprocess.Popen([str(binary), 'run', '-c', str(config)], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            check(child.poll() is None,
                  'Xray exited at startup; check fixed ports and transparent-socket privileges')
            if ports <= {port for _, port in listeners(child.pid)}:
                break
            time.sleep(0.03)
        else:
            raise AssertionError('Xray did not open expected listeners')
        yield child
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *_):
        pass


class Target(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, tls=None):
        self.accepts = 0
        self.lock = threading.Lock()
        self.tls = tls
        super().__init__(('127.0.0.1', 0), Handler)

    def get_request(self):
        conn, address = super().get_request()
        # Count TCP accepts, including incomplete TLS/HTTP, not just successful GETs.
        with self.lock:
            self.accepts += 1
        conn.settimeout(3)
        if self.tls:
            try:
                conn = self.tls.wrap_socket(conn, server_side=True)
            except Exception:
                conn.close()
                raise
        return conn, address

    def count(self):
        with self.lock:
            return self.accepts


@contextmanager
def target_server(tls=None):
    server = Target(tls)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=4)


def curl(target, scheme, protocol=None, port=None, credentials=None,
         proxy_host=LAN, prefix=()):
    # stdin keeps credentials out of process argv and diagnostic output. Disable all
    # ambient proxy configuration and loopback NO_PROXY exemptions explicitly.
    options = ['silent', 'show-error', 'fail', 'insecure', 'max-time = 3',
               'connect-timeout = 2', 'noproxy = ""',
               f'url = "{scheme}://127.0.0.1:{target.server_port}/acceptance"']
    if protocol:
        proxy_scheme = 'socks5h' if protocol == 'socks' else 'http'
        options.append(f'proxy = "{proxy_scheme}://{proxy_host}:{port}"')
    else:
        options.append('proxy = ""')
    if credentials:
        options.append(f'proxy-user = "{credentials[0]}:{credentials[1]}"')
    return subprocess.run([*prefix, 'curl', '-q', '--config', '-'], input='\n'.join(options).encode(),
                          capture_output=True, timeout=6)


def assert_request(targets, scheme, protocol, port, credentials, success, label):
    before = [target.count() for target in targets.values()]
    result = curl(targets[scheme], scheme, protocol, port, credentials)
    check((result.returncode == 0 and result.stdout == BODY) == success,
          label + ': unexpected request result (output withheld)')
    if not success:
        check(result.returncode != 0, label + ': failure must be a curl error')
    # Give a wrongly routed asynchronous connection a chance to reach the target.
    if not success:
        time.sleep(0.08)
    after = [target.count() for target in targets.values()]
    expected = before.copy()
    if success:
        expected[list(targets).index(scheme)] += 1
    check(after == expected, label + ': unexpected target TCP accepts')


def write_uci(confdir, enabled, ports, accounts, upstream_port, upstream_account,
              address=None, lan_iface=IFACE, legacy=None, shared=True, auth=None):
    lines = ["config main 'main'", " option enabled '1'", f" option node '{NODE}'",
             " option sniffing '0'", " option xray_log_level 'error'",
             f" list lan_ifaces '{lan_iface}'"]
    if auth is not None:
        lines.append(f" option proxy_auth_enabled '{auth}'")
    for index, field in enumerate(('username', 'password')):
        if shared is True or shared == field:
            lines.append(f" option proxy_{field} '{accounts['socks'][index]}'")
    if address is not None:
        lines.append(f" option proxy_address '{address}'")
    if enabled is not None:
        for protocol in ('socks', 'http'):
            lines += [f" option {protocol}_enabled '{int(protocol in enabled)}'",
                      f" option {protocol}_port '{ports[protocol]}'"]
    for protocol, pair in (legacy or {}).items():
        lines += [f" option {protocol}_username '{pair[0]}'",
                  f" option {protocol}_password '{pair[1]}'",
                  f" option {protocol}_listen '203.0.113.99'"]
    lines += ["config dns 'dns'", " list china_dns '127.0.0.1'",
              " list trust_dns '127.0.0.1'", f"config node '{NODE}'",
              " option protocol 'socks'", " option address '127.0.0.1'",
              f" option port '{upstream_port}'", f" option username '{upstream_account[0]}'",
              f" option password '{upstream_account[1]}'"]
    path = confdir / 'aetherproxy'
    path.write_text('\n'.join(lines) + '\n')
    path.chmod(0o600)


def cli_render(confdir, work):
    for name in ('data', 'base', 'custom'):
        (work / name).mkdir(exist_ok=True)
    for name in ('gfwlist', 'chnlist', 'apple'):
        (work / 'base' / (name + '.txt')).write_text('example.invalid\n')
    for name in ('chnroute4', 'gfw_static4'):
        (work / 'base' / (name + '.txt')).write_text('192.0.2.0/24\n')
    command = [str(UCODE), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--',
               'render', 'xray', '--confdir', str(confdir), '--data-dir', str(work / 'data'),
               '--baseline-dir', str(work / 'base'), '--custom-dir', str(work / 'custom'),
               '--run-dir', str(work / 'cli-run'), '--bin-dir', str(work / 'bin')]
    result = run(command, 'CLI render')
    check(not result.stderr, 'CLI render wrote unexpected stderr (withheld)')
    check(not (work / 'cli-run').exists(), 'CLI render unexpectedly created runtime/log files')
    return result.stdout


def main():
    binary = discover_xray()
    check(UCODE.is_file(), 'tests/host/ucode unavailable; run tests/host/bootstrap.sh')
    for tool in ('curl', 'openssl'):
        check(shutil.which(tool) is not None, tool + ' is required')
    banner = run([str(binary), 'version'], 'Xray version').stdout.decode().splitlines()[0]
    check(banner.startswith('Xray '), 'unexpected real Xray banner')
    print('Real engine:', banner, flush=True)
    # Fail instead of treating missing runtime prerequisites as a successful skip.
    for port in (31080, 31081, 31082, 31083):
        with socket.socket() as sock:
            sock.bind(('0.0.0.0', port))
    with tempfile.TemporaryDirectory(prefix='aether-explicit-proxy-') as temp, ExitStack() as stack:
        work = Path(temp)
        env = dict(os.environ, XRAY_LOCATION_ASSET=str(work / 'empty-assets'))
        (work / 'empty-assets').mkdir()
        ports = {}
        while len(set(ports.values())) < 3:
            ports = {name: free_port() for name in ('socks', 'http', 'upstream')}
        accounts = {name: (secrets.token_hex(8), secrets.token_hex(16))
                    for name in ('socks', 'upstream')}
        accounts['http'] = accounts['socks']
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=localhost', '-keyout', str(work / 'key.pem'),
             '-out', str(work / 'cert.pem')], 'local TLS certificate')
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(work / 'cert.pem', work / 'key.pem')
        targets = {'http': stack.enter_context(target_server()),
                   'https': stack.enter_context(target_server(tls))}
        for scheme in targets:
            assert_request(targets, scheme, None, None, None, True, 'direct target control')
        upstream = {
            'log': {'loglevel': 'none', 'access': 'none'},
            'inbounds': [{'listen': '127.0.0.1', 'port': ports['upstream'], 'protocol': 'socks',
                          'settings': {'auth': 'password', 'udp': False,
                                       'accounts': [{'user': accounts['upstream'][0],
                                                     'pass': accounts['upstream'][1]}]}}],
            'outbounds': [{'protocol': 'freedom'}]}
        upstream_path = work / 'upstream.json'
        upstream_path.write_text(json.dumps(upstream))
        upstream_path.chmod(0o600)
        legacy = None
        for name, enabled in [('omitted', None), ('off', set()),
                              ('noauth-before', {'socks', 'http'}),
                              ('socks', {'socks'}), ('http', {'http'}),
                              ('both', {'socks', 'http'}),
                              ('legacy-shared', {'socks', 'http'}),
                              ('legacy-old', {'socks', 'http'}),
                              ('off-retain-auth', set()),
                              ('noauth-retain-credentials', {'socks', 'http'}),
                              ('noauth-after-clear', {'socks', 'http'})]:
            case = work / name
            case.mkdir()
            confdir = case / 'config'
            confdir.mkdir()
            authenticated = bool(enabled) and not name.startswith('noauth-')
            # Exercise explicit on/off separately from absent-field legacy migration.
            auth = None if name.startswith('legacy-') or name == 'omitted' else ('1' if authenticated else '0')
            retained = name in ('off-retain-auth', 'noauth-retain-credentials')
            old_pairs = {'socks': accounts['socks'], 'http': accounts['http']} if name == 'legacy-old' else None
            write_uci(confdir, enabled, ports, accounts, ports['upstream'], accounts['upstream'],
                      shared=(authenticated or retained) and name != 'legacy-old',
                      legacy=old_pairs, auth=auth)
            ubus_fixture(case / 'bin')
            cli_artifact = cli_render(confdir, case)
            rendered = case / 'xray.json'
            # Deliberately permissive umask: protection must come from sys.write_atomic.
            old_umask = os.umask(0)
            try:
                result = run([str(UCODE), str(HERE / 'render.uc'), str(confdir), str(rendered), str(case)],
                             name + ' UCI loader/render')
            finally:
                os.umask(old_umask)
            check(not result.stderr, name + ': unexpected renderer stderr (withheld)')
            loaded = json.loads(result.stdout)
            config, main_config = loaded['config'], loaded['main']
            if enabled:
                check(bool(main_config.get('proxy_auth_enabled')) == authenticated,
                      name + ': authentication flag normalization/migration')
            if name == 'noauth-retain-credentials':
                check(main_config.get('proxy_username') == accounts['socks'][0]
                      and main_config.get('proxy_password') == accounts['socks'][1],
                      name + ': explicit off must retain stored credentials')
            check(stat.S_IMODE(rendered.stat().st_mode) == 0o600,
                  name + ': shared atomic writer did not produce mode 0600')
            check(cli_artifact == rendered.read_bytes(), name + ': CLI/render mismatch')
            check((case / 'bin/ubus-calls').exists() == bool(enabled),
                  name + ': double-off queried LAN or active render did not resolve LAN')
            if enabled is None:
                legacy = config
                check(main_config['socks_port'] == 1080 and main_config['http_port'] == 8080,
                      'schema explicit port defaults changed')
                check(not main_config.get('socks_enabled') and not main_config.get('http_enabled'),
                      'omitted explicit flags did not default off')
            elif not enabled:
                check(config == legacy, 'both-off render changed legacy output')
            active = enabled or set()
            inbound_by_tag = {inbound['tag']: inbound for inbound in config['inbounds']}
            check(inbound_by_tag['http-in'] == {'tag': 'http-in', 'listen': '127.0.0.1',
                  'port': 31081, 'protocol': 'http', 'settings': {}},
                  name + ': legacy diagnostic HTTP inbound changed')
            for protocol in ('socks', 'http'):
                tag = 'explicit-' + protocol
                check((tag in inbound_by_tag) == (protocol in active), name + ': inbound enable gate')
                if enabled is not None:
                    check(main_config[protocol + '_enabled'] is (protocol in active),
                          name + ': enabled is not a normalized boolean')
                if protocol not in active:
                    continue
                inbound = inbound_by_tag[tag]
                check(inbound['listen'] == LAN and inbound['port'] == ports[protocol]
                      and inbound['protocol'] == protocol, name + ': explicit inbound binding')
                settings = inbound['settings']
                check(bool(settings.get('accounts')) == authenticated,
                      name + ': unexpected authentication accounts')
                if protocol == 'socks':
                    check(settings['auth'] == ('password' if authenticated else 'noauth')
                          and settings['udp'] is False, name + ': SOCKS auth/TCP-only')
                routes = [rule for rule in config['routing']['rules'] if tag in rule.get('inboundTag', [])]
                check(routes and all(rule.get('outboundTag') == 'proxy' for rule in routes),
                      name + ': explicit inbound is not routed exclusively to proxy')
            run([str(binary), 'run', '-test', '-c', str(rendered)], name + ' Xray validation', env=env)
            with xray_process(binary, rendered, {31081, *(ports[p] for p in active)}, env) as child:
                actual = listeners(child.pid)
                for protocol in ('socks', 'http'):
                    bound = [host for host, port in actual if port == ports[protocol]]
                    check(bound == ([HEX_LAN] if protocol in active else []),
                          name + ': actual listener is not exact LAN IP or disabled')
                # With both disabled, no request may reach either explicit port.
                for protocol in {'socks', 'http'} - active:
                    for scheme in targets:
                        assert_request(targets, scheme, protocol, ports[protocol], accounts[protocol],
                                       False, name + ': disabled listener')
                with xray_process(binary, upstream_path, {ports['upstream']}, env):
                    for protocol in sorted(active):
                        user, password = accounts[protocol]
                        for scheme in targets:
                            for label, credentials in [('no auth', None),
                                                       ('bad user', ('wrong', password)),
                                                       ('bad password', (user, 'wrong'))]:
                                assert_request(targets, scheme, protocol, ports[protocol], credentials,
                                               not authenticated, name + ': ' + protocol + ' ' + scheme + ' ' + label)
                            assert_request(targets, scheme, protocol, ports[protocol], accounts[protocol],
                                           True, name + ': ' + protocol + ' ' + scheme + ' correct auth')
                for protocol in sorted(active):
                    for scheme in targets:
                        assert_request(targets, scheme, protocol, ports[protocol], accounts[protocol],
                                       False, name + ': upstream stopped, fail closed')
                # Targets remain directly reachable: failure must not be a dead target.
                for scheme in targets:
                    assert_request(targets, scheme, None, None, None, True, name + ': direct control')
            print('PASS', name + ': UCI/CLI/render, Xray config/runtime, LAN binding/auth/fail-closed', flush=True)
        print('PASS offline acceptance: HTTP + TLS via SOCKS5 and HTTP/CONNECT; '
              'unauthorized/upstream-down/disabled requests made zero target TCP accepts', flush=True)


if __name__ == '__main__':
    try:
        with lan_network():
            main()
    except (AssertionError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        # No tracebacks, subprocess argv or captured output containing secrets.
        print('FAIL explicit-proxy:', str(error) if isinstance(error, AssertionError)
              else type(error).__name__ + ' (details withheld)', file=sys.stderr)
        sys.exit(1)
