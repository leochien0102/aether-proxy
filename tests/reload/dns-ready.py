#!/usr/bin/env python3
"""T16.91: real reload transactions must wait for formal DNS readiness (forward & rollback)."""
import contextlib
import ipaddress
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/xray-ready'))
from proc_fixture import seed_elf

UCODE = ROOT / 'tests/host/ucode'
passed = 0


def check(condition, label, detail=''):
    global passed
    if not condition:
        raise AssertionError(f'{label}{": " + detail if detail else ""}')
    passed += 1
    print('PASS ', label, flush=True)


def wait_for(predicate, timeout=12, label='timeout'):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(f'wait_for failed: {label}')


FORMAL_DNS_STUB = r'''#!/usr/bin/env python3
import ipaddress
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time

if sys.argv[1:] == ['-V']:
    os.execv(str(Path(__file__).with_name('chinadns-ng-original')), sys.argv)

if '-C' not in sys.argv:
    os.execv(str(Path(__file__).with_name('chinadns-ng-original')), sys.argv)

config = Path(sys.argv[sys.argv.index('-C') + 1])
if config.name == 'bootstrap.conf':
    os.execv(str(Path(__file__).with_name('chinadns-ng-original')), sys.argv)

root = Path(str(config).split('/var/run/aether-proxy/')[0])
log_path = root / 'calls.log'
pid = os.getpid()


def trace(line):
    with log_path.open('a') as f:
        f.write(line + '\n')
        f.flush()


def addr_hex_le(addr):
    packed = ipaddress.IPv4Address(addr).packed
    return f'{packed[3]:02X}{packed[2]:02X}{packed[1]:02X}{packed[0]:02X}'


def write_atomic(path, content):
    tmp = path.with_name(path.name + f'.tmp.{pid}')
    tmp.write_text(content)
    tmp.replace(path)


def row(addr_hex, port, proto, inode):
    state = '0A' if proto == 'tcp' else '07'
    return (f'  0: {addr_hex}:{port:04X} 00000000:0000 {state} '
            f'00000000:00000000 00:00000000 00000000 0 0 {inode}\n')


bind_addr = '127.0.0.1'
bind_port = 31053
tag = 'unknown'
for raw in config.read_text().splitlines():
    s = raw.strip()
    if s.startswith('bind-addr '):
        bind_addr = s.split()[1]
    elif s.startswith('bind-port '):
        bind_port = int(s.split()[1])
    elif s.startswith('default-tag '):
        tag = s.split()[1]

# Consume next scripted behavior if present; default is immediate normal readiness.
behavior = {'mode': 'normal'}
queue_path = root / 'dns-behaviors.json'
if queue_path.exists():
    items = json.loads(queue_path.read_text())
    if items:
        behavior = items.pop(0)
        write_atomic(queue_path, json.dumps(items))

proc = root / 'proc' / str(pid)
(proc / 'fd').mkdir(parents=True, exist_ok=True)
(proc / 'net').mkdir(exist_ok=True)
(proc / 'stat').write_text(Path(f'/proc/{pid}/stat').read_text())
for table in ('tcp', 'udp', 'tcp6', 'udp6'):
    (proc / 'net' / table).write_text('')

(root / 'chinadns.pid').write_text(str(pid))
trace(f'chinadns-ng {" ".join(sys.argv[1:])}')
trace(f'dns-forked {pid} {bind_port} {tag} {behavior["mode"]}')

stop = False


def handle_term(*_):
    global stop
    stop = True


signal.signal(signal.SIGTERM, handle_term)
signal.signal(signal.SIGINT, handle_term)

addr_hex = addr_hex_le(bind_addr)


def publish_owned(port, include_tcp=True, include_udp=True, extra_tcp='', extra_udp='', log_ready=False):
    tcp_inode = 90000 + pid * 10 + 1
    udp_inode = 90000 + pid * 10 + 2
    if include_tcp:
        fd0 = proc / 'fd/0'
        if not fd0.is_symlink():
            fd0.symlink_to(f'socket:[{tcp_inode}]')
        write_atomic(proc / 'net/tcp', extra_tcp + row(addr_hex, port, 'tcp', tcp_inode))
    else:
        write_atomic(proc / 'net/tcp', extra_tcp)
    if include_udp:
        fd1 = proc / 'fd/1'
        if not fd1.is_symlink():
            fd1.symlink_to(f'socket:[{udp_inode}]')
        if log_ready:
            trace(f'dns-ready-publish {pid} {port} {tag}')
        write_atomic(proc / 'net/udp', extra_udp + row(addr_hex, port, 'udp', udp_inode))
    else:
        write_atomic(proc / 'net/udp', extra_udp)


try:
    mode = behavior['mode']
    if mode == 'exit_early':
        trace(f'dns-exit-early {pid} {bind_port} {tag}')
        sys.exit(1)
    elif mode == 'normal':
        publish_owned(bind_port, True, True, log_ready=True)
    elif mode == 'wrong_port':
        override_port = int(behavior['port'])
        publish_owned(override_port, True, True, log_ready=False)
        trace(f'dns-wrong-port {pid} {override_port} {bind_port} {tag}')
    elif mode == 'impostor_only':
        imp_tcp = row(addr_hex, bind_port, 'tcp', 700001)
        imp_udp = row(addr_hex, bind_port, 'udp', 700002)
        write_atomic(proc / 'net/tcp', imp_tcp)
        write_atomic(proc / 'net/udp', imp_udp)
        trace(f'dns-impostor-planted {pid} {bind_port} {tag}')
    elif mode == 'barrier':
        gate = root / behavior['gate']
        imp_tcp = row(addr_hex, bind_port, 'tcp', 700001) if behavior.get('impostor') else ''
        imp_udp = row(addr_hex, bind_port, 'udp', 700002) if behavior.get('impostor') else ''
        if behavior.get('impostor'):
            write_atomic(proc / 'net/tcp', imp_tcp)
            write_atomic(proc / 'net/udp', imp_udp)
            trace(f'dns-impostor-planted {pid} {bind_port} {tag}')
        tcp_done = False
        while not stop:
            step = gate.read_text().strip() if gate.exists() else 'release'
            if step == 'tcp-only' and not tcp_done:
                publish_owned(bind_port, True, False, extra_tcp=imp_tcp, extra_udp=imp_udp, log_ready=False)
                trace(f'dns-tcp-only {pid} {bind_port} {tag}')
                tcp_done = True
            elif step == 'release':
                publish_owned(bind_port, True, True, extra_tcp=imp_tcp, extra_udp=imp_udp, log_ready=True)
                break
            time.sleep(0.01)
    while not stop:
        time.sleep(0.02)
finally:
    shutil.rmtree(proc, ignore_errors=True)
    pidfile = root / 'chinadns.pid'
    if pidfile.exists() and pidfile.read_text().strip() == str(pid):
        pidfile.unlink(missing_ok=True)
    trace(f'dns-exit {pid} {bind_port} {tag}')
'''


