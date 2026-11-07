#!/usr/bin/env python3
"""W7-W9 actual daemon/reload/monitor with explicitly synthetic per-child proc data."""
import contextlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time
from proc_fixture import seed_elf

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
passed = 0


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS ', label, flush=True)


def wait_for(predicate, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.015)
    raise AssertionError('lifecycle timeout')


class Fixture:
    def __init__(self, base, name, trust=('tcp://8.8.8.8',), degraded=False):
        self.degraded = degraded
        self.base = base / name
        self.root = self.base / 'root'
        self.run = self.root / 'var/run/aether-proxy'
        self.bin = self.base / 'bin'
        shutil.copytree(ROOT / 'tests/stubs/daemon-bin', self.bin)
        for directory in ('etc/config', 'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
                          'sys/class/net/br-lan', 'var/lock', 'var/run/aether-proxy',
                          'etc/aether-proxy/state'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for directory in ('data', 'baseline', 'custom'):
            (self.base / directory).mkdir()
        for name in ('gfwlist', 'chnlist', 'apple'):
            (self.base / 'baseline' / f'{name}.txt').write_text('example.com\n')
        (self.base / 'baseline/chnroute4.txt').write_text('1.0.0.0/8\n')
        (self.base / 'baseline/gfw_static4.txt').write_text('91.108.4.0/22\n')
        (self.root / 'var/etc/dnsmasq.conf.test').write_text(
            'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
        script = self.root / 'etc/init.d/dnsmasq'
        script.write_text('#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n')
        script.chmod(0o755)
        seed_elf(self.root)
        (self.root / 'proc/net/tcp').write_text(
            ' 0: 0100007F:794D 00000000:0000 0A 00000000:00000000 00:00000000 00000000 0 0 0\n')
        for file in ('ip-rules', 'ip-routes', 'conflicts', 'curl-count', 'calls.log'):
            (self.root / file).touch()
        self.conf = self.root / 'etc/config/aetherproxy'
        self.sample = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text()
        self.configure(trust)
        if degraded:
            (self.root / 'resolve-always-fail').touch()
        self.env = dict(os.environ, SYSROOT=str(self.root), STUB_LOG=str(self.root / 'calls.log'),
            STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'), PATH=str(self.bin) + ':' + os.environ['PATH'],
            AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
            AETHER_PROXY_TEST_RAW_LOG_COLLECTOR=str(ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'),
            LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''))
        # Only scheduling of refresh is accelerated. All production actions, busy/lock,
        # supervision, published artifact selection, readiness and events remain real.
        self.modules = self.base / 'modules/aetherproxy'
        shutil.copytree(ROOT / 'aether-proxy/src/lib', self.modules)
        path = self.modules / 'monitor.uc'
        source = path.read_text()
        needle = '\tlet obs = observe(daemon);'
        assert source.count(needle) == 1
        path.write_text(source.replace(needle, '''
	if (fs.stat(system_path(daemon.ctx, '/refresh-now')) != null) {
		if (!fs.unlink(system_path(daemon.ctx, '/refresh-now'))) die('refresh marker unlink failed');
		daemon.machine.last_node_refresh = 0;
	}
''' + needle))
        # One-shot publication failure after forward readiness, then remove the old
        # generation's DNS socket so the state-write rollback path must report its gate.
        path = self.modules / 'state.uc'
        source = path.read_text()
        needle = "\tlet result = sys.write_atomic(path, sprintf('%.J', obj) + '\\n');"
        assert source.count(needle) == 1
        path.write_text(source.replace(needle, '''
	let fault = getenv('SYSROOT') + '/fail-publish-state';
	if (fs.stat(fault) != null && obj.render_hash != null) {
		if (!fs.unlink(fault)) die('cannot consume state fault');
		if (!fs.writefile(getenv('SYSROOT') + '/xray-dns-missing-port', '31082')) die('cannot inject rollback socket loss');
		last_error = 'injected state publication failure';
		return false;
	}
''' + needle))

    def configure(self, trust, sniff=False):
        text = self.sample + "\nconfig dns 'dns'\n"
        text += ''.join(f"\tlist trust_dns '{item}'\n" for item in trust)
        if sniff:
            text = text.replace("option mode 'gfw'", "option mode 'gfw'\n\toption sniffing '0'")
        self.conf.write_text(text)

    def state(self):
        try:
            return json.loads((self.run / 'state.json').read_text())
        except FileNotFoundError:
            return {}

    def events(self, code):
        path = self.run / 'events.jsonl'
        if not path.exists():
            return []
        return [e for line in path.read_text().splitlines() if (e := json.loads(line))['code'] == code]

    def count(self, name):
        path = self.root / name
        return len(path.read_text().splitlines()) if path.exists() else 0

    def probes(self):
        return (self.root / 'calls.log').read_text().count('curl ')

    def delay(self):
        (self.root / 'xray-dns-delay').write_text('0.7')

    def missing(self, port):
        (self.root / 'xray-dns-missing-port').write_text(str(port))

    @contextlib.contextmanager
    def daemon(self, expected_exit=0):
        command = [str(ROOT / 'tests/host/prefix/bin/ucode'), '-L', str(self.base / 'modules/*.uc'),
            '-S', str(ROOT / 'aether-proxy/src/aether-proxy'), '--', 'daemon',
            '--sys-root', str(self.root), '--bin-dir', str(self.bin),
            '--confdir', str(self.conf.parent), '--data-dir', str(self.base / 'data'),
            '--baseline-dir', str(self.base / 'baseline'), '--custom-dir', str(self.base / 'custom')]
        with (self.base / 'stdout').open('w') as out, (self.base / 'stderr').open('w') as err:
            child = subprocess.Popen(command, env=self.env, stdout=out, stderr=err, start_new_session=True)
            try:
                yield child
            except Exception:
                print('DEBUG state', self.state(), flush=True)
                event_file = self.run / 'events.jsonl'
                print('DEBUG events', event_file.read_text() if event_file.exists() else '<no events yet>', flush=True)
                print('DEBUG calls', (self.root / 'calls.log').read_text(), flush=True)
                raise
            finally:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                    raise
                if expected_exit == -signal.SIGKILL:
                    # Explicitly owned test session cleanup, not production orphan
                    # recovery. Also runs on a failed assertion before normal cleanup.
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # All members of this test-owned session already exited.
                stderr = (self.base / 'stderr').read_text()
                check(child.returncode == expected_exit and not stderr,
                      'W7-W9 proc fixture daemon exits cleanly' if expected_exit == 0 else
                      (f'C8 fixture observes actual intentional exit {expected_exit}'
                       if expected_exit == -signal.SIGKILL else
                       f'C6 fixture observes actual failed cleanup exit {expected_exit}'))

    def running(self):
        wait_for(lambda: self.state().get('monitor') is not None and
                 (self.degraded or self.state().get('last_probe', {}).get('ok') is True))


def main(base):
    for trust in [('tcp://8.8.8.8',), ('udp://8.8.8.8',), ('udp://8.8.8.8', 'tcp://1.1.1.1')]:
        f = Fixture(base, 'start-' + str(len(list(base.iterdir()))), trust)
        f.delay()
        with f.daemon():
            wait_for(lambda: f.count('xray-dns-pending') == 1)
            check(not f.events('SERVICE_STARTED') and f.probes() == 0,
                  f'W7 proc fixture {trust} startup cannot succeed before referenced DNS')
            f.running()
            check(f.count('xray-dns-published') == 1 and bool(f.events('SERVICE_STARTED')),
                  f'W7 proc fixture {trust} startup succeeds after DNS publication')
            calls = (f.root / 'calls.log').read_text()
            check(calls.index('bootstrap-query ') < calls.index('bootstrap-exit ') <
                  calls.index('xray run -c ') < calls.index('ip rule add') <
                  calls.index('chinadns-ng -C ') < calls.index('dns-owned-ready ') < calls.index('dnsmasq restart'),
                  'W7 B3 private exit then Xray gate dataplane formal owned DNS and handoff order')
    f = Fixture(base, 'degraded', degraded=True)
    with f.daemon():
        f.running()
        check(not (f.run / 'xray.pid').exists() and f.count('xray-dns-pending') == 0,
              'W7 degraded unresolved node creates no Xray and does not wait')

    f = Fixture(base, 'reload-generations')
    with f.daemon() as child:
        f.running()
        old_hashes = f.state()['render_hash']
        probes = f.probes()
        f.delay()
        f.configure(('udp://8.8.8.8', 'tcp://1.1.1.1'))
        child.send_signal(signal.SIGHUP)
        wait_for(lambda: f.count('xray-dns-pending') >= 2)
        check(f.probes() == probes and f.state()['render_hash'] == old_hashes,
              'W8 forward reload with mixed new references waits before hash/probe success')
        wait_for(lambda: f.state().get('last_reload', {}).get('ok') is True)
        check(f.count('xray-dns-published') >= 2 and f.state()['render_hash'] != old_hashes,
              'W8 forward reload commits only after new child referenced DNS ready')
        check(f.probes() == probes, 'W8 trust-only reload preserves original no-extra-probe semantics')
        # Restore single trust, then try mixed with missing second DNS. Rollback must
        # read restored single-trust artifacts and ignore that missing second port.
        prior = f.state()['last_reload']['at']
        probes = f.probes()
        f.configure(('tcp://8.8.8.8',))
        child.send_signal(signal.SIGHUP)
        wait_for(lambda: f.state()['render_hash'] == old_hashes and
                 f.state().get('last_reload', {}).get('at', 0) > prior)
        prior = f.state()['last_reload']['at']
        probes = f.probes()
        f.missing(31083)
        f.configure(('udp://8.8.8.8', 'tcp://1.1.1.1'))
        child.send_signal(signal.SIGHUP)
        wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > prior, timeout=9)
        last = f.state()['last_reload']
        check(last['ok'] is False and 'rollback_xray' not in last['error'] and
              f.state()['render_hash'] == old_hashes and f.probes() == probes,
              'W8 failed mixed forward restores single-trust child without stale second-port requirement')
        f.missing(31082)
        prior = last['at']
        child.send_signal(signal.SIGHUP)
        wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > prior, timeout=12)
        check('rollback_xray' in f.state()['last_reload']['error'],
              'W8 rollback readiness failure is explicit in returned reload error')

    f = Fixture(base, 'state-write-rollback')
    with f.daemon() as child:
        f.running()
        (f.root / 'fail-publish-state').touch()
        f.configure(('tcp://8.8.8.8',), sniff=True)
        child.send_signal(signal.SIGHUP)
        wait_for(lambda: f.state().get('last_reload') is not None, timeout=9)
        last = f.state()['last_reload']
        check(last['ok'] is False and 'injected state publication failure' in last['error'] and
              'rollback_xray' in last['error'],
              'W8 state-write failure preserves original cause and returns rollback gate failure')

    f = Fixture(base, 'planned-restarts')
    with f.daemon() as child:
        f.running()
        # Periodic observation deliberately remains TPROXY-only and nonblocking.
        pid = (f.run / 'xray.pid').read_text().strip()
        table = f.root / 'proc' / pid / 'net/tcp'
        table.write_text(''.join(line for line in table.read_text().splitlines(True) if ':7968 ' in line))
        probes = f.probes()
        at = time.monotonic()
        child.send_signal(signal.SIGUSR1)
        wait_for(lambda: f.probes() > probes, timeout=1)
        check(time.monotonic() - at < 1,
              'W10 periodic health remains nonblocking when referenced DNS socket disappears')
        f.delay()
        probes = f.probes()
        pending = f.count('xray-dns-pending')
        child.send_signal(signal.SIGUSR2)
        wait_for(lambda: f.count('xray-dns-pending') > pending)
        check(f.probes() == probes, 'W9 SIGUSR2 cannot probe before replacement referenced DNS ready')
        wait_for(lambda: f.probes() > probes)
        check(f.count('xray-dns-published') > pending, 'W9 SIGUSR2 probes only after replacement DNS ready')
        # Force the real monitor IP refresh path using a different resolved IP.
        (f.root / 'resolve-ip').write_text('198.51.100.44\n')
        (f.root / 'refresh-now').touch()
        pending = f.count('xray-dns-pending')
        child.send_signal(signal.SIGUSR1)
        wait_for(lambda: f.count('xray-dns-pending') > pending)
        check(not f.events('NODE_IP_CHANGED'), 'W9 monitor cannot publish IP change before replacement DNS ready')
        # The event is emitted before the monitor's atomic state write. Observe
        # both completion records rather than racing that legitimate ordering.
        wait_for(lambda: bool(f.events('NODE_IP_CHANGED')) and f.state()['node_ip'] == '198.51.100.44')
        check(f.state()['node_ip'] == '198.51.100.44', 'W9 monitor publishes resolved IP after DNS ready')
        f.missing(31082)
        probes = f.probes()
        pending = f.count('xray-dns-pending')
        child.send_signal(signal.SIGUSR2)
        wait_for(lambda: f.count('xray-dns-pending') > pending)
        at = time.monotonic()
        child.terminate()
        child.wait(timeout=3)
        check(time.monotonic() - at < 2 and f.probes() == probes and f.state()['state'] == 'stopped',
              'W9 SIGUSR2 missing DNS real TERM cancels without success probe/state')

    for operation in ('monitor', 'reload'):
        f = Fixture(base, 'cancel-' + operation)
        with f.daemon() as child:
            f.running()
            f.missing(31082)
            if operation == 'monitor':
                (f.root / 'resolve-ip').write_text('198.51.100.45\n')
                (f.root / 'refresh-now').touch()
                child.send_signal(signal.SIGUSR1)
            else:
                f.configure(('tcp://8.8.8.8',), sniff=True)
                child.send_signal(signal.SIGHUP)
            wait_for(lambda: f.count('xray-dns-pending') >= 2)
            probes = f.probes()
            at = time.monotonic()
            child.terminate()
            child.wait(timeout=3)
            check(time.monotonic() - at < 2 and not f.events('NODE_IP_CHANGED') and
                  f.probes() == probes and f.state()['state'] == 'stopped',
                  f'W8/W9 {operation} missing DNS real TERM cancels without success state/probe')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.lifecycle-', dir=HERE) as directory:
        main(pathlib.Path(directory))
    print(f'xray-ready lifecycle proc fixtures: {passed} passed, 0 failed')
