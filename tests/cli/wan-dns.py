#!/usr/bin/env python3
"""T9.23 end-to-end WAN DNS, sync-wan and applied-state regression checks (docs/03)."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
UCODE = ROOT / 'tests/host/ucode'
ENTRY = ROOT / 'aether-proxy/src/aether-proxy'
ISP = ['202.96.128.86', '202.96.134.133']
FALLBACK = '223.5.5.5'
PUBLIC = '114.114.114.114'


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print('PASS  T9.23 ' + name, flush=True)


def interface(name, dns, default=True):
    return {'interface': name, 'up': True, 'dns-server': dns,
            'route': [{'target': '0.0.0.0', 'mask': 0}] if default else []}


def test_hotplug(t):
    hook_bin = t / 'hook-bin'
    hook_bin.mkdir()
    command = hook_bin / 'aether-proxy'
    command.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$HOOK_CALLS"
printf 'background stdout\\n'
printf 'background stderr\\n' >&2
# A foreground hook would never return before the harness releases this gate.
while [ -f "$HOOK_GATE" ]; do sleep 0.05; done
printf 'done\\n' >> "$HOOK_DONE"
exit 7
''')
    command.chmod(0o755)
    # Like the procd suite, substitute only the two target-only library imports.
    # The disabled-service substitute leaves every packaged hook branch intact and
    # proves DNS synchronization starts before enabled/DEVICE/LAN/service checks.
    source = (ROOT / 'aether-proxy/files/aether-proxy.hotplug').read_text()
    imports = {'. /lib/functions.sh', '. /lib/functions/procd.sh'}
    assert sum(line in imports for line in source.splitlines()) == 2
    hook_script = t / 'hotplug.test.sh'
    hook_script.write_text('#!/bin/sh\nconfig_load() { :; }\n'
                           'config_get_bool() { eval "$1=0"; }\n' +
                           '\n'.join(line for line in source.splitlines() if line not in imports) + '\n')
    for action in ('ifup', 'ifupdate'):
        calls, gate, done = (t / (action + suffix) for suffix in ('.calls', '.gate', '.done'))
        gate.touch()
        env = {**os.environ, 'ACTION': action, 'DEVICE': 'pppoe-wan', 'HOOK_CALLS': str(calls),
               'HOOK_GATE': str(gate), 'HOOK_DONE': str(done),
               'PATH': str(hook_bin) + ':' + os.environ['PATH']}
        output, errors = t / (action + '.stdout'), t / (action + '.stderr')
        with output.open('w') as stdout, errors.open('w') as stderr:
            hook = subprocess.Popen(['sh', str(hook_script)], env=env, stdout=stdout, stderr=stderr)
            try:
                check(f'hotplug {action} returns while sync-wan is blocked', hook.wait(timeout=3) == 0)
            finally:
                gate.unlink()
                if hook.poll() is None:
                    hook.kill()
                    hook.wait()
        deadline = time.monotonic() + 3
        while not done.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        check(f'hotplug {action} calls sync-wan exactly once in background',
              done.exists() and calls.read_text() == 'dns sync-wan\n')
        check(f'hotplug {action} suppresses background stdout and stderr',
              output.read_text() == '' and errors.read_text() == '')
    makefile = (ROOT / 'aether-proxy/Makefile').read_text()
    check('package installs hotplug as 90-aether-proxy',
          './files/aether-proxy.hotplug $(1)/etc/hotplug.d/iface/90-aether-proxy' in makefile)


def run_suite(t):
    def put(path, text, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    conf = t / 'conf'
    baseline = t / 'baseline'
    run = t / 'run'
    root = t / 'sysroot'
    bin_dir = t / 'bin'
    for path in (conf, baseline, run, bin_dir, t / 'data', t / 'custom'):
        path.mkdir()
    for path in (ROOT / 'tests/stubs/daemon-bin').iterdir():
        shutil.copy2(path, bin_dir / path.name)
    for name in ('gfwlist', 'chnlist', 'apple'):
        put(baseline / (name + '.txt'), 'example.com\n')
    put(baseline / 'chnroute4.txt', '1.0.0.0/8\n')
    put(baseline / 'gfw_static4.txt', '91.108.4.0/22\n')
    calls = t / 'ubus.calls'
    reply = t / 'reply.json'
    reload_calls = t / 'reload.calls'
    env = {**os.environ, 'WAN_DNS_CALLS': str(calls), 'WAN_DNS_REPLY': str(reply),
           'WAN_DNS_MODE': 'ok', 'WAN_RELOAD_CALLS': str(reload_calls),
           'PATH': str(bin_dir) + ':' + os.environ['PATH']}
    # A reload request is observed without touching the host's init service. When testing
    # the real daemon below, this substitute delivers exactly the requested SIGHUP.
    put(root / 'etc/init.d/aether-proxy', '''#!/bin/sh
printf '%s\n' "$*" >> "$WAN_RELOAD_CALLS"
if [ "${WAN_RELOAD_RC:-0}" != 0 ]; then exit "$WAN_RELOAD_RC"; fi
if [ -n "${WAN_DAEMON_PID:-}" ]; then kill -HUP "$WAN_DAEMON_PID"; fi
''', True)
    options = ['--confdir', str(conf), '--data-dir', str(t / 'data'),
               '--baseline-dir', str(baseline), '--custom-dir', str(t / 'custom'),
               '--run-dir', str(run), '--sys-root', str(root), '--bin-dir', str(bin_dir)]

    def ap(*args, extra_env=None, extra_options=(), expected=0):
        selected = options
        if args[0] == 'status':
            selected = [value for i in range(0, len(options), 2)
                        if options[i] in ('--confdir', '--run-dir', '--sys-root', '--bin-dir')
                        for value in options[i:i + 2]]
        result = subprocess.run([str(UCODE), '-S', str(ENTRY), '--', *args, *selected, *extra_options, '--json'],
                                env={**env, **(extra_env or {})}, text=True, capture_output=True, timeout=20)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        assert not result.stderr, (args, result.stderr)
        return json.loads(result.stdout)

    def pipeline():
        result = subprocess.run([str(UCODE), str(ROOT / 'tests/cli/wan-dns.uc'), '--', *options],
                                env=env, text=True, capture_output=True, timeout=10)
        assert result.returncode == 0 and not result.stderr, (result.stdout, result.stderr)
        return json.loads(result.stdout)

    def config(entries=None, enabled=False):
        text = (ROOT / 'tests/fixtures/sample/aetherproxy').read_text() if enabled else "config global 'main'\n"
        if entries is not None:
            text += "\nconfig dns 'dns'\n" + ''.join(f"\tlist china_dns '{entry}'\n" for entry in entries)
        put(conf / 'aetherproxy', text)

    def dump(interfaces):
        # Publish atomically: the daemon may read the reply while its monitor is active.
        tmp = reply.with_suffix('.tmp')
        put(tmp, json.dumps({'interface': interfaces}))
        tmp.replace(reply)

    def count(path):
        return len(path.read_text().splitlines()) if path.exists() else 0

    def no_events():
        return not (run / 'events.jsonl').exists()

    test_hotplug(t)
    shutil.copy2(ROOT / 'aether-proxy/files/aether-proxy.config', conf / 'aetherproxy')
    packaged = (conf / 'aetherproxy').read_text()
    check('packaged default china_dns is wan plus 114',
          [line.strip() for line in packaged.splitlines() if 'list china_dns ' in line] ==
          ["list china_dns 'wan'", "list china_dns '114.114.114.114'"])
    config()
    dump([interface('wan', ISP), interface('lan', ['192.168.1.1'], False)])
    built = pipeline()
    check('pipeline read selects WAN default route and excludes LAN',
          built['wan_dns'] == ISP and built['snapshot']['dns']['china_dns'] == ISP + [PUBLIC])
    china = ','.join(ISP + [PUBLIC])
    text = built['artifacts']['chinadns']
    check('china udirect and T3 all use expanded DNS',
          f'china-dns {china}\n' in text and f'trust-dns {china}\n' in text and
          f'group udirect\ngroup-dnl {t}/custom/direct_domain.txt\ngroup-upstream {china}\n' in text)
    check('render chinadns expands WAN DNS', f'china-dns {china}\n' in ap('render', 'chinadns')['content'])
    checked = ap('check', '--no-precheck')
    check('check accepts wan and completes rendering', checked['ok'])
    dump([interface('wan', ISP + [PUBLIC])])
    check('pipeline deduplicates ISP 114 against configured 114',
          pipeline()['snapshot']['dns']['china_dns'] == ISP + [PUBLIC])
    for mode in ('fail', 'timeout', 'invalid', 'ipv6', 'empty'):
        env['WAN_DNS_MODE'] = mode if mode in ('fail', 'timeout', 'invalid') else 'ok'
        dump([interface('wan', ['2001:db8::53'])] if mode == 'ipv6' else [])
        started = time.monotonic()
        built = pipeline()
        elapsed = time.monotonic() - started
        check(mode + ' uses fallback with empty observation and no events',
              built['wan_dns'] == [] and built['snapshot']['dns']['china_dns'] == [FALLBACK, PUBLIC]
              and no_events())
        if mode == 'timeout':
            check('ubus timeout bounded at three seconds', 2.8 <= elapsed < 4.8)
    env['WAN_DNS_MODE'] = 'ok'
    config([FALLBACK, PUBLIC])
    before = count(calls)
    built = pipeline()
    check('explicit china_dns never calls ubus and records null WAN',
          built['wan_dns'] is None and count(calls) == before)

    # sync-wan's decisions are independent of action/device names and do not rewrite state.
    state_path = run / 'state.json'
    config()
    dump([interface('wan', ISP)])
    for state in ('starting', 'running', 'degraded', 'failsafe'):
        put(state_path, json.dumps({'state': state, 'wan_dns': []}))
        before = count(reload_calls)
        value = ap('dns', 'sync-wan')
        check(f'sync {state} changed sends one reload',
              value == {'ok': True, 'wan_dns': ISP, 'reload': True} and count(reload_calls) == before + 1
              and json.loads(state_path.read_text())['wan_dns'] == [])
    put(state_path, json.dumps({'state': 'running', 'wan_dns': []}))
    before = count(reload_calls)
    value = ap('dns', 'sync-wan', extra_env={'WAN_DNS_MODE': 'fail'})
    check('sync unavailable WAN compares empty observation without reload or events',
          value == {'ok': True, 'wan_dns': [], 'reload': False} and count(reload_calls) == before
          and no_events())
    put(state_path, json.dumps({'state': 'running', 'wan_dns': ISP}))
    before = count(reload_calls)
    check('sync unchanged sends no reload', not ap('dns', 'sync-wan')['reload'] and count(reload_calls) == before)
    for state in ('stopped', 'error'):
        put(state_path, json.dumps({'state': state, 'wan_dns': []}))
        queries = count(calls)
        check(f'sync {state} skips query and reload',
              not ap('dns', 'sync-wan')['reload'] and count(calls) == queries and count(reload_calls) == before)
    state_path.unlink()
    check('sync missing state is stopped', not ap('dns', 'sync-wan')['reload'])
    put(state_path, '{broken')
    queries = count(calls)
    check('sync corrupt state refuses query and reload',
          ap('dns', 'sync-wan', expected=1)['code'] == 'FS_FAILED' and
          count(calls) == queries and count(reload_calls) == before)
    config([FALLBACK, PUBLIC])
    check('sync without wan skips even corrupt state and ubus',
          ap('dns', 'sync-wan') == {'ok': True, 'wan_dns': None, 'reload': False} and count(calls) == queries)
    config()
    put(state_path, json.dumps({'state': 'running', 'wan_dns': []}))
    check('sync reload command failure is reported',
          ap('dns', 'sync-wan', extra_env={'WAN_RELOAD_RC': '7'}, expected=1)['code'] == 'CMD_FAILED')
    check('sync rejects unexpected arguments', ap('dns', 'unknown', expected=2)['code'] == 'USAGE')

    # Real startup and incremental reload: only the supervised binaries are substituted.
    config(enabled=True)
    dump([])
    daemon_run = root / 'var/run/aether-proxy'
    for path in ('var/etc', 'tmp/dnsmasq.d', 'proc/net', 'sys/class/net/br-lan',
                 'etc/aether-proxy/state', 'var/lock', 'var/run/aether-proxy'):
        (root / path).mkdir(parents=True, exist_ok=True)
    put(root / 'var/etc/dnsmasq.conf.test', 'interface=br-lan\nconf-dir=/tmp/dnsmasq.d,*.conf\n')
    put(root / 'etc/init.d/dnsmasq', '#!/bin/sh\nprintf "dnsmasq %s\\n" "$*" >> "$STUB_LOG"\n', True)
    put(root / 'proc/net/tcp', '  0: 0100007F:794D 00000000:0000 0A 0 0 0\n')
    for name in ('ip-rules', 'ip-routes', 'conflicts'):
        put(root / name, '')
    put(root / 'curl-count', '0\n')
    stub_log = t / 'daemon.calls'
    daemon_env = {**env, 'SYSROOT': str(root), 'STUB_LOG': str(stub_log),
                  'STUB_CURL_COUNT_FILE': str(root / 'curl-count'),
                  'AETHER_PROXY_TEST_LOGFILTER': str(ROOT / 'aether-proxy/files/aether-proxy-logfilter.awk')}
    daemon_options = options.copy()
    offset = daemon_options.index('--run-dir')
    del daemon_options[offset:offset + 2]
    stdout = (t / 'daemon.stdout').open('w')
    stderr = (t / 'daemon.stderr').open('w')
    daemon = subprocess.Popen([str(UCODE), '-S', str(ENTRY), '--', 'daemon', *daemon_options],
                              env=daemon_env, stdout=stdout, stderr=stderr)
    applied = daemon_run / 'state.json'

    def state_now():
        return json.loads(applied.read_text()) if applied.exists() else {}

    def wait_for(predicate):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if daemon.poll() is not None:
                raise AssertionError('daemon exited: ' + (t / 'daemon.stderr').read_text())
            if predicate():
                return
            time.sleep(0.05)
        raise AssertionError('daemon timeout: ' + (t / 'daemon.stderr').read_text())

    def child_starts():
        text = (root / 'calls.log').read_text()
        return text.count('chinadns-ng -C '), text.count('xray run -c ')

    try:
        wait_for(lambda: state_now().get('state') == 'running')
        check('daemon startup records fallback observation []', state_now().get('wan_dns') == [])
        check('daemon startup publishes fallback DNS',
              f'china-dns {FALLBACK},{PUBLIC}\n' in (daemon_run / 'current/chinadns.conf').read_text())
        sync_env = {'WAN_DAEMON_PID': str(daemon.pid)}
        # Explicit --run-dir overrides the earlier CLI scratch directory.
        def sync_daemon():
            return ap('dns', 'sync-wan', extra_options=['--run-dir', str(daemon_run)], extra_env=sync_env)

        starts = child_starts()
        dump([interface('wan', [FALLBACK])])
        check('same fallback address still requests metadata reload', sync_daemon()['reload'])
        wait_for(lambda: state_now().get('wan_dns') == [FALLBACK])
        check('no-op reload updates wan_dns without restarting components', child_starts() == starts)
        dump([interface('wan', ISP)])
        check('WAN arrival requests daemon reload', sync_daemon()['reload'])
        wait_for(lambda: state_now().get('wan_dns') == ISP)
        check('changed WAN restarts only chinadns', child_starts() == (starts[0] + 1, starts[1]))
        text = (daemon_run / 'current/chinadns.conf').read_text()
        check('reload publishes actual ISP DNS and status exposes wan_dns',
              f'china-dns {china}\n' in text and
              ap('status', extra_options=['--run-dir', str(daemon_run)])['wan_dns'] == ISP)
        before = count(reload_calls)
        check('post-commit sync does not reload twice',
              not sync_daemon()['reload'] and count(reload_calls) == before)
        config(ISP + [PUBLIC], enabled=True)
        queries = count(calls)
        daemon.send_signal(signal.SIGHUP)
        wait_for(lambda: state_now().get('wan_dns', 'missing') is None)
        check('explicit DNS reload records null without ubus or component restart',
              count(calls) == queries and child_starts() == (starts[0] + 1, starts[1]))

        daemon.terminate()
        daemon.wait(timeout=20)
        check('first daemon shuts down cleanly', daemon.returncode == 0)
        config(enabled=True)
        once = t / 'first-reply.json'
        put(once, '{"interface":[]}')
        daemon_env['WAN_DNS_ONCE_REPLY'] = str(once)
        daemon = subprocess.Popen([str(UCODE), '-S', str(ENTRY), '--', 'daemon', *daemon_options],
                                  env=daemon_env, stdout=stdout, stderr=stderr)
        wait_for(lambda: state_now().get('state') == 'running')
        check('WAN arrival during startup records the published observation',
              not once.exists() and state_now().get('wan_dns') == ISP)
        check('first monitor tick retains published WAN DNS instead of stale precheck snapshot',
              f'china-dns {china}\n' in (daemon_run / 'current/chinadns.conf').read_text())
    finally:
        if daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=20)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait()
                raise
        stdout.close()
        stderr.close()
    check('daemon shuts down cleanly', daemon.returncode == 0)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='.wan-dns-', dir=ROOT / 'tests/cli') as temporary:
        run_suite(Path(temporary))
