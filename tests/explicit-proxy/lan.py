#!/usr/bin/env python3
"""Independent LAN-client traffic to the production daemon in disposable netns."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile

from acceptance import (ROOT, UCODE, BODY, check, curl, discover_xray, free_port, listeners,
                        run, target_server, write_uci, xray_process)
from network import LAN, IFACE, HEX_LAN, ip, lan_network, lan_dump
from reload import Fixture


class LanFixture(Fixture):
    listen = LAN
    address = None
    legacy = None
    shared = True

    def configure(self, enabled):
        write_uci(self.conf.parent, enabled, self.ports, self.accounts,
                  self.ports['upstream'], self.accounts['upstream'], self.address, IFACE,
                  legacy=self.legacy, shared=self.shared)

    def verify_lan_status(self, addresses):
        result = run([str(UCODE), '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--',
                      'status', '--json', '--confdir', str(self.conf.parent),
                      '--run-dir', str(self.run), '--sys-root', str(self.root),
                      '--bin-dir', str(self.bin)], 'LAN status', env=self.env)
        check(not result.stderr, 'status wrote unexpected stderr (withheld)')
        check(not any(secret.encode() in result.stdout for pair in self.accounts.values()
                      for secret in pair), 'status exposed credentials (output withheld)')
        check(json.loads(result.stdout)['explicit_lan'] ==
              {'interface': 'lan', 'addresses': addresses}, 'status LAN candidates diverged')

    def firewall_evidence(self):
        # Only command execution is fixture evidence, not a real firewall test.
        calls = tuple(line for line in self.calls()
                      if line.startswith(('nft -f ', 'nft delete ', 'fw4 ')))
        nft = (self.run / 'current/aether-proxy.nft').read_bytes()
        config = json.loads((self.run / 'current/xray.json').read_text())
        config['inbounds'] = [row for row in config['inbounds']
                              if not row['tag'].startswith('explicit-')]
        for rule in config['routing']['rules']:
            if 'inboundTag' in rule:
                rule['inboundTag'] = [tag for tag in rule['inboundTag']
                                      if not tag.startswith('explicit-')]
        return nft, calls, config

    def traffic(self, targets, prefix, protocol, scheme, credentials, success):
        before = [target.count() for target in targets.values()]
        result = curl(targets[scheme], scheme, protocol, self.ports[protocol],
                      credentials, proxy_host=self.listen, prefix=prefix)
        check((result.returncode == 0 and result.stdout == BODY) == success,
              protocol + '/' + scheme + ': unexpected LAN client response (output withheld)')
        if not success:
            check(result.returncode != 0, 'denied LAN request must fail curl')
            import time
            time.sleep(0.08)
        expected = before.copy()
        if success:
            expected[list(targets).index(scheme)] += 1
        check([target.count() for target in targets.values()] == expected,
              'LAN request reached unexpected target TCP accepts')

    def verify_lan(self, enabled, targets, prefix):
        pid = self.xray_pid()
        actual = listeners(pid)
        config = json.loads((self.run / 'current/xray.json').read_text())
        explicit = {row['tag']: row for row in config['inbounds']
                    if row['tag'].startswith('explicit-')}
        check(set(explicit) == {'explicit-' + p for p in enabled},
              'published explicit inbound enable mismatch')
        for protocol in ('socks', 'http'):
            check([host for host, port in actual if port == self.ports[protocol]] ==
                  ([socket.inet_aton(self.listen)[::-1].hex().upper()] if protocol in enabled else []),
                  'current Xray does not own exact LAN socket (or has extra loopback/wildcard)')
            if protocol in enabled:
                check(explicit['explicit-' + protocol]['listen'] == self.listen and
                      explicit['explicit-' + protocol]['port'] == self.ports[protocol],
                      'published explicit listen/port changed')
                check(explicit['explicit-' + protocol]['settings']['accounts'] == [
                      {'user': self.accounts['socks'][0], 'pass': self.accounts['socks'][1]}],
                      'protocols did not use the shared account')
            for scheme in targets:
                if protocol not in enabled:
                    self.traffic(targets, prefix, protocol, scheme,
                                 self.accounts[protocol], False)
                    continue
                username, password = self.accounts[protocol]
                for credentials in (None, ('wrong', password), (username, 'wrong')):
                    self.traffic(targets, prefix, protocol, scheme, credentials, False)
                self.traffic(targets, prefix, protocol, scheme,
                             self.accounts[protocol], True)
        self.no_secret_logs()
        return pid


def main(prefix):
    binary = discover_xray()
    banner = run([str(binary), 'version'], 'Xray version').stdout.decode().splitlines()[0]
    check(banner.startswith('Xray 26.11.9 '), 'LAN acceptance requires Xray 26.11.9')
    print('Real engine:', banner, flush=True)
    print('Real network: isolated server lan-test 192.0.2.1/24 <-> independent client '
          '192.0.2.2/24; no default route or host firewall changes', flush=True)
    ip('addr', 'add', '198.51.100.1/32', 'dev', 'lo')
    ports = {}
    while len(set(ports.values())) < 3:
        ports = {name: free_port() for name in ('socks', 'http', 'upstream')}
    accounts = {name: (secrets.token_hex(8), secrets.token_hex(16)) for name in ports}
    accounts['http'] = accounts['socks']
    with tempfile.TemporaryDirectory(prefix='aether-explicit-lan-') as temp, ExitStack() as stack:
        base = Path(temp)
        run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-subj', '/CN=localhost', '-keyout', str(base / 'key.pem'),
             '-out', str(base / 'cert.pem')], 'offline TLS certificate')
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(base / 'cert.pem', base / 'key.pem')
        targets = {'http': stack.enter_context(target_server()),
                   'https': stack.enter_context(target_server(tls))}
        for scheme, target in targets.items():
            result = curl(target, scheme, prefix=prefix)
            check(result.returncode != 0 and target.count() == 0,
                  'client unexpectedly reached server loopback without explicit proxy')
        upstream_path = base / 'upstream.json'
        upstream_path.write_text(json.dumps({'log': {'loglevel': 'none', 'access': 'none'},
            'inbounds': [{'listen': '127.0.0.1', 'port': ports['upstream'], 'protocol': 'socks',
                          'settings': {'auth': 'password', 'udp': False, 'accounts': [
                              {'user': accounts['upstream'][0], 'pass': accounts['upstream'][1]}]}}],
            'outbounds': [{'protocol': 'freedom'}]}))
        upstream_path.chmod(0o600)
        upstream = stack.enter_context(xray_process(binary, upstream_path,
                                                    {ports['upstream']}, os.environ.copy()))
        f = LanFixture(base, 'lan-daemon', binary, ports, accounts)
        with f.daemon() as child:
            f.daemon_pid = child.pid
            f.wait_running()
            old_pid = f.verify_lan(set(), targets, prefix)
            firewall = f.firewall_evidence()
            f.verify_lan_status([LAN])
            for label, enabled in [('SOCKS only', {'socks'}), ('both', {'socks', 'http'}),
                                   ('HTTP only', {'http'}), ('both again', {'socks', 'http'}),
                                   ('SOCKS retained', {'socks'}), ('double off', set()),
                                   ('HTTP for rollback', {'http'})]:
                f.reload(child, enabled)
                pid = f.verify_lan(enabled, targets, prefix)
                check(pid != old_pid, 'successful reload did not replace Xray generation')
                old_pid = pid
                check(f.firewall_evidence() == firewall,
                      'explicit-only reload changed nft artifact or loaded firewall commands')
                print('PASS real LAN:', label, 'HTTP + TLS/auth/exact child sockets', flush=True)
            saved = (f.run / 'current/xray.json').read_bytes()
            hashes = f.state()['render_hash']
            invalid_dumps = [('no LAN address', lan_dump([])),
                             ('LAN down', lan_dump([LAN], up=False)),
                             ('multiple without selection', lan_dump([LAN, '192.0.2.3']))]
            for bad in ('not-an-ip', '0.0.0.0', '127.0.0.1', '::1'):
                invalid_dumps.append(('invalid candidate ' + bad, lan_dump([bad])))
            for label, dump in invalid_dumps:
                f.lan_state.write_text(json.dumps(dump))
                f.reload(child, {'http'}, ok=False)
                f.lan_state.write_text(json.dumps(lan_dump()))
                check((f.run / 'current/xray.json').read_bytes() == saved and
                      f.state()['render_hash'] == hashes and f.state()['state'] == 'running',
                      'invalid/non-LAN listen reload lost valid artifacts/running state')
                f.verify_lan({'http'}, targets, prefix)
                check(f.firewall_evidence() == firewall, 'failed address reload changed firewall')
                print('PASS offline LAN-state rejected reload:', label,
                      'old authenticated HTTP/CONNECT remains usable', flush=True)
            f.lan_state.write_text(json.dumps(lan_dump([LAN, '192.0.2.3'])))
            f.verify_lan_status([LAN, '192.0.2.3'])
            for selection in ('198.51.100.1', '192.0.2.99'):
                f.address = selection
                f.reload(child, {'http'}, ok=False)
                check((f.run / 'current/xray.json').read_bytes() == saved and
                      f.state()['render_hash'] == hashes, 'noncandidate selection published')
                f.verify_lan({'http'}, targets, prefix)
            f.address = None
            f.lan_state.write_text(json.dumps(lan_dump()))
            print('PASS noncandidate selection refused (local other-interface/WAN and nonlocal); '
                  'status exposes logical-LAN candidates only', flush=True)
            # Semantic port conflicts fail before replacing the current generation.
            original_socks = ports['socks']
            for label, bad_port in [('same explicit port', ports['http']),
                                    ('internal diagnostic port', 31081)]:
                ports['socks'] = bad_port
                f.reload(child, {'socks', 'http'}, ok=False)
                ports['socks'] = original_socks
                check((f.run / 'current/xray.json').read_bytes() == saved and
                      f.state()['render_hash'] == hashes, 'port conflict published bad config')
                f.verify_lan({'http'}, targets, prefix)
                print('PASS conflict refused:', label, flush=True)
            f.shared = False
            for label, legacy in [('identical legacy pair', {'socks': accounts['socks'],
                                                            'http': accounts['socks']}),
                                  ('single legacy account', {'socks': accounts['socks']})]:
                f.legacy = legacy
                f.reload(child, {'socks', 'http'}, changed=label == 'identical legacy pair')
                f.verify_lan({'socks', 'http'}, targets, prefix)
                print('PASS unambiguous read compatibility:', label, flush=True)
            f.legacy = {'socks': accounts['socks'], 'http': accounts['upstream']}
            # Return to HTTP-only using a complete explicit shared choice first.
            f.shared = True
            f.reload(child, {'http'})
            f.shared = False
            saved = (f.run / 'current/xray.json').read_bytes()
            hashes = f.state()['render_hash']
            f.reload(child, {'socks', 'http'}, ok=False)
            check((f.run / 'current/xray.json').read_bytes() == saved and
                  f.state()['render_hash'] == hashes, 'ambiguous credentials changed artifact')
            f.verify_lan({'http'}, targets, prefix)
            for partial in ('username', 'password'):
                f.shared = partial
                f.reload(child, {'socks', 'http'}, ok=False)
                check((f.run / 'current/xray.json').read_bytes() == saved and
                      f.state()['render_hash'] == hashes, 'partial new account bypassed ambiguity')
                f.verify_lan({'http'}, targets, prefix)
            print('PASS different legacy credentials and partial replacements refused; '
                  'UCI/artifact retained', flush=True)
            # A complete explicit replacement resolves ambiguity without deleting old fields.
            f.shared = True
            f.reload(child, {'http'}, changed=False)
            f.verify_lan({'http'}, targets, prefix)
            f.legacy = None
            # Occupy only the newly added port; preserve and exercise prior HTTP.
            with socket.socket() as occupied:
                occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                occupied.bind((LAN, ports['socks']))
                occupied.listen()
                inode = os.readlink(f'/proc/self/fd/{occupied.fileno()}')
                f.reload(child, {'socks', 'http'}, ok=False)
                check(os.readlink(f'/proc/self/fd/{occupied.fileno()}') == inode and
                      (HEX_LAN, ports['socks']) in listeners(os.getpid()),
                      'failed reload disturbed foreign socket ownership')
                check((f.run / 'current/xray.json').read_bytes() == saved and
                      f.state()['render_hash'] == hashes and f.state()['state'] == 'running',
                      'occupied-port rollback lost old artifacts/running state')
                check(all(port != ports['socks'] for _, port in listeners(f.xray_pid())),
                      'rollback Xray incorrectly owns foreign occupied socket')
                for scheme in targets:
                    f.traffic(targets, prefix, 'http', scheme, accounts['http'], True)
                check(f.firewall_evidence() == firewall, 'occupied-port reload changed firewall')
                print('PASS real LAN occupied port: failed reload; foreign inode unchanged; '
                      'rollback HTTP forward + CONNECT/TLS usable', flush=True)
            # Re-resolve logical lan on each apply, never persist runtime proxy_listen.
            next_lan = '192.0.2.3'
            ip('addr', 'add', next_lan + '/24', 'dev', IFACE)
            f.lan_state.write_text(json.dumps(lan_dump([LAN, next_lan])))
            f.address = next_lan
            f.listen = next_lan
            f.reload(child, {'socks', 'http'})
            f.verify_lan({'socks', 'http'}, targets, prefix)
            check(ports['socks'] != ports['http'], 'renumbered explicit ports not distinct')
            ip('addr', 'del', LAN + '/24', 'dev', IFACE)
            f.lan_state.write_text(json.dumps(lan_dump([next_lan])))
            f.address = None
            f.reload(child, {'socks', 'http'}, changed=False)
            f.verify_lan_status([next_lan])
            f.verify_lan({'socks', 'http'}, targets, prefix)
            # A second renumber has no UCI edits: only live logical-LAN state changes.
            previous_lan, next_lan = next_lan, '192.0.2.4'
            uci_before = f.conf.read_bytes()
            ip('addr', 'add', next_lan + '/24', 'dev', IFACE)
            f.lan_state.write_text(json.dumps(lan_dump([next_lan])))
            f.listen = next_lan
            f.reload(child, {'socks', 'http'})
            check(f.conf.read_bytes() == uci_before, 'automatic LAN reapply required UCI edits')
            f.verify_lan({'socks', 'http'}, targets, prefix)
            f.verify_lan_status([next_lan])
            ip('addr', 'del', previous_lan + '/24', 'dev', IFACE)
            for old_address in (LAN, previous_lan):
                for protocol in ('socks', 'http'):
                    result = curl(targets['http'], 'http', protocol, ports[protocol],
                                  accounts[protocol], proxy_host=old_address, prefix=prefix)
                    check(result.returncode != 0, 'old LAN endpoint remains reachable')
            check('proxy_listen' not in f.conf.read_text(), 'runtime address persisted in UCI')
            check(f.firewall_evidence() == firewall, 'LAN reapply changed transparent/firewall config')
            print('PASS LAN change: multiple-candidate selection then sole-address renumber '
                  'with unchanged UCI; both exact sockets/different ports, HTTP+TLS/auth, '
                  'old endpoints closed', flush=True)
            # Double-off accepts missing LAN and retains the shared credentials.
            f.lan_state.write_text(json.dumps(lan_dump([])))
            f.reload(child, set())
            f.verify_lan_status([])
            f.verify_lan(set(), targets, prefix)
            f.lan_state.write_text(json.dumps(lan_dump([next_lan])))
            f.reload(child, {'http'})
            f.verify_lan({'http'}, targets, prefix)
            print('PASS double-off without LAN; re-enable uses retained shared account', flush=True)
            upstream.terminate()
            upstream.wait(timeout=5)
            for scheme in targets:
                f.traffic(targets, prefix, 'http', scheme, accounts['http'], False)
            f.no_secret_logs()
            print('PASS real LAN upstream stopped: no direct fallback and zero target accepts', flush=True)
            print('PASS rooted command fixture: explicit reloads leave nft bytes/load and fw4 '
                  'counts/transparent config unchanged (not real firewall evidence)', flush=True)


if __name__ == '__main__':
    try:
        with lan_network() as client_prefix:
            main(client_prefix)
    except (AssertionError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print('FAIL explicit-proxy LAN:', str(error) if isinstance(error, AssertionError)
              else type(error).__name__ + ' (details withheld)', file=sys.stderr)
        sys.exit(1)
