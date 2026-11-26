#!/usr/bin/env python3
"""Production daemon/reload with real Xray; separately labelled proc-visibility faults."""
from contextlib import contextmanager, ExitStack
import importlib.util
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile

from network import LAN, IFACE, HEX_LAN, lan_network, ubus_fixture
from acceptance import (ROOT, BODY, check, discover_xray, free_port, listeners,
                        write_uci, target_server, curl, xray_process)

spec = importlib.util.spec_from_file_location('dns_ready_fixture', ROOT / 'tests/reload/dns-ready.py')
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)


def replace_once(path, old, new):
    text = path.read_text()
    check(text.count(old) == 1, 'fixture source boundary changed: ' + path.name)
    path.write_text(text.replace(old, new, 1))


class Fixture(dns.ReloadFixture):
    def __init__(self, base, name, binary, ports, accounts, barrier=False, baseline=False):
        super().__init__(base, name)
        self.ports, self.accounts = ports, accounts
        self.gate = self.base / 'withhold-explicit.json'
        self.probes = self.base / 'ready-probes.jsonl'
        self.env['XRAY_LOCATION_ASSET'] = str(self.base / 'empty-assets')
        (self.base / 'empty-assets').mkdir()
        # Xray/sockets are native; ubus LAN, DNS, nft, routing and dnsmasq
        # remain explicitly labelled offline/rooted daemon fixtures.
        (self.bin / 'xray').unlink()
        (self.bin / 'xray').symlink_to(binary)
        # The existing monitor reads the global tcp6 table for TPROXY health.
        # Native read-only data replaces the shell Xray stub's synthetic row.
        (self.root / 'proc/net/tcp6').symlink_to('/proc/net/tcp6')
        self.configure(set())
        self.lan_state = ubus_fixture(self.bin)
        (self.root / 'sys/class/net' / IFACE).mkdir(parents=True, exist_ok=True)
        replace_once(self.root / 'var/etc/dnsmasq.conf.test', 'interface=br-lan',
                     'interface=' + IFACE)
        ready = self.modules / 'xray_ready.uc'
        # Rooted artifacts remain real production renders. Only the observation
        # context changes to native /proc + socket_diag for this real child.
        replace_once(ready,
                     'return result.ok ? wait(ctx, child, result.required, on_signal) : result;',
                     "return result.ok ? wait({ ...ctx, root: '' }, child, result.required, on_signal) : result;")
        if baseline:
            text = ready.read_text()
            start = text.index("\tfor (let protocol in [ 'socks', 'http' ]) {")
            end = text.index('\n\tlet tunnels =', start)
            check(text.count("\tfor (let protocol in [ 'socks', 'http' ]) {") == 1,
                  'baseline mutation boundary changed')
            ready.write_text(text[:start] + text[end:])
        if barrier:
            # Fault fixture: hide selected rows at the proc-snapshot I/O boundary,
            # not the requirements, ownership checks, readiness result or budget.
            replace_once(ready, '\treturn { ok: true, rows };',
                         f'\tlet hidden = fs.readfile({json.dumps(str(self.gate))});\n'
                         '\tif (hidden != null) {\n'
                         '\t\tlet ports = json(hidden);\n'
                         '\t\trows = filter(rows, row => index(ports, row.port) < 0);\n'
                         '\t}\n\treturn { ok: true, rows };')
            replace_once(ready, '\t\tif (ready)\n\t\t\treturn { ok: true };',
                         f'\t\tlet trace = fs.open({json.dumps(str(self.probes))}, "a");\n'
                         '\t\ttrace.write(sprintf("%J\\n", { ready, '
                         "explicit: length(filter(required, r => r.role == 'explicit')) }));\n"
                         '\t\ttrace.close();\n'
                         '\t\tif (ready)\n\t\t\treturn { ok: true };')

    def configure(self, enabled):
        write_uci(self.conf.parent, enabled, self.ports, self.accounts,
                  self.ports['upstream'], self.accounts['upstream'])

    def hold(self):
        self.gate.write_text(json.dumps([self.ports[p] for p in ('socks', 'http')]))
        self.probes.unlink(missing_ok=True)

    def samples(self):
        if not self.probes.exists():
            return []
        return [json.loads(row) for row in self.probes.read_text().splitlines() if row]

    def observe_base(self, enabled):
        # Observe the same generation through the unmodified native gate, outside
        # the hidden-row fixture. Count only daemon evaluations after this proof.
        def has_explicit_listeners():
            try:
                pid = self.xray_pid()
                return {self.ports[p] for p in enabled} <= {port for _, port in listeners(pid)}
            except (AssertionError, FileNotFoundError, ProcessLookupError):
                return False
        dns.wait_for(has_explicit_listeners, label='native Xray generation listeners')
        pid = self.xray_pid()
        observer = self.base / 'observe-base.uc'
        observer.write_text("""import * as fs from 'fs';
import * as uloop from 'uloop';
import * as ready from 'aetherproxy.xray_ready';
uloop.init();
let result = ready.requirements(fs.readfile(ARGV[0] + '/chinadns.conf'),
    fs.readfile(ARGV[0] + '/xray.json'));
if (!result.ok) exit(1);
let pid = +ARGV[1];
result = ready.wait({}, { pid: () => pid },
    filter(result.required, r => r.role != 'explicit'), null, { timeout_ms: 1000 });
print(sprintf('%J', result));
uloop.done();
""")
        observed = subprocess.run([str(ROOT / 'tests/host/ucode'), str(observer),
                                   str(self.run / 'current'), str(pid)],
                                  capture_output=True, timeout=3)
        check(observed.returncode == 0 and json.loads(observed.stdout)['ok'],
              'independent native observer did not prove all non-explicit requirements')
        check(self.xray_pid() == pid, 'Xray generation changed during native observation')
        return len(self.samples()), pid

    @contextmanager
    def daemon(self):
        # Same production command as ReloadFixture; suppress its debug-on-error
        # dumper because runtime state and rendered configs contain credentials.
        command = [str(ROOT / 'tests/host/prefix/bin/ucode'),
                   '-L', str(self.base / 'modules/*.uc'), '-S',
                   str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'daemon',
                   '--sys-root', str(self.root), '--bin-dir', str(self.bin),
                   '--confdir', str(self.conf.parent), '--data-dir', str(self.base / 'data'),
                   '--baseline-dir', str(self.base / 'baseline'),
                   '--custom-dir', str(self.base / 'custom')]
        with (self.base / 'stdout').open('w') as out, (self.base / 'stderr').open('w') as err:
            child = subprocess.Popen(command, env=self.env, stdout=out, stderr=err,
                                     start_new_session=True)
            try:
                yield child
            finally:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                    raise AssertionError('daemon cleanup timed out')
                check(child.returncode == 0 and not (self.base / 'stderr').read_bytes(),
                      'daemon did not exit cleanly (output withheld)')
                self.no_secret_logs()

    def no_secret_logs(self):
        paths = [self.base / 'stdout', self.base / 'stderr', self.root / 'calls.log']
        paths += list(self.run.rglob('*.log')) + list(self.run.rglob('*.jsonl'))
        paths += [self.run / 'state.json']
        for path in paths:
            if path.is_file():
                data = path.read_bytes()
                check(not any(secret.encode() in data for pair in self.accounts.values()
                              for secret in pair), 'credential leaked in runtime log/state')

    def xray_pid(self):
        # Use the daemon's actual child tree, not process-name/global-port guesses.
        children = Path(f'/proc/{self.daemon_pid}/task/{self.daemon_pid}/children').read_text().split()
        pids = []
        for pid in children:
            try:
                if Path(f'/proc/{pid}/exe').resolve() == (self.bin / 'xray').resolve():
                    pids.append(int(pid))
            except FileNotFoundError:
                pass
        check(len(pids) == 1, 'expected exactly one daemon-owned real Xray child')
        return pids[0]

    def verify(self, enabled, target):
        pid = self.xray_pid()
        actual = listeners(pid)
        config = json.loads((self.run / 'current/xray.json').read_text())
        tags = {row['tag'] for row in config['inbounds']}
        for protocol in ('socks', 'http'):
            check(('explicit-' + protocol in tags) == (protocol in enabled),
                  'published inbound enable mismatch')
            bound = [host for host, port in actual if port == self.ports[protocol]]
            check(bound == ([HEX_LAN] if protocol in enabled else []),
                  'explicit listener is not child-owned exact LAN IP/disabled')
            if protocol not in enabled:
                with socket.socket() as sock:
                    sock.settimeout(0.5)
                    check(sock.connect_ex((LAN, self.ports[protocol])) != 0,
                          'disabled explicit port remains connectable')
            else:
                result = curl(target, 'http', protocol, self.ports[protocol], self.accounts[protocol])
                check(result.returncode == 0 and result.stdout == BODY,
                      'real authenticated proxy request failed (output withheld)')
                unauthorized = curl(target, 'http', protocol, self.ports[protocol], None)
                check(unauthorized.returncode != 0, 'proxy accepted unauthenticated request')
        self.no_secret_logs()
        return pid

    def reload(self, child, enabled, ok=True, changed=True):
        before = self.state().get('last_reload')
        applied = len(self.events('RELOAD_APPLIED'))
        self.configure(enabled)
        uci_before = self.conf.read_bytes()
        child.send_signal(signal.SIGHUP)
        dns.wait_for(lambda: self.state().get('last_reload') != before,
                     timeout=15, label='reload completion')
        check(self.state()['last_reload']['ok'] is ok, 'unexpected reload transaction result')
        check(len(self.events('RELOAD_APPLIED')) == applied + int(ok and changed),
              'incorrect RELOAD_APPLIED publication')
        check(self.conf.read_bytes() == uci_before,
              'reload read/validation silently rewrote UCI credentials or runtime address')