class ReloadFixture:
    def __init__(self, base, name, custom_global_port=None):
        self.base = base / name
        self.root = self.base / 'root'
        self.run = self.root / 'var/run/aether-proxy'
        self.bin = self.base / 'bin'
        shutil.copytree(ROOT / 'tests/stubs/daemon-bin', self.bin)
        shutil.move(str(self.bin / 'chinadns-ng'), str(self.bin / 'chinadns-ng-original'))
        stub = self.bin / 'chinadns-ng'
        stub.write_text(FORMAL_DNS_STUB)
        stub.chmod(0o755)
        for directory in ('etc/config', 'etc/init.d', 'var/etc', 'tmp/dnsmasq.d', 'proc/net',
                          'sys/class/net/br-lan', 'var/lock', 'var/run/aether-proxy',
                          'etc/aether-proxy/state'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for directory in ('data', 'baseline', 'custom'):
            (self.base / directory).mkdir()
        for item in ('gfwlist', 'chnlist', 'apple'):
            (self.base / 'baseline' / f'{item}.txt').write_text('example.com\n')
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
        self.set_mode('gfw')
        self.modules = self.base / 'modules/aetherproxy'
        shutil.copytree(ROOT / 'aether-proxy/src/lib', self.modules)
        if custom_global_port is not None:
            chinadns_render = self.modules / 'render/chinadns.uc'
            src = chinadns_render.read_text()
            needle = "\tpush(out, 'bind-port ' + C.CHINADNS_PORT);"
            assert src.count(needle) == 1
            replacement = f"\tpush(out, 'bind-port ' + (mode == 'global' ? {custom_global_port} : C.CHINADNS_PORT));"
            chinadns_render.write_text(src.replace(needle, replacement))
        self.env = dict(
            os.environ,
            SYSROOT=str(self.root),
            STUB_LOG=str(self.root / 'calls.log'),
            STUB_CURL_COUNT_FILE=str(self.root / 'curl-count'),
            PATH=str(self.bin) + ':' + os.environ['PATH'],
            AETHER_PROXY_TEST_LOGFILTER=str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk'),
            AETHER_PROXY_TEST_RAW_LOG_COLLECTOR=str(ROOT / 'aether-proxy/files/aether-proxy-rawlog.sh'),
            LD_LIBRARY_PATH=str(ROOT / 'tests/host/prefix/lib') + ':' + os.environ.get('LD_LIBRARY_PATH', ''),
        )

    def set_mode(self, mode):
        self.conf.write_text(self.sample.replace("option mode 'gfw'", f"option mode '{mode}'", 1))

    def queue_behaviors(self, items):
        (self.root / 'dns-behaviors.json').write_text(json.dumps(items))

    def calls(self):
        return (self.root / 'calls.log').read_text().splitlines()

    def state(self):
        try:
            return json.loads((self.run / 'state.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def events(self, code=None):
        path = self.run / 'events.jsonl'
        if not path.exists():
            return []
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        return rows if code is None else [e for e in rows if e.get('code') == code]

    @contextlib.contextmanager
    def daemon(self):
        command = [
            str(ROOT / 'tests/host/prefix/bin/ucode'),
            '-L', str(self.base / 'modules/*.uc'),
            '-S', str(ROOT / 'aether-proxy/src/aether-proxy'),
            '--', 'daemon',
            '--sys-root', str(self.root),
            '--bin-dir', str(self.bin),
            '--confdir', str(self.conf.parent),
            '--data-dir', str(self.base / 'data'),
            '--baseline-dir', str(self.base / 'baseline'),
            '--custom-dir', str(self.base / 'custom'),
        ]
        with (self.base / 'stdout').open('w') as out, (self.base / 'stderr').open('w') as err:
            child = subprocess.Popen(command, env=self.env, stdout=out, stderr=err, start_new_session=True)
            try:
                yield child
            except Exception:
                print('DEBUG state:', json.dumps(self.state()), flush=True)
                print('DEBUG events:', json.dumps(self.events()), flush=True)
                print('DEBUG calls:\n' + '\n'.join(self.calls()), flush=True)
                print('DEBUG stderr:\n' + (self.base / 'stderr').read_text(), flush=True)
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
                stderr = (self.base / 'stderr').read_text()
                check(child.returncode == 0 and not stderr,
                      f'{self.base.name}: daemon exits cleanly', f'rc={child.returncode} stderr={stderr!r}')

    def wait_running(self):
        wait_for(lambda: self.state().get('state') == 'running' and self.state().get('monitor') is not None,
                 timeout=12, label=f'{self.base.name} running')


def run_unit_checks():
    script = r'''
import * as xr from 'aetherproxy.xray_ready';
function assert_eq(cond, msg) { if (!cond) { warn('FAIL ' + msg + '\n'); exit(1); } }
let ok1 = xr.dns_requirements("bind-addr 127.0.0.1\nbind-port 31053\n");
assert_eq(ok1.ok && length(ok1.required) == 2, 'default bind-addr/bind-port');
assert_eq(ok1.required[0].protocol == 'udp' && ok1.required[1].protocol == 'tcp', 'udp+tcp order');
assert_eq(ok1.required[0].address == '127.0.0.1' && ok1.required[0].port == 31053, 'tuple values');

let ok2 = xr.dns_requirements("# header\nbind-addr 127.0.0.1 # loopback\nbind-port 31054 # custom\n");
assert_eq(ok2.ok && ok2.required[0].port == 31054 && ok2.required[1].port == 31054, 'custom port + comments');

for (let bad in [
    null,
    "bind-port 31053\n",
    "bind-addr 127.0.0.1\n",
    "bind-addr not-an-ip\nbind-port 31053\n",
    "bind-addr 127.0.0.1\nbind-port 0\n",
    "bind-addr 127.0.0.1\nbind-port 70000\n",
    "bind-addr 127.0.0.1\nbind-port 31053\nbind-port 31054\n",
    "bind-addr 127.0.0.1\nbind-addr 127.0.0.2\nbind-port 31053\n"
]) {
    let r = xr.dns_requirements(bad);
    assert_eq(!r.ok, 'reject invalid config: ' + sprintf('%J', bad));
}
print('UNIT_OK\n');
'''
    proc = subprocess.run([str(UCODE), '-e', script], capture_output=True, text=True)
    check(proc.returncode == 0 and 'UNIT_OK' in proc.stdout,
          'T16.91 dns_requirements unit checks', proc.stderr or proc.stdout)


def scenario_barrier_and_impostor(base):
    f = ReloadFixture(base, 'barrier-impostor')
    with f.daemon() as proc:
        f.wait_running()
        offset = len(f.calls())
        applied_before = len(f.events('RELOAD_APPLIED'))
        gate = f.root / 'gate-1'
        gate.write_text('hold')
        f.queue_behaviors([{'mode': 'barrier', 'gate': 'gate-1', 'impostor': True}])
        f.set_mode('bypass_cn')
        proc.send_signal(signal.SIGHUP)

        wait_for(lambda: any(l.startswith('dns-impostor-planted ') for l in f.calls()[offset:]),
                 label='dns forked with impostor sockets')
        # Hold across multiple DAEMON_POLL_MS (100ms) ticks: neither HUP nor RELOAD_APPLIED may occur.
        time.sleep(0.35)
        mid_calls = f.calls()[offset:]
        check('killall -HUP dnsmasq' not in mid_calls,
              'T16.91 barrier: no premature HUP when forked without owned sockets (even with impostor on same port)',
              '\n'.join(mid_calls))
        check(len(f.events('RELOAD_APPLIED')) == applied_before,
              'T16.91 barrier: no premature RELOAD_APPLIED while barrier held')

        # Publish owned TCP only (UDP still unowned/missing): still must not HUP.
        gate.write_text('tcp-only')
        wait_for(lambda: any(l.startswith('dns-tcp-only ') for l in f.calls()[offset:]),
                 label='dns tcp-only published')
        time.sleep(0.25)
        tcp_calls = f.calls()[offset:]
        check('killall -HUP dnsmasq' not in tcp_calls,
              'T16.91 barrier: TCP-only without owned UDP does not satisfy DNS readiness',
              '\n'.join(tcp_calls))
        check(len(f.events('RELOAD_APPLIED')) == applied_before,
              'T16.91 barrier: TCP-only does not emit RELOAD_APPLIED')

        # Release barrier: owned UDP published -> HUP and RELOAD_APPLIED follow in strict causal order.
        gate.write_text('release')
        wait_for(lambda: len(f.events('RELOAD_APPLIED')) == applied_before + 1 and
                 f.state().get('last_reload', {}).get('ok') is True,
                 label='reload applied after barrier release')
        after_calls = f.calls()[offset:]
        fork_idx = next(i for i, l in enumerate(after_calls) if l.startswith('dns-forked '))
        ready_idx = next(i for i, l in enumerate(after_calls) if l.startswith('dns-ready-publish '))
        hup_idx = next(i for i, l in enumerate(after_calls) if l == 'killall -HUP dnsmasq')
        check(fork_idx < ready_idx < hup_idx,
              'T16.91 barrier: strict causal order dns-forked < dns-ready-publish < dnsmasq HUP',
              f'fork={fork_idx} ready={ready_idx} hup={hup_idx}')


def scenario_forward_fail_rollback_success(base):
    f = ReloadFixture(base, 'forward-fail-rollback-ok')
    with f.daemon() as proc:
        f.wait_running()
        old_conf = (f.run / 'current/chinadns.conf').read_bytes()
        old_hashes = f.state()['render_hash']
        applied_before = len(f.events('RELOAD_APPLIED'))
        prior_at = f.state().get('last_reload', {}).get('at', 0)
        offset = len(f.calls())

        # Forward DNS has only impostor sockets (never owned -> 5s timeout); rollback DNS has controllable barrier.
        rb_gate = f.root / 'rb-gate'
        rb_gate.write_text('hold')
        f.queue_behaviors([
            {'mode': 'impostor_only'},
            {'mode': 'barrier', 'gate': 'rb-gate', 'impostor': False},
        ])
        f.set_mode('bypass_cn')
        proc.send_signal(signal.SIGHUP)

        # Wait until rollback DNS has forked (which proves forward failed after old DNS stopped).
        wait_for(lambda: sum(1 for l in f.calls()[offset:] if l.startswith('dns-forked ')) >= 2,
                 timeout=10, label='rollback dns forked after forward timeout')
        time.sleep(0.30)
        mid_calls = f.calls()[offset:]
        check('killall -HUP dnsmasq' not in mid_calls,
              'T16.91 rollback: no HUP on forward failure or before restored DNS is ready',
              '\n'.join(mid_calls))
        check(len(f.events('RELOAD_APPLIED')) == applied_before,
              'T16.91 rollback: forward failure never emits RELOAD_APPLIED')

        # Release rollback barrier -> restored DNS becomes ready -> HUP follows.
        rb_gate.write_text('release')
        wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > prior_at,
                 timeout=10, label='failed reload completion recorded')
        last = f.state()['last_reload']
        check(last['ok'] is False and 'rollback_chinadns' not in (last.get('error') or ''),
              'T16.91 rollback-ok: last_reload records forward failure without rollback error', json.dumps(last))
        check(f.state()['render_hash'] == old_hashes and (f.run / 'current/chinadns.conf').read_bytes() == old_conf,
              'T16.91 rollback-ok: old config and render_hash restored')
        after_calls = f.calls()[offset:]
        fork_idxs = [i for i, l in enumerate(after_calls) if l.startswith('dns-forked ')]
        ready_idxs = [i for i, l in enumerate(after_calls) if l.startswith('dns-ready-publish ')]
        hup_idxs = [i for i, l in enumerate(after_calls) if l == 'killall -HUP dnsmasq']
        check(len(fork_idxs) == 2 and len(ready_idxs) == 1 and len(hup_idxs) == 1 and
              fork_idxs[0] < fork_idxs[1] < ready_idxs[0] < hup_idxs[0],
              'T16.91 rollback-ok: causal order forward-fork < rollback-fork < rollback-ready < single HUP',
              '\n'.join(after_calls))


def scenario_port_selection_published_vs_restored(base):
    # New 'global' config binds 31054; old 'gfw' config binds 31053.
    f = ReloadFixture(base, 'port-selection', custom_global_port=31054)
    with f.daemon() as proc:
        f.wait_running()
        prior_at = f.state().get('last_reload', {}).get('at', 0)
        offset = len(f.calls())

        # Forward child listens on old port 31053 instead of published 31054 -> MUST fail readiness!
        # Rollback restores gfw (31053) and listens on 31053 -> MUST succeed!
        f.queue_behaviors([
            {'mode': 'wrong_port', 'port': 31053},
            {'mode': 'normal'},
        ])
        f.set_mode('global')
        proc.send_signal(signal.SIGHUP)

        wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > prior_at,
                 timeout=12, label='port-selection reload completion')
        last = f.state()['last_reload']
        after_calls = f.calls()[offset:]
        check(last['ok'] is False and 'rollback_chinadns' not in (last.get('error') or ''),
              'T16.91 port-selection: forward rejects old port 31053 when published config requires 31054',
              json.dumps(last))
        check(any(l.startswith('dns-wrong-port ') and ' 31053 31054 ' in l for l in after_calls),
              'T16.91 port-selection: observed forward child bound 31053 for 31054 config')
        check(any(l.startswith('dns-ready-publish ') and ' 31053 chn' in l for l in after_calls),
              'T16.91 port-selection: rollback restored gfw config and verified port 31053')


def scenario_forward_fail_rollback_fail(base):
    f = ReloadFixture(base, 'forward-fail-rollback-fail')
    with f.daemon() as proc:
        f.wait_running()
        applied_before = len(f.events('RELOAD_APPLIED'))
        prior_at = f.state().get('last_reload', {}).get('at', 0)
        offset = len(f.calls())

        # Both forward and rollback DNS children exit early before listening.
        f.queue_behaviors([
            {'mode': 'exit_early'},
            {'mode': 'exit_early'},
        ])
        f.set_mode('bypass_cn')
        proc.send_signal(signal.SIGHUP)

        wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > prior_at,
                 timeout=10, label='rollback-fail completion recorded')
        last = f.state()['last_reload']
        after_calls = f.calls()[offset:]
        start_failed = f.events('START_FAILED')
        rb_events = [e for e in start_failed if e.get('args', {}).get('step') == 'reload:rollback_chinadns']
        act_events = [e for e in start_failed if e.get('args', {}).get('step') == 'reload:actions']
        check(last['ok'] is False, 'T16.91 rollback-fail: last_reload.ok is False', json.dumps(last))
        check('rollback_chinadns:' in (last.get('error') or ''),
              'T16.91 rollback-fail: rollback_chinadns reason is visible in last_reload.error', json.dumps(last))
        check(len(rb_events) >= 1 and 'formal DNS' in (rb_events[-1].get('args', {}).get('detail') or ''),
              'T16.91 rollback-fail: START_FAILED reload:rollback_chinadns retains locatable reason',
              json.dumps(rb_events))
        check(len(act_events) >= 1 and 'rollback_chinadns:' in (act_events[-1].get('args', {}).get('detail') or ''),
              'T16.91 rollback-fail: START_FAILED reload:actions surfaces rollback_chinadns failure',
              json.dumps(act_events))
        check('killall -HUP dnsmasq' not in after_calls,
              'T16.91 rollback-fail: zero dnsmasq HUPs when both forward and rollback DNS fail',
              '\n'.join(after_calls))
        check(len(f.events('RELOAD_APPLIED')) == applied_before,
              'T16.91 rollback-fail: no RELOAD_APPLIED event')