def real_transactions(base, binary, ports, accounts, target):
    f = Fixture(base, 'real-reload', binary, ports, accounts)
    with f.daemon() as child:
        f.daemon_pid = child.pid
        f.wait_running()
        old = f.verify(set(), target)
        for label, enabled in [('HTTP', {'http'}), ('both', {'http', 'socks'}),
                               ('SOCKS', {'socks'}), ('off', set())]:
            f.reload(child, enabled)
            new = f.verify(enabled, target)
            check(new != old, 'reload did not replace Xray generation')
            old = new
            print('PASS real Xray daemon reload:', label, flush=True)
        for existing, added in [('http', 'socks'), ('socks', 'http')]:
            f.reload(child, {existing})
            f.verify({existing}, target)
            saved = (f.run / 'current/xray.json').read_bytes()
            hashes = f.state()['render_hash']
            # A separate foreign process must survive forward failure + rollback.
            occupier_code = ('import socket,sys; s=socket.socket(); '
                             's.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); '
                             f's.bind(("{LAN}",int(sys.argv[1]))); s.listen(); '
                             'print("ready",flush=True); sys.stdin.read()')
            occupier = subprocess.Popen([sys.executable, '-c', occupier_code, str(ports[added])],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL)
            try:
                check(occupier.stdout.readline() == b'ready\n', 'foreign occupier failed to bind')
                check(listeners(occupier.pid) == [(HEX_LAN, ports[added])],
                      'foreign process does not own occupied port')
                socket_ids = {os.readlink(fd) for fd in Path(f'/proc/{occupier.pid}/fd').iterdir()
                              if os.readlink(fd).startswith('socket:[')}
                f.reload(child, {'http', 'socks'}, ok=False)
                check(occupier.poll() is None and
                      listeners(occupier.pid) == [(HEX_LAN, ports[added])] and
                      socket_ids == {os.readlink(fd)
                                     for fd in Path(f'/proc/{occupier.pid}/fd').iterdir()
                                     if os.readlink(fd).startswith('socket:[')},
                      'reload changed foreign port owner/socket identity')
                check((f.run / 'current/xray.json').read_bytes() == saved and
                      f.state()['render_hash'] == hashes, 'rollback did not restore prior artifact/hash')
                check(f.state()['state'] == 'running' and
                      bool(f.state()['last_reload'].get('error')),
                      'failed reload did not retain running state/visible failure')
                check(f.events('START_FAILED'), 'failed reload did not emit failure event')
                # The added port is deliberately still foreign-owned.
                pid = f.xray_pid()
                check((HEX_LAN, ports[existing]) in listeners(pid) and
                      all(port != ports[added] for _, port in listeners(pid)),
                      'rollback listener ownership incorrect')
                result = curl(target, 'http', existing, ports[existing], accounts[existing])
                check(result.returncode == 0 and result.stdout == BODY,
                      'rollback prior authenticated proxy unusable')
                f.no_secret_logs()
                print('PASS real Xray occupied added ' + added + ': reload failed, rollback usable, '
                      'foreign PID/socket unchanged, no credential logs', flush=True)
            finally:
                occupier.stdin.close()
                occupier.wait(timeout=5)


def barriers(base, binary, ports, accounts, target, baseline=False):
    f = Fixture(base, 'baseline-barrier' if baseline else 'barrier', binary, ports, accounts,
                barrier=True, baseline=baseline)
    f.configure(set() if baseline else {'http'})
    if not baseline:
        f.hold()
    with f.daemon() as child:
        f.daemon_pid = child.pid
        if baseline:
            # Start double-off: only the reload barrier can reject this mutation.
            f.wait_running()
            f.hold()
            applied = len(f.events('RELOAD_APPLIED'))
            f.configure({'http'})
            child.send_signal(signal.SIGHUP)
            dns.wait_for(lambda: len(f.events('RELOAD_APPLIED')) > applied or
                         sum(not row['ready'] and row['explicit'] > 0
                             for row in f.samples()) >= 3,
                         label='baseline reload visibility barrier evaluated')
            check(len(f.events('RELOAD_APPLIED')) == applied,
                  'premature reload publication behind explicit visibility barrier')
            return
        # Only evaluations after all non-explicit requirements are proven count.
        start, observed_pid = f.observe_base({'http'})
        dns.wait_for(lambda: f.state().get('state') == 'running' or
                     sum(not row['ready'] and row['explicit'] > 0 for row in f.samples()[start:]) >= 3,
                     label='startup visibility barrier evaluated')
        if f.state().get('state') == 'running':
            raise AssertionError('premature startup publication behind explicit visibility barrier')
        check(not f.events('SERVICE_STARTED') and not f.events('RELOAD_APPLIED'),
              'startup barrier published success')
        check(f.xray_pid() == observed_pid, 'startup barrier changed observed generation')
        f.gate.unlink()
        f.wait_running()
        f.verify({'http'}, target)
        print('PASS fixture startup: repeated not-ready evaluations precede release/running', flush=True)
        applied = len(f.events('RELOAD_APPLIED'))
        last_reload = f.state().get('last_reload')
        f.hold()
        f.configure({'http', 'socks'})
        child.send_signal(signal.SIGHUP)
        start, observed_pid = f.observe_base({'http', 'socks'})
        dns.wait_for(lambda: len(f.events('RELOAD_APPLIED')) > applied or
                     sum(not row['ready'] and row['explicit'] == 2 for row in f.samples()[start:]) >= 3,
                     label='reload visibility barrier evaluated')
        check(len(f.events('RELOAD_APPLIED')) == applied and
              f.state().get('last_reload') == last_reload,
              'premature reload publication behind explicit visibility barrier')
        check(f.xray_pid() == observed_pid, 'reload barrier changed observed generation')
        f.gate.unlink()
        dns.wait_for(lambda: len(f.events('RELOAD_APPLIED')) == applied + 1,
                     label='reload after visibility barrier release')
        f.verify({'http', 'socks'}, target)
        print('PASS fixture reload: repeated explicit not-ready evaluations, '
              'no RELOAD_APPLIED until release', flush=True)