def scenario_sigterm_cancels_dns_wait(base):
    f = ReloadFixture(base, 'sigterm-cancels-dns-wait')
    with f.daemon() as proc:
        f.wait_running()
        applied_before = len(f.events('RELOAD_APPLIED'))
        offset = len(f.calls())
        gate = f.root / 'term-gate'
        gate.write_text('hold')
        f.queue_behaviors([{'mode': 'barrier', 'gate': 'term-gate', 'impostor': False}])
        f.set_mode('bypass_cn')
        proc.send_signal(signal.SIGHUP)
        wait_for(lambda: any(l.startswith('dns-forked ') for l in f.calls()[offset:]),
                 label='dns forked before SIGTERM')
        started = time.monotonic()
        proc.terminate()
        proc.wait(timeout=4)
        elapsed = time.monotonic() - started
        after_calls = f.calls()[offset:]
        check(elapsed < 3.5,
              f'T16.91 cancel: SIGTERM cancels DNS readiness wait promptly ({elapsed:.2f}s)')
        check('killall -HUP dnsmasq' not in after_calls,
              'T16.91 cancel: no dnsmasq HUP when SIGTERM cancels DNS wait')
        check(len(f.events('RELOAD_APPLIED')) == applied_before,
              'T16.91 cancel: no RELOAD_APPLIED when SIGTERM cancels DNS wait')


def main():
    with tempfile.TemporaryDirectory(prefix='t1691-dns-ready-') as tmp:
        base = pathlib.Path(tmp)
        run_unit_checks()
        scenario_barrier_and_impostor(base)
        scenario_forward_fail_rollback_success(base)
        scenario_port_selection_published_vs_restored(base)
        scenario_forward_fail_rollback_fail(base)
        scenario_sigterm_cancels_dns_wait(base)
    print(f't16.91 dns-ready: {passed} passed, 0 failed', flush=True)


if __name__ == '__main__':
    main()