def main():
    binary = discover_xray()
    banner = subprocess.run([str(binary), 'version'], capture_output=True, check=True).stdout
    print('Real engine:', banner.decode().splitlines()[0], flush=True)
    for port in (31080, 31081, 31082, 31083):
        with socket.socket() as sock:
            sock.bind(('0.0.0.0', port))
    ports = {}
    while len(set(ports.values())) < 3:
        ports = {name: free_port() for name in ('socks', 'http', 'upstream')}
    accounts = {name: (secrets.token_hex(8), secrets.token_hex(16)) for name in ports}
    accounts['http'] = accounts['socks']
    with tempfile.TemporaryDirectory(prefix='aether-explicit-reload-') as temp, ExitStack() as stack:
        base = Path(temp)
        target = stack.enter_context(target_server())
        config = base / 'upstream.json'
        config.write_text(json.dumps({'log': {'loglevel': 'none', 'access': 'none'},
            'inbounds': [{'listen': '127.0.0.1', 'port': ports['upstream'], 'protocol': 'socks',
                          'settings': {'auth': 'password', 'udp': False, 'accounts': [
                              {'user': accounts['upstream'][0], 'pass': accounts['upstream'][1]}]}}],
            'outbounds': [{'protocol': 'freedom'}]}))
        config.chmod(0o600)
        stack.enter_context(xray_process(binary, config, {ports['upstream']}, os.environ.copy()))
        real_transactions(base, binary, ports, accounts, target)
        barriers(base, binary, ports, accounts, target)
        try:
            barriers(base, binary, ports, accounts, target, baseline=True)
        except AssertionError as error:
            check(str(error) == 'premature reload publication behind explicit visibility barrier',
                  'baseline mutation failed for unrelated reason')
            print('PASS mutation sensitivity: baseline omission emits premature RELOAD_APPLIED '
                  '(expected rejection)', flush=True)
        else:
            raise AssertionError('barrier did not reject baseline requirements omission')


if __name__ == '__main__':
    try:
        with lan_network():
            main()
    except (AssertionError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print('FAIL explicit-proxy reload:', str(error) if isinstance(error, AssertionError)
              else type(error).__name__ + ' (details withheld)', file=sys.stderr)
        sys.exit(1)
